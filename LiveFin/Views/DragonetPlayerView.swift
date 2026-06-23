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
    private var pauseObserver: NSKeyValueObservation?
    private var bufferEmptyObserver: NSKeyValueObservation?
    private var likelyToKeepUpObserver: NSKeyValueObservation?
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
        self.player.automaticallyWaitsToMinimizeStalling = false // Force instant start
        
        if #available(iOS 15.0, *) {
            self.player.audiovisualBackgroundPlaybackPolicy = .continuesIfPossible
        }
        
        if let cid = channel?.id {
            appState.startEPGPolling(for: cid)
        }
        
        setupNowPlayingObservers()
        attachBufferingObservers(to: item)

        // 💥 THE BARRIER BREAKER 💥
        if #available(iOS 15.0, *) {
            Task {
                _ = try? await asset.load(.duration)
                _ = try? await asset.loadMediaSelectionGroup(for: .legible)
            }
        } else {
            asset.loadValuesAsynchronously(forKeys: ["duration", "availableMediaCharacteristicsWithMediaSelectionOptions"]) { }
        }
    }

    // 💥 FIX: THREAD-SAFE DEALLOCATION 💥
    // Since deinit is nonisolated and can run on any background thread, we must capture
    // references synchronously and dispatch AVPlayer/KVO mutations safely to the Main Queue.
    deinit {
        // 1. Capture local references to avoid referencing 'self' inside the main queue block
        let player = self.player
        let tObserver = timeObserver
        let pObserver = progressObserver
        let rObserver = pauseObserver
        let bObserver = bufferEmptyObserver
        let lObserver = likelyToKeepUpObserver
        let channelId = channel?.id
        let state = appState

        // 2. Safely perform AVPlayer and KVO teardown on the Main Queue
        DispatchQueue.main.async {
            if let tObserver = tObserver { player.removeTimeObserver(tObserver) }
            if let pObserver = pObserver { player.removeTimeObserver(pObserver) }
            
            rObserver?.invalidate()
            bObserver?.invalidate()
            lObserver?.invalidate()
            
            // Ensure EPG Polling is clean if stopped abruptly
            if channelId != nil {
                state.stopEPGPolling()
            }
            
            // Remote control event teardown
            UIApplication.shared.endReceivingRemoteControlEvents()
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        }

        // Cancellables will automatically release when self is completely gone,
        // but we explicitly remove them here to immediately halt any active pipelines.
        cancellables.removeAll()
    }

    // MARK: Playback & Reporting

    func startPlayback() {
        guard !hasStartedPlayback else { return }
        hasStartedPlayback = true
        
        activateAudioSession()
        
        player.playImmediately(atRate: 1.0)
        isPlaying = true
        
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
            // 💥 FIX FOR AIRPLAY STUCK LOADING 💥
            // Long form video policy ensures CoreMedia routing prepares buffer sizes
            // optimized for remote television casting (AppleTV / Smart TV targets).
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
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            player.play()
            isPlaying = true
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
        
        attachBufferingObservers(to: fresh)
        player.replaceCurrentItem(with: fresh)
        player.playImmediately(atRate: 1.0)
        
        if #available(iOS 15.0, *) {
            Task {
                _ = try? await asset.load(.duration)
                _ = try? await asset.loadMediaSelectionGroup(for: .legible)
            }
        }
        
        isPlaying    = true
        isAtLiveEdge = true
        isReloading  = false
    }

    func stopAndDismiss(dismiss: DismissAction) {
        if let itemId = channel?.id {
            appState.reportPlaybackStopped(itemId: itemId, positionTicks: 0)
            appState.stopEPGPolling()
        }
        
        player.pause()
        player.replaceCurrentItem(with: nil)
        dismiss()
    }
    
    // MARK: - Buffering Observers
    
    private func attachBufferingObservers(to item: AVPlayerItem) {
        bufferEmptyObserver?.invalidate()
        likelyToKeepUpObserver?.invalidate()
        
        bufferEmptyObserver = item.observe(\.isPlaybackBufferEmpty, options: [.initial, .new]) { [weak self] observedItem, _ in
            DispatchQueue.main.async {
                if observedItem.isPlaybackBufferEmpty {
                    self?.isBuffering = true
                }
            }
        }
        
        likelyToKeepUpObserver = item.observe(\.isPlaybackLikelyToKeepUp, options: [.initial, .new]) { [weak self] observedItem, _ in
            DispatchQueue.main.async {
                if observedItem.isPlaybackLikelyToKeepUp {
                    self?.isBuffering = false
                    
                    // 💥 FIX FOR PERMANENT BUFFERING 💥
                    // Because `automaticallyWaitsToMinimizeStalling` is false, AVPlayer
                    // will NOT resume on its own. We must manually kickstart it again.
                    if self?.isPlaying == true {
                        self?.player.play()
                    }
                }
            }
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
        titleItem.keySpace = .common
        titleItem.value = displayTitle as NSString
        metadataItems.append(titleItem)
        
        if !displaySub.isEmpty {
            let subItem = AVMutableMetadataItem()
            subItem.identifier = .commonIdentifierDescription
            subItem.keySpace = .common
            subItem.value = displaySub as NSString
            metadataItems.append(subItem)
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
                artItem.keySpace = .common
                artItem.value = pngData as NSData

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
            self?.isPlaying = true
            return .success
        }
        
        center.pauseCommand.isEnabled = true
        center.pauseCommand.addTarget { [weak self] _ in
            self?.player.pause()
            self?.isPlaying = false
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
            let ticks = Int64(CMTimeGetSeconds(time) * 10_000_000)
            Task { @MainActor in
                self.appState.reportPlaybackProgress(itemId: itemId, positionTicks: ticks, canSeek: false)
            }
        }
        
        pauseObserver = player.observe(\.rate, options: [.initial, .new]) { [weak self] player, _ in
            guard let self = self else { return }
            let paused = player.rate == 0
            let ticks = Int64(player.currentTime().seconds * 10_000_000)
            Task { @MainActor in
                self.appState.reportPlaybackProgress(itemId: itemId, positionTicks: ticks, canSeek: false, isPaused: paused)
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

            // 💥 FIX 1: Fade Loading using GPU-Accelerated Opacity 💥
            loadingOverlay
                .zIndex(2)
                .allowsHitTesting(false)
                .opacity(vm.isBuffering ? 1 : 0)
                .animation(.easeInOut(duration: 0.4), value: vm.isBuffering)

            // 💥 FIX 2: Fade Controls using GPU-Accelerated Opacity 💥
            landscapeOverlay
                .zIndex(3)
                .opacity(vm.controlsVisible ? 1 : 0)
                // Prevents phantom button clicks when the overlay is invisible
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
                .aspectRatio(contentMode: .fit) // Restored back to fit (as requested)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea()
                .opacity(0.3)
                // 💥 REMOVED .clipped() Modifier 💥
                // This prevents SwiftUI from truncating the bottom edge to the safe area limits,
                // fixing the cutout completely while preserving pristine fit layout.
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
            // 💥 FIX 3: Add explicit curve and duration to the Tap toggle 💥
            vc.onTap = { [weak vc] in
                withAnimation(.easeOut(duration: 0.2)) {
                    vm.controlsVisible.toggle()
                }
                if vm.controlsVisible { vc?.resetAutoHideTimer() }
            }
            // 💥 FIX 4: Add explicit curve and duration to Auto-hide 💥
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

    // MARK: - Cinematic Custom UI Overlay
    
    private var landscapeOverlay: some View {
        VStack(spacing: 0) {
            // ── Top Action Bar ──
            HStack(alignment: .top) {
                // Program Metadata (Logo + Title)
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
                .padding(.top, 8) // 💥 MOVED UP: Reduced top padding from 24 to 8 💥

                Spacer()

                // Utility Buttons
                HStack(spacing: 12) {
                    ccButton
                    pipButton
                    airplayButton
                    closeButton
                }
                .padding(.trailing, 32)
                .padding(.top, 8) // 💥 MOVED UP: Reduced top padding from 24 to 8 💥
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
