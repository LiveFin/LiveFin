//
//  PlanktonPlayerView.swift
//  LiveFin
//
//  Created by KPGamingz on 5/23/26.
//

import SwiftUI
import AVKit
import AVFoundation
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
    
    // Audio and Subtitle Tracks
    @Published var availableAudioTracks: [AVMediaSelectionOption] = []
    @Published var selectedAudioTrack: AVMediaSelectionOption? = nil
    
    @Published var availableSubtitleTracks: [AVMediaSelectionOption] = []
    @Published var selectedSubtitleTrack: AVMediaSelectionOption? = nil
    
    // Scrubber State
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var isScrubbing: Bool = false
    
    let appState: AppState
    @Published var streamURL: URL? = nil
    
    var onFinishedPlaylist: (() -> Void)?
    
    private var timeObserver: Any?
    private var itemStatusObserver: NSKeyValueObservation?
    private var playbackStateObserver: NSKeyValueObservation?
    private var cancellables = Set<AnyCancellable>()
    
    private var hasResumedCurrentItem = false
    private var lastReportedTicks: Int64 = 0
    
    // Local dictionary cache to prevent Apple's MPNowPlayingInfoCenter from returning nil/wiping out items
    private var nowPlayingInfo: [String: Any] = [:]

    init(playlist: [JFItemDto], startIndex: Int, seriesName: String?, appState: AppState) {
        self.playlist = playlist
        self.currentIndex = startIndex
        self.seriesName = seriesName
        self.appState = appState
        
        self.player.automaticallyWaitsToMinimizeStalling = true
        
        if #available(iOS 15.0, *) {
            self.player.audiovisualBackgroundPlaybackPolicy = .continuesIfPossible
        }
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(playerItemDidFinishPlaying),
            name: .AVPlayerItemDidPlayToEndTime,
            object: nil
        )
        
        setupPlaybackStateObserver()
        loadItem(at: currentIndex)
        setupRemoteCommands()
    }
    
    func cleanup() {
        if let obs = timeObserver {
            player.removeTimeObserver(obs)
            timeObserver = nil
        }
        itemStatusObserver?.invalidate()
        playbackStateObserver?.invalidate()
        NotificationCenter.default.removeObserver(self)
        
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.removeTarget(nil)
        center.pauseCommand.removeTarget(nil)
        center.skipForwardCommand.removeTarget(nil)
        center.skipBackwardCommand.removeTarget(nil)
        center.changePlaybackPositionCommand.removeTarget(nil)
        
        UIApplication.shared.endReceivingRemoteControlEvents()
        
        nowPlayingInfo.removeAll()
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
        
        self.availableAudioTracks = []
        self.selectedAudioTrack = nil
        self.availableSubtitleTracks = []
        self.selectedSubtitleTrack = nil
        
        Task {
            let base = appState.serverURL.hasSuffix("/") ? String(appState.serverURL.dropLast()) : appState.serverURL
            
            do {
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
                    // EXPLICITLY request HEVC here to avoid server dropping HDR via unexpected H264 transcodes
                    audioCodec: "aac,ac3,eac3,mp3,alac,flac",
                    videoCodec: "hevc,h265,h264",
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
                    
                    Task.detached { @MainActor in
                        do {
                            try AVAudioSession.sharedInstance().setCategory(
                                .playback,
                                mode: .moviePlayback,
                                policy: .longFormVideo,
                                options: []
                            )
                            try await AVAudioSession.sharedInstance().setActive(true)
                        } catch {
                            print("Failed to set audio session category/activate: \(error)")
                        }
                    }
                    
                    let userAgent = "LiveFin iOS/\(appState.clientVersion)"
                    var headers: [String: String] = ["User-Agent": userAgent]
                    headers["X-Emby-Token"] = appState.accessToken
                    headers["X-Emby-User-Id"] = appState.userID
                    
                    let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
                    let playerItem = AVPlayerItem(asset: asset)
                    
                    if #available(iOS 15.0, *) {
                        Task {
                            _ = try? await asset.load(.duration)
                            _ = try? await asset.loadMediaSelectionGroup(for: .legible)
                        }
                    }
                    
                    self.observeItem(playerItem)
                    self.player.replaceCurrentItem(with: playerItem)
                    self.player.play()
                    
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
        
        itemStatusObserver = item.observe(\.status, options: [.new]) { [weak self] observedItem, _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                
                if observedItem.status == .readyToPlay {
                    self.duration = observedItem.duration.seconds.isNaN ? 0 : observedItem.duration.seconds
                    
                    self.populateMediaSelectionTracks(for: observedItem)
                    self.updateNowPlayingPlaybackState()
                    
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
    
    // MARK: - Core Playback State Observer
    
    private func setupPlaybackStateObserver() {
        playbackStateObserver = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
            guard let self = self else { return }
            let status = player.timeControlStatus
            
            DispatchQueue.main.async {
                self.isBuffering = (status == .waitingToPlayAtSpecifiedRate)
                if status == .playing { self.isPlaying = true }
                if status == .paused { self.isPlaying = false }
                
                self.updateNowPlayingPlaybackState()
            }
        }
    }
    
    @objc private func playerItemDidFinishPlaying(notification: NSNotification) {
        guard let finishedItem = notification.object as? AVPlayerItem,
              finishedItem == player.currentItem,
              let currentItem = currentItem else { return }
        
        let totalTicks = Int64(duration * 10_000_000)
        
        // BIND PLAY SESSION ID: Releases active VOD transcoding jobs immediately when finished
        let playSessionId = streamURL.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?
            .queryItems?.first(where: { $0.name.caseInsensitiveCompare("PlaySessionId") == .orderedSame })?.value
        appState.reportPlaybackStopped(itemId: currentItem.Id, positionTicks: totalTicks, playSessionId: playSessionId)
        
        if currentIndex + 1 < playlist.count {
            currentIndex += 1
            loadItem(at: currentIndex)
        } else {
            cleanup()
            onFinishedPlaylist?()
        }
    }
    
    func togglePlayPause() {
        if player.timeControlStatus == .paused {
            player.play()
        } else {
            player.pause()
        }
        
        if let id = currentItem?.Id {
            let ticks = Int64(currentTime * 10_000_000)
            let isPausedNow = (player.timeControlStatus == .paused)
            appState.reportPlaybackProgress(itemId: id, positionTicks: ticks, canSeek: true, isPaused: isPausedNow)
        }
    }
    
    func skipForward() {
        let newTime = min(currentTime + 10, duration)
        seek(to: newTime)
    }
    
    func skipBackward() {
        let newTime = max(currentTime - 10, 0)
        seek(to: newTime)
    }
    
    func seek(to seconds: Double) {
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600)) { [weak self] finished in
            if finished {
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    if self.isPlaying {
                        self.player.play()
                    }
                    self.updateNowPlayingPlaybackState()
                }
            }
        }
    }
    
    func stopAndDismiss() {
        if let id = currentItem?.Id {
            let ticks = Int64(currentTime * 10_000_000)
            
            // BIND PLAY SESSION ID: Releases active VOD transcoding jobs immediately when exiting
            let playSessionId = streamURL.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?
                .queryItems?.first(where: { $0.name.caseInsensitiveCompare("PlaySessionId") == .orderedSame })?.value
            appState.reportPlaybackStopped(itemId: id, positionTicks: ticks, playSessionId: playSessionId)
        }
        cleanup()
        onFinishedPlaylist?()
    }
    
    // MARK: - Track Selection Management
    
    private func populateMediaSelectionTracks(for playerItem: AVPlayerItem) {
        let asset = playerItem.asset
        
        if let audioGroup = asset.mediaSelectionGroup(forMediaCharacteristic: .audible) {
            self.availableAudioTracks = audioGroup.options
            self.selectedAudioTrack = playerItem.currentMediaSelection.selectedMediaOption(in: audioGroup)
        } else {
            self.availableAudioTracks = []
            self.selectedAudioTrack = nil
        }
        
        if let subtitleGroup = asset.mediaSelectionGroup(forMediaCharacteristic: .legible) {
            self.availableSubtitleTracks = subtitleGroup.options
            self.selectedSubtitleTrack = playerItem.currentMediaSelection.selectedMediaOption(in: subtitleGroup)
            self.isCCEnabled = (self.selectedSubtitleTrack != nil)
        } else {
            self.availableSubtitleTracks = []
            self.selectedSubtitleTrack = nil
            self.isCCEnabled = false
        }
    }
    
    func selectAudioTrack(_ option: AVMediaSelectionOption) {
        guard let playerItem = player.currentItem,
              let group = playerItem.asset.mediaSelectionGroup(forMediaCharacteristic: .audible) else {
            return
        }
        playerItem.select(option, in: group)
        self.selectedAudioTrack = option
        updateNowPlayingPlaybackState()
    }
    
    func selectSubtitleTrack(_ option: AVMediaSelectionOption?) {
        guard let playerItem = player.currentItem,
              let group = playerItem.asset.mediaSelectionGroup(forMediaCharacteristic: .legible) else {
            return
        }
        playerItem.select(option, in: group)
        self.selectedSubtitleTrack = option
        
        let desiredCCState = (option != nil)
        if self.isCCEnabled != desiredCCState {
            self.isCCEnabled = desiredCCState
        }
        updateNowPlayingPlaybackState()
    }
    
    func handleCCEnabledChanged(_ enabled: Bool) {
        if !enabled {
            if selectedSubtitleTrack != nil {
                selectSubtitleTrack(nil)
            }
        } else {
            if selectedSubtitleTrack == nil, let firstTrack = availableSubtitleTracks.first {
                selectSubtitleTrack(firstTrack)
            }
        }
    }
    
    // MARK: - Now Playing
    
    private func updateNowPlayingInfo() {
        guard let item = currentItem else { return }
        
        let isEpisode = item.Type.lowercased() == "episode"
        let activeSeriesName = seriesName ?? item.SeriesName
        
        let title: String
        let subtitle: String
        
        if isEpisode, let series = activeSeriesName, !series.isEmpty {
            title = series
            let s = item.ParentIndexNumber.map { String(format: "S%02d", $0) } ?? ""
            let e = item.IndexNumber.map { String(format: "E%02d", $0) } ?? ""
            let se = [s, e].filter { !$0.isEmpty }.joined()
            if !se.isEmpty {
                subtitle = "\(se) • \(item.Name)"
            } else {
                subtitle = item.Name
            }
        } else {
            title = item.Name
            subtitle = "" // Hide genres for movies as requested
        }
        
        nowPlayingInfo[MPMediaItemPropertyTitle] = title
        if !subtitle.isEmpty {
            nowPlayingInfo[MPMediaItemPropertyArtist] = subtitle
        } else {
            nowPlayingInfo.removeValue(forKey: MPMediaItemPropertyArtist)
        }
        nowPlayingInfo[MPNowPlayingInfoPropertyMediaType] = 2 // Lock Screen layout formats as Video Media
        
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
        updateNowPlayingPlaybackState()
        
        let base = appState.serverURL.hasSuffix("/") ? String(appState.serverURL.dropLast()) : appState.serverURL
        
        if isEpisode {
            guard let url = URL(string: "\(base)/Users/\(appState.userID)/Items/\(item.Id)") else { return }
            var req = URLRequest(url: url)
            req.setValue(appState.accessToken, forHTTPHeaderField: "X-Emby-Token")
            
            URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
                guard let self = self else { return }
                guard let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    self.setFallbackArtwork(item: item, base: base)
                    return
                }
                
                let seriesId = json["SeriesId"] as? String
                let parentThumbId = json["ParentThumbItemId"] as? String
                let thumbId = seriesId ?? parentThumbId
                let thumbTag = (json["ParentThumbImageTag"] as? String) ?? (json["SeriesThumbImageTag"] as? String)
                
                if let tId = thumbId, let tTag = thumbTag {
                    self.fetchAndSetNowPlayingArtwork(itemId: tId, imageType: "Thumb", tag: tTag, base: base)
                } else if let sId = seriesId {
                    // Fallback to querying the Series item explicitly since Jellyfin often omits Series image tags on episodes
                    guard let seriesUrl = URL(string: "\(base)/Users/\(self.appState.userID)/Items/\(sId)") else {
                        self.setFallbackArtwork(item: item, base: base)
                        return
                    }
                    var sReq = URLRequest(url: seriesUrl)
                    sReq.setValue(self.appState.accessToken, forHTTPHeaderField: "X-Emby-Token")
                    
                    URLSession.shared.dataTask(with: sReq) { sData, _, _ in
                        guard let sData = sData,
                              let sJson = try? JSONSerialization.jsonObject(with: sData) as? [String: Any],
                              let imageTags = sJson["ImageTags"] as? [String: String] else {
                            self.setFallbackArtwork(item: item, base: base)
                            return
                        }
                        
                        if let sThumb = imageTags["Thumb"] {
                            self.fetchAndSetNowPlayingArtwork(itemId: sId, imageType: "Thumb", tag: sThumb, base: base)
                        } else if let sBackdrop = (sJson["BackdropImageTags"] as? [String])?.first {
                            self.fetchAndSetNowPlayingArtwork(itemId: sId, imageType: "Backdrop/0", tag: sBackdrop, base: base)
                        } else if let sPrimary = imageTags["Primary"] {
                            self.fetchAndSetNowPlayingArtwork(itemId: sId, imageType: "Primary", tag: sPrimary, base: base)
                        } else {
                            self.setFallbackArtwork(item: item, base: base)
                        }
                    }.resume()
                } else {
                    self.setFallbackArtwork(item: item, base: base)
                }
            }.resume()
        } else {
            setFallbackArtwork(item: item, base: base)
        }
    }
    
    func updateNowPlayingPlaybackState() {
        guard currentItem != nil else { return }
        
        nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = duration
        nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
    }
    
    private func setFallbackArtwork(item: JFItemDto, base: String) {
        // Enforce fallback preference for landscape imagery before defaulting to Primary
        if let thumb = item.ImageTags?["Thumb"] {
            fetchAndSetNowPlayingArtwork(itemId: item.Id, imageType: "Thumb", tag: thumb, base: base)
        } else if let backdrop = item.backdropImageTag {
            fetchAndSetNowPlayingArtwork(itemId: item.Id, imageType: "Backdrop/0", tag: backdrop, base: base)
        } else if let primaryTag = item.primaryImageTag {
            fetchAndSetNowPlayingArtwork(itemId: item.Id, imageType: "Primary", tag: primaryTag, base: base)
        }
    }
    
    private func fetchAndSetNowPlayingArtwork(itemId: String, imageType: String, tag: String, base: String) {
        guard let url = URL(string: "\(base)/Items/\(itemId)/Images/\(imageType)?tag=\(tag)&maxWidth=800") else { return }
        
        var req = URLRequest(url: url)
        req.setValue(appState.accessToken, forHTTPHeaderField: "X-Emby-Token")
        
        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            guard let self = self else { return }
            guard let data = data, let image = UIImage(data: data) else { return }
            DispatchQueue.main.async {
                self.nowPlayingInfo[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                MPNowPlayingInfoCenter.default().nowPlayingInfo = self.nowPlayingInfo
                self.updateNowPlayingPlaybackState()
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
        
        center.changePlaybackPositionCommand.isEnabled = true
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self = self,
                  let positionEvent = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            let targetTime = positionEvent.positionTime
            self.seek(to: targetTime)
            self.currentTime = targetTime
            self.updateNowPlayingPlaybackState()
            return .success
        }
    }
}

// MARK: - PlanktonPlayerView

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
                    // Prevents AVPlayerViewController from automatically overwriting our robust local NowPlaying dictionary with empty MP4 header tags
                    vc.updatesNowPlayingInfoCenter = false
                    
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
            Task { @MainActor in
                do {
                    try AVAudioSession.sharedInstance().setCategory(
                        .playback,
                        mode: .moviePlayback,
                        policy: .longFormVideo,
                        options: []
                    )
                    try await AVAudioSession.sharedInstance().setActive(true)
                } catch {
                    print("Failed to set audio session on Appear: \(error)")
                }
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
        .onChange(of: vm.isCCEnabled) { enabled in
            vm.handleCCEnabledChanged(enabled)
        }
    }
    
    // MARK: - Custom VOD Overlay
    
    private var controlsOverlay: some View {
        ZStack {
            VStack(spacing: 0) {
                LinearGradient(colors: [.black.opacity(0.85), .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: 140)
                Spacer()
                LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 120)
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
                    
                    VStack(alignment: .leading, spacing: 4) {
                        let isEpisode = vm.currentItem?.Type.lowercased() == "episode"
                        let activeSeriesName = vm.seriesName ?? vm.currentItem?.SeriesName
                        
                        if isEpisode, let series = activeSeriesName, !series.isEmpty {
                            Text(series)
                                .font(.title3.bold())
                                .foregroundStyle(.white)
                                .shadow(radius: 2)
                            
                            let s = vm.currentItem?.ParentIndexNumber.map { String(format: "S%02d", $0) } ?? ""
                            let e = vm.currentItem?.IndexNumber.map { String(format: "E%02d", $0) } ?? ""
                            let se = [s, e].filter { !$0.isEmpty }.joined()
                            let epName = vm.currentItem?.Name ?? ""
                            let subtitleText = se.isEmpty ? epName : "\(se) • \(epName)"
                            
                            Text(subtitleText)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.white.opacity(0.85))
                                .shadow(radius: 2)
                        } else {
                            Text(vm.currentItem?.Name ?? "")
                                .font(.title3.bold())
                                .foregroundStyle(.white)
                                .shadow(radius: 2)
                        }
                    }
                    .padding(.leading, 12)
                    .padding(.top, 2)
                    
                    Spacer()
                    
                    HStack(spacing: 12) {
                        // ── Audio / Language Tracks Menu ──
                        Menu {
                            if vm.availableAudioTracks.isEmpty {
                                Button("No Audio Tracks Available") {}
                                    .disabled(true)
                            } else {
                                ForEach(vm.availableAudioTracks, id: \.self) { option in
                                    Button(action: {
                                        vm.selectAudioTrack(option)
                                        playerController?.resetAutoHideTimer()
                                    }) {
                                        HStack {
                                            Text(option.safeDisplayName)
                                            if vm.selectedAudioTrack == option {
                                                Image(systemName: "checkmark")
                                            }
                                        }
                                    }
                                }
                            }
                        } label: {
                            Image(systemName: "waveform")
                                .foregroundStyle(.white)
                                .font(.system(size: 18, weight: .medium))
                                .frame(width: 44, height: 44)
                        }
                        .glassEffect(in: Circle())
                        
                        // ── Subtitles / Closed Captions Tracks Menu ──
                        Menu {
                            if vm.availableSubtitleTracks.isEmpty {
                                Button("No Subtitles Available") {}
                                    .disabled(true)
                            } else {
                                Button(action: {
                                    vm.selectSubtitleTrack(nil)
                                    playerController?.resetAutoHideTimer()
                                }) {
                                    HStack {
                                        Text("Off")
                                        if !vm.isCCEnabled || vm.selectedSubtitleTrack == nil {
                                            Image(systemName: "checkmark")
                                        }
                                    }
                                }
                                
                                ForEach(vm.availableSubtitleTracks, id: \.self) { option in
                                    Button(action: {
                                        vm.selectSubtitleTrack(option)
                                        playerController?.resetAutoHideTimer()
                                    }) {
                                        HStack {
                                            Text(option.safeDisplayName)
                                            if vm.isCCEnabled && vm.selectedSubtitleTrack == option {
                                                Image(systemName: "checkmark")
                                            }
                                        }
                                    }
                                }
                            }
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
                .padding(.top, 8)
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
                        Image(systemName: "gobackward.10")
                            .font(.system(size: 24, weight: .regular))
                            .foregroundStyle(.white)
                            .frame(width: 56, height: 56)
                            .glassEffect(in: Circle())
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
                        Image(systemName: "goforward.10")
                            .font(.system(size: 24, weight: .regular))
                            .foregroundStyle(.white)
                            .frame(width: 56, height: 56)
                            .glassEffect(in: Circle())
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
                .padding(.vertical, 10)
                .padding(.horizontal, 24)
                .glassEffect(in: Capsule())
                .padding(.horizontal, 32)
                .padding(.bottom, 4)
                .safeAreaPadding(.horizontal)
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

// MARK: - AVMediaSelectionOption safe layout helper

extension AVMediaSelectionOption {
    var safeDisplayName: String {
        let name = self.displayName(with: Locale.current)
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let lang = self.extendedLanguageTag {
                return Locale.current.localizedString(forLanguageCode: lang) ?? lang
            }
            return "Unknown"
        }
        return name
    }
}
