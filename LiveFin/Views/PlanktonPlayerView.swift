//
//  PlanktonPlayerView.swift
//  LiveFin
//
//  Created by KPGamingz on 5/23/26.
//

import SwiftUI
import AVKit
import Combine
import MediaPlayer

// MARK: - ViewModel

@MainActor
final class PlanktonPlayerViewModel: ObservableObject {
    let player = AVPlayer()
    
    @Published var playlist: [JFItemDto]
    @Published var currentIndex: Int
    @Published var seriesName: String?
    
    @Published var controlsVisible: Bool = true
    @Published var isPlaying: Bool = true
    @Published var isBuffering: Bool = true
    @Published var isPiPActive: Bool = false
    @Published var isCCEnabled: Bool = false
    
    // Scrubber State
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var isScrubbing: Bool = false
    
    let appState: AppState
    @Published var streamURL: URL? = nil
    
    var onFinishedPlaylist: (() -> Void)?
    
    private var timeObserver: Any?
    private var itemStatusObserver: NSKeyValueObservation?
    private var bufferingObserver: NSKeyValueObservation?
    private var cancellables = Set<AnyCancellable>()
    
    private var hasResumedCurrentItem = false
    private var lastReportedTicks: Int64 = 0

    init(playlist: [JFItemDto], startIndex: Int, seriesName: String?, appState: AppState) {
        self.playlist = playlist
        self.currentIndex = startIndex
        self.seriesName = seriesName
        self.appState = appState
        
        self.player.automaticallyWaitsToMinimizeStalling = false
        
        if #available(iOS 15.0, *) {
            self.player.audiovisualBackgroundPlaybackPolicy = .continuesIfPossible
        }
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(playerItemDidFinishPlaying),
            name: .AVPlayerItemDidPlayToEndTime,
            object: nil
        )
        
        loadItem(at: currentIndex)
        setupRemoteCommands()
    }
    
    func cleanup() {
        if let obs = timeObserver {
            player.removeTimeObserver(obs)
            timeObserver = nil
        }
        itemStatusObserver?.invalidate()
        bufferingObserver?.invalidate()
        NotificationCenter.default.removeObserver(self)
        UIApplication.shared.endReceivingRemoteControlEvents()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
    }
    
    var currentItem: JFItemDto? {
        guard playlist.indices.contains(currentIndex) else { return nil }
        return playlist[currentIndex]
    }
    
    // MARK: - Playback Logic
    
    func loadItem(at index: Int) {
        guard playlist.indices.contains(index) else {
            cleanup()
            onFinishedPlaylist?()
            return
        }
        
        let item = playlist[index]
        self.hasResumedCurrentItem = false
        self.isBuffering = true
        self.currentTime = 0
        self.duration = 0
        
        Task {
            let base = appState.serverURL.hasSuffix("/") ? String(appState.serverURL.dropLast()) : appState.serverURL
            
            do {
                // FIX: Use PlaybackInfoService to correctly negotiate Direct Play vs Transcoding URLs with Jellyfin
                let (_, turl, _, _) = try await JFPlaybackInfoService.fetchPlaybackInfoWithTranscodingUrl(
                    itemId: item.Id,
                    userId: appState.userID,
                    serverURL: appState.serverURL,
                    accessToken: appState.accessToken,
                    deviceId: appState.deviceId,
                    deviceName: appState.clientDevice,
                    clientVersion: appState.clientVersion,
                    enableDirectPlay: true,
                    enableDirectStream: true,
                    enableTranscoding: true,
                    debug: true
                )
                
                let finalUrlString: String
                if let turl = turl, !turl.isEmpty {
                    if turl.hasPrefix("http") {
                        finalUrlString = turl
                    } else {
                        finalUrlString = base + (turl.hasPrefix("/") ? turl : "/\(turl)")
                    }
                } else {
                    finalUrlString = "\(base)/Videos/\(item.Id)/stream.mp4?Static=true"
                }
                
                var urlToPlay = finalUrlString
                if !urlToPlay.contains("api_key=") && !urlToPlay.contains("api_key") && !urlToPlay.contains("ApiKey") {
                    let separator = urlToPlay.contains("?") ? "&" : "?"
                    urlToPlay += "\(separator)api_key=\(appState.accessToken)"
                }
                
                guard let url = URL(string: urlToPlay) else { return }
                
                await MainActor.run {
                    self.streamURL = url
                    
                    // FIX: Ensure Audio Session bypasses physical ringer switch explicitly right before playback starts
                    do {
                        try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, options: [])
                        try AVAudioSession.sharedInstance().setActive(true)
                    } catch {
                        print("Failed to set audio session category: \(error)")
                    }
                    
                    let userAgent = "LiveFin iOS/\(appState.clientVersion)"
                    var headers: [String: String] = ["User-Agent": userAgent]
                    headers["X-Emby-Token"] = appState.accessToken
                    headers["X-Emby-User-Id"] = appState.userID
                    
                    let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
                    let playerItem = AVPlayerItem(asset: asset)
                    
                    self.observeItem(playerItem)
                    self.player.replaceCurrentItem(with: playerItem)
                    self.player.play()
                    self.isPlaying = true
                    
                    self.updateNowPlayingInfo()
                    self.appState.reportPlaybackStart(itemId: item.Id, canSeek: true)
                }
            } catch {
                print("PlaybackInfo fetch failed: \(error)")
                await MainActor.run {
                    self.isBuffering = false
                }
            }
        }
    }
    
    private func observeItem(_ item: AVPlayerItem) {
        if let obs = timeObserver {
            player.removeTimeObserver(obs)
            timeObserver = nil
        }
        itemStatusObserver?.invalidate()
        bufferingObserver?.invalidate()
        
        bufferingObserver = item.observe(\.isPlaybackBufferEmpty, options: [.new]) { [weak self] observedItem, _ in
            DispatchQueue.main.async { self?.isBuffering = observedItem.isPlaybackBufferEmpty }
        }
        
        itemStatusObserver = item.observe(\.status, options: [.new]) { [weak self] observedItem, _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                
                if observedItem.status == .readyToPlay {
                    self.duration = observedItem.duration.seconds.isNaN ? 0 : observedItem.duration.seconds
                    self.isBuffering = false
                    
                    if !self.hasResumedCurrentItem {
                        self.hasResumedCurrentItem = true
                        if let ticks = self.currentItem?.UserData?.PlaybackPositionTicks, ticks > 0 {
                            let secondsToResume = Double(ticks) / 10_000_000.0
                            if secondsToResume < self.duration * 0.95 {
                                self.seek(to: secondsToResume)
                            }
                        }
                    }
                }
            }
        }
        
        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self = self, let currentItem = self.currentItem else { return }
            
            if !self.isScrubbing {
                self.currentTime = time.seconds
            }
            
            let ticks = Int64(time.seconds * 10_000_000)
            if abs(ticks - self.lastReportedTicks) > 100_000_000 {
                self.lastReportedTicks = ticks
                Task {
                    self.appState.reportPlaybackProgress(itemId: currentItem.Id, positionTicks: ticks, canSeek: true, isPaused: !self.isPlaying)
                }
            }
        }
    }
    
    @objc private func playerItemDidFinishPlaying(notification: NSNotification) {
        guard let finishedItem = notification.object as? AVPlayerItem,
              finishedItem == player.currentItem,
              let currentItem = currentItem else { return }
        
        let totalTicks = Int64(duration * 10_000_000)
        appState.reportPlaybackStopped(itemId: currentItem.Id, positionTicks: totalTicks)
        
        if currentIndex + 1 < playlist.count {
            currentIndex += 1
            loadItem(at: currentIndex)
        } else {
            cleanup()
            onFinishedPlaylist?()
        }
    }
    
    func togglePlayPause() {
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            player.play()
            isPlaying = true
        }
        if let id = currentItem?.Id {
            let ticks = Int64(currentTime * 10_000_000)
            appState.reportPlaybackProgress(itemId: id, positionTicks: ticks, canSeek: true, isPaused: !isPlaying)
        }
    }
    
    func skipForward() {
        let newTime = min(currentTime + 15, duration)
        seek(to: newTime)
    }
    
    func skipBackward() {
        let newTime = max(currentTime - 15, 0)
        seek(to: newTime)
    }
    
    func seek(to seconds: Double) {
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
    }
    
    func stopAndDismiss() {
        if let id = currentItem?.Id {
            appState.reportPlaybackStopped(itemId: id, positionTicks: Int64(currentTime * 10_000_000))
        }
        cleanup()
        onFinishedPlaylist?()
    }
    
    // MARK: - Now Playing
    
    private func updateNowPlayingInfo() {
        guard let item = currentItem else { return }
        
        let title = seriesName ?? item.Name
        let subtitle = seriesName != nil ? item.Name : ""
        
        var nowPlaying = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        nowPlaying[MPMediaItemPropertyTitle] = title
        if !subtitle.isEmpty {
            nowPlaying[MPMediaItemPropertyArtist] = subtitle
        }
        nowPlaying[MPNowPlayingInfoPropertyPlaybackRate] = 1.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlaying
        
        let base = appState.serverURL.hasSuffix("/") ? String(appState.serverURL.dropLast()) : appState.serverURL
        
        if seriesName != nil {
            guard let url = URL(string: "\(base)/Users/\(appState.userID)/Items/\(item.Id)?Fields=SeriesThumbImageTag,SeriesPrimaryImageTag") else { return }
            var req = URLRequest(url: url)
            req.setValue(appState.accessToken, forHTTPHeaderField: "X-Emby-Token")
            
            URLSession.shared.dataTask(with: req) { data, _, _ in
                guard let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    self.setFallbackArtwork(item: item, base: base)
                    return
                }
                
                // FIX: Strictly prioritize 'Thumb' for 16:9 Now Playing display
                if let seriesId = json["SeriesId"] as? String, let seriesThumb = json["SeriesThumbImageTag"] as? String {
                    self.fetchAndSetNowPlayingArtwork(itemId: seriesId, imageType: "Thumb", tag: seriesThumb, base: base)
                } else {
                    self.setFallbackArtwork(item: item, base: base)
                }
            }.resume()
        } else {
            setFallbackArtwork(item: item, base: base)
        }
    }
    
    private func setFallbackArtwork(item: JFItemDto, base: String) {
        if let thumb = item.ImageTags?["Thumb"] {
            fetchAndSetNowPlayingArtwork(itemId: item.Id, imageType: "Thumb", tag: thumb, base: base)
        } else if let backdrop = item.backdropImageTag {
            fetchAndSetNowPlayingArtwork(itemId: item.Id, imageType: "Backdrop/0", tag: backdrop, base: base)
        } else if let primary = item.primaryImageTag {
            fetchAndSetNowPlayingArtwork(itemId: item.Id, imageType: "Primary", tag: primary, base: base)
        }
    }
    
    private func fetchAndSetNowPlayingArtwork(itemId: String, imageType: String, tag: String, base: String) {
        guard let url = URL(string: "\(base)/Items/\(itemId)/Images/\(imageType)?tag=\(tag)&maxWidth=800") else { return }
        
        URLSession.shared.dataTask(with: url) { data, _, _ in
            guard let data = data, let image = UIImage(data: data) else { return }
            DispatchQueue.main.async {
                var np = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
                np[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                MPNowPlayingInfoCenter.default().nowPlayingInfo = np
            }
        }.resume()
    }
    
    private func setupRemoteCommands() {
        UIApplication.shared.beginReceivingRemoteControlEvents()
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in self?.togglePlayPause(); return .success }
        center.pauseCommand.addTarget { [weak self] _ in self?.togglePlayPause(); return .success }
        center.skipForwardCommand.addTarget { [weak self] _ in self?.skipForward(); return .success }
        center.skipBackwardCommand.addTarget { [weak self] _ in self?.skipBackward(); return .success }
    }
}

// MARK: - Views

struct PlanktonPlayerView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var appState: AppState
    @StateObject private var vm: PlanktonPlayerViewModel
    @State private var playerController: DragonetPlayerController?
    
    init(playlist: [JFItemDto], startIndex: Int, seriesName: String?, appState: AppState) {
        AppDelegate.orientationLock = .landscape
        _vm = StateObject(wrappedValue: PlanktonPlayerViewModel(playlist: playlist, startIndex: startIndex, seriesName: seriesName, appState: appState))
    }
    
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            if let url = vm.streamURL {
                DragonetPlayer(
                    player: vm.player,
                    streamURL: url,
                    isPiPActive: $vm.isPiPActive,
                    isCCEnabled: $vm.isCCEnabled,
                    controlsVisible: $vm.controlsVisible,
                    onPlaybackError: { _ in }
                ) { vc in
                    vc.onTap = {
                        withAnimation(.easeOut(duration: 0.2)) { vm.controlsVisible.toggle() }
                        if vm.controlsVisible { vc.resetAutoHideTimer() }
                    }
                    vc.onAutoHide = {
                        withAnimation(.easeOut(duration: 0.4)) { vm.controlsVisible = false }
                    }
                    playerController = vc
                    if vm.controlsVisible { vc.resetAutoHideTimer() }
                }
                .ignoresSafeArea()
            }
            
            if vm.isBuffering {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    .scaleEffect(2.0)
                    .allowsHitTesting(false)
            }
            
            controlsOverlay
                .opacity(vm.controlsVisible ? 1 : 0)
                .allowsHitTesting(vm.controlsVisible)
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .onAppear {
            vm.onFinishedPlaylist = {
                dismiss()
            }
            // Double check AVAudioSession on Appear to ensure view presentation didn't steal context
            do {
                try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, options: [])
                try AVAudioSession.sharedInstance().setActive(true)
            } catch {
                print("Failed to set audio session on Appear: \(error)")
            }
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
                    windowScene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscapeRight))
                }
            }
        }
        .onDisappear {
            vm.cleanup()
            AppDelegate.orientationLock = .portrait
            if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
                windowScene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait))
            }
        }
        .onChange(of: vm.controlsVisible) { visible in
            if visible { playerController?.resetAutoHideTimer() }
            else       { playerController?.cancelTimer() }
        }
    }
    
    // MARK: - Custom VOD Overlay
    
    private var controlsOverlay: some View {
        ZStack {
            VStack(spacing: 0) {
                LinearGradient(colors: [.black.opacity(0.85), .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: 160)
                Spacer()
                LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 160)
            }
            .ignoresSafeArea()
            
            VStack(spacing: 0) {
                // ── Top Action Bar ──
                HStack(alignment: .top) {
                    Button { vm.stopAndDismiss() } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .glassEffect(in: Circle())
                    }
                    
                    // FIX: Re-added image but properly formatted. 16:9 for Episodes, 2:3 for Movies.
                    if let item = vm.currentItem, let tag = item.primaryImageTag {
                        let base = appState.serverURL.hasSuffix("/") ? String(appState.serverURL.dropLast()) : appState.serverURL
                        if let url = URL(string: "\(base)/Items/\(item.Id)/Images/Primary?tag=\(tag)&maxWidth=300") {
                            AsyncImage(url: url) { phase in
                                if let image = phase.image {
                                    image.resizable().aspectRatio(contentMode: .fill)
                                } else {
                                    Color(UIColor.secondarySystemBackground)
                                }
                            }
                            .frame(width: vm.seriesName != nil ? 80 : 48, height: vm.seriesName != nil ? 45 : 72)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .shadow(radius: 4)
                            .padding(.leading, 12)
                        }
                    }
                    
                    VStack(alignment: .leading, spacing: 4) {
                        if let seriesName = vm.seriesName {
                            Text(seriesName).font(.title3.bold()).foregroundStyle(.white).shadow(radius: 2)
                            Text(vm.currentItem?.Name ?? "").font(.subheadline.weight(.medium)).foregroundStyle(.white.opacity(0.85)).shadow(radius: 2)
                        } else {
                            Text(vm.currentItem?.Name ?? "").font(.title3.bold()).foregroundStyle(.white).shadow(radius: 2)
                        }
                    }
                    .padding(.leading, 12)
                    .padding(.top, 2)
                    
                    Spacer()
                    
                    HStack(spacing: 12) {
                        Button {
                            vm.isCCEnabled.toggle()
                            playerController?.resetAutoHideTimer()
                        } label: {
                            Image(systemName: vm.isCCEnabled ? "captions.bubble.fill" : "captions.bubble")
                                .foregroundStyle(vm.isCCEnabled ? Color.blue : .white)
                                .font(.system(size: 18, weight: .medium))
                                .frame(width: 44, height: 44)
                        }
                        .glassEffect(in: Circle())
                        
                        Button {
                            NotificationCenter.default.post(name: .dragonetTogglePiP, object: nil)
                            playerController?.resetAutoHideTimer()
                        } label: {
                            Image(systemName: vm.isPiPActive ? "rectangle.on.rectangle.slash" : "rectangle.on.rectangle")
                                .foregroundStyle(vm.isPiPActive ? Color.blue : .white)
                                .font(.system(size: 18, weight: .medium))
                                .frame(width: 44, height: 44)
                        }
                        .glassEffect(in: Circle())
                        
                        DragonetAirPlayButton()
                            .frame(width: 44, height: 44)
                            .glassEffect(in: Circle())
                    }
                }
                .padding(.top, 16)
                .padding(.horizontal, 32)
                .safeAreaPadding(.horizontal)
                .safeAreaPadding(.top)
                
                Spacer()
                
                // ── Center Controls ──
                HStack(spacing: 40) {
                    Button {
                        vm.skipBackward()
                        playerController?.resetAutoHideTimer()
                    } label: {
                        Image(systemName: "gobackward.15")
                            .font(.system(size: 36, weight: .regular))
                            .foregroundStyle(.white)
                    }
                    
                    Button {
                        vm.togglePlayPause()
                        playerController?.resetAutoHideTimer()
                    } label: {
                        Image(systemName: vm.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 48, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 80, height: 80)
                            .glassEffect(in: Circle())
                    }
                    
                    Button {
                        vm.skipForward()
                        playerController?.resetAutoHideTimer()
                    } label: {
                        Image(systemName: "goforward.15")
                            .font(.system(size: 36, weight: .regular))
                            .foregroundStyle(.white)
                    }
                }
                
                Spacer()
                
                // ── Scrubber Bottom Bar ──
                HStack(spacing: 16) {
                    Text(formatTime(vm.currentTime))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.white)
                        .frame(width: 50, alignment: .trailing)
                    
                    Slider(value: $vm.currentTime, in: 0...max(vm.duration, 1)) { editing in
                        vm.isScrubbing = editing
                        if editing {
                            playerController?.cancelTimer()
                        } else {
                            vm.seek(to: vm.currentTime)
                            playerController?.resetAutoHideTimer()
                        }
                    }
                    .tint(.white)
                    
                    Text(formatTime(max(vm.duration - vm.currentTime, 0)))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.7))
                        .frame(width: 50, alignment: .leading)
                }
                .padding(.bottom, 24)
                .padding(.horizontal, 32)
                .safeAreaPadding(.horizontal)
                .safeAreaPadding(.bottom)
            }
        }
    }
    
    private func formatTime(_ seconds: Double) -> String {
        guard !seconds.isNaN && !seconds.isInfinite else { return "0:00" }
        let totalSeconds = Int(seconds)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let secs = totalSeconds % 60
        
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        } else {
            return String(format: "%d:%02d", minutes, secs)
        }
    }
}
