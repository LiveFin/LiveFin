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

    @Published var controlsVisible: Bool  = true
    @Published var isPiPActive: Bool      = false
    @Published var isCCEnabled: Bool      = false {
        didSet {
            guard oldValue != isCCEnabled else { return }
            applyCC()
        }
    }
    @Published var isPlaying: Bool        = true
    @Published var isAtLiveEdge: Bool     = true
    @Published var isReloading: Bool      = false
    @Published var isBuffering: Bool      = true
    @Published var hasRenderedVideo: Bool = false
    
    @Published var disableNowPlayingUpdates: Bool = false {
        didSet {
            if disableNowPlayingUpdates {
                MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
                self.lastNowPlayingTitle = nil
                self.lastNowPlayingImageId = nil
            } else {
                restoreNowPlaying()
            }
        }
    }
    
    // Scrubber specific state for recordings
    @Published var isRecording: Bool      = false
    @Published var currentTime: Double    = 0
    @Published var seekableStart: Double  = 0
    @Published var seekableEnd: Double    = 1
    @Published var isScrubbing: Bool      = false
    
    // Metadata State
    @Published var streamURL: URL
    @Published var channel: LiveTvChannelDto?
    @Published var program: JFProgram?

    // MARK: Player

    private(set) var player: AVPlayer
    
    let appState: AppState
    let isMultiView: Bool
    var preventCleanupOnDeinit: Bool = false

    /// MultiView-only hook: fired when this stream's playback ends or fails outright,
    /// so the grid can drop the tile instead of leaving it stuck retrying forever.
    /// Non-multiview playback keeps its existing "reconnect live" recovery behavior.
    var onStreamEnded: (() -> Void)?

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

    init(streamURL: URL, channel: LiveTvChannelDto?, program: JFProgram? = nil, appState: AppState, isMultiView: Bool = false) {
        self.streamURL = streamURL
        self.channel   = channel
        self.program   = program
        self.appState  = appState
        self.isMultiView = isMultiView

        let userAgent = "LiveFin iOS/\(appState.clientVersion)"
        var headers: [String: String] = ["User-Agent": userAgent]
        headers["X-Emby-Token"] = appState.accessToken
        headers["X-Emby-User-Id"] = appState.userID

        let asset = AVURLAsset(url: streamURL, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
        let item = AVPlayerItem(asset: asset)
        
        self.player = AVPlayer(playerItem: item)
        self.player.automaticallyWaitsToMinimizeStalling = true
        
        if #available(iOS 15.0, *) {
            self.player.audiovisualBackgroundPlaybackPolicy = .continuesIfPossible
        }
        
        if let cid = channel?.id {
            appState.startEPGPolling(for: cid)
        }
        
        if !isMultiView {
            setupNowPlayingObservers()
        }
        
        setupPlaybackStateObserver()
        setupStreamErrorRecovery()

        if #available(iOS 15.0, *) {
            Task {
                _ = try? await asset.load(.duration)
                _ = try? await asset.loadMediaSelectionGroup(for: .legible)
                self.applyCC()
            }
        } else {
            asset.loadValuesAsynchronously(forKeys: ["duration", "availableMediaCharacteristicsWithMediaSelectionOptions"]) {
                DispatchQueue.main.async {
                    self.applyCC()
                }
            }
        }
        
        // Ensure we automatically start playback once the item is ready
        self.player.play()
    }

    deinit {
        // Nothing needed here. Swift 6 Concurrency rules prevent accessing @MainActor properties here.
        // Instead, cleanup is deterministically handled by `explicitCleanup()`
    }
    
    /// Thread-safe cleanup explicitly triggered when the view disappears or is dismissed.
    func explicitCleanup() {
        guard !preventCleanupOnDeinit else { return }
        
        let tObserver = timeObserver
        let pObserver = progressObserver
        let stateObserver = playbackStateObserver
        let channelId = channel?.id
        let state = appState
        let isMulti = isMultiView
        
        let liveStreamId = URLComponents(url: self.streamURL, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name.caseInsensitiveCompare("LiveStreamId") == .orderedSame })?.value
        let ticks = safeTicks(from: player.currentTime())

        player.pause()
        
        if let tObserver = tObserver { player.removeTimeObserver(tObserver); self.timeObserver = nil }
        if let pObserver = pObserver { player.removeTimeObserver(pObserver); self.progressObserver = nil }
        
        stateObserver?.invalidate()
        self.playbackStateObserver = nil
        
        if let cid = channelId {
            state.reportPlaybackStopped(itemId: cid, positionTicks: ticks)
            if let lsid = liveStreamId {
                state.closeLiveStream(liveStreamId: lsid)
            }
            state.stopEPGPolling()
        }
        
        if !isMulti {
            UIApplication.shared.endReceivingRemoteControlEvents()
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        }

        cancellables.removeAll()
        preventCleanupOnDeinit = true
    }
    
    // MARK: - Captions
    
    private func applyCC() {
        guard let item = player.currentItem else { return }
        let wantEnabled = isCCEnabled
        
        Task {
            var group: AVMediaSelectionGroup?
            if #available(iOS 15.0, *) {
                group = try? await item.asset.loadMediaSelectionGroup(for: .legible)
            } else {
                group = item.asset.mediaSelectionGroup(forMediaCharacteristic: .legible)
            }
            
            guard let safeGroup = group else { return }
            
            // Double check if item is still current once the group finishes loading
            guard self.player.currentItem == item else { return }
            
            let currentOption = item.currentMediaSelection.selectedMediaOption(in: safeGroup)
            let isCurrentlyEnabled = currentOption != nil
            
            if wantEnabled && !isCurrentlyEnabled {
                let locale = Locale.current
                let options = AVMediaSelectionGroup.mediaSelectionOptions(from: safeGroup.options, with: locale)
                if let option = options.first ?? safeGroup.options.first {
                    item.select(option, in: safeGroup)
                }
            } else if !wantEnabled && isCurrentlyEnabled {
                item.select(nil, in: safeGroup)
            }
        }
    }
    
    // MARK: - MultiView State Hand-off
    
    /// Prepares this player to be adopted by another ViewModel, stripping local observers
    /// but leaving the playback state entirely intact for seamless handoff.
    func transferPlayer() -> AVPlayer {
        if let tObserver = timeObserver { player.removeTimeObserver(tObserver); self.timeObserver = nil }
        if let pObserver = progressObserver { player.removeTimeObserver(pObserver); self.progressObserver = nil }
        
        playbackStateObserver?.invalidate()
        self.playbackStateObserver = nil
        
        preventCleanupOnDeinit = true
        return self.player
    }
    
    /// Flawlessly hijacks the playback item and metadata from a surviving MultiView stream
    /// and elevates it into this primary controller without reloading.
    func replaceStream(with other: DragonetPlayerViewModel) {
        let newURL = other.streamURL
        let newChannel = other.channel
        let newProgram = other.program
        
        let newTitle = newProgram?.name ?? newChannel?.name ?? "LiveFin"
        let newSubtitle = newProgram?.episodeTitle ?? newProgram?.overview
        let newId = newProgram?.id ?? newChannel?.id
        
        // Clean our current state without destroying the other player's session
        self.explicitCleanup()
        self.preventCleanupOnDeinit = false
        
        // Seamlessly adopt the AVPlayer from the other view model
        self.player = other.transferPlayer()
        
        // Adopt state
        self.streamURL = newURL
        self.channel = newChannel
        self.program = newProgram
        
        // Update Global AppState and Metadata so UI overlay names change immediately
        self.appState.currentProgramTitle = newTitle
        self.appState.currentProgramSubtitle = newSubtitle
        self.appState.currentProgramId = newId
        self.appState.currentProgramStartDate = newProgram?.startDate
        self.appState.currentProgramEndDate = newProgram?.endDate
        self.appState.currentProgramIsMovie = newProgram?.isMovie ?? false
        self.appState.currentProgramGenres = newProgram?.genres
        
        // Re-attach local playback reporting observers to the adopted player
        setupPlaybackStateObserver()
        setupStreamErrorRecovery()
        startLiveEdgeObserver()
        setupReportingObservers()
        
        self.player.isMuted = false
        
        if let newCid = self.channel?.id {
            appState.startEPGPolling(for: newCid)
            appState.reportPlaybackStart(itemId: newCid, canSeek: false)
        }
        
        Task { await checkRecordingStatus() }
    }

    // MARK: Playback & Reporting

    func startPlayback() {
        guard !hasStartedPlayback else { return }
        hasStartedPlayback = true
        
        if !isMultiView {
            activateAudioSession()
            setupRemoteCommands()
        }
        
        player.play()
        
        startLiveEdgeObserver()
        setupReportingObservers()
        
        Task { await checkRecordingStatus() }
        
        if let itemId = channel?.id {
            appState.reportPlaybackStart(itemId: itemId, canSeek: false)
            appState.reportFullClientCapabilities()
        }
    }
    
    func restoreNowPlaying() {
        guard !disableNowPlayingUpdates else { return }
        self.lastNowPlayingTitle = nil
        self.lastNowPlayingImageId = nil
        self.updateNowPlayingInfo(
            title: appState.currentProgramTitle,
            subtitle: appState.currentProgramSubtitle,
            progId: appState.currentProgramId
        )
    }
    
    private func checkRecordingStatus() async {
        guard let p = program else { return }
        let urlStr = appState.serverURL.hasSuffix("/") ? String(appState.serverURL.dropLast()) : appState.serverURL
        guard let url = URL(string: "\(urlStr)/LiveTv/Timers") else { return }
        
        var req = URLRequest(url: url)
        req.setValue(appState.accessToken, forHTTPHeaderField: "X-Emby-Token")
        
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            struct JFQueryResult: Decodable { let Items: [JFTimer] }
            let response = try JSONDecoder().decode(JFQueryResult.self, from: data)
            if response.Items.contains(where: { $0.ProgramId == p.id && $0.Status == "InProgress" }) {
                self.isRecording = true
            }
        } catch {
            print("Failed to verify live recording status: \(error)")
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
            guard let item = player.currentItem else {
                player.play()
                return
            }

            if let seekableRange = item.seekableTimeRanges.last?.timeRangeValue {
                let earliestAvailable = seekableRange.start
                if item.currentTime().seconds < earliestAvailable.seconds {
                    goToLive()
                    return
                }
            }
            
            player.play()
            
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard let self = self else { return }
                
                if self.player.timeControlStatus == .waitingToPlayAtSpecifiedRate {
                    self.goToLive()
                }
            }
        } else {
            player.pause()
        }
    }

    func goToLive() {
        isReloading = true
        isBuffering = true
        hasRenderedVideo = false
        lastPlaybackTime = .invalid
        
        var components = URLComponents(url: streamURL, resolvingAgainstBaseURL: false)
        if let queryItems = components?.queryItems {
            var newItems = queryItems.filter { $0.name.caseInsensitiveCompare("PlaySessionId") != .orderedSame }
            newItems.append(URLQueryItem(name: "PlaySessionId", value: UUID().uuidString.replacingOccurrences(of: "-", with: "")))
            components?.queryItems = newItems
        }
        
        guard let freshURL = components?.url else { return }
        
        let userAgent = "LiveFin iOS/\(appState.clientVersion)"
        var headers: [String: String] = ["User-Agent": userAgent]
        headers["X-Emby-Token"] = appState.accessToken
        headers["X-Emby-User-Id"] = appState.userID

        let asset = AVURLAsset(url: freshURL, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
        let fresh = AVPlayerItem(asset: asset)
        
        player.replaceCurrentItem(with: fresh)
        player.play()
        
        if #available(iOS 15.0, *) {
            Task {
                _ = try? await asset.load(.duration)
                _ = try? await asset.loadMediaSelectionGroup(for: .legible)
                self.applyCC()
            }
        } else {
            asset.loadValuesAsynchronously(forKeys: ["duration", "availableMediaCharacteristicsWithMediaSelectionOptions"]) {
                DispatchQueue.main.async { self.applyCC() }
            }
        }
        
        isAtLiveEdge = true
        isReloading  = false
    }

    func stopAndDismiss(dismiss: DismissAction) {
        explicitCleanup()
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
                self.isBuffering = (status == .waitingToPlayAtSpecifiedRate)
                
                if status == .playing {
                    self.isPlaying = true
                    if !self.isMultiView {
                        self.updateNowPlayingPlaybackState(rate: 1.0)
                    }
                }
                if status == .paused {
                    self.isPlaying = false
                    if !self.isMultiView {
                        self.updateNowPlayingPlaybackState(rate: 0.0)
                    }
                }
            }
            
            if let itemId = self.channel?.id {
                let isPaused = (status == .paused)
                Task { @MainActor in
                    self.appState.reportPlaybackProgress(itemId: itemId, positionTicks: ticks, canSeek: false, isPaused: isPaused)
                }
            }
        }
    }
    
    private func setupStreamErrorRecovery() {
        // If the live stream stops because it thinks it hit the end (lost connection / missed segments):
        // in single playback, reconnect live. In MultiView, just drop the tile rather than looping forever.
        NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                guard let self = self,
                      let item = notification.object as? AVPlayerItem,
                      item == self.player.currentItem else { return }
                
                if self.isMultiView {
                    self.onStreamEnded?()
                    return
                }
                
                self.isBuffering = true
                self.goToLive()
            }
            .store(in: &cancellables)

        // Handle generic stream failures (like timeout loading segment)
        NotificationCenter.default.publisher(for: .AVPlayerItemFailedToPlayToEndTime)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                guard let self = self,
                      let item = notification.object as? AVPlayerItem,
                      item == self.player.currentItem else { return }
                
                if self.isMultiView {
                    self.onStreamEnded?()
                    return
                }
                
                self.isBuffering = true
                self.goToLive()
            }
            .store(in: &cancellables)

        // Ensure if the stream stalls out and pauses, we try kickstarting it.
        // (Kept for MultiView too — a stall isn't necessarily a dead stream, so we still
        // attempt to resume before giving up on the tile.)
        NotificationCenter.default.publisher(for: .AVPlayerItemPlaybackStalled)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                guard let self = self,
                      let item = notification.object as? AVPlayerItem,
                      item == self.player.currentItem else { return }
                
                self.isBuffering = true
                if self.player.timeControlStatus == .paused && self.hasStartedPlayback {
                    self.player.play()
                }
            }
            .store(in: &cancellables)
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
        guard !disableNowPlayingUpdates else { return }
        guard let item = player.currentItem else { return }
        
        let displayTitle = title ?? channel?.name ?? "LiveFin"
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
            let artistItem = AVMutableMetadataItem()
            artistItem.identifier = .commonIdentifierArtist
            artistItem.value = displaySub as NSString
            artistItem.extendedLanguageTag = "und"
            metadataItems.append(artistItem)
            
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
                    if !self.hasRenderedVideo {
                        self.hasRenderedVideo = true
                    }
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
        guard let item = player.currentItem else {
            isAtLiveEdge = true
            return
        }
        if let last = item.seekableTimeRanges.last?.timeRangeValue {
            seekableStart = last.start.seconds
            seekableEnd = last.end.seconds
            
            let lag = seekableEnd - item.currentTime().seconds
            isAtLiveEdge = lag < 10
            
            if !isScrubbing {
                currentTime = item.currentTime().seconds
            }
        } else {
            isAtLiveEdge = true
        }
    }

    // MARK: - Helpers

    nonisolated private func safeTicks(from time: CMTime) -> Int64 {
        let seconds = CMTimeGetSeconds(time)
        guard seconds.isFinite && !seconds.isNaN else { return 0 }
        return Int64(seconds * 10_000_000)
    }
}

// MARK: - Presentation helper

struct DragonetPlayerModifier: ViewModifier {
    @Binding var isPresented: Bool
    let streamURL: URL?
    let channel: LiveTvChannelDto?
    let program: JFProgram?
    let onPlaybackError: ((String) -> Void)?
    
    @EnvironmentObject var appState: AppState
    
    func body(content: Content) -> some View {
        content
            .fullScreenCover(isPresented: $isPresented) {
                if let url = streamURL {
                    DragonetPlayerView(
                        streamURL: url,
                        channel: channel,
                        program: program,
                        appState: appState,
                        onPlaybackError: onPlaybackError
                    )
                    .environmentObject(appState)
                } else {
                    Color.black.ignoresSafeArea()
                }
            }
    }
}

extension View {
    func dragonetPlayer(
        isPresented: Binding<Bool>,
        streamURL: URL?,
        channel: LiveTvChannelDto? = nil,
        program: JFProgram? = nil,
        onPlaybackError: ((String) -> Void)? = nil
    ) -> some View {
        self.modifier(DragonetPlayerModifier(
            isPresented: isPresented,
            streamURL: streamURL,
            channel: channel,
            program: program,
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
    
    @State private var showMultiView = false
    @State private var showAddChannelSheet = false
    @State private var multiVM: DragonetMultiViewModel?
    @State private var isTransitioningToMultiView = false

    let streamURL: URL
    let channel: LiveTvChannelDto?
    let program: JFProgram?
    let onPlaybackError: ((String) -> Void)?

    init(streamURL: URL, channel: LiveTvChannelDto?, program: JFProgram? = nil, appState: AppState, onPlaybackError: ((String) -> Void)? = nil) {
        AppDelegate.orientationLock = .landscape
        self.streamURL = streamURL
        self.channel = channel
        self.program = program
        self.onPlaybackError = onPlaybackError
        _vm = StateObject(wrappedValue: DragonetPlayerViewModel(streamURL: streamURL, channel: channel, program: program, appState: appState))
    }

    var effectiveProgram: JFProgram? {
        if let p = vm.program { return p }
        let id = appState.currentProgramId ?? "manual_\(vm.channel?.id ?? UUID().uuidString)"
        var dict: [String: Any] = [:]
        dict["Id"] = id
        dict["Name"] = appState.currentProgramTitle ?? vm.channel?.name ?? "LiveFin"
        
        if let cid = vm.channel?.id { dict["ChannelId"] = cid }
        if let cname = vm.channel?.name { dict["ChannelName"] = cname }
        
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        if let s = appState.currentProgramStartDate { dict["StartDate"] = iso.string(from: s) }
        if let e = appState.currentProgramEndDate { dict["EndDate"] = iso.string(from: e) }
        dict["IsMovie"] = appState.currentProgramIsMovie ?? false
        if let genres = appState.currentProgramGenres { dict["Genres"] = genres }
        
        return JFProgram(json: dict)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            makePlayer()
                .ignoresSafeArea()

            bufferImageOverlay
                .zIndex(1)
                .allowsHitTesting(false)
                .opacity(!vm.hasRenderedVideo ? 1 : 0)
                .animation(.easeInOut(duration: 0.4), value: vm.hasRenderedVideo)

            spinnerOverlay
                .zIndex(2)
                .allowsHitTesting(false)
                .opacity(vm.isBuffering ? 1 : 0)
                .animation(.easeInOut(duration: 0.2), value: vm.isBuffering)

            landscapeOverlay
                .zIndex(3)
                .opacity(vm.controlsVisible ? 1 : 0)
                .allowsHitTesting(vm.controlsVisible)
        }
        .sheet(isPresented: $showAddChannelSheet) {
            let activeIds = [vm.channel?.id].compactMap { $0 }
            MultiViewChannelPickerView(appState: appState, activeChannelIds: activeIds) { url, channel, program in
                if self.multiVM == nil {
                    let manager = DragonetMultiViewModel(appState: appState)
                    manager.adoptStream(self.vm)
                    self.multiVM = manager
                }
                self.multiVM?.addStream(url: url, channel: channel, program: program)
                self.showMultiView = true
            }
        }
        .fullScreenCover(isPresented: $showMultiView, onDismiss: {
            if let manager = multiVM {
                // Determine which stream to keep
                let streamToKeep: DragonetPlayerViewModel?
                if let explicitlySelected = manager.selectedStreamToKeep {
                    streamToKeep = explicitlySelected
                } else {
                    let focusIndex = manager.activeAudioIndex
                    streamToKeep = manager.activeStreams.indices.contains(focusIndex) ? manager.activeStreams[focusIndex] : manager.activeStreams.first
                }
                
                manager.selectedStreamToKeep = streamToKeep
                
                // ONLY replace metadata and player if it's a completely different stream object
                if let remaining = streamToKeep, remaining !== vm {
                    vm.replaceStream(with: remaining)
                }
            }
            
            vm.player.isMuted = false
            if vm.isPlaying {
                vm.player.play()
            }
            
            self.multiVM?.cleanup()
            self.multiVM = nil
        }) {
            if let manager = multiVM {
                DragonetMultiView(multiVM: manager)
                    .environmentObject(appState)
            } else {
                Color.black.ignoresSafeArea()
            }
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .onChange(of: showMultiView) { newValue in
            isTransitioningToMultiView = newValue
            vm.disableNowPlayingUpdates = newValue
        }
        .onAppear {
            isTransitioningToMultiView = false
            vm.startPlayback()
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
                    windowScene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscapeRight))
                }
            }
        }
        .onDisappear {
            // Guard to protect against orientation lock breakage when moving inside multiview grid
            if !isTransitioningToMultiView {
                AppDelegate.orientationLock = .portrait
                if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
                    windowScene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait))
                }
                vm.explicitCleanup()
            }
        }
        .onChange(of: vm.controlsVisible) { _, visible in
            if visible { playerController?.resetAutoHideTimer() }
            else       { playerController?.cancelTimer() }
        }
    }
    
    // MARK: - Loading Overlays
    
    private var bufferImageOverlay: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            if let targetId = appState.currentProgramId ?? vm.channel?.id {
                let server = appState.serverURL.hasSuffix("/") ? String(appState.serverURL.dropLast()) : appState.serverURL
                let urlString = "\(server)/Items/\(targetId)/Images/Primary?api_key=\(appState.accessToken)&maxWidth=1920&quality=100"
                
                AsyncImage(url: URL(string: urlString)) { phase in
                    switch phase {
                    case .empty:
                        Color.black
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                    case .failure:
                        ChannelImageView(
                            baseUrl: appState.serverURL,
                            apiKey: appState.accessToken,
                            channelId: targetId
                        )
                        .aspectRatio(contentMode: .fit)
                    @unknown default:
                        EmptyView()
                    }
                }
                .id(urlString)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea()
                .opacity(0.3)
            }
        }
    }
    
    private var spinnerOverlay: some View {
        ZStack {
            ProgressView()
                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                .scaleEffect(2.0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            HStack(alignment: .top) {
                HStack(spacing: 16) {
                    if let cid = vm.channel?.id {
                        ChannelImageView(
                            baseUrl: appState.serverURL,
                            apiKey: appState.accessToken,
                            channelId: cid
                        )
                        .id(cid)
                        .frame(width: 50, height: 50)
                        .shadow(radius: 4)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text(appState.currentProgramTitle ?? vm.channel?.name ?? "LiveFin")
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
                    
                    if let effProg = effectiveProgram {
                        DragonetRecordingButtons(program: effProg, appState: appState)
                            .id(appState.currentProgramId ?? vm.channel?.id ?? UUID().uuidString)
                    }
                    
                    ccButton
                    multiViewButton
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

            HStack(spacing: 24) {
                playPauseButton
                
                liveBadge
                
                if vm.isRecording {
                    scrubberView
                } else {
                    Spacer()
                }
            }
            .padding(.horizontal, 40)
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
    
    private var scrubberView: some View {
        HStack(spacing: 12) {
            Text(formatTime(vm.currentTime - vm.seekableStart))
                .font(.caption.monospacedDigit())
                .foregroundColor(.white)
            
            let rangeStart = max(vm.seekableStart, 0)
            let rangeEnd = max(vm.seekableEnd, rangeStart + 1)
            
            Slider(value: Binding(
                get: { max(min(vm.currentTime, rangeEnd), rangeStart) },
                set: { val in vm.currentTime = val }
            ), in: rangeStart...rangeEnd) { editing in
                vm.isScrubbing = editing
                if !editing {
                    vm.player.seek(to: CMTime(seconds: vm.currentTime, preferredTimescale: 600))
                    playerController?.resetAutoHideTimer()
                }
            }
            .tint(.red)
            
            Text("-" + formatTime(vm.seekableEnd - vm.currentTime))
                .font(.caption.monospacedDigit())
                .foregroundColor(.white)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .glassEffect(in: Capsule())
        .frame(maxWidth: .infinity)
    }
    
    private func formatTime(_ seconds: Double) -> String {
        guard seconds > 0 && seconds.isFinite else { return "00:00" }
        let min = Int(seconds) / 60
        let sec = Int(seconds) % 60
        if min > 59 {
            let hr = min / 60
            let m = min % 60
            return String(format: "%d:%02d:%02d", hr, m, sec)
        }
        return String(format: "%02d:%02d", min, sec)
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

    private var multiViewButton: some View {
        Button {
            playerController?.cancelTimer()
            self.showAddChannelSheet = true
        } label: {
            Image(systemName: "square.grid.2x2")
                .foregroundStyle(.white)
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

// MARK: - Recording Actions View

struct DragonetRecordingButtons: View {
    @StateObject var recordingViewModel: ProgramRecordingViewModel
    @State private var showRecordingSheet = false
    
    init(program: JFProgram, appState: AppState) {
        _recordingViewModel = StateObject(wrappedValue: ProgramRecordingViewModel(program: program, appState: appState))
    }
    
    var body: some View {
        Button {
            showRecordingSheet = true
        } label: {
            Image(systemName: recordingViewModel.isRecordingScheduled == true ? "record.circle.fill" : "record.circle")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(recordingViewModel.isRecordingScheduled == true ? Color.red : .white)
                .frame(width: 44, height: 44)
                .background(recordingViewModel.isRecordingScheduled == true ? Color.red.opacity(0.4) : Color.clear)
        }
        .glassEffect(in: Circle())
        .sheet(isPresented: $showRecordingSheet) {
            RecordingConfigurationView(viewModel: recordingViewModel)
        }
        .onAppear {
            recordingViewModel.checkPendingNotifications()
        }
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
