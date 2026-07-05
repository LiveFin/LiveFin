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

// MARK: - Models

struct JFDynamicChapter: Decodable {
    let Name: String?
    let StartPositionTicks: Int64?
    let MarkerType: String?
}

// Added modern Marker model for Jellyfin 10.9+ / Intro Skipper
struct JFDynamicMarker: Decodable {
    let Id: Int?
    let Name: String?
    let PositionTicks: Int64?
    let EndPositionTicks: Int64?
    let MarkerType: String?
}

struct JFMediaStream: Decodable, Hashable {
    let Index: Int?
    let type: String? // "Audio", "Subtitle", "Video"
    let Language: String?
    let Title: String?
    let DisplayTitle: String?
    let IsDefault: Bool?
    let IsForced: Bool?
    
    // Support for server-driven delivery URLs (ChatGPT feedback)
    let DeliveryUrl: String?
    let DeliveryMethod: String?
    let IsExternal: Bool?
    let Codec: String?
    
    enum CodingKeys: String, CodingKey {
        case Index
        case type = "Type"
        case Language
        case Title
        case DisplayTitle
        case IsDefault
        case IsForced
        case DeliveryUrl
        case DeliveryMethod
        case IsExternal
        case Codec
    }
    
    var safeDisplayName: String {
        if let display = DisplayTitle, !display.isEmpty { return display }
        if let title = Title, !title.isEmpty, title.lowercased() != "und" { return title }
        if let lang = Language, !lang.isEmpty { return Locale.current.localizedString(forLanguageCode: lang)?.capitalized ?? lang.uppercased() }
        
        return "Unknown Track"
    }
}

struct JFMediaSource: Decodable {
    let Id: String?
    let MediaStreams: [JFMediaStream]?
}

struct JFItemMediaData: Decodable {
    let Chapters: [JFDynamicChapter]?
    let MediaSources: [JFMediaSource]?
    let Markers: [JFDynamicMarker]? // Added support for native intro markers
}

struct VTTCue: Identifiable, Sendable {
    let id = UUID()
    let startTime: Double
    let endTime: Double
    let text: String
}

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
    
    // Guard flag to prevent feedback loops when the player item changes, reloads, or resets
    @Published var isSettingUpPlayerItem: Bool = false
    
    // Auto Play Next
    @Published var autoPlayNextEpisode: Bool = true
    
    // Audio Tracks
    @Published var availableAudioTracks: [JFMediaStream] = []
    @Published var selectedAudioTrack: JFMediaStream? = nil
    
    // Subtitle Tracks & Sidecar State
    @Published var availableSubtitleTracks: [JFMediaStream] = []
    @Published var selectedSubtitleTrack: JFMediaStream? = nil
    
    @Published var vttCues: [VTTCue] = []
    @Published var currentSubtitleText: String = ""
    @Published var currentMediaSourceId: String? = nil
    @Published var defaultMediaSourceId: String? = nil
    private var activeSubtitleTask: Task<Void, Never>? = nil
    
    // Scrubber & Chapters State
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var isScrubbing: Bool = false
    @Published var isSeeking: Bool = false
    @Published var activeChapters: [JFDynamicChapter] = []
    @Published var activeMarkers: [JFDynamicMarker] = []
    
    // Next Episode Countdown State
    @Published var showNextEpisodeCountdown: Bool = false
    @Published var nextEpisodeCountdown: Int = 5
    private var countdownDismissed: Bool = false
    private var countdownTimerTask: Task<Void, Never>? = nil
    
    let appState: AppState
    @Published var streamURL: URL? = nil
    
    private var timeObserver: Any?
    private var itemStatusObserver: NSKeyValueObservation?
    private var playbackStateObserver: NSKeyValueObservation?
    private var cancellables = Set<AnyCancellable>()
    
    private var hasResumedCurrentItem = false
    private var lastReportedTicks: Int64 = 0
    
    // Local dictionary cache to prevent Apple's MPNowPlayingInfoCenter from returning nil/wiping out items
    private var nowPlayingInfo: [String: Any] = [:]
    
    var onFinishedPlaylist: (() -> Void)?

    init(playlist: [JFItemDto], startIndex: Int, seriesName: String?, appState: AppState) {
        self.playlist = playlist
        self.currentIndex = startIndex
        self.seriesName = seriesName
        self.appState = appState
        
        self.player.automaticallyWaitsToMinimizeStalling = true
        self.isSettingUpPlayerItem = true
        
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
        self.isSettingUpPlayerItem = false
        activeSubtitleTask?.cancel()
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
    
    var hasNextEpisode: Bool {
        return currentIndex + 1 < playlist.count
    }
    
    var isEpisode: Bool {
        return currentItem?.Type.lowercased() == "episode"
    }
    
    var currentIntroEndTarget: Double? {
        let currentTicks = Int64(currentTime * 10_000_000)
        
        for marker in activeMarkers {
            let startTicks = marker.PositionTicks ?? 0
            let endTicks = marker.EndPositionTicks ?? .max
            
            if currentTicks >= startTicks && currentTicks < endTicks {
                let name = marker.Name?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let type = marker.MarkerType?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                
                if type == "introstart" || type == "intro" || name.contains("intro") {
                    return Double(endTicks) / 10_000_000.0
                }
            }
        }
        
        for (index, chapter) in activeChapters.enumerated() {
            let startTicks = chapter.StartPositionTicks ?? 0
            let nextTicks = (index + 1 < activeChapters.count) ? (activeChapters[index + 1].StartPositionTicks ?? .max) : .max
            
            if currentTicks >= startTicks && currentTicks < nextTicks {
                let name = chapter.Name?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let type = chapter.MarkerType?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                
                if name.contains("intro") || type.contains("intro") || name == "opening" {
                    return nextTicks == .max ? nil : Double(nextTicks) / 10_000_000.0
                }
            }
        }
        return nil
    }
    
    var creditsStartTime: Double? {
        guard duration > 0 else { return nil }
        
        for marker in activeMarkers {
            let name = marker.Name?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let type = marker.MarkerType?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            
            if type == "credits" || name.contains("credits") || name == "ending" {
                return Double(marker.PositionTicks ?? 0) / 10_000_000.0
            }
        }
        
        for chapter in activeChapters {
            let name = chapter.Name?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let type = chapter.MarkerType?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            
            if type == "credits" || name.contains("credits") || name == "ending" {
                return Double(chapter.StartPositionTicks ?? 0) / 10_000_000.0
            }
        }
        
        return max(0, duration - 30.0)
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
        self.isSettingUpPlayerItem = true
        self.currentTime = 0
        self.duration = 0
        
        self.availableAudioTracks = []
        self.selectedAudioTrack = nil
        self.availableSubtitleTracks = []
        self.selectedSubtitleTrack = nil
        
        self.vttCues = []
        self.currentSubtitleText = ""
        self.currentMediaSourceId = nil
        self.defaultMediaSourceId = nil
        activeSubtitleTask?.cancel()
        
        self.showNextEpisodeCountdown = false
        self.countdownDismissed = false
        self.countdownTimerTask?.cancel()
        
        self.activeChapters = []
        self.activeMarkers = []
        
        self.dynamicallyFetchNextEpisodes(for: item)
        
        Task {
            let base = appState.serverURL.hasSuffix("/") ? String(appState.serverURL.dropLast()) : appState.serverURL
            
            do {
                guard let url = URL(string: "\(base)/Users/\(self.appState.userID)/Items/\(item.Id)?Fields=Chapters,MediaSources,Markers") else { return }
                var req = URLRequest(url: url)
                req.setValue(self.appState.accessToken, forHTTPHeaderField: "X-Emby-Token")
                
                let (data, _) = try await URLSession.shared.data(for: req)
                let itemData = try JSONDecoder().decode(JFItemMediaData.self, from: data)
                
                await MainActor.run {
                    self.activeChapters = itemData.Chapters ?? []
                    self.activeMarkers = itemData.Markers ?? []
                    
                    if let source = itemData.MediaSources?.first {
                        self.defaultMediaSourceId = source.Id
                        if let streams = source.MediaStreams {
                            self.availableAudioTracks = streams.filter { $0.type?.lowercased() == "audio" }
                            self.selectedAudioTrack = self.availableAudioTracks.first(where: { $0.IsDefault == true }) ?? self.availableAudioTracks.first
                            
                            self.availableSubtitleTracks = streams.filter { $0.type?.lowercased() == "subtitle" }
                            let defaultSub = self.availableSubtitleTracks.first(where: { $0.IsDefault == true || $0.IsForced == true })
                            self.selectedSubtitleTrack = defaultSub
                            self.isCCEnabled = (defaultSub != nil && defaultSub?.IsForced != true)
                        }
                    }
                }
            } catch {
                print("Failed to fetch MediaSources/Chapters: \(error)")
            }
            
            await self.playCurrentSelection(resumeTime: nil)
        }
    }
    
    private func isTextSub(_ sub: JFMediaStream) -> Bool {
        let codec = sub.Codec?.lowercased() ?? ""
        return (codec == "subrip" || codec == "srt" || codec == "vtt" || codec == "webvtt")
    }
    
    private func playCurrentSelection(resumeTime: Double?) async {
        guard let item = currentItem else { return }
        let base = appState.serverURL.hasSuffix("/") ? String(appState.serverURL.dropLast()) : appState.serverURL
        
        await MainActor.run {
            self.isSettingUpPlayerItem = true
            self.isBuffering = true
            self.player.pause()
        }
        
        do {
            // Determine if the subtitle needs to be burned in (e.g. PGS/ASS). If it's a text format, we omit the stream index
            // so Jellyfin won't burn it in, allowing us to overlay it natively in the app.
            let subtitleStreamIndexToTranscode: Int?
            if let selectedSub = self.selectedSubtitleTrack, !isTextSub(selectedSub) {
                subtitleStreamIndexToTranscode = selectedSub.Index
            } else {
                subtitleStreamIndexToTranscode = nil
            }
            
            let (_, turl, mediaSourceIdOut, _) = try await JFPlaybackInfoService.fetchPlaybackInfoWithTranscodingUrl(
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
                audioCodec: "aac,ac3,eac3,mp3,alac,flac",
                videoCodec: "hevc,h265,h264",
                subtitleStreamIndex: subtitleStreamIndexToTranscode,
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
            
            var components = URLComponents(string: finalUrlString)
            var queryItems = components?.queryItems ?? []
            
            if !queryItems.contains(where: { $0.name.lowercased() == "api_key" }) {
                queryItems.append(URLQueryItem(name: "api_key", value: appState.accessToken))
            }
            
            if let audioIndex = self.selectedAudioTrack?.Index {
                queryItems.removeAll(where: { $0.name.lowercased() == "audiostreamindex" })
                queryItems.append(URLQueryItem(name: "AudioStreamIndex", value: String(audioIndex)))
            }
            
            // Clean up any rogue SubtitleStreamIndex tags
            if let subIndex = subtitleStreamIndexToTranscode {
                queryItems.removeAll(where: { $0.name.lowercased() == "subtitlestreamindex" })
                queryItems.append(URLQueryItem(name: "SubtitleStreamIndex", value: String(subIndex)))
            } else {
                queryItems.removeAll(where: { $0.name.lowercased() == "subtitlestreamindex" })
            }
            
            components?.queryItems = queryItems
            guard let url = components?.url else { return }
            
            await MainActor.run {
                self.streamURL = url
                self.currentMediaSourceId = mediaSourceIdOut ?? self.defaultMediaSourceId
                
                Task.detached { @MainActor in
                    do {
                        try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, policy: .longFormVideo, options: [])
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
                
                self.observeItem(playerItem)
                self.player.replaceCurrentItem(with: playerItem)
                self.player.play()
                
                self.updateNowPlayingInfo()
                self.appState.reportPlaybackStart(itemId: item.Id, canSeek: true)
                
                if let targetTime = resumeTime {
                    self.seek(to: targetTime)
                }
                
                // If it's a text subtitle format, we download it instead of having the server transcode it
                if let sub = self.selectedSubtitleTrack, isTextSub(sub) {
                    self.fetchExternalSubtitlePayload(sub)
                }
            }
        } catch {
            print("PlaybackInfo fetch failed: \(error)")
            await MainActor.run {
                self.isBuffering = false
                self.isSettingUpPlayerItem = false
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
                    
                    self.isSettingUpPlayerItem = false
                }
            }
        }
        
        // 200ms updates to keep subtitle syncing smooth
        let interval = CMTime(seconds: 0.2, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self = self, let currentItem = self.currentItem else { return }
            
            if !self.isScrubbing && !self.isSeeking {
                self.currentTime = time.seconds
            }
            
            // Subtitle Sync Engine
            if !self.vttCues.isEmpty {
                let currentSecs = time.seconds
                if let activeCue = self.vttCues.first(where: { currentSecs >= $0.startTime && currentSecs <= $0.endTime }) {
                    if self.currentSubtitleText != activeCue.text {
                        self.currentSubtitleText = activeCue.text
                    }
                } else {
                    if !self.currentSubtitleText.isEmpty {
                        self.currentSubtitleText = ""
                    }
                }
            } else {
                if !self.currentSubtitleText.isEmpty {
                    self.currentSubtitleText = ""
                }
            }
            
            // Next Episode Countdown Engine
            if self.isEpisode && self.hasNextEpisode && self.autoPlayNextEpisode && !self.countdownDismissed && !self.showNextEpisodeCountdown {
                if let triggerTime = self.creditsStartTime, time.seconds >= triggerTime {
                    self.startNextEpisodeCountdown()
                }
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
        
        let playSessionId = streamURL.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?
            .queryItems?.first(where: { $0.name.caseInsensitiveCompare("PlaySessionId") == .orderedSame })?.value
        appState.reportPlaybackStopped(itemId: currentItem.Id, positionTicks: totalTicks, playSessionId: playSessionId)
        
        if hasNextEpisode && autoPlayNextEpisode {
            skipToNextEpisode()
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
        self.currentTime = newTime
        self.updateNowPlayingPlaybackState()
        seek(to: newTime)
    }
    
    func skipBackward() {
        let newTime = max(currentTime - 10, 0)
        self.currentTime = newTime
        self.updateNowPlayingPlaybackState()
        seek(to: newTime)
    }
    
    func skipToNextEpisode() {
        guard hasNextEpisode else { return }
        countdownTimerTask?.cancel()
        currentIndex += 1
        loadItem(at: currentIndex)
    }
    
    func startNextEpisodeCountdown() {
        showNextEpisodeCountdown = true
        nextEpisodeCountdown = 5
        countdownTimerTask?.cancel()
        
        countdownTimerTask = Task { @MainActor in
            for _ in 0..<5 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { return }
                self.nextEpisodeCountdown -= 1
            }
            
            if !Task.isCancelled && self.showNextEpisodeCountdown {
                self.skipToNextEpisode()
            }
        }
    }
    
    func dismissCountdown() {
        countdownDismissed = true
        showNextEpisodeCountdown = false
        countdownTimerTask?.cancel()
    }
    
    func seek(to seconds: Double) {
        isSeeking = true
        let targetTime = CMTime(seconds: seconds, preferredTimescale: 600)
        
        player.seek(to: targetTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            DispatchQueue.main.async {
                guard let self = self else { return }
                
                if finished {
                    self.isSeeking = false
                    
                    let actualTime = self.player.currentTime().seconds
                    if !actualTime.isNaN {
                        self.currentTime = actualTime
                    }
                    
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
            
            let playSessionId = streamURL.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?
                .queryItems?.first(where: { $0.name.caseInsensitiveCompare("PlaySessionId") == .orderedSame })?.value
            appState.reportPlaybackStopped(itemId: id, positionTicks: ticks, playSessionId: playSessionId)
        }
        cleanup()
        onFinishedPlaylist?()
    }
    
    // MARK: - Track Selection Management
    
    func selectAudioTrack(_ option: JFMediaStream) {
        guard self.selectedAudioTrack != option else { return }
        self.selectedAudioTrack = option
        
        Task { await self.playCurrentSelection(resumeTime: self.currentTime) }
    }
    
    func selectSubtitleTrack(_ option: JFMediaStream?) {
        let previousSub = self.selectedSubtitleTrack
        guard previousSub != option else { return }
        self.selectedSubtitleTrack = option
        
        let desiredCCState = (option != nil && option?.IsForced != true)
        if self.isCCEnabled != desiredCCState {
            self.isCCEnabled = desiredCCState
        }
        
        activeSubtitleTask?.cancel()
        self.vttCues = []
        self.currentSubtitleText = ""
        
        let wasBurningIn = previousSub != nil && !isTextSub(previousSub!)
        let willBurnIn = option != nil && !isTextSub(option!)
        
        // If we transitioned to/from an image format, Jellyfin needs to restart the transcode session
        if willBurnIn || wasBurningIn {
            Task { await self.playCurrentSelection(resumeTime: self.currentTime) }
        } else if let selectedSub = option {
            // Text subtitle switches are instant because they are downloaded client-side
            fetchExternalSubtitlePayload(selectedSub)
        }
    }
    
    private func fetchExternalSubtitlePayload(_ option: JFMediaStream) {
        guard let item = currentItem else { return }
        let base = appState.serverURL.hasSuffix("/") ? String(appState.serverURL.dropLast()) : appState.serverURL
        
        let subtitleUrlString: String
        
        // Follow ChatGPT's advice: Use the explicit DeliveryUrl provided by the server if available
        if let deliveryUrl = option.DeliveryUrl, !deliveryUrl.isEmpty {
            let prefix = deliveryUrl.hasPrefix("/") ? "" : "/"
            subtitleUrlString = "\(base)\(prefix)\(deliveryUrl)\(deliveryUrl.contains("?") ? "&" : "?")api_key=\(appState.accessToken)"
        } else {
            // Fallback for older servers or if not explicitly provided
            guard let mediaSourceId = self.currentMediaSourceId ?? self.defaultMediaSourceId else { return }
            subtitleUrlString = "\(base)/Videos/\(item.Id)/\(mediaSourceId)/Subtitles/\(option.Index ?? 0)/0/Stream.vtt?api_key=\(appState.accessToken)"
        }
        
        guard let url = URL(string: subtitleUrlString) else { return }
        
        activeSubtitleTask = Task {
            do {
                var req = URLRequest(url: url)
                req.setValue(appState.accessToken, forHTTPHeaderField: "X-Emby-Token")
                
                let (data, response) = try await URLSession.shared.data(for: req)
                guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200,
                      let vttText = String(data: data, encoding: .utf8) else {
                    print("Failed to decode VTT text or bad status")
                    return
                }
                
                if !Task.isCancelled {
                    let parsedCues = parseVTT(vttText)
                    await MainActor.run {
                        self.vttCues = parsedCues
                    }
                }
            } catch {
                print("Failed to fetch WebVTT stream: \(error)")
            }
        }
    }
    
    private func parseVTTTime(_ timeString: String) -> Double? {
        let cleanString = timeString.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Handles both SRT (comma) and VTT (period) milliseconds
        let timeParts = cleanString.components(separatedBy: CharacterSet(charactersIn: ".,"))
        let mainTime = timeParts[0]
        let fraction = timeParts.count > 1 ? (Double("0." + timeParts[1]) ?? 0.0) : 0.0
        
        let parts = mainTime.components(separatedBy: ":")
        var seconds: Double = 0
        
        if parts.count == 3 {
            seconds += (Double(parts[0]) ?? 0) * 3600
            seconds += (Double(parts[1]) ?? 0) * 60
            seconds += (Double(parts[2]) ?? 0)
        } else if parts.count == 2 {
            seconds += (Double(parts[0]) ?? 0) * 60
            seconds += (Double(parts[1]) ?? 0)
        } else {
            return nil
        }
        
        return seconds + fraction
    }
    
    private func parseVTT(_ vttText: String) -> [VTTCue] {
        var cues: [VTTCue] = []
        // Normalize line endings regardless of server OS
        let text = vttText.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let lines = text.components(separatedBy: "\n")
        
        var i = 0
        while i < lines.count {
            let line = lines[i]
            if line.contains("-->") {
                let parts = line.components(separatedBy: "-->")
                if parts.count == 2 {
                    let startStr = parts[0].trimmingCharacters(in: .whitespaces)
                    
                    // Strip inline formatting attributes that may follow the end time
                    let endStr = parts[1].trimmingCharacters(in: .whitespaces).components(separatedBy: .whitespaces).first ?? parts[1].trimmingCharacters(in: .whitespaces)
                    
                    if let start = parseVTTTime(startStr), let end = parseVTTTime(endStr) {
                        var textLines: [String] = []
                        i += 1
                        while i < lines.count && !lines[i].trimmingCharacters(in: .whitespaces).isEmpty && !lines[i].contains("-->") {
                            textLines.append(lines[i].trimmingCharacters(in: .whitespaces))
                            i += 1
                        }
                        
                        // Strip HTML/Formatting tags (e.g., <i>, <c.color>)
                        let cleanText = textLines.joined(separator: "\n").replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                        if !cleanText.isEmpty {
                            cues.append(VTTCue(startTime: start, endTime: end, text: cleanText))
                        }
                        continue
                    }
                }
            }
            i += 1
        }
        return cues
    }

    func handleCCEnabledChanged(_ enabled: Bool) {
        guard !isSettingUpPlayerItem else { return }
        
        if !enabled {
            selectSubtitleTrack(nil)
        } else {
            // Turn on the first available option if none is selected
            if selectedSubtitleTrack == nil {
                let firstStandard = availableSubtitleTracks.first(where: { $0.IsForced != true }) ?? availableSubtitleTracks.first
                if let track = firstStandard {
                    selectSubtitleTrack(track)
                }
            }
        }
    }
    
    // MARK: - Now Playing
    
    private func updateNowPlayingInfo() {
        guard let item = currentItem else { return }
        
        let isEpisodeVal = item.Type.lowercased() == "episode"
        let activeSeriesName = seriesName ?? item.SeriesName
        
        let title: String
        let subtitle: String
        
        if isEpisodeVal, let series = activeSeriesName, !series.isEmpty {
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
            subtitle = ""
        }
        
        nowPlayingInfo[MPMediaItemPropertyTitle] = title
        if !subtitle.isEmpty {
            nowPlayingInfo[MPMediaItemPropertyArtist] = subtitle
        } else {
            nowPlayingInfo.removeValue(forKey: MPMediaItemPropertyArtist)
        }
        nowPlayingInfo[MPNowPlayingInfoPropertyMediaType] = 2
        
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
        updateNowPlayingPlaybackState()
        
        let base = appState.serverURL.hasSuffix("/") ? String(appState.serverURL.dropLast()) : appState.serverURL
        
        if isEpisodeVal {
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
        
        let activeRate = (isPlaying && !isBuffering) ? 1.0 : 0.0
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = activeRate
        
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
    }
    
    private func setFallbackArtwork(item: JFItemDto, base: String) {
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
            self.currentTime = targetTime
            self.updateNowPlayingPlaybackState()
            self.seek(to: targetTime)
            return .success
        }
    }
    
    // MARK: - Dynamic Playlist Fetching
    
    private func dynamicallyFetchNextEpisodes(for item: JFItemDto) {
        guard item.Type.caseInsensitiveCompare("episode") == .orderedSame, let seriesId = item.SeriesId else { return }
        guard currentIndex == playlist.count - 1 else { return }
        
        Task {
            let base = appState.serverURL.hasSuffix("/") ? String(appState.serverURL.dropLast()) : appState.serverURL
            var targetSeasonId = item.SeasonId
            
            if targetSeasonId == nil {
                guard let url = URL(string: "\(base)/Users/\(appState.userID)/Items/\(item.Id)?Fields=SeasonId") else { return }
                var req = URLRequest(url: url)
                req.setValue(appState.accessToken, forHTTPHeaderField: "X-Emby-Token")
                if let (data, _) = try? await URLSession.shared.data(for: req),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let sid = json["SeasonId"] as? String {
                    targetSeasonId = sid
                }
            }
            
            guard let seasonId = targetSeasonId else { return }
            
            var components = URLComponents(string: "\(base)/Shows/\(seriesId)/Episodes")
            components?.queryItems = [
                URLQueryItem(name: "seasonId", value: seasonId),
                URLQueryItem(name: "userId", value: appState.userID),
                URLQueryItem(name: "Fields", value: "Overview,ImageTags,UserData,SeriesName,SeriesId")
            ]
            
            guard let url = components?.url else { return }
            var req = URLRequest(url: url)
            req.setValue(appState.accessToken, forHTTPHeaderField: "X-Emby-Token")
            
            do {
                let (data, response) = try await URLSession.shared.data(for: req)
                guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else { return }
                
                struct EpisodesResponse: Decodable { let Items: [JFItemDto] }
                let decoded = try JSONDecoder().decode(EpisodesResponse.self, from: data)
                
                if let matchedIndex = decoded.Items.firstIndex(where: { $0.Id == item.Id }) {
                    let nextEpisodes = Array(decoded.Items[(matchedIndex + 1)...])
                    
                    if !nextEpisodes.isEmpty {
                        await MainActor.run {
                            guard self.currentIndex == self.playlist.count - 1 else { return }
                            self.playlist.append(contentsOf: nextEpisodes)
                        }
                    } else {
                        await fetchNextSeasonEpisodes(seriesId: seriesId, currentSeasonId: seasonId, base: base)
                    }
                }
            } catch {
                print("Failed to fetch dynamic episodes: \(error)")
            }
        }
    }
    
    private func fetchNextSeasonEpisodes(seriesId: String, currentSeasonId: String, base: String) async {
        guard let url = URL(string: "\(base)/Shows/\(seriesId)/Seasons?userId=\(appState.userID)") else { return }
        var req = URLRequest(url: url)
        req.setValue(appState.accessToken, forHTTPHeaderField: "X-Emby-Token")
        
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            struct SeasonsResponse: Decodable { let Items: [JFItemDto] }
            let decoded = try JSONDecoder().decode(SeasonsResponse.self, from: data)
            
            let seasons = decoded.Items
            guard let currentIdx = seasons.firstIndex(where: { $0.Id == currentSeasonId }),
                  currentIdx + 1 < seasons.count else { return }
            
            let nextSeason = seasons[currentIdx + 1]
            
            var components = URLComponents(string: "\(base)/Shows/\(seriesId)/Episodes")
            components?.queryItems = [
                URLQueryItem(name: "seasonId", value: nextSeason.Id),
                URLQueryItem(name: "userId", value: appState.userID),
                URLQueryItem(name: "Fields", value: "Overview,ImageTags,UserData,SeriesName,SeriesId")
            ]
            guard let epUrl = components?.url else { return }
            var epReq = URLRequest(url: epUrl)
            epReq.setValue(epReq.value(forHTTPHeaderField: "X-Emby-Token") ?? appState.accessToken, forHTTPHeaderField: "X-Emby-Token")
            
            let (epData, _) = try await URLSession.shared.data(for: epReq)
            struct EpisodesResponse: Decodable { let Items: [JFItemDto] }
            let epDecoded = try JSONDecoder().decode(EpisodesResponse.self, from: epData)
            
            if !epDecoded.Items.isEmpty {
                await MainActor.run {
                    guard self.currentIndex == self.playlist.count - 1 else { return }
                    self.playlist.append(contentsOf: epDecoded.Items)
                }
            }
        } catch {
            print("Failed to fetch next season episodes: \(error)")
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
            
            // ── 1. Background Video Player ──
            if let url = vm.streamURL {
                DragonetPlayer(
                    player: vm.player,
                    streamURL: url,
                    isPiPActive: $vm.isPiPActive,
                    isCCEnabled: $vm.isCCEnabled,
                    controlsVisible: $vm.controlsVisible,
                    onPlaybackError: { _ in }
                ) { vc in
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
            
            // ── 2. Loading Indicator ──
            if vm.isBuffering {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    .scaleEffect(2.0)
                    .allowsHitTesting(false)
            }
            
            // ── 3. Subtitles Overlay ──
            if !vm.currentSubtitleText.isEmpty {
                VStack {
                    Spacer()
                    Text(vm.currentSubtitleText)
                        .font(.system(size: 20, weight: .semibold, design: .rounded))
                        .foregroundColor(.white)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color.black.opacity(0.7))
                        )
                        .padding(.bottom, vm.controlsVisible ? 110 : 44) // Dynamically push up/down to stay out of progress bars
                        .shadow(color: .black.opacity(0.3), radius: 4, x: 0, y: 2)
                        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: vm.controlsVisible)
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 80)
                .allowsHitTesting(false) // Never block control click gestures
            }
            
            // ── 4. Independent "Skip Intro" Button ──
            // Appears automatically outside the normal controls visibility lifecycle
            if let skipTarget = vm.currentIntroEndTarget {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Button(action: {
                            vm.seek(to: skipTarget)
                            playerController?.resetAutoHideTimer()
                        }) {
                            HStack(spacing: 6) {
                                Image(systemName: "forward.end.fill")
                                Text("Skip Intro")
                                    .font(.subheadline.weight(.semibold))
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(.black.opacity(0.6))
                            .foregroundStyle(.white)
                            .clipShape(Capsule())
                            .overlay(Capsule().strokeBorder(.white.opacity(0.3), lineWidth: 1))
                        }
                    }
                    .padding(.horizontal, 32)
                    // If controls are visible, sit above the scrubber. If hidden, sit closer to the bottom.
                    .padding(.bottom, vm.controlsVisible ? 110 : 50)
                    .safeAreaPadding(.horizontal)
                }
                .transition(.move(edge: .trailing).combined(with: .opacity))
                .animation(.spring(response: 0.4, dampingFraction: 0.8), value: vm.controlsVisible)
            }
            
            // ── 4b. Independent "Next Episode" Countdown ──
            if vm.showNextEpisodeCountdown {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        HStack(spacing: 16) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Next Episode")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(.white.opacity(0.8))
                                Text("Playing in \(vm.nextEpisodeCountdown)s")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.white)
                            }
                            
                            Button {
                                vm.skipToNextEpisode()
                            } label: {
                                Image(systemName: "play.fill")
                                    .font(.system(size: 16, weight: .bold))
                                    .foregroundStyle(.black)
                                    .frame(width: 36, height: 36)
                                    .background(Color.white)
                                    .clipShape(Circle())
                            }
                            
                            Button {
                                vm.dismissCountdown()
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundStyle(.white)
                                    .frame(width: 30, height: 30)
                                    .background(Color.white.opacity(0.2))
                                    .clipShape(Circle())
                            }
                        }
                        .padding(.vertical, 10)
                        .padding(.horizontal, 16)
                        .background(Color.black.opacity(0.85))
                        .clipShape(RoundedRectangle(cornerRadius: 40, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 40, style: .continuous).strokeBorder(.white.opacity(0.2), lineWidth: 1))
                        .shadow(color: .black.opacity(0.4), radius: 10, x: 0, y: 4)
                    }
                    .padding(.horizontal, 32)
                    .padding(.bottom, vm.controlsVisible ? 110 : 50)
                    .safeAreaPadding(.horizontal)
                }
                .transition(.move(edge: .trailing).combined(with: .opacity))
                .animation(.spring(response: 0.4, dampingFraction: 0.8), value: vm.showNextEpisodeCountdown)
                .animation(.spring(response: 0.4, dampingFraction: 0.8), value: vm.controlsVisible)
            }
            
            // ── 5. Main Controls Overlay ──
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
        .onChange(of: vm.controlsVisible) { _, visible in
            if visible { playerController?.resetAutoHideTimer() }
            else       { playerController?.cancelTimer() }
        }
        .onChange(of: vm.isCCEnabled) { _, enabled in
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
                        let activeSeriesName = vm.seriesName ?? vm.currentItem?.SeriesName
                        
                        if vm.isEpisode, let series = activeSeriesName, !series.isEmpty {
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
                        // ── Auto Play Next Episode Toggle ──
                        if vm.isEpisode {
                            Button {
                                vm.autoPlayNextEpisode.toggle()
                                playerController?.resetAutoHideTimer()
                            } label: {
                                Image(systemName: vm.autoPlayNextEpisode ? "play.square.stack.fill" : "play.square.stack")
                                    .foregroundStyle(vm.autoPlayNextEpisode ? Color.blue : .white)
                                    .font(.system(size: 18, weight: .medium))
                                    .frame(width: 44, height: 44)
                            }
                            .glassEffect(in: Circle())
                        }
                        
                        // ── Audio / Language Tracks Menu ──
                        if vm.availableAudioTracks.isEmpty {
                            Image(systemName: "waveform")
                                .foregroundStyle(.white.opacity(0.3))
                                .font(.system(size: 18, weight: .medium))
                                .frame(width: 44, height: 44)
                                .glassEffect(in: Circle())
                        } else {
                            Menu {
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
                            } label: {
                                Image(systemName: "waveform")
                                    .foregroundStyle(.white)
                                    .font(.system(size: 18, weight: .medium))
                                    .frame(width: 44, height: 44)
                            }
                            .glassEffect(in: Circle())
                        }
                        
                        // ── Subtitles / Closed Captions Tracks Menu ──
                        if vm.availableSubtitleTracks.isEmpty {
                            Image(systemName: "captions.bubble")
                                .foregroundStyle(.white.opacity(0.3))
                                .font(.system(size: 18, weight: .medium))
                                .frame(width: 44, height: 44)
                                .glassEffect(in: Circle())
                        } else {
                            Menu {
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
                            } label: {
                                Image(systemName: vm.isCCEnabled ? "captions.bubble.fill" : "captions.bubble")
                                    .foregroundStyle(vm.isCCEnabled ? Color.blue : .white)
                                    .font(.system(size: 18, weight: .medium))
                                    .frame(width: 44, height: 44)
                            }
                            .glassEffect(in: Circle())
                        }
                        
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
                HStack(spacing: 24) {
                    
                    // ── Restart Button ──
                    if vm.isEpisode {
                        Button {
                            vm.seek(to: 0)
                            playerController?.resetAutoHideTimer()
                        } label: {
                            Image(systemName: "backward.end.fill")
                                .font(.system(size: 24, weight: .regular))
                                .foregroundStyle(.white)
                                .frame(width: 56, height: 56)
                                .glassEffect(in: Circle())
                        }
                    } else {
                        Color.clear.frame(width: 56, height: 56)
                    }
                    
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
                    
                    // ── Next Episode Button ──
                    if vm.isEpisode && vm.hasNextEpisode {
                        Button {
                            vm.skipToNextEpisode()
                            playerController?.resetAutoHideTimer()
                        } label: {
                            Image(systemName: "forward.end.fill")
                                .font(.system(size: 24, weight: .regular))
                                .foregroundStyle(.white)
                                .frame(width: 56, height: 56)
                                .glassEffect(in: Circle())
                        }
                    } else {
                        Color.clear.frame(width: 56, height: 56)
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
                            vm.updateNowPlayingPlaybackState()
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
