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
@Published var isSwitchingChannel: Bool = false

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

// Sports Stats State
@Published var liveGameScore: LiveGameScore?
@Published var isCheckingSportsStats: Bool = false
@Published var detectedMatchQuery: MatchQuery?
@Published var isSportsProgram: Bool = false

// AirPlay State
@Published var isExternalPlaybackActive: Bool = false
@Published var externalPlaybackDeviceName: String? = nil
private var externalPlaybackObserver: NSKeyValueObservation?

// MARK: Player

private(set) var player: AVPlayer

let appState: AppState
let isMultiView: Bool
var preventCleanupOnDeinit: Bool = false

/// MultiView-only hook: fired when this stream's playback ends or fails outright
var onStreamEnded: (() -> Void)?

private var timeObserver: Any?
private var progressObserver: Any?
private var playerItemObserver: NSKeyValueObservation?
private var playbackStateObserver: NSKeyValueObservation?
private var likelyToKeepUpObserver: NSKeyValueObservation?
private var bufferEmptyObserver: NSKeyValueObservation?
private var cancellables: Set<AnyCancellable> = []

private var lastNowPlayingTitle: String?
private var lastNowPlayingSubtitle: String?
private var lastNowPlayingImageId: String?

private var hasStartedPlayback = false
private var intentionallyPaused = false
private var lastPlaybackTime: CMTime = .invalid
private var switchChannelTask: Task<Void, Never>?
private var sportsStatsTask: Task<Void, Never>?

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
    self.player.automaticallyWaitsToMinimizeStalling = false
    self.player.allowsExternalPlayback = true
    self.player.usesExternalPlaybackWhileExternalScreenIsActive = true
    
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
    setupExternalPlaybackObservation()
    observeItem(item)

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
    
    self.intentionallyPaused = false
    self.player.play()
    self.refreshSportsTracking()
}

deinit { }

private func observeItem(_ item: AVPlayerItem) {
    likelyToKeepUpObserver?.invalidate()
    bufferEmptyObserver?.invalidate()
    
    likelyToKeepUpObserver = item.observe(\.isPlaybackLikelyToKeepUp, options: [.initial, .new]) { [weak self] item, _ in
        guard let self = self else { return }
        DispatchQueue.main.async {
            guard !self.isSwitchingChannel else { return }
            if item.isPlaybackLikelyToKeepUp {
                if self.isBuffering {
                    self.isBuffering = false
                }
                if !self.intentionallyPaused && self.hasStartedPlayback && self.player.timeControlStatus != .playing {
                    self.player.play()
                }
            }
        }
    }
    
    bufferEmptyObserver = item.observe(\.isPlaybackBufferEmpty, options: [.initial, .new]) { [weak self] item, _ in
        guard let self = self else { return }
        DispatchQueue.main.async {
            guard !self.isSwitchingChannel else { return }
            if item.isPlaybackBufferEmpty {
                self.isBuffering = true
            }
        }
    }
}

func explicitCleanup() {
    guard !preventCleanupOnDeinit else { return }
    
    stopSportsStatsTracking()
    switchChannelTask?.cancel()
    switchChannelTask = nil
    
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
    
    likelyToKeepUpObserver?.invalidate()
    self.likelyToKeepUpObserver = nil
    
    bufferEmptyObserver?.invalidate()
    self.bufferEmptyObserver = nil
    
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
    externalPlaybackObserver?.invalidate()
    externalPlaybackObserver = nil
    NotificationCenter.default.removeObserver(self, name: AVAudioSession.routeChangeNotification, object: nil)
    preventCleanupOnDeinit = true
}

// MARK: - AirPlay Observation

private func setupExternalPlaybackObservation() {
    externalPlaybackObserver = player.observe(\.isExternalPlaybackActive, options: [.initial, .new]) { [weak self] _, _ in
        Task { @MainActor [weak self] in
            self?.updateExternalPlaybackStatus()
        }
    }
    NotificationCenter.default.addObserver(
        self,
        selector: #selector(handleAudioRouteChange),
        name: AVAudioSession.routeChangeNotification,
        object: nil
    )
    updateExternalPlaybackStatus()
}

@objc private func handleAudioRouteChange(_ notification: Notification) {
    Task { @MainActor [weak self] in
        self?.updateExternalPlaybackStatus()
    }
}

private func updateExternalPlaybackStatus() {
    let active = player.isExternalPlaybackActive
    self.isExternalPlaybackActive = active
    if active {
        let route = AVAudioSession.sharedInstance().currentRoute
        let airplayPort = route.outputs.first { $0.portType == .airPlay }
        self.externalPlaybackDeviceName = airplayPort?.portName ?? "AirPlay"
    } else {
        self.externalPlaybackDeviceName = nil
    }
}

// MARK: - Channel Switching

func switchChannel(to newChannel: LiveTvChannelDto, program: JFProgram? = nil) {
    guard newChannel.id != self.channel?.id else { return }
    
    switchChannelTask?.cancel()
    self.isSwitchingChannel = true
    
    let ticks = safeTicks(from: player.currentTime())
    if let oldCid = channel?.id {
        appState.reportPlaybackStopped(itemId: oldCid, positionTicks: ticks)
        appState.stopEPGPolling()
    }
    
    player.pause()
    likelyToKeepUpObserver?.invalidate()
    bufferEmptyObserver?.invalidate()
    player.replaceCurrentItem(with: nil)
    
    self.isBuffering = true
    self.hasRenderedVideo = false
    self.lastPlaybackTime = .invalid
    
    self.channel = newChannel
    self.program = program
    self.isRecording = (program?.timerId != nil || program?.seriesTimerId != nil)
    
    let displayTitle = program?.name ?? newChannel.name
    let displaySubtitle = program?.episodeTitle ?? program?.overview
    let targetId = program?.id ?? newChannel.id
    
    self.appState.currentProgramTitle = displayTitle
    self.appState.currentProgramSubtitle = displaySubtitle
    self.appState.currentProgramId = targetId
    self.appState.currentProgramStartDate = program?.startDate
    self.appState.currentProgramEndDate = program?.endDate
    self.appState.currentProgramIsMovie = program?.isMovie ?? false
    self.appState.currentProgramGenres = program?.genres
    
    if !self.isMultiView {
        self.lastNowPlayingTitle = nil
        self.lastNowPlayingSubtitle = nil
        self.lastNowPlayingImageId = nil
        restoreNowPlaying()
    }
    
    self.refreshSportsTracking()

    switchChannelTask = Task { @MainActor [weak self] in
        guard let self = self else { return }
        
        let streamURLString: String?
        if let resolved = await JFOpenLiveStreamService.resolveStreamURL(appState: self.appState, channelId: newChannel.id) {
            streamURLString = resolved
        } else {
            let server = self.appState.serverURL.hasSuffix("/") ? String(self.appState.serverURL.dropLast()) : self.appState.serverURL
            let playSessionId = UUID().uuidString.replacingOccurrences(of: "-", with: "")
            streamURLString = "\(server)/Videos/\(newChannel.id)/live.m3u8?DeviceId=\(self.appState.deviceId)&MediaSourceId=\(newChannel.id)&PlaySessionId=\(playSessionId)&api_key=\(self.appState.accessToken)"
        }
        
        guard !Task.isCancelled else { return }
        
        guard let urlStr = streamURLString, let freshURL = URL(string: urlStr) else {
            self.isBuffering = false
            self.isSwitchingChannel = false
            return
        }
        
        self.streamURL = freshURL
        
        let userAgent = "LiveFin iOS/\(self.appState.clientVersion)"
        var headers: [String: String] = ["User-Agent": userAgent]
        headers["X-Emby-Token"] = self.appState.accessToken
        headers["X-Emby-User-Id"] = self.appState.userID

        let asset = AVURLAsset(url: freshURL, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
        let freshItem = AVPlayerItem(asset: asset)
        
        self.player.replaceCurrentItem(with: freshItem)
        self.observeItem(freshItem)
        
        self.appState.startEPGPolling(for: newChannel.id)
        self.appState.reportPlaybackStart(itemId: newChannel.id, canSeek: false)
        self.appState.reportPlaybackProgress(itemId: newChannel.id, positionTicks: 0, canSeek: false, isPaused: false)
        
        self.isSwitchingChannel = false
        self.intentionallyPaused = false
        self.player.play()
        
        if #available(iOS 15.0, *) {
            _ = try? await asset.load(.duration)
            _ = try? await asset.loadMediaSelectionGroup(for: .legible)
            self.applyCC()
        }
        
        await self.checkRecordingStatus()
    }
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
        
        guard let safeGroup = group, self.player.currentItem == item else { return }
        
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

func transferPlayer() -> AVPlayer {
    if let tObserver = timeObserver { player.removeTimeObserver(tObserver); self.timeObserver = nil }
    if let pObserver = progressObserver { player.removeTimeObserver(pObserver); self.progressObserver = nil }
    
    playbackStateObserver?.invalidate()
    self.playbackStateObserver = nil
    
    likelyToKeepUpObserver?.invalidate()
    self.likelyToKeepUpObserver = nil
    
    bufferEmptyObserver?.invalidate()
    self.bufferEmptyObserver = nil
    
    preventCleanupOnDeinit = true
    return self.player
}

func replaceStream(with other: DragonetPlayerViewModel) {
    let newURL = other.streamURL
    let newChannel = other.channel
    let newProgram = other.program
    
    let newTitle = newProgram?.name ?? newChannel?.name ?? "LiveFin"
    let newSubtitle = newProgram?.episodeTitle ?? newProgram?.overview
    let newId = newProgram?.id ?? newChannel?.id
    
    self.explicitCleanup()
    self.preventCleanupOnDeinit = false
    
    self.player = other.transferPlayer()
    
    if let item = self.player.currentItem {
        observeItem(item)
    }
    
    self.streamURL = newURL
    self.channel = newChannel
    self.program = newProgram
    
    self.appState.currentProgramTitle = newTitle
    self.appState.currentProgramSubtitle = newSubtitle
    self.appState.currentProgramId = newId
    self.appState.currentProgramStartDate = newProgram?.startDate
    self.appState.currentProgramEndDate = newProgram?.endDate
    self.appState.currentProgramIsMovie = newProgram?.isMovie ?? false
    self.appState.currentProgramGenres = newProgram?.genres
    
    setupPlaybackStateObserver()
    setupStreamErrorRecovery()
    startLiveEdgeObserver()
    setupReportingObservers()
    
    if !self.isMultiView {
        setupNowPlayingObservers()
        setupRemoteCommands()
        
        self.lastNowPlayingTitle = nil
        self.lastNowPlayingSubtitle = nil
        self.lastNowPlayingImageId = nil
        
        restoreNowPlaying()
    }
    
    self.player.isMuted = false
    
    if let newCid = self.channel?.id {
        appState.startEPGPolling(for: newCid)
        appState.reportPlaybackStart(itemId: newCid, canSeek: false)
        appState.reportPlaybackProgress(itemId: newCid, positionTicks: 0, canSeek: false, isPaused: false)
    }
    
    refreshSportsTracking()
    Task { await checkRecordingStatus() }
}

// MARK: Playback & Reporting

func startPlayback() {
    guard !hasStartedPlayback else { return }
    hasStartedPlayback = true
    intentionallyPaused = false
    
    if !isMultiView {
        activateAudioSession()
        setupRemoteCommands()
    }
    
    player.play()
    startLiveEdgeObserver()
    setupReportingObservers()
    refreshSportsTracking()
    
    Task { await checkRecordingStatus() }
    
    if let itemId = channel?.id {
        appState.reportPlaybackStart(itemId: itemId, canSeek: false)
        appState.reportPlaybackProgress(itemId: itemId, positionTicks: 0, canSeek: false, isPaused: false)
        appState.reportFullClientCapabilities()
    }
}

// MARK: - Sports Tracking Engine (Temporarily removed, saving for 2.4.1)

func refreshSportsTracking() {
    // Temporarily disabled for now, saving for 2.4.1
    /*
    sportsStatsTask?.cancel()

    let title = program?.name ?? appState.currentProgramTitle
    let subtitle = program?.episodeTitle ?? program?.overview ?? appState.currentProgramSubtitle
    let channelName = channel?.name
    let genres = program?.genres ?? appState.currentProgramGenres
    let startDate = program?.startDate ?? appState.currentProgramStartDate

    // Verify content is not a non-game studio talk show
    guard !SportsMatchEngine.shared.isTalkOrStudioShow(title: title, subtitle: subtitle) else {
        self.isSportsProgram = false
        self.detectedMatchQuery = nil
        self.liveGameScore = nil
        return
    }

    guard let query = SportsMatchEngine.shared.parseQuery(
        title: title,
        subtitle: subtitle,
        channelName: channelName,
        genres: genres,
        startDate: startDate
    ) else {
        self.isSportsProgram = false
        self.detectedMatchQuery = nil
        self.liveGameScore = nil
        return
    }

    self.isSportsProgram = true
    self.detectedMatchQuery = query

    sportsStatsTask = Task { @MainActor [weak self] in
        guard let self = self else { return }
        self.isCheckingSportsStats = true
        
        while !Task.isCancelled {
            let score = await SportsDataManager.shared.resolveLiveScore(for: query)
            guard !Task.isCancelled else { return }
            
            withAnimation(.easeInOut(duration: 0.25)) {
                self.liveGameScore = score
                self.isCheckingSportsStats = false
            }

            let intervalSeconds: UInt64 = (score?.isLive == true) ? 12 : 45
            try? await Task.sleep(nanoseconds: intervalSeconds * 1_000_000_000)
        }
    }
    */
}

func stopSportsStatsTracking() {
    sportsStatsTask?.cancel()
    sportsStatsTask = nil
    liveGameScore = nil
    detectedMatchQuery = nil
    isCheckingSportsStats = false
    isSportsProgram = false
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
        intentionallyPaused = false
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
        intentionallyPaused = true
        player.pause()
    }
}

func skipBackward(seconds: Double = 10) {
        let current = player.currentTime().seconds
        guard current.isFinite else { return }
        let target = max(current - seconds, seekableStart)
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600))
    }

    func skipForward(seconds: Double = 10) {
        if !isAtLiveEdge {
            let current = player.currentTime().seconds
            guard current.isFinite else { return }
            let target = min(current + seconds, seekableEnd)
            if target >= seekableEnd - 2 {
                goToLive()
            } else {
                player.seek(to: CMTime(seconds: target, preferredTimescale: 600))
            }
        } else {
            goToLive()
        }
    }

    func goToLive() {
    guard !isSwitchingChannel else { return }
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
    observeItem(fresh)
    
    intentionallyPaused = false
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

func stopAndDismiss(dismiss: (() -> Void)? = nil) {
    explicitCleanup()
    player.pause()
    player.replaceCurrentItem(with: nil)
    dismiss?()
}

// MARK: - Core Playback State Observer

private func setupPlaybackStateObserver() {
    playbackStateObserver = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
        guard let self = self else { return }
        let status = player.timeControlStatus
        let ticks = self.safeTicks(from: player.currentTime())
        
        DispatchQueue.main.async {
            guard !self.isSwitchingChannel else { return }
            
            if status == .waitingToPlayAtSpecifiedRate {
                self.isBuffering = true
            }
            
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
        
        if let itemId = self.channel?.id, !self.isSwitchingChannel {
            let isPaused = (status == .paused)
            Task { @MainActor in
                self.appState.reportPlaybackProgress(itemId: itemId, positionTicks: ticks, canSeek: false, isPaused: isPaused)
            }
        }
    }
}

private func setupStreamErrorRecovery() {
    NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)
        .receive(on: DispatchQueue.main)
        .sink { [weak self] notification in
            guard let self = self,
                  !self.isSwitchingChannel,
                  let item = notification.object as? AVPlayerItem,
                  let current = self.player.currentItem,
                  item === current else { return }
            
            if self.isMultiView {
                self.onStreamEnded?()
                return
            }
            
            self.isBuffering = true
            self.goToLive()
        }
        .store(in: &cancellables)

    NotificationCenter.default.publisher(for: .AVPlayerItemFailedToPlayToEndTime)
        .receive(on: DispatchQueue.main)
        .sink { [weak self] notification in
            guard let self = self,
                  !self.isSwitchingChannel,
                  let item = notification.object as? AVPlayerItem,
                  let current = self.player.currentItem,
                  item === current else { return }
            
            if self.isMultiView {
                self.onStreamEnded?()
                return
            }
            
            self.isBuffering = true
            self.goToLive()
        }
        .store(in: &cancellables)

    NotificationCenter.default.publisher(for: .AVPlayerItemPlaybackStalled)
        .receive(on: DispatchQueue.main)
        .sink { [weak self] notification in
            guard let self = self,
              !self.isSwitchingChannel,
              let item = notification.object as? AVPlayerItem,
              let current = self.player.currentItem,
              item === current else { return }
        
        self.isBuffering = true
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
        self?.updateNowPlayingInfo(title: title, subtitle: progId == nil ? nil : subtitle, progId: progId)
        self?.refreshSportsTracking()
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
            guard !self.isSwitchingChannel else { return }
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
    if let pObserver = progressObserver {
        player.removeTimeObserver(pObserver)
        self.progressObserver = nil
    }
    
    let interval = CMTime(seconds: 10, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
    progressObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
        guard let self = self,
              let currentItemId = self.channel?.id,
              !self.isSwitchingChannel else { return }
        
        let ticks = self.safeTicks(from: time)
        Task { @MainActor in
            self.appState.reportPlaybackProgress(itemId: currentItemId, positionTicks: ticks, canSeek: false)
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
@Environment(\.presentationMode) private var presentationMode

@StateObject private var vm: DragonetPlayerViewModel

@State private var playerController: DragonetPlayerController?

@State private var showMultiView = false
@State private var showAddChannelSheet = false
@State private var showChannelDrawer = false
@State private var showStatsSidebar = false
@State private var availableChannels: [LiveTvChannelDto] = []
@State private var channelPrograms: [String: JFProgram] = [:]
@State private var multiVM: DragonetMultiViewModel?
@State private var isTransitioningToMultiView = false
    @State private var isPartiallyFolded = false
    @State private var showRecordingSheet = false

let streamURL: URL
let channel: LiveTvChannelDto?
let program: JFProgram?
let onPlaybackError: ((String) -> Void)?

init(streamURL: URL, channel: LiveTvChannelDto?, program: JFProgram? = nil, appState: AppState, onPlaybackError: ((String) -> Void)? = nil) {
    AppDelegate.orientationLock = UIDevice.isiPhoneDuo ? .allButUpsideDown : .landscape
    self.streamURL = streamURL
    self.channel = channel
    self.program = program
    self.onPlaybackError = onPlaybackError
    _vm = StateObject(wrappedValue: DragonetPlayerViewModel(streamURL: streamURL, channel: channel, program: program, appState: appState))
}

var effectiveProgram: JFProgram? {
    if let p = vm.program { return p }
    if let cid = vm.channel?.id, let p = channelPrograms[cid] { return p }
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

    private var isTabletopMultiViewActive: Bool {
        guard let manager = multiVM else { return false }
        return manager.activeStreams.count > 1
    }

    private func exitMultiView() {
        if let manager = multiVM {
            let focusIndex = manager.activeAudioIndex
            let streamToKeep = manager.activeStreams.indices.contains(focusIndex) ? manager.activeStreams[focusIndex] : manager.activeStreams.first
            
            manager.selectedStreamToKeep = streamToKeep
            
            if let remaining = streamToKeep, remaining !== vm {
                vm.replaceStream(with: remaining)
            }
            manager.cleanup()
        }
        
        vm.player.isMuted = false
        if vm.isPlaying {
            vm.player.play()
        }
        
        self.multiVM = nil
    }

    var body: some View {
        DuoTabletopSplitLayout(isPartiallyFolded: isPartiallyFolded) {
            tabletopVideoPane
        } secondary: {
            tabletopDeckPane
        } normal: {
            normalPlayerContent
        }
        .duoHingeObservation(isPartiallyFolded: $isPartiallyFolded)
        .sheet(isPresented: $showRecordingSheet) {
            if let p = effectiveProgram {
                RecordingConfigurationView(viewModel: ProgramRecordingViewModel(program: p, appState: appState))
            }
        }
        .sheet(isPresented: $showAddChannelSheet) {
            let activeIds = multiVM?.activeStreams.compactMap { $0.channel?.id } ?? [vm.channel?.id].compactMap { $0 }
            MultiViewChannelPickerView(appState: appState, activeChannelIds: activeIds) { url, channel, program in
                if self.multiVM == nil {
                    let manager = DragonetMultiViewModel(appState: appState)
                    manager.adoptStream(self.vm)
                    self.multiVM = manager
                }
                self.multiVM?.addStream(url: url, channel: channel, program: program)
                
                // In tabletop mode, adding a channel stays inside the split view and does not take up the full screen
                let inTabletop = UIDevice.isiPhoneDuo && isPartiallyFolded
                if !inTabletop && !isPartiallyFolded {
                    self.showMultiView = true
                }
            }
        }
        .onChange(of: multiVM?.shouldDismiss) { _, should in
            if should == true {
                exitMultiView()
            }
        }
        .fullScreenCover(isPresented: $showMultiView, onDismiss: {
            if let manager = multiVM {
                let streamToKeep: DragonetPlayerViewModel?
                if let explicitlySelected = manager.selectedStreamToKeep {
                    streamToKeep = explicitlySelected
                } else {
                    let focusIndex = manager.activeAudioIndex
                    streamToKeep = manager.activeStreams.indices.contains(focusIndex) ? manager.activeStreams[focusIndex] : manager.activeStreams.first
                }
                
                manager.selectedStreamToKeep = streamToKeep
                
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
            vm.refreshSportsTracking()
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
                    let targetOrientation: UIInterfaceOrientationMask = UIDevice.isiPhoneDuo ? .allButUpsideDown : .landscapeRight
                    windowScene.requestGeometryUpdate(.iOS(interfaceOrientations: targetOrientation))
                }
            }
        }
        .task {
            await fetchChannelsAndPrograms()
            
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                await checkAndRefreshAiringProgramsIfNeeded()
            }
        }
        .onChange(of: appState.currentProgramId) { _, _ in
            Task {
                await fetchAiringPrograms()
            }
        }
        .onDisappear {
            if !isTransitioningToMultiView {
                AppDelegate.orientationLock = .portrait
                if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
                    windowScene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait))
                }
                multiVM?.cleanup()
                multiVM = nil
                vm.explicitCleanup()
            }
        }
        .onChange(of: vm.controlsVisible) { _, visible in
            if visible && !showChannelDrawer && !showStatsSidebar {
                playerController?.resetAutoHideTimer()
            } else {
                playerController?.cancelTimer()
            }
        }
    }

    // MARK: - iPhone Duo Tabletop Panes

    private var tabletopVideoPane: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if isTabletopMultiViewActive, let manager = multiVM {
                let activeIdx = manager.activeAudioIndex
                let prominentVM = manager.activeStreams.indices.contains(activeIdx) ? manager.activeStreams[activeIdx] : (manager.activeStreams.first ?? vm)
                
                DragonetPlayer(
                    player: prominentVM.player,
                    streamURL: prominentVM.streamURL,
                    isPiPActive: Binding(
                        get: { prominentVM.isPiPActive },
                        set: { prominentVM.isPiPActive = $0 }
                    ),
                    isCCEnabled: Binding(
                        get: { prominentVM.isCCEnabled },
                        set: { prominentVM.isCCEnabled = $0 }
                    ),
                    controlsVisible: .constant(false),
                    onPlaybackError: { [weak prominentVM] _ in
                        guard let prominentVM = prominentVM else { return }
                        manager.removeStream(prominentVM)
                    }
                ) { vc in
                    prominentVM.startPlayback()
                }
                .ignoresSafeArea()
                .id(prominentVM.streamURL)
                
                VStack {
                    HStack {
                        DuoTabletopStatusBadge(isLive: true, customText: prominentVM.channel?.name)
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    Spacer()
                }
            } else {
                makePlayer()
                    .ignoresSafeArea()

                if vm.isExternalPlaybackActive {
                    airplayActiveOverlay
                        .zIndex(0.5)
                }

                bufferImageOverlay
                    .zIndex(1)
                    .allowsHitTesting(false)
                    .opacity((!vm.hasRenderedVideo && !vm.isExternalPlaybackActive) ? 1 : 0)
                    .animation(.easeInOut(duration: 0.4), value: vm.hasRenderedVideo)

                spinnerOverlay
                    .zIndex(2)
                    .allowsHitTesting(false)
                    .opacity(vm.isBuffering ? 1 : 0)
                    .animation(.easeInOut(duration: 0.2), value: vm.isBuffering)
            }
        }
    }

    private var tabletopDeckPane: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if isTabletopMultiViewActive, let manager = multiVM {
                DragonetTabletopMultiViewDeckView(
                    multiVM: manager,
                    appState: appState,
                    showAddChannelSheet: $showAddChannelSheet,
                    showFullScreenMultiView: $showMultiView,
                    onExitMultiView: {
                        exitMultiView()
                    },
                    onDismiss: {
                        presentationMode.wrappedValue.dismiss()
                    }
                )
            } else {
                DragonetTabletopDeckView(
                    vm: vm,
                    appState: appState,
                    dismiss: {
                        presentationMode.wrappedValue.dismiss()
                    },
                    showChannelDrawer: $showChannelDrawer,
                    showStatsSidebar: $showStatsSidebar,
                    showAddChannelSheet: $showAddChannelSheet,
                    showRecordingSheet: $showRecordingSheet,
                    playerController: playerController,
                    effectiveProgram: effectiveProgram
                )

                if showChannelDrawer {
                    channelSwitchDrawer
                        .zIndex(4)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                // Sports stats sidebar (Temporarily removed, saving for 2.4.1)
                /*
                if showStatsSidebar {
                    statsSidebarView
                        .zIndex(5)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
                */
            }
        }
    }

    private var normalPlayerContent: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if isTabletopMultiViewActive, let manager = multiVM {
                DragonetMultiView(multiVM: manager)
                    .environmentObject(appState)
            } else {
                makePlayer()
                    .ignoresSafeArea()

                if vm.isExternalPlaybackActive {
                    airplayActiveOverlay
                        .zIndex(0.5)
                }

                bufferImageOverlay
                    .zIndex(1)
                    .allowsHitTesting(false)
                    .opacity((!vm.hasRenderedVideo && !vm.isExternalPlaybackActive) ? 1 : 0)
                    .animation(.easeInOut(duration: 0.4), value: vm.hasRenderedVideo)

                spinnerOverlay
                    .zIndex(2)
                    .allowsHitTesting(false)
                    .opacity(vm.isBuffering ? 1 : 0)
                    .animation(.easeInOut(duration: 0.2), value: vm.isBuffering)

                landscapeOverlay
                    .zIndex(3)
                    .opacity(vm.controlsVisible && !showChannelDrawer ? 1 : 0)
                    .allowsHitTesting(vm.controlsVisible && !showChannelDrawer)

                if showChannelDrawer {
                    channelSwitchDrawer
                        .zIndex(4)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                // Sports stats sidebar (Temporarily removed, saving for 2.4.1)
                /*
                if showStatsSidebar {
                    statsSidebarView
                        .zIndex(5)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
                */
            }
        }
        .gesture(
            DragGesture(minimumDistance: 25)
                .onEnded { value in
                    if value.translation.height < -40 {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                            showChannelDrawer = true
                        }
                        playerController?.cancelTimer()
                    } else if value.translation.height > 40 {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                            showChannelDrawer = false
                        }
                        if vm.controlsVisible && !showStatsSidebar {
                            playerController?.resetAutoHideTimer()
                        }
                    }
                }
        )
    }

// MARK: - Channel Switcher Drawer (Swipe-Up Row)

private var channelSwitchDrawer: some View {
    VStack(spacing: 0) {
        Spacer()
        
        VStack(alignment: .center, spacing: 8) {
            HStack {
                Capsule()
                    .fill(Color.white.opacity(0.4))
                    .frame(width: 36, height: 4)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 8)
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    showChannelDrawer = false
                }
            }
            
            Text("Quick Switch")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)

            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 12) {
                        ForEach(availableChannels) { ch in
                            let isCurrent = ch.id == vm.channel?.id
                            let prog = channelPrograms[ch.id]
                            let targetImageId = prog?.id ?? ch.id
                            let isRecording = (prog?.timerId != nil || prog?.seriesTimerId != nil)
                            
                            Button {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                    showChannelDrawer = false
                                }
                                vm.switchChannel(to: ch, program: prog)
                            } label: {
                                ZStack {
                                    let server = appState.serverURL.hasSuffix("/") ? String(appState.serverURL.dropLast()) : appState.serverURL
                                    let imageURLString = "\(server)/Items/\(targetImageId)/Images/Primary?api_key=\(appState.accessToken)&maxWidth=500&quality=80"
                                    let imageURL = URL(string: imageURLString)
                                    
                                    CachedAsyncImage(url: imageURL) { phase in
                                        switch phase {
                                        case .success(let img):
                                            img
                                                .resizable()
                                                .aspectRatio(contentMode: .fill)
                                        default:
                                            Color.white.opacity(0.08)
                                        }
                                    }
                                    .frame(width: 150, height: 84)
                                    .clipped()
                                    
                                    LinearGradient(
                                        colors: [.clear, Color.black.opacity(0.8)],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                    
                                    VStack {
                                        Spacer()
                                        HStack {
                                            ChannelImageView(
                                                baseUrl: appState.serverURL,
                                                apiKey: appState.accessToken,
                                                channelId: ch.id
                                            )
                                            .frame(width: 30, height: 30)
                                            .shadow(color: .black.opacity(0.9), radius: 3)
                                            
                                            Spacer()
                                            
                                            if isRecording {
                                                Image(systemName: "record.circle")
                                                    .font(.system(size: 15))
                                                    .foregroundStyle(.red)
                                                    .shadow(color: .black.opacity(0.6), radius: 3, x: 0, y: 1)
                                            }
                                        }
                                        .padding(6)
                                    }
                                }
                                .frame(width: 150, height: 84)
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .stroke(isCurrent ? Color.accentColor : Color.white.opacity(0.18), lineWidth: isCurrent ? 2.5 : 1)
                                )
                                .shadow(color: isCurrent ? Color.accentColor.opacity(0.35) : Color.black.opacity(0.3), radius: 6)
                            }
                            .buttonStyle(.plain)
                            .id(ch.id)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 2)
                }
                .frame(height: 90)
                .onAppear {
                    if let currentId = vm.channel?.id {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                            proxy.scrollTo(currentId, anchor: .center)
                        }
                    }
                }
                .onChange(of: showChannelDrawer) { _, isShown in
                    if isShown, let currentId = vm.channel?.id {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                            proxy.scrollTo(currentId, anchor: .center)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 4)
        .padding(.bottom, 12)
        .glassEffect(in: .rect(cornerRadius: 16.0))
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    .ignoresSafeArea()
}

// MARK: - Channel & Program Fetching

private func fetchChannelsAndPrograms() async {
    guard !appState.serverURL.isEmpty else { return }
    let server = appState.serverURL.hasSuffix("/") ? String(appState.serverURL.dropLast()) : appState.serverURL
    
    var comps = URLComponents(string: "\(server)/LiveTv/Channels")
    comps?.queryItems = [
        URLQueryItem(name: "Limit", value: "500"),
        URLQueryItem(name: "StartIndex", value: "0"),
        URLQueryItem(name: "EnableImages", value: "true"),
        URLQueryItem(name: "EnableUserData", value: "true")
    ]
    if !appState.userID.isEmpty {
        comps?.queryItems?.append(URLQueryItem(name: "UserId", value: appState.userID))
    }
    guard let channelUrl = comps?.url else { return }
    
    var req = URLRequest(url: channelUrl)
    req.httpMethod = "GET"
    if !appState.accessToken.isEmpty {
        req.setValue(appState.accessToken, forHTTPHeaderField: "X-Emby-Token")
        req.setValue(appState.getAuthorizationHeader(), forHTTPHeaderField: "Authorization")
    }
    
    do {
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return }
        struct JFChannelQueryResult: Decodable {
            let Items: [LiveTvChannelDto]?
        }
        let res = try JSONDecoder().decode(JFChannelQueryResult.self, from: data)
        guard let channels = res.Items, !channels.isEmpty else { return }
        
        self.availableChannels = channels
        await fetchAiringPrograms()
    } catch {
        print("Failed to fetch channels: \(error)")
    }
}

private func checkAndRefreshAiringProgramsIfNeeded() async {
    let now = Date()
    let hasExpiredProgram = channelPrograms.values.contains { prog in
        if let end = prog.endDate { return end <= now }
        if let start = prog.startDate, let ticks = prog.runTimeTicks {
            let durationSec = TimeInterval(Double(ticks) / 10_000_000.0)
            return start.addingTimeInterval(durationSec) <= now
        }
        return false
    }
    
    if hasExpiredProgram || channelPrograms.isEmpty {
        await fetchAiringPrograms()
    }
}

private func fetchAiringPrograms() async {
    guard !appState.serverURL.isEmpty else { return }
    let server = appState.serverURL.hasSuffix("/") ? String(appState.serverURL.dropLast()) : appState.serverURL
    
    var progComps = URLComponents(string: "\(server)/LiveTv/Programs")
    progComps?.queryItems = [
        URLQueryItem(name: "IsAiring", value: "true"),
        URLQueryItem(name: "Limit", value: "500"),
        URLQueryItem(name: "fields", value: "Overview,OfficialRating,Genres,SeriesName,EpisodeTitle,RunTimeTicks,ParentIndexNumber,IndexNumber,ChannelId,ProgramId,TimerId,SeriesTimerId,PrimaryImageAspectRatio")
    ]
    if !appState.userID.isEmpty {
        progComps?.queryItems?.append(URLQueryItem(name: "userId", value: appState.userID))
    }
    
    guard let progUrl = progComps?.url else { return }
    var progReq = URLRequest(url: progUrl)
    progReq.httpMethod = "GET"
    if !appState.accessToken.isEmpty {
        progReq.setValue(appState.accessToken, forHTTPHeaderField: "X-Emby-Token")
        progReq.setValue(appState.getAuthorizationHeader(), forHTTPHeaderField: "Authorization")
    }
    
    do {
        let (pData, pResp) = try await URLSession.shared.data(for: progReq)
        guard let pHttp = pResp as? HTTPURLResponse, pHttp.statusCode == 200 else { return }
        
        if let root = try? JSONSerialization.jsonObject(with: pData) as? [String: Any],
           let items = (root["Items"] ?? root["items"]) as? [[String: Any]] {
            let now = Date()
            var progMap: [String: JFProgram] = [:]
            
            for dict in items {
                if let program = JFProgram(json: dict), let cid = program.channelId {
                    let notEnded: Bool = {
                        if let end = program.endDate { return end > now }
                        if let start = program.startDate, let ticks = program.runTimeTicks {
                            return start.addingTimeInterval(TimeInterval(Double(ticks) / 10_000_000.0)) > now
                        }
                        return true
                    }()
                    
                    if notEnded {
                        progMap[cid] = program
                    }
                }
            }
            
            withAnimation(.easeInOut(duration: 0.3)) {
                self.channelPrograms = progMap
            }
            
            if let currentChannelId = vm.channel?.id, let activeProgram = progMap[currentChannelId] {
                if vm.program?.id != activeProgram.id {
                    vm.program = activeProgram
                    appState.currentProgramTitle = activeProgram.name
                    appState.currentProgramSubtitle = activeProgram.episodeTitle ?? activeProgram.overview
                    appState.currentProgramId = activeProgram.id
                    appState.currentProgramStartDate = activeProgram.startDate
                    appState.currentProgramEndDate = activeProgram.endDate
                    appState.currentProgramIsMovie = activeProgram.isMovie
                    appState.currentProgramGenres = activeProgram.genres
                    vm.restoreNowPlaying()
                    vm.refreshSportsTracking()
                }
            }
        }
    } catch {
        print("Failed to fetch airing programs: \(error)")
    }
}

// MARK: - Loading Overlays

private var bufferImageOverlay: some View {
    ZStack {
        Color.black.ignoresSafeArea()
        
        let effectiveProg = vm.program ?? channelPrograms[vm.channel?.id ?? ""]
        let targetId = effectiveProg?.id ?? appState.currentProgramId ?? vm.channel?.id
        
        if let targetId = targetId {
            let server = appState.serverURL.hasSuffix("/") ? String(appState.serverURL.dropLast()) : appState.serverURL
            
            let cachedThumbnailURL = "\(server)/Items/\(targetId)/Images/Primary?api_key=\(appState.accessToken)&maxWidth=500&quality=80"
            let highResBackdropURL = "\(server)/Items/\(targetId)/Images/Primary?api_key=\(appState.accessToken)&maxWidth=1280&quality=85"
            
            ZStack {
                CachedAsyncImage(url: URL(string: cachedThumbnailURL)) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                    default:
                        EmptyView()
                    }
                }
                
                CachedAsyncImage(url: URL(string: highResBackdropURL)) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                    default:
                        if let cid = vm.channel?.id {
                            ChannelImageView(
                                baseUrl: appState.serverURL,
                                apiKey: appState.accessToken,
                                channelId: cid
                            )
                            .frame(maxWidth: 240, maxHeight: 240)
                            .aspectRatio(contentMode: .fit)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea()
            .opacity(0.35)
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

private var airplayActiveOverlay: some View {
    ZStack {
        Color.black.ignoresSafeArea()
        
        VStack(spacing: 18) {
            Image(systemName: "airplayvideo")
                .font(.system(size: 64, weight: .light))
                .foregroundStyle(.white)
            
            VStack(spacing: 6) {
                Text("AirPlay")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.white)
                
                Text("This video is playing on \"\(vm.externalPlaybackDeviceName ?? "AirPlay")\"")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.8))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
        }
    }
    .contentShape(Rectangle())
    .onTapGesture {
        if showChannelDrawer {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                showChannelDrawer = false
            }
            return
        }
        if showStatsSidebar {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                showStatsSidebar = false
            }
            return
        }
        withAnimation(.easeOut(duration: 0.2)) {
            vm.controlsVisible.toggle()
        }
        if vm.controlsVisible {
            playerController?.resetAutoHideTimer()
        }
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
            if showChannelDrawer {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    showChannelDrawer = false
                }
                return
            }
            if showStatsSidebar {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    showStatsSidebar = false
                }
                return
            }
            withAnimation(.easeOut(duration: 0.2)) {
                vm.controlsVisible.toggle()
            }
            if vm.controlsVisible { vc?.resetAutoHideTimer() }
        }
        vc.onAutoHide = {
            if !showChannelDrawer && !showStatsSidebar {
                withAnimation(.easeOut(duration: 0.4)) {
                    vm.controlsVisible = false
                }
            }
        }
        playerController = vc
        
        if vm.controlsVisible && !showChannelDrawer && !showStatsSidebar {
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
                if appState.canManageRecordings, let effProg = effectiveProgram {
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

        // Bottom Controls Row
        HStack(spacing: 20) {
            playPauseButton
            
            liveBadge
            
            if vm.isRecording {
                scrubberView
            } else {
                Spacer()
            }

            // Sports Stats Liquid Glass Trigger (Bottom-Right) (Temporarily removed, saving for 2.4.1)
            /*
            if vm.isSportsProgram && vm.detectedMatchQuery != nil {
                liquidGlassStatsButton
            }
            */
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

// MARK: - Liquid Glass Bottom-Right Stats Button (Temporarily removed, saving for 2.4.1)
/*
// MARK: - Liquid Glass Bottom-Right Stats Button

private var liquidGlassStatsButton: some View {
    Button {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            showStatsSidebar.toggle()
        }
        if showStatsSidebar {
            playerController?.cancelTimer()
        } else {
            playerController?.resetAutoHideTimer()
        }
    } label: {
        HStack(spacing: 10) {
            if let score = vm.liveGameScore {
                // Away Team Logo & Abbreviation
                HStack(spacing: 5) {
                    teamLogoImage(url: score.awayLogoURL, size: 20)
                    if let rank = score.awayRank {
                        Text("#\(rank)")
                            .font(.system(size: 10, weight: .black))
                            .foregroundColor(.yellow)
                    }
                    Text(score.awayTeamAbbr)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.white)
                }

                // Score or VS separator
                if score.isPreGame {
                    Text("vs")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white.opacity(0.6))
                } else {
                    Text("\(score.awayScore) - \(score.homeScore)")
                        .font(.system(size: 14, weight: .black, design: .rounded))
                        .foregroundColor(.white)
                }

                // Home Team Logo & Abbreviation
                HStack(spacing: 5) {
                    Text(score.homeTeamAbbr)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.white)
                    if let rank = score.homeRank {
                        Text("#\(rank)")
                            .font(.system(size: 10, weight: .black))
                            .foregroundColor(.yellow)
                    }
                    teamLogoImage(url: score.homeLogoURL, size: 20)
                }

                // Status Indicator
                HStack(spacing: 4) {
                    Circle()
                        .fill(score.isLive ? Color.red : (score.isFinal ? Color.gray : Color.blue))
                        .frame(width: 6, height: 6)
                    Text(score.statusDisplay)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(score.isLive ? .red : .white.opacity(0.85))
                        .lineLimit(1)
                }
                .padding(.leading, 2)
            } else {
                // Match resolved but waiting for live stats polling
                HStack(spacing: 8) {
                    if vm.isCheckingSportsStats {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                            .scaleEffect(0.7)
                    } else {
                        Image(systemName: "chart.bar.xaxis")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(.white)
                    }
                    Text(vm.detectedMatchQuery?.isPregame == true ? "Preview" : (vm.detectedMatchQuery?.isPostgame == true ? "Postgame" : "Match Stats"))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                }
            }

            Image(systemName: showStatsSidebar ? "chevron.right" : "sidebar.right")
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(.white.opacity(0.8))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            Capsule()
                .fill(Color.white.opacity(0.08))
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(
                    Capsule()
                        .stroke(
                            LinearGradient(
                                colors: [.white.opacity(0.55), .white.opacity(0.12), .clear],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1
                        )
                )
        )
        .shadow(color: .black.opacity(0.4), radius: 10, x: 0, y: 4)
    }
    .accessibilityLabel("Sports Game Stats and Scoreboard")
}

// MARK: - Slide-out Stats Sidebar

private var statsSidebarView: some View {
    HStack(spacing: 0) {
        Spacer()
        
        VStack(spacing: 0) {
            statsSidebarHeader
            
            Divider()
                .background(Color.white.opacity(0.15))
            
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 20) {
                    if let score = vm.liveGameScore {
                        statsPrimaryScoreCard(score)
                        
                        if !score.isPreGame && (!score.awayLineScores.isEmpty || !score.homeLineScores.isEmpty) {
                            statsLineScoresView(score)
                        }
                        
                        statsMatchupDetailsView(score)
                    } else {
                        statsLoadingView
                    }
                }
                .padding(20)
            }
        }
        .frame(width: 360)
        .background(
            Color.black.opacity(0.85)
                .background(.ultraThinMaterial)
        )
        .overlay(
            Rectangle()
                .fill(Color.white.opacity(0.12))
                .frame(width: 1),
            alignment: .leading
        )
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
    .ignoresSafeArea()
}

private var statsSidebarHeader: some View {
    HStack {
        VStack(alignment: .leading, spacing: 2) {
            Text(vm.liveGameScore?.league.displayName.uppercased() ?? "SPORTS STATS")
                .font(.system(size: 11, weight: .black))
                .foregroundColor(.blue)
            
            Text(vm.liveGameScore?.isPreGame == true ? "Game Preview" : (vm.liveGameScore?.isFinal == true ? "Final Score" : "Live Gamecast"))
                .font(.headline.weight(.bold))
                .foregroundColor(.white)
        }
        
        Spacer()
        
        Button {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                showStatsSidebar = false
            }
            if vm.controlsVisible { playerController?.resetAutoHideTimer() }
        } label: {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 24))
                .foregroundColor(.white.opacity(0.6))
        }
    }
    .padding(.horizontal, 20)
    .padding(.top, 24)
    .padding(.bottom, 16)
}

@ViewBuilder
private func teamScoreColumn(logoURL: URL?, rank: Int?, name: String, record: String?) -> some View {
    VStack(spacing: 6) {
        teamLogoImage(url: logoURL, size: 52)
        
        if let rank = rank {
            Text("#\(rank)")
                .font(.system(size: 11, weight: .black))
                .foregroundColor(.yellow)
        }
        
        Text(name)
            .font(.callout.weight(.bold))
            .foregroundColor(.white)
            .multilineTextAlignment(.center)
            .lineLimit(2)
        
        if let rec = record {
            Text("(\(rec))")
                .font(.caption2)
                .foregroundColor(.white.opacity(0.6))
        }
    }
    .frame(maxWidth: .infinity)
}

@ViewBuilder
private func cardBackgroundView(cornerRadius: CGFloat = 14, opacity: Double = 0.04) -> some View {
    RoundedRectangle(cornerRadius: cornerRadius)
        .fill(Color.white.opacity(opacity))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius)
                .stroke(Color.white.opacity(opacity * 2.0), lineWidth: 1)
        )
}

@ViewBuilder
private func statsStatusBanner(_ score: LiveGameScore) -> some View {
    HStack {
        if score.isLive {
            HStack(spacing: 5) {
                Circle().fill(Color.red).frame(width: 8, height: 8)
                Text("LIVE")
                    .font(.system(size: 11, weight: .black))
                    .foregroundColor(.red)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.red.opacity(0.15)))
        } else if score.isFinal {
            Text("FINAL")
                .font(.system(size: 11, weight: .black))
                .foregroundColor(.white.opacity(0.8))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.white.opacity(0.15)))
        } else {
            Text("UPCOMING")
                .font(.system(size: 11, weight: .black))
                .foregroundColor(.blue)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.blue.opacity(0.15)))
        }
        
        Spacer()
        
        Text(score.statusDisplay)
            .font(.subheadline.weight(.semibold))
            .foregroundColor(.white.opacity(0.9))
    }
}

@ViewBuilder
private func statsScoreCenterView(_ score: LiveGameScore) -> some View {
    VStack(spacing: 4) {
        if score.isPreGame {
            Text("VS")
                .font(.title2.weight(.black))
                .foregroundColor(.white.opacity(0.5))
            if let start = score.startTimeDisplay {
                Text(start)
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.white.opacity(0.8))
            }
        } else {
            HStack(spacing: 12) {
                Text("\(score.awayScore)")
                    .font(.system(size: 34, weight: .black, design: .rounded))
                    .foregroundColor(.white)
                
                Text("-")
                    .font(.title2.bold())
                    .foregroundColor(.white.opacity(0.4))
                
                Text("\(score.homeScore)")
                    .font(.system(size: 34, weight: .black, design: .rounded))
                    .foregroundColor(.white)
            }
        }
    }
    .frame(minWidth: 90)
}

@ViewBuilder
private func statsPrimaryScoreCard(_ score: LiveGameScore) -> some View {
    VStack(spacing: 16) {
        statsStatusBanner(score)
        
        HStack(alignment: .center) {
            teamScoreColumn(logoURL: score.awayLogoURL, rank: score.awayRank, name: score.awayTeamName, record: score.awayRecord)
            statsScoreCenterView(score)
            teamScoreColumn(logoURL: score.homeLogoURL, rank: score.homeRank, name: score.homeTeamName, record: score.homeRecord)
        }
    }
    .padding(18)
    .background(cardBackgroundView(cornerRadius: 16, opacity: 0.06))
}

@ViewBuilder
private func lineScoreHeaderRow(totalCols: Int) -> some View {
    HStack {
        Text("TEAM")
            .font(.caption2.bold())
            .foregroundColor(.white.opacity(0.5))
            .frame(width: 54, alignment: .leading)
        
        ForEach(0..<totalCols, id: \.self) { idx in
            Text("\(idx + 1)")
                .font(.caption2.bold())
                .foregroundColor(.white.opacity(0.5))
                .frame(maxWidth: .infinity)
        }
        
        Text("T")
            .font(.system(size: 11, weight: .black))
            .foregroundColor(.white)
            .frame(width: 32, alignment: .trailing)
    }
}

@ViewBuilder
private func lineScoreRow(logoURL: URL?, abbr: String, lineScores: [Int], totalCols: Int, totalScore: Int) -> some View {
    HStack {
        HStack(spacing: 4) {
            teamLogoImage(url: logoURL, size: 14)
            Text(abbr)
                .font(.caption.bold())
                .foregroundColor(.white)
        }
        .frame(width: 54, alignment: .leading)
        
        ForEach(0..<totalCols, id: \.self) { idx in
            let itemText = idx < lineScores.count ? "\(lineScores[idx])" : "-"
            Text(itemText)
                .font(.caption.monospacedDigit())
                .foregroundColor(.white.opacity(0.9))
                .frame(maxWidth: .infinity)
        }
        
        Text("\(totalScore)")
            .font(.caption.bold())
            .foregroundColor(.white)
            .frame(width: 32, alignment: .trailing)
    }
}

@ViewBuilder
private func statsLineScoresView(_ score: LiveGameScore) -> some View {
    let totalCols = max(score.awayLineScores.count, score.homeLineScores.count)
    let awayRow = lineScoreRow(
        logoURL: score.awayLogoURL,
        abbr: score.awayTeamAbbr,
        lineScores: score.awayLineScores,
        totalCols: totalCols,
        totalScore: score.awayScore
    )
    let homeRow = lineScoreRow(
        logoURL: score.homeLogoURL,
        abbr: score.homeTeamAbbr,
        lineScores: score.homeLineScores,
        totalCols: totalCols,
        totalScore: score.homeScore
    )
    
    VStack(alignment: .leading, spacing: 10) {
        Text("SCORING SUMMARY")
            .font(.system(size: 12, weight: .black))
            .foregroundColor(.white.opacity(0.6))
        
        lineScoreHeaderRow(totalCols: totalCols)
        
        Divider().background(Color.white.opacity(0.1))
        
        awayRow
        homeRow
    }
    .padding(16)
    .background(cardBackgroundView(cornerRadius: 14, opacity: 0.04))
}

@ViewBuilder
private func statsMatchupItem(label: String, icon: String, value: String, lineLimit: Int? = nil) -> some View {
    HStack {
        Label(label, systemImage: icon)
            .font(.caption)
            .foregroundColor(.white.opacity(0.6))
        Spacer()
        if let lineLimit = lineLimit {
            Text(value)
                .font(.caption.bold())
                .foregroundColor(.white)
                .lineLimit(lineLimit)
        } else {
            Text(value)
                .font(.caption.bold())
                .foregroundColor(.white)
        }
    }
}

@ViewBuilder
private func statsMatchupDetailsView(_ score: LiveGameScore) -> some View {
    VStack(spacing: 12) {
        if let odds = score.oddsSummary {
            statsMatchupItem(label: "Odds / Spread", icon: "chart.line.uptrend.xyaxis", value: odds)
        }
        
        if let ou = score.overUnder {
            statsMatchupItem(label: "Total Line", icon: "arrow.up.and.down.circle", value: ou)
        }
        
        if let venue = score.venueName {
            statsMatchupItem(label: "Venue", icon: "mappin.and.ellipse", value: venue, lineLimit: 1)
        }
        
        if let net = score.broadcastNetwork {
            statsMatchupItem(label: "Broadcast", icon: "tv", value: net)
        }
    }
    .padding(16)
    .background(cardBackgroundView(cornerRadius: 14, opacity: 0.04))
}

private var statsLoadingView: some View {
    VStack(spacing: 14) {
        ProgressView()
            .progressViewStyle(CircularProgressViewStyle(tint: .white))
            .scaleEffect(1.2)
        
        Text("Connecting to Live Gamecast...")
            .font(.subheadline)
            .foregroundColor(.white.opacity(0.7))
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 40)
}

// MARK: - Team Logo Helper

@ViewBuilder
private func teamLogoImage(url: URL?, size: CGFloat) -> some View {
    if let url = url {
        AsyncImage(url: url) { phase in
            switch phase {
            case .success(let image):
                image
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: size, height: size)
            default:
                Circle()
                    .fill(Color.white.opacity(0.15))
                    .frame(width: size, height: size)
            }
        }
    } else {
        Circle()
            .fill(Color.white.opacity(0.15))
            .frame(width: size, height: size)
    }
}

*/

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
    let rangeStart: Double = max(vm.seekableStart, 0)
    let rangeEnd: Double = max(vm.seekableEnd, rangeStart + 1)

    let sliderBinding = Binding<Double>(
        get: { max(min(vm.currentTime, rangeEnd), rangeStart) },
        set: { val in vm.currentTime = val }
    )

    return HStack(spacing: 12) {
        Text(formatTime(vm.currentTime - vm.seekableStart))
            .font(.caption.monospacedDigit())
            .foregroundColor(.white)

        Slider(
            value: sliderBinding,
            in: rangeStart...rangeEnd,
            onEditingChanged: { editing in
                vm.isScrubbing = editing
                if !editing {
                    let targetTime = CMTime(seconds: vm.currentTime, preferredTimescale: 600)
                    vm.player.seek(to: targetTime)
                    playerController?.resetAutoHideTimer()
                }
            }
        )
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
    DragonetAirPlayButton(player: vm.player) { presenting in
        if presenting {
            playerController?.cancelTimer()
        } else {
            if vm.controlsVisible && !showChannelDrawer && !showStatsSidebar {
                playerController?.resetAutoHideTimer()
            }
        }
    }
    .frame(width: 44, height: 44)
    .glassEffect(in: Circle())
}

private var closeButton: some View {
    Button { vm.stopAndDismiss(dismiss: { presentationMode.wrappedValue.dismiss() }) } label: {
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
    @State private var showRecordingSheet: Bool = false

    init(program: JFProgram, appState: AppState) {
        _recordingViewModel = StateObject(
            wrappedValue: ProgramRecordingViewModel(program: program, appState: appState)
        )
    }

    private var isScheduled: Bool {
        recordingViewModel.isRecordingScheduled == true
    }

    private var iconImage: some View {
        let name: String = isScheduled ? "record.circle.fill" : "record.circle"
        let fgColor: Color = isScheduled ? .red : .white
        let bgColor: Color = isScheduled ? Color.red.opacity(0.4) : .clear

        return Image(systemName: name)
            .font(.system(size: 18, weight: .medium))
            .foregroundStyle(fgColor)
            .frame(width: 44, height: 44)
            .background(bgColor)
    }

    var body: some View {
        Button(action: {
            showRecordingSheet = true
        }) {
            iconImage
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
                .glassEffect(.regular, in: shape)
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
