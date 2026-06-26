//
//  DragonetPlayerView.swift
//  LiveFin
//
//  Created by KPGamingz on 1/13/26.
//

import SwiftUI
import AVKit
@preconcurrency import AVFoundation
import MediaPlayer
import Combine

// MARK: - ViewModel

@MainActor
final class DragonetPlayerViewModel: ObservableObject {

    // MARK: Published state

    @Published var controlsVisible: Bool = true
    @Published var isPiPActive: Bool      = false
    @Published var isCCEnabled: Bool      = false
    @Published var isPlaying: Bool        = true
    @Published var isAtLiveEdge: Bool     = true
    @Published var isReloading: Bool      = false
    @Published var isBuffering: Bool      = true // Drives the loading overlay

    // MARK: Player

    private(set) var player: AVPlayer
    private(set) var streamURL: URL
    let channel: LiveTvChannelDto?
    let appState: AppState

    private var timeObserver: Any?
    private var progressObserver: Any?
    private var playerItemObserver: NSKeyValueObservation?
    private var playbackStateObserver: NSKeyValueObservation?
    private var cancellables: Set<AnyCancellable> = []
    
    private var lastNowPlayingTitle: String?
    private var lastNowPlayingSubtitle: String?
    private var lastNowPlayingImageId: String?
    
    private var hasStartedPlayback = false
    private var lastPlaybackTime: CMTime = .invalid

    init(streamURL: URL, channel: LiveTvChannelDto?, appState: AppState) {
        self.streamURL = streamURL
        self.channel   = channel
        self.appState  = appState

        let userAgent = "LiveFin iOS/\(appState.clientVersion)"
        var headers: [String: String] = ["User-Agent": userAgent]
        headers["X-Emby-Token"] = appState.accessToken
        headers["X-Emby-User-Id"] = appState.userID

        let asset = AVURLAsset(url: streamURL, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
        let item = AVPlayerItem(asset: asset)
        
        self.player = AVPlayer(playerItem: item)
        // Let AVPlayer handle stalling and auto-resuming natively
        self.player.automaticallyWaitsToMinimizeStalling = true
        
        if #available(iOS 15.0, *) {
            self.player.audiovisualBackgroundPlaybackPolicy = .continuesIfPossible
        }
        
        if let cid = channel?.id {
            appState.startEPGPolling(for: cid)
        }
        
        setupNowPlayingObservers()
        setupPlaybackStateObserver()

        if #available(iOS 15.0, *) {
            Task {
                _ = try? await asset.load(.duration)
                _ = try? await asset.loadMediaSelectionGroup(for: .legible)
            }
        } else {
            asset.loadValuesAsynchronously(forKeys: ["duration", "availableMediaCharacteristicsWithMediaSelectionOptions"]) { }
        }
    }

    deinit {
        // 1. Capture local Sendable properties to bypass thread containment rules safely
        let player = self.player
        let tObserver = timeObserver
        let pObserver = progressObserver
        let stateObserver = playbackStateObserver
        let channelId = channel?.id
        let state = appState
        
        let liveStreamId = URLComponents(url: self.streamURL, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name.caseInsensitiveCompare("LiveStreamId") == .orderedSame })?.value
        let ticks = safeTicks(from: player.currentTime())

        // 2. Safely perform player pause, observers invalidation and API releases on Main Queue
        DispatchQueue.main.async {
            player.pause()
            
            if let tObserver = tObserver { player.removeTimeObserver(tObserver) }
            if let pObserver = pObserver { player.removeTimeObserver(pObserver) }
            
            stateObserver?.invalidate()
            
            if let cid = channelId {
                state.reportPlaybackStopped(itemId: cid, positionTicks: ticks)
                if let lsid = liveStreamId {
                    state.closeLiveStream(liveStreamId: lsid)
                }
                state.stopEPGPolling()
            }
            
            // Remote control event teardown
            UIApplication.shared.endReceivingRemoteControlEvents()
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        }

        cancellables.removeAll()
    }

    // MARK: Playback & Reporting

    func startPlayback() {
        guard !hasStartedPlayback else { return }
        hasStartedPlayback = true
        
        activateAudioSession()
        
        player.play()
        
        startLiveEdgeObserver()
        setupReportingObservers()
        setupRemoteCommands()
        
        if let itemId = channel?.id {
            appState.reportPlaybackStart(itemId: itemId, canSeek: false)
            appState.reportFullClientCapabilities()
        }
    }

    private func activateAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(
                .playback,
                mode: .moviePlayback,
                policy: .longFormVideo,
                options: []
            )
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("[DragonetPlayer] AVAudioSession activation failed: \(error)")
        }
    }

    func togglePlayPause() {
        if player.timeControlStatus == .paused {
            player.play()
        } else {
            player.pause()
        }
    }

    func goToLive() {
        isReloading = true
        isBuffering = true
        lastPlaybackTime = .invalid
        
        let userAgent = "LiveFin iOS/\(appState.clientVersion)"
        var headers: [String: String] = ["User-Agent": userAgent]
        headers["X-Emby-Token"] = appState.accessToken
        headers["X-Emby-User-Id"] = appState.userID

        let asset = AVURLAsset(url: streamURL, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
        let fresh = AVPlayerItem(asset: asset)
        
        player.replaceCurrentItem(with: fresh)
        player.play()
        
        if #available(iOS 15.0, *) {
            Task {
                _ = try? await asset.load(.duration)
                _ = try? await asset.loadMediaSelectionGroup(for: .legible)
            }
        }
        
        isAtLiveEdge = true
        isReloading  = false
    }

    func stopAndDismiss(dismiss: DismissAction) {
        let liveStreamId = URLComponents(url: streamURL, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name.caseInsensitiveCompare("LiveStreamId") == .orderedSame })?.value
        let ticks = safeTicks(from: player.currentTime())

        if let itemId = channel?.id {
            appState.reportPlaybackStopped(itemId: itemId, positionTicks: ticks)
            if let lsid = liveStreamId {
                appState.closeLiveStream(liveStreamId: lsid)
            }
            appState.stopEPGPolling()
        }
        
        player.pause()
        player.replaceCurrentItem(with: nil)
        dismiss()
    }
    
    // MARK: - Core Playback State Observer
    
    private func setupPlaybackStateObserver() {
        playbackStateObserver = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
            guard let self = self else { return }
            let status = player.timeControlStatus
            let ticks = self.safeTicks(from: player.currentTime())
            
            DispatchQueue.main.async {
                // Determine buffering explicitly from the waiting state
                self.isBuffering = (status == .waitingToPlayAtSpecifiedRate)
                
                // Tie `isPlaying` tightly to the player's core playback intent and update NowPlaying rate
                if status == .playing {
                    self.isPlaying = true
                    self.updateNowPlayingPlaybackState(rate: 1.0)
                }
                if status == .paused {
                    self.isPlaying = false
                    self.updateNowPlayingPlaybackState(rate: 0.0)
                }
            }
            
            // Handle reporting seamlessly
            if let itemId = self.channel?.id {
                let isPaused = (status == .paused)
                Task { @MainActor in
                    self.appState.reportPlaybackProgress(itemId: itemId, positionTicks: ticks, canSeek: false, isPaused: isPaused)
                }
            }
        }
    }

    private func updateNowPlayingPlaybackState(rate: Float) {
        if var nowPlaying = MPNowPlayingInfoCenter.default().nowPlayingInfo {
            nowPlaying[MPNowPlayingInfoPropertyPlaybackRate] = rate
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlaying
        }
    }

    // MARK: Now Playing & Remote Commands

    private func setupNowPlayingObservers() {
        Publishers.CombineLatest3(
            appState.$currentProgramTitle,
            appState.$currentProgramSubtitle,
            appState.$currentProgramId
        )
        .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
        .sink { [weak self] (title, subtitle, progId) in
            self?.updateNowPlayingInfo(title: title, subtitle: subtitle, progId: progId)
        }
        .store(in: &cancellables)
    }

    private func updateNowPlayingInfo(title: String?, subtitle: String?, progId: String?) {
        guard let item = player.currentItem else { return }
        
        let displayTitle = title ?? channel?.name ?? "Live TV"
        let displaySub = subtitle ?? ""
        let targetId = progId ?? channel?.id
        
        if displayTitle == lastNowPlayingTitle && displaySub == lastNowPlayingSubtitle && targetId == lastNowPlayingImageId {
            return
        }
        
        lastNowPlayingTitle = displayTitle
        lastNowPlayingSubtitle = displaySub
        lastNowPlayingImageId = targetId
        
        var metadataItems: [AVMetadataItem] = []
        
        let titleItem = AVMutableMetadataItem()
        titleItem.identifier = .commonIdentifierTitle
        titleItem.value = displayTitle as NSString
        titleItem.extendedLanguageTag = "und"
        metadataItems.append(titleItem)
        
        if !displaySub.isEmpty {
            // For AVPlayer, the system maps 'Artist' to the subtitle line in Now Playing UI
            let artistItem = AVMutableMetadataItem()
            artistItem.identifier = .commonIdentifierArtist
            artistItem.value = displaySub as NSString
            artistItem.extendedLanguageTag = "und"
            metadataItems.append(artistItem)
            
            // Keep description as a fallback
            let descItem = AVMutableMetadataItem()
            descItem.identifier = .commonIdentifierDescription
            descItem.value = displaySub as NSString
            descItem.extendedLanguageTag = "und"
            metadataItems.append(descItem)
        }
        
        item.externalMetadata = metadataItems
        
        var nowPlaying = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        nowPlaying[MPMediaItemPropertyTitle] = displayTitle
        
        if !displaySub.isEmpty {
            nowPlaying[MPMediaItemPropertyArtist] = displaySub
        } else {
            nowPlaying.removeValue(forKey: MPMediaItemPropertyArtist)
        }
        nowPlaying[MPNowPlayingInfoPropertyIsLiveStream] = true
        nowPlaying[MPNowPlayingInfoPropertyPlaybackRate] = self.player.timeControlStatus == .playing ? 1.0 : 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlaying
        
        if let targetId = targetId {
            fetchArtworkAndAppend(targetId: targetId, currentMetadata: metadataItems, for: item)
        }
    }

    private func fetchArtworkAndAppend(targetId: String, currentMetadata: [AVMetadataItem], for item: AVPlayerItem) {
        guard !appState.serverURL.isEmpty else { return }
        let server = appState.serverURL.hasSuffix("/") ? String(appState.serverURL.dropLast()) : appState.serverURL
        var components = URLComponents(string: "\(server)/Items/\(targetId)/Images/Primary")
        if !appState.accessToken.isEmpty {
            components?.queryItems = [URLQueryItem(name: "api_key", value: appState.accessToken)]
        }
        guard let url = components?.url else { return }
        
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let data = data, let image = UIImage(data: data), let pngData = image.pngData() else { return }
            // Copy metadata to avoid capturing the original non-Sendable array across threads
            let safeMetadata = currentMetadata
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                guard self.player.currentItem == item else { return }

                let artItem = AVMutableMetadataItem()
                artItem.identifier = .commonIdentifierArtwork
                artItem.value = pngData as NSData
                artItem.dataType = kCMMetadataBaseDataType_PNG as String
                artItem.extendedLanguageTag = "und"

                var newMetadata = safeMetadata
                newMetadata.append(artItem)
                item.externalMetadata = newMetadata

                var np = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
                np[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                MPNowPlayingInfoCenter.default().nowPlayingInfo = np
            }
        }.resume()
    }

    private func setupRemoteCommands() {
        UIApplication.shared.beginReceivingRemoteControlEvents()
        let center = MPRemoteCommandCenter.shared()
        
        center.playCommand.isEnabled = true
        center.playCommand.addTarget { [weak self] _ in
            self?.player.play()
            return .success
        }
        
        center.pauseCommand.isEnabled = true
        center.pauseCommand.addTarget { [weak self] _ in
            self?.player.pause()
            return .success
        }
        
        center.togglePlayPauseCommand.isEnabled = true
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.togglePlayPause()
            return .success
        }
    }

    // MARK: Observers

    private func startLiveEdgeObserver() {
        let interval = CMTime(seconds: 0.25, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                if self.lastPlaybackTime.isValid && time != self.lastPlaybackTime {
                    if self.isBuffering {
                        self.isBuffering = false
                    }
                }
                self.lastPlaybackTime = time
                self.checkLiveEdge()
            }
        }
    }
    
    private func setupReportingObservers() {
        guard let itemId = channel?.id else { return }
        
        let interval = CMTime(seconds: 10, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        progressObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self = self else { return }
            let ticks = self.safeTicks(from: time)
            Task { @MainActor in
                self.appState.reportPlaybackProgress(itemId: itemId, positionTicks: ticks, canSeek: false)
            }
        }
    }

    private func checkLiveEdge() {
        guard let item = player.currentItem else { isAtLiveEdge = true; return }
        guard let last = item.seekableTimeRanges.last?.timeRangeValue else {
            isAtLiveEdge = true
            return
        }
        let edgeTime    = CMTimeRangeGetEnd(last)
        let currentTime = item.currentTime()
        let lag         = CMTimeSubtract(edgeTime, currentTime).seconds
        isAtLiveEdge = lag < 10
    }

    // MARK: - Helpers

    nonisolated private func safeTicks(from time: CMTime) -> Int64 {
        let seconds = CMTimeGetSeconds(time)
        // Ensure the value is finite and not NaN before casting to Int64
        guard seconds.isFinite && !seconds.isNaN else { return 0 }
        return Int64(seconds * 10_000_000)
    }
}

// MARK: - Presentation helper

struct DragonetPlayerModifier: ViewModifier {
    @Binding var isPresented: Bool
    let streamURL: URL?
    let channel: LiveTvChannelDto?
    let onPlaybackError: ((String) -> Void)?
    
    @EnvironmentObject var appState: AppState
    
    func body(content: Content) -> some View {
        content
            .fullScreenCover(isPresented: $isPresented) {
                if let url = streamURL {
                    DragonetPlayerView(
                        streamURL: url,
                        channel: channel,
                        appState: appState,
                        onPlaybackError: onPlaybackError
                    )
                }
            }
    }
}

extension View {
    func dragonetPlayer(
        isPresented: Binding<Bool>,
        streamURL: URL?,
        channel: LiveTvChannelDto? = nil,
        onPlaybackError: ((String) -> Void)? = nil
    ) -> some View {
        self.modifier(DragonetPlayerModifier(
            isPresented: isPresented,
            streamURL: streamURL,
            channel: channel,
            onPlaybackError: onPlaybackError
        ))
    }
}

// MARK: - DragonetPlayerView (Strictly Horizontal)

struct DragonetPlayerView: View {

    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    
    @StateObject private var vm: DragonetPlayerViewModel
    @State private var playerController: DragonetPlayerController?

    let streamURL: URL
    let channel: LiveTvChannelDto?
    let onPlaybackError: ((String) -> Void)?

    init(streamURL: URL, channel: LiveTvChannelDto?, appState: AppState, onPlaybackError: ((String) -> Void)? = nil) {
        
        AppDelegate.orientationLock = .landscape
        
        self.streamURL = streamURL
        self.channel = channel
        self.onPlaybackError = onPlaybackError
        _vm = StateObject(wrappedValue: DragonetPlayerViewModel(streamURL: streamURL, channel: channel, appState: appState))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            makePlayer()
                .ignoresSafeArea()

            // Fade Loading
            loadingOverlay
                .zIndex(2)
                .allowsHitTesting(false)
                .opacity(vm.isBuffering ? 1 : 0)
                .animation(.easeInOut(duration: 0.4), value: vm.isBuffering)

            // Fade Controls
            landscapeOverlay
                .zIndex(3)
                .opacity(vm.controlsVisible ? 1 : 0)
                .allowsHitTesting(vm.controlsVisible)
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .onAppear {
            vm.startPlayback()
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
                    windowScene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscapeRight))
                }
            }
        }
        .onDisappear {
            AppDelegate.orientationLock = .portrait
            if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
                windowScene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait))
            }
        }
        .onChange(of: vm.controlsVisible) { _, visible in
            if visible { playerController?.resetAutoHideTimer() }
            else       { playerController?.cancelTimer() }
        }
    }
    
    // MARK: - Loading Overlay View
    
    private var loadingOverlay: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            if let targetId = appState.currentProgramId ?? channel?.id {
                ChannelImageView(
                    baseUrl: appState.serverURL,
                    apiKey: appState.accessToken,
                    channelId: targetId
                )
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea()
                .opacity(0.3)
            }
            
            ProgressView()
                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                .scaleEffect(2.0)
        }
    }

    // MARK: - Core Player
    
    private func makePlayer() -> some View {
        DragonetPlayer(
            player: vm.player,
            streamURL: vm.streamURL,
            isPiPActive: $vm.isPiPActive,
            isCCEnabled: $vm.isCCEnabled,
            controlsVisible: $vm.controlsVisible,
            onPlaybackError: onPlaybackError
        ) { vc in
            vc.onTap = { [weak vc] in
                withAnimation(.easeOut(duration: 0.2)) {
                    vm.controlsVisible.toggle()
                }
                if vm.controlsVisible { vc?.resetAutoHideTimer() }
            }
            vc.onAutoHide = {
                withAnimation(.easeOut(duration: 0.4)) {
                    vm.controlsVisible = false
                }
            }
            playerController = vc
            
            if vm.controlsVisible {
                vc.resetAutoHideTimer()
            }
        }
    }

    // MARK: - Custom UI Overlay
    
    private var landscapeOverlay: some View {
        VStack(spacing: 0) {
            // ── Top Action Bar ──
            HStack(alignment: .top) {
                HStack(spacing: 16) {
                    if let cid = channel?.id {
                        ChannelImageView(
                            baseUrl: appState.serverURL,
                            apiKey: appState.accessToken,
                            channelId: cid
                        )
                        .frame(width: 50, height: 50)
                        .shadow(radius: 4)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text(appState.currentProgramTitle ?? vm.channel?.name ?? "Live TV")
                            .font(.title3.bold())
                            .foregroundStyle(.white)
                            .shadow(radius: 2)
                            .lineLimit(1)
                        
                        if let sub = appState.currentProgramSubtitle {
                            Text(sub)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.white.opacity(0.85))
                                .shadow(radius: 2)
                                .lineLimit(1)
                        }
                    }
                }
                .padding(.leading, 32)
                .padding(.top, 8)

                Spacer()

                HStack(spacing: 12) {
                    ccButton
                    pipButton
                    airplayButton
                    closeButton
                }
                .padding(.trailing, 32)
                .padding(.top, 8)
            }
            .safeAreaPadding(.horizontal)
            .safeAreaPadding(.top)
            .frame(maxWidth: .infinity)
            .background(
                LinearGradient(
                    colors: [.black.opacity(0.85), .clear],
                    startPoint: .top, endPoint: .bottom
                )
                .frame(height: 160)
                .allowsHitTesting(false),
                alignment: .top
            )

            Spacer()

            // ── Bottom Playback Bar ──
            HStack(spacing: 24) {
                playPauseButton
                liveBadge
            }
            .padding(.leading, 40)
            .padding(.bottom, 16)
            .safeAreaPadding(.horizontal)
            .safeAreaPadding(.bottom)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                LinearGradient(
                    colors: [.clear, .black.opacity(0.85)],
                    startPoint: .top, endPoint: .bottom
                )
                .frame(height: 160)
                .allowsHitTesting(false),
                alignment: .bottom
            )
        }
        .ignoresSafeArea()
    }

    // MARK: - Buttons
    
    private var playPauseButton: some View {
        Button {
            vm.togglePlayPause()
            playerController?.resetAutoHideTimer()
        } label: {
            Image(systemName: vm.isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 32, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
        }
        .glassEffect(in: Circle())
        .accessibilityLabel(vm.isPlaying ? "Pause" : "Play")
    }

    @ViewBuilder
    private var liveBadge: some View {
        if !vm.isAtLiveEdge {
            Button {
                vm.goToLive()
                playerController?.resetAutoHideTimer()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "dot.radiowaves.right")
                        .font(.system(size: 14, weight: .bold))
                    Text("LIVE")
                        .font(.system(size: 14, weight: .black))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
            .glassEffect(in: Capsule())
            .transition(.scale.combined(with: .opacity))
            .animation(.spring(duration: 0.3), value: vm.isAtLiveEdge)
        } else {
            HStack(spacing: 6) {
                Circle()
                    .fill(Color.red)
                    .frame(width: 8, height: 8)
                Text("LIVE")
                    .font(.system(size: 14, weight: .black))
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color.black.opacity(0.4))
            .glassEffect(in: Capsule())
        }
    }

    private var ccButton: some View {
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
    }

    private var pipButton: some View {
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
    }

    private var airplayButton: some View {
        DragonetAirPlayButton()
            .frame(width: 44, height: 44)
            .glassEffect(in: Circle())
    }

    private var closeButton: some View {
        Button { vm.stopAndDismiss(dismiss: dismiss) } label: {
            Image(systemName: "xmark")
                .foregroundStyle(.white)
                .font(.system(size: 16, weight: .bold))
                .frame(width: 44, height: 44)
        }
        .glassEffect(in: Circle())
    }
}

// MARK: - View Modifiers

extension View {
    @ViewBuilder
    func glassEffect<S: Shape>(in shape: S) -> some View {
        if #available(iOS 26, *) {
            self
                .glassEffect(.regular)
                .clipShape(shape)
        } else {
            self
                .background(
                    shape.fill(.ultraThinMaterial)
                         .overlay(shape.stroke(.white.opacity(0.25), lineWidth: 0.5))
                )
                .clipShape(shape)
        }
    }
}
