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

struct JFDynamicMarker: Decodable {
    let Id: String?
    let Name: String?
    let PositionTicks: Int64?
    let EndPositionTicks: Int64?
    let MarkerType: String?
    
    init(id: String? = nil, name: String? = nil, positionTicks: Int64?, endPositionTicks: Int64?, markerType: String?) {
        self.Id = id
        self.Name = name
        self.PositionTicks = positionTicks
        self.EndPositionTicks = endPositionTicks
        self.MarkerType = markerType
    }
    
    enum CodingKeys: String, CodingKey {
        case Id, id
        case Name, name
        case PositionTicks, StartPositionTicks, StartTicks, startTicks, positionTicks
        case EndPositionTicks, EndTicks, endTicks, endPositionTicks
        case MarkerType, `Type`, type, markerType
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        
        if let strId = try? container.decodeIfPresent(String.self, forKey: .Id) ?? container.decodeIfPresent(String.self, forKey: .id) {
            self.Id = strId
        } else if let intId = try? container.decodeIfPresent(Int.self, forKey: .Id) ?? container.decodeIfPresent(Int.self, forKey: .id) {
            self.Id = String(intId)
        } else {
            self.Id = nil
        }
        
        self.Name = try? container.decodeIfPresent(String.self, forKey: .Name) ?? container.decodeIfPresent(String.self, forKey: .name)
        
        var pos: Int64? = try? container.decodeIfPresent(Int64.self, forKey: .PositionTicks)
        if pos == nil { pos = try? container.decodeIfPresent(Int64.self, forKey: .StartPositionTicks) }
        if pos == nil { pos = try? container.decodeIfPresent(Int64.self, forKey: .StartTicks) }
        if pos == nil { pos = try? container.decodeIfPresent(Int64.self, forKey: .startTicks) }
        if pos == nil { pos = try? container.decodeIfPresent(Int64.self, forKey: .positionTicks) }
        self.PositionTicks = pos
        
        var end: Int64? = try? container.decodeIfPresent(Int64.self, forKey: .EndPositionTicks)
        if end == nil { end = try? container.decodeIfPresent(Int64.self, forKey: .EndTicks) }
        if end == nil { end = try? container.decodeIfPresent(Int64.self, forKey: .endTicks) }
        if end == nil { end = try? container.decodeIfPresent(Int64.self, forKey: .endPositionTicks) }
        self.EndPositionTicks = end
        
        var mType: String? = try? container.decodeIfPresent(String.self, forKey: .MarkerType)
        if mType == nil { mType = try? container.decodeIfPresent(String.self, forKey: .`Type`) }
        if mType == nil { mType = try? container.decodeIfPresent(String.self, forKey: .type) }
        if mType == nil { mType = try? container.decodeIfPresent(String.self, forKey: .markerType) }
        self.MarkerType = mType
    }
}

struct JFMediaStream: Decodable, Hashable {
    let Index: Int?
    let type: String? // "Audio", "Subtitle", "Video"
    let Language: String?
    let Title: String?
    let DisplayTitle: String?
    let IsDefault: Bool?
    let IsForced: Bool?
    
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
    let Markers: [JFDynamicMarker]?
}

struct JFMediaSegmentsResponse: Decodable {
    let Items: [JFDynamicMarker]?
}

struct JFLegacyIntroResponse: Decodable {
    let Valid: Bool?
    let IntroStart: Double?
    let IntroEnd: Double?
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
    @Published var isShuffled: Bool
    
    // Seasons & QuickSwitch State
    @Published var seasons: [JFItemDto] = []
    @Published var selectedSeasonId: String? = nil
    @Published var drawerEpisodes: [JFItemDto] = []
    @Published var isLoadingSeasons: Bool = false
    @Published var isLoadingSeasonEpisodes: Bool = false
    private var loadedSeriesId: String? = nil
    private var seasonEpisodesCache: [String: [JFItemDto]] = [:]
    
    @Published var controlsVisible: Bool = true
    @Published var isPlaying: Bool = true
    @Published var isBuffering: Bool = true
    @Published var isPiPActive: Bool = false
    @Published var isCCEnabled: Bool = false
    
    // AirPlay State
    @Published var isExternalPlaybackActive: Bool = false
    @Published var externalPlaybackDeviceName: String? = nil
    private var externalPlaybackObserver: NSKeyValueObservation?
    
    @Published var isSettingUpPlayerItem: Bool = false
    @Published var autoPlayNextEpisode: Bool = true
    
    // Audio Tracks
    @Published var availableAudioTracks: [JFMediaStream] = []
    @Published var selectedAudioTrack: JFMediaStream? = nil
    
    // Subtitle Tracks & Sidecar State
    @Published var availableSubtitleTracks: [JFMediaStream] = []
    @Published var selectedSubtitleTrack: JFMediaStream? = nil
    
    // Native Apple Subtitles (For PiP/Airplay)
    private var nativeSubtitleGroup: AVMediaSelectionGroup?
    private var nativeSubtitleOptions: [AVMediaSelectionOption] = []
    
    // Custom SwiftUI Subtitles (For Direct Play/Instant Sync)
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
    
    var onPlaybackError: ((String) -> Void)?
    
    let appState: AppState
    @Published var streamURL: URL? = nil
    @Published var errorMessage: String? = nil
    
    private var timeObserver: Any?
    private var itemStatusObserver: NSKeyValueObservation?
    private var playbackStateObserver: NSKeyValueObservation?
    private var playerStatusObserver: NSKeyValueObservation?
    
    private var hasResumedCurrentItem = false
    private var lastReportedTicks: Int64 = 0
    private var nowPlayingInfo: [String: Any] = [:]
    
    var onFinishedPlaylist: (() -> Void)?

    init(playlist: [JFItemDto], startIndex: Int, seriesName: String?, isShuffled: Bool = false, appState: AppState) {
        self.playlist = playlist
        self.drawerEpisodes = playlist
        self.currentIndex = startIndex
        self.seriesName = seriesName
        self.isShuffled = isShuffled
        self.appState = appState
        
        self.player.automaticallyWaitsToMinimizeStalling = true
        self.player.allowsExternalPlayback = true
        self.player.usesExternalPlaybackWhileExternalScreenIsActive = true
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
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(playerItemFailedToPlayToEndTime),
            name: .AVPlayerItemFailedToPlayToEndTime,
            object: nil
        )
        
        setupPlaybackStateObserver()
        setupExternalPlaybackObservation()
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
        playerStatusObserver?.invalidate()
        externalPlaybackObserver?.invalidate()
        externalPlaybackObserver = nil
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
                if type == "introstart" || type == "intro" || type.contains("intro") || name.contains("intro") {
                    if let end = marker.EndPositionTicks, end > startTicks {
                        return Double(end) / 10_000_000.0
                    }
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
            if type == "credits" || name.contains("credits") || name == "ending" || type == "outro" || name.contains("outro") {
                return Double(marker.PositionTicks ?? 0) / 10_000_000.0
            }
        }
        for chapter in activeChapters {
            let name = chapter.Name?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let type = chapter.MarkerType?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if type == "credits" || name.contains("credits") || name == "ending" || type == "outro" || name.contains("outro") {
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
        self.errorMessage = nil
        self.hasResumedCurrentItem = false
        self.isBuffering = true
        self.isSettingUpPlayerItem = true
        self.currentTime = 0
        self.duration = 0
        
        self.availableAudioTracks = []
        self.selectedAudioTrack = nil
        self.availableSubtitleTracks = []
        self.selectedSubtitleTrack = nil
        
        self.nativeSubtitleGroup = nil
        self.nativeSubtitleOptions = []
        
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
        
        if !self.isShuffled {
            self.dynamicallyFetchNextEpisodes(for: item)
        }
        if item.Type.caseInsensitiveCompare("episode") == .orderedSame {
            self.fetchSeasons(for: item)
        }
        
        Task {
            let base = appState.serverURL.hasSuffix("/") ? String(appState.serverURL.dropLast()) : appState.serverURL
            
            do {
                guard let url = URL(string: "\(base)/Users/\(self.appState.userID)/Items/\(item.Id)?Fields=Chapters,MediaSources,Markers") else { return }
                var req = URLRequest(url: url)
                req.setValue(self.appState.accessToken, forHTTPHeaderField: "X-Emby-Token")
                
                let (data, _) = try await URLSession.shared.data(for: req)
                let itemData = try JSONDecoder().decode(JFItemMediaData.self, from: data)
                
                var detectedMarkers: [JFDynamicMarker] = itemData.Markers ?? []
                
                // Fetch MediaSegments (Jellyfin 10.10+ / Intro Skipper 12.0+)
                if let segUrl = URL(string: "\(base)/MediaSegments/\(item.Id)") {
                    var segReq = URLRequest(url: segUrl)
                    segReq.setValue(self.appState.accessToken, forHTTPHeaderField: "X-Emby-Token")
                    if let (segData, segResp) = try? await URLSession.shared.data(for: segReq),
                       let httpResp = segResp as? HTTPURLResponse, httpResp.statusCode == 200 {
                        if let queryResult = try? JSONDecoder().decode(JFMediaSegmentsResponse.self, from: segData),
                           let items = queryResult.Items, !items.isEmpty {
                            detectedMarkers.append(contentsOf: items)
                        } else if let list = try? JSONDecoder().decode([JFDynamicMarker].self, from: segData), !list.isEmpty {
                            detectedMarkers.append(contentsOf: list)
                        }
                    }
                }
                
                // Fallback to legacy Intro Skipper plugin endpoint if no intro marker found yet
                if !detectedMarkers.contains(where: { ($0.MarkerType?.lowercased().contains("intro") ?? false) }) {
                    if let legacyUrl = URL(string: "\(base)/Episode/\(item.Id)/IntroTimestamps") {
                        var legacyReq = URLRequest(url: legacyUrl)
                        legacyReq.setValue(self.appState.accessToken, forHTTPHeaderField: "X-Emby-Token")
                        if let (legacyData, legacyResp) = try? await URLSession.shared.data(for: legacyReq),
                           let httpResp = legacyResp as? HTTPURLResponse, httpResp.statusCode == 200,
                           let legacy = try? JSONDecoder().decode(JFLegacyIntroResponse.self, from: legacyData),
                           legacy.Valid == true,
                           let start = legacy.IntroStart, let end = legacy.IntroEnd, end > start {
                            detectedMarkers.append(JFDynamicMarker(
                                id: nil,
                                name: "Intro",
                                positionTicks: Int64(start * 10_000_000),
                                endPositionTicks: Int64(end * 10_000_000),
                                markerType: "Intro"
                            ))
                        }
                    }
                }
                
                await MainActor.run {
                    self.activeChapters = itemData.Chapters ?? []
                    self.activeMarkers = detectedMarkers
                    
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
            self.errorMessage = nil
            self.isSettingUpPlayerItem = true
            self.isBuffering = true
            self.player.pause()
        }
        
        do {
            // ONLY pass the SubtitleStreamIndex if it's an image format (PGS/ASS) that REQUIRES burn-in
            // For text subs, we handle them natively to avoid the server reloading/losing sync.
            let subtitleStreamIndexToTranscode: Int?
            if let selectedSub = self.selectedSubtitleTrack, !isTextSub(selectedSub) {
                subtitleStreamIndexToTranscode = selectedSub.Index
            } else {
                subtitleStreamIndexToTranscode = nil
            }
            
            let (playbackInfo, turl, mediaSourceIdOut, _) = try await JFPlaybackInfoService.fetchPlaybackInfoWithTranscodingUrl(
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
            
            let primarySource = playbackInfo.mediaSources?.first
            let finalUrlString: String
            if let turl = turl, !turl.isEmpty {
                if turl.hasPrefix("http") {
                    finalUrlString = turl
                } else {
                    finalUrlString = base + (turl.hasPrefix("/") ? turl : "/\(turl)")
                }
            } else if primarySource?.isSupportsDirectPlay == true, let path = primarySource?.path, path.hasPrefix("http") {
                finalUrlString = path
            } else if primarySource?.isSupportsDirectPlay == true {
                let ext = (primarySource?.container ?? "mp4").lowercased()
                finalUrlString = "\(base)/Videos/\(item.Id)/stream.\(ext)?Static=true"
            } else {
                await MainActor.run {
                    let msg = "Server did not return a playable stream URL for this item."
                    self.errorMessage = msg
                    self.isBuffering = false
                    self.isSettingUpPlayerItem = false
                    self.onPlaybackError?(msg)
                }
                return
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
            
            if let subIndex = subtitleStreamIndexToTranscode {
                queryItems.removeAll(where: { $0.name.lowercased() == "subtitlestreamindex" })
                queryItems.append(URLQueryItem(name: "SubtitleStreamIndex", value: String(subIndex)))
            } else {
                queryItems.removeAll(where: { $0.name.lowercased() == "subtitlestreamindex" })
            }
            
            components?.queryItems = queryItems
            guard let url = components?.url else {
                await MainActor.run {
                    let msg = "Unable to create stream URL."
                    self.errorMessage = msg
                    self.isBuffering = false
                    self.isSettingUpPlayerItem = false
                    self.onPlaybackError?(msg)
                }
                return
            }
            
            await MainActor.run {
                self.streamURL = url
                self.currentMediaSourceId = mediaSourceIdOut ?? self.defaultMediaSourceId
                
                Task.detached { @MainActor in
                    do {
                        try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, policy: .longFormVideo, options: [])
                        try await AVAudioSession.sharedInstance().setActive(true)
                    } catch {
                        print("Failed to set audio session: \(error)")
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
                
                // Fetch overlay subtitles natively if they are text format
                if let sub = self.selectedSubtitleTrack, isTextSub(sub) {
                    self.fetchExternalSubtitlePayload(sub)
                }
            }
        } catch {
            print("PlaybackInfo fetch failed: \(error)")
            await MainActor.run {
                self.isBuffering = false
                self.isSettingUpPlayerItem = false
                self.errorMessage = error.localizedDescription
                self.onPlaybackError?(error.localizedDescription)
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
                    self.errorMessage = nil
                    self.duration = observedItem.duration.seconds.isNaN ? 0 : observedItem.duration.seconds
                    self.updateNowPlayingPlaybackState()
                    
                    // Extract native HLS subtitle tracks if provided by server
                    Task {
                        if let group = try? await observedItem.asset.loadMediaSelectionGroup(for: .legible) {
                            await MainActor.run {
                                self.nativeSubtitleGroup = group
                                self.nativeSubtitleOptions = group.options
                            }
                        }
                    }
                    
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
                } else if observedItem.status == .failed {
                    let msg = observedItem.error?.localizedDescription ?? "Playback failed"
                    self.errorMessage = msg
                    self.isBuffering = false
                    self.isSettingUpPlayerItem = false
                    self.onPlaybackError?(msg)
                }
            }
        }
        
        let interval = CMTime(seconds: 0.2, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self = self, let currentItem = self.currentItem else { return }
            
            if !self.isScrubbing && !self.isSeeking {
                self.currentTime = time.seconds
            }
            
            // Subtitle Sync Engine (Only used if native HLS tracks aren't active)
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
        
        playerStatusObserver = player.observe(\.status, options: [.new]) { [weak self] player, _ in
            guard let self = self, player.status == .failed else { return }
            let msg = player.error?.localizedDescription ?? "Playback failed"
            DispatchQueue.main.async {
                self.errorMessage = msg
                self.isBuffering = false
                self.isSettingUpPlayerItem = false
                self.onPlaybackError?(msg)
            }
        }
    }
    
    @objc private func playerItemFailedToPlayToEndTime(notification: NSNotification) {
        guard let failedItem = notification.object as? AVPlayerItem,
              failedItem == player.currentItem else { return }
        let msg = failedItem.error?.localizedDescription ?? "Playback failed to play to end time."
        DispatchQueue.main.async {
            self.errorMessage = msg
            self.isBuffering = false
            self.isSettingUpPlayerItem = false
            self.onPlaybackError?(msg)
        }
    }
    
    func retryPlayback() {
        self.errorMessage = nil
        self.isBuffering = true
        Task {
            let resume = self.currentTime > 0 ? self.currentTime : nil
            await self.playCurrentSelection(resumeTime: resume)
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
        
        // Reset overlay state
        activeSubtitleTask?.cancel()
        self.vttCues = []
        self.currentSubtitleText = ""
        
        // Turn off any native tracks first
        if let group = nativeSubtitleGroup {
            player.currentItem?.select(nil, in: group)
        }
        
        guard let selectedSub = option else { return } // Subtitles turned off
        
        // --- DUAL ENGINE SUBTITLE LOGIC ---
        
        // 1. Check if Apple HLS Native Tracks exist (Perfect for PiP/Airplay)
        if let group = nativeSubtitleGroup,
           let nativeOption = nativeSubtitleOptions.first(where: {
               $0.displayName == selectedSub.safeDisplayName ||
               $0.extendedLanguageTag == selectedSub.Language
           }) {
            // Found native HLS subtitle! Switch instantly without reloading.
            player.currentItem?.select(nativeOption, in: group)
            return
        }
        
        // 2. Fallback to Custom Overlay OR Server Transcode
        if isTextSub(selectedSub) {
            // Text Subtitle (VTT/SRT) -> Download & Overlay locally (Instant, Perfect Sync, No Reload)
            fetchExternalSubtitlePayload(selectedSub)
        } else {
            // Image Subtitle (PGS/ASS) -> Force Server Burn-In (Will cause a reload, but unavoidable)
            Task { await self.playCurrentSelection(resumeTime: self.currentTime) }
        }
    }
    
    private func fetchExternalSubtitlePayload(_ option: JFMediaStream) {
        guard let item = currentItem else { return }
        let base = appState.serverURL.hasSuffix("/") ? String(appState.serverURL.dropLast()) : appState.serverURL
        
        let subtitleUrlString: String
        if let deliveryUrl = option.DeliveryUrl, !deliveryUrl.isEmpty {
            let prefix = deliveryUrl.hasPrefix("/") ? "" : "/"
            subtitleUrlString = "\(base)\(prefix)\(deliveryUrl)\(deliveryUrl.contains("?") ? "&" : "?")api_key=\(appState.accessToken)"
        } else {
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
        let text = vttText.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let lines = text.components(separatedBy: "\n")
        
        var i = 0
        while i < lines.count {
            let line = lines[i]
            if line.contains("-->") {
                let parts = line.components(separatedBy: "-->")
                if parts.count == 2 {
                    let startStr = parts[0].trimmingCharacters(in: .whitespaces)
                    let endStr = parts[1].trimmingCharacters(in: .whitespaces).components(separatedBy: .whitespaces).first ?? parts[1].trimmingCharacters(in: .whitespaces)
                    
                    if let start = parseVTTTime(startStr), let end = parseVTTTime(endStr) {
                        var textLines: [String] = []
                        i += 1
                        while i < lines.count && !lines[i].trimmingCharacters(in: .whitespaces).isEmpty && !lines[i].contains("-->") {
                            textLines.append(lines[i].trimmingCharacters(in: .whitespaces))
                            i += 1
                        }
                        
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
            subtitle = se.isEmpty ? item.Name : "\(se) • \(item.Name)"
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
                URLQueryItem(name: "Fields", value: "Overview,ImageTags,UserData,SeriesName,SeriesId,SeasonId,ParentIndexNumber,IndexNumber,RunTimeTicks")
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
                    await MainActor.run {
                        self.seasonEpisodesCache[seasonId] = decoded.Items
                        if self.selectedSeasonId == seasonId || self.selectedSeasonId == nil {
                            self.selectedSeasonId = seasonId
                            self.drawerEpisodes = decoded.Items
                        }
                        
                        // If playlist is missing previous episodes, expand it to the full season
                        if self.playlist.count < decoded.Items.count {
                            self.playlist = decoded.Items
                            self.currentIndex = matchedIndex
                        } else if matchedIndex + 1 < decoded.Items.count {
                            let nextEpisodes = Array(decoded.Items[(matchedIndex + 1)...])
                            if self.currentIndex == self.playlist.count - 1 {
                                self.playlist.append(contentsOf: nextEpisodes)
                            }
                        }
                    }
                    
                    if matchedIndex == decoded.Items.count - 1 {
                        await fetchNextSeasonEpisodes(seriesId: seriesId, currentSeasonId: seasonId, base: base)
                    }
                }
            } catch {
                print("Failed to fetch dynamic episodes: \(error)")
            }
        }
    }
    
    // MARK: - Season & QuickSwitch Management
    
    var selectedSeason: JFItemDto? {
        seasons.first(where: { $0.Id == selectedSeasonId })
    }
    
    func fetchSeasons(for item: JFItemDto?) {
        guard let item = item, item.Type.caseInsensitiveCompare("episode") == .orderedSame else { return }
        
        Task {
            let base = appState.serverURL.hasSuffix("/") ? String(appState.serverURL.dropLast()) : appState.serverURL
            var targetSeriesId = item.SeriesId
            var targetSeasonId = item.SeasonId
            
            if targetSeriesId == nil || targetSeasonId == nil {
                guard let url = URL(string: "\(base)/Users/\(appState.userID)/Items/\(item.Id)?Fields=SeriesId,SeasonId,SeriesName") else { return }
                var req = URLRequest(url: url)
                req.setValue(appState.accessToken, forHTTPHeaderField: "X-Emby-Token")
                if let (data, _) = try? await URLSession.shared.data(for: req),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    if targetSeriesId == nil { targetSeriesId = json["SeriesId"] as? String }
                    if targetSeasonId == nil { targetSeasonId = json["SeasonId"] as? String }
                    if self.seriesName == nil { self.seriesName = json["SeriesName"] as? String }
                }
            }
            
            guard let seriesId = targetSeriesId else { return }
            
            if self.loadedSeriesId == seriesId && !self.seasons.isEmpty {
                await MainActor.run {
                    if let sid = targetSeasonId, self.seasons.contains(where: { $0.Id == sid }) {
                        self.selectedSeasonId = sid
                    } else if let pIndex = item.ParentIndexNumber,
                              let match = self.seasons.first(where: { $0.IndexNumber == pIndex }) {
                        self.selectedSeasonId = match.Id
                    }
                    
                    if let sid = self.selectedSeasonId {
                        if let cached = self.seasonEpisodesCache[sid] {
                            self.drawerEpisodes = cached
                            if let cur = self.currentItem,
                               (cur.SeasonId == sid || cached.contains(where: { $0.Id == cur.Id })),
                               !self.isShuffled,
                               let matchedIndex = cached.firstIndex(where: { $0.Id == cur.Id }) {
                                if self.playlist.count < cached.count || self.currentIndex != matchedIndex {
                                    self.playlist = cached
                                    self.currentIndex = matchedIndex
                                }
                            }
                        } else {
                            self.loadEpisodesForSeason(seasonId: sid, seriesId: seriesId)
                        }
                    }
                }
                return
            }
            
            self.loadedSeriesId = seriesId
            self.isLoadingSeasons = true
            
            guard let url = URL(string: "\(base)/Shows/\(seriesId)/Seasons?userId=\(appState.userID)") else {
                self.isLoadingSeasons = false
                return
            }
            var req = URLRequest(url: url)
            req.setValue(appState.accessToken, forHTTPHeaderField: "X-Emby-Token")
            
            do {
                let (data, response) = try await URLSession.shared.data(for: req)
                guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                    self.isLoadingSeasons = false
                    return
                }
                struct SeasonsResponse: Decodable { let Items: [JFItemDto] }
                let decoded = try JSONDecoder().decode(SeasonsResponse.self, from: data)
                
                await MainActor.run {
                    self.seasons = decoded.Items
                    self.isLoadingSeasons = false
                    
                    if let sid = targetSeasonId, self.seasons.contains(where: { $0.Id == sid }) {
                        self.selectedSeasonId = sid
                    } else if let pIndex = item.ParentIndexNumber,
                              let match = self.seasons.first(where: { $0.IndexNumber == pIndex }) {
                        self.selectedSeasonId = match.Id
                    } else {
                        self.selectedSeasonId = self.seasons.first?.Id
                    }
                    
                    if let sid = self.selectedSeasonId {
                        if let cached = self.seasonEpisodesCache[sid] {
                            self.drawerEpisodes = cached
                            if let cur = self.currentItem,
                               (cur.SeasonId == sid || cached.contains(where: { $0.Id == cur.Id })),
                               !self.isShuffled,
                               let matchedIndex = cached.firstIndex(where: { $0.Id == cur.Id }) {
                                if self.playlist.count < cached.count || self.currentIndex != matchedIndex {
                                    self.playlist = cached
                                    self.currentIndex = matchedIndex
                                }
                            }
                        } else {
                            self.loadEpisodesForSeason(seasonId: sid, seriesId: seriesId)
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    self.isLoadingSeasons = false
                }
                print("Failed to fetch seasons: \(error)")
            }
        }
    }
    
    func selectSeason(_ season: JFItemDto) {
        guard selectedSeasonId != season.Id else { return }
        selectedSeasonId = season.Id
        
        if let cached = seasonEpisodesCache[season.Id] {
            self.drawerEpisodes = cached
            return
        }
        
        guard let seriesId = loadedSeriesId ?? currentItem?.SeriesId else { return }
        loadEpisodesForSeason(seasonId: season.Id, seriesId: seriesId)
    }
    
    func loadEpisodesForSeason(seasonId: String, seriesId: String) {
        isLoadingSeasonEpisodes = true
        Task {
            let base = appState.serverURL.hasSuffix("/") ? String(appState.serverURL.dropLast()) : appState.serverURL
            var components = URLComponents(string: "\(base)/Shows/\(seriesId)/Episodes")
            components?.queryItems = [
                URLQueryItem(name: "seasonId", value: seasonId),
                URLQueryItem(name: "userId", value: appState.userID),
                URLQueryItem(name: "Fields", value: "Overview,ImageTags,UserData,SeriesName,SeriesId,SeasonId,ParentIndexNumber,IndexNumber,RunTimeTicks")
            ]
            guard let url = components?.url else {
                await MainActor.run { self.isLoadingSeasonEpisodes = false }
                return
            }
            var req = URLRequest(url: url)
            req.setValue(appState.accessToken, forHTTPHeaderField: "X-Emby-Token")
            
            do {
                let (data, response) = try await URLSession.shared.data(for: req)
                guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                    await MainActor.run { self.isLoadingSeasonEpisodes = false }
                    return
                }
                struct EpisodesResponse: Decodable { let Items: [JFItemDto] }
                let decoded = try JSONDecoder().decode(EpisodesResponse.self, from: data)
                
                await MainActor.run {
                    self.seasonEpisodesCache[seasonId] = decoded.Items
                    if self.selectedSeasonId == seasonId {
                        self.drawerEpisodes = decoded.Items
                    }
                    
                    // If current item is from this season, ensure playlist contains ALL episodes
                    // so all previous episodes exist in the queue and can be navigated to
                    if let cur = self.currentItem,
                       (cur.SeasonId == seasonId || decoded.Items.contains(where: { $0.Id == cur.Id })),
                       !self.isShuffled {
                        if let matchedIndex = decoded.Items.firstIndex(where: { $0.Id == cur.Id }) {
                            if self.playlist.count < decoded.Items.count || self.currentIndex != matchedIndex {
                                self.playlist = decoded.Items
                                self.currentIndex = matchedIndex
                            }
                            if matchedIndex == decoded.Items.count - 1 {
                                Task {
                                    await self.fetchNextSeasonEpisodes(seriesId: seriesId, currentSeasonId: seasonId, base: base)
                                }
                            }
                        }
                    }
                    
                    self.isLoadingSeasonEpisodes = false
                }
            } catch {
                print("Failed to fetch episodes for season \(seasonId): \(error)")
                await MainActor.run { self.isLoadingSeasonEpisodes = false }
            }
        }
    }
    
    func playDrawerItem(item: JFItemDto) {
        if let idx = playlist.firstIndex(where: { $0.Id == item.Id }) {
            if idx != currentIndex {
                currentIndex = idx
                loadItem(at: idx)
            }
        } else {
            let newPlaylist = self.drawerEpisodes.isEmpty ? [item] : self.drawerEpisodes
            self.playlist = newPlaylist
            if let newIdx = newPlaylist.firstIndex(where: { $0.Id == item.Id }) {
                self.currentIndex = newIdx
                self.loadItem(at: newIdx)
            } else {
                self.currentIndex = 0
                self.loadItem(at: 0)
            }
        }
    }
    
    func playSelectedSeasonFromBeginning() {
        guard let firstEp = drawerEpisodes.first else { return }
        playDrawerItem(item: firstEp)
    }
    
    private func fetchNextSeasonEpisodes(seriesId: String, currentSeasonId: String, base: String) async {
        let seasonsList: [JFItemDto]
        if !self.seasons.isEmpty {
            seasonsList = self.seasons
        } else {
            guard let url = URL(string: "\(base)/Shows/\(seriesId)/Seasons?userId=\(appState.userID)") else { return }
            var req = URLRequest(url: url)
            req.setValue(appState.accessToken, forHTTPHeaderField: "X-Emby-Token")
            
            guard let (data, _) = try? await URLSession.shared.data(for: req) else { return }
            struct SeasonsResponse: Decodable { let Items: [JFItemDto] }
            guard let decoded = try? JSONDecoder().decode(SeasonsResponse.self, from: data) else { return }
            seasonsList = decoded.Items
        }
        
        guard let currentIdx = seasonsList.firstIndex(where: { $0.Id == currentSeasonId }),
              currentIdx + 1 < seasonsList.count else { return }
        
        let nextSeason = seasonsList[currentIdx + 1]
        
        if let cached = seasonEpisodesCache[nextSeason.Id], !cached.isEmpty {
            await MainActor.run {
                guard self.currentIndex == self.playlist.count - 1 else { return }
                self.playlist.append(contentsOf: cached)
            }
            return
        }
        
        var components = URLComponents(string: "\(base)/Shows/\(seriesId)/Episodes")
        components?.queryItems = [
            URLQueryItem(name: "seasonId", value: nextSeason.Id),
            URLQueryItem(name: "userId", value: appState.userID),
            URLQueryItem(name: "Fields", value: "Overview,ImageTags,UserData,SeriesName,SeriesId,SeasonId,ParentIndexNumber,IndexNumber,RunTimeTicks")
        ]
        guard let epUrl = components?.url else { return }
        var epReq = URLRequest(url: epUrl)
        epReq.setValue(epReq.value(forHTTPHeaderField: "X-Emby-Token") ?? appState.accessToken, forHTTPHeaderField: "X-Emby-Token")
        
        do {
            let (epData, _) = try await URLSession.shared.data(for: epReq)
            struct EpisodesResponse: Decodable { let Items: [JFItemDto] }
            let epDecoded = try JSONDecoder().decode(EpisodesResponse.self, from: epData)
            
            if !epDecoded.Items.isEmpty {
                await MainActor.run {
                    self.seasonEpisodesCache[nextSeason.Id] = epDecoded.Items
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
    @State private var isPartiallyFolded: Bool = false
    @State private var showEpisodesDrawer: Bool = false
    
    let onPlaybackError: ((String) -> Void)?
    
    init(playlist: [JFItemDto], startIndex: Int, seriesName: String?, isShuffled: Bool = false, appState: AppState, onPlaybackError: ((String) -> Void)? = nil) {
        AppDelegate.orientationLock = UIDevice.isiPhoneDuo ? .allButUpsideDown : .landscape
        self.onPlaybackError = onPlaybackError
        _vm = StateObject(wrappedValue: PlanktonPlayerViewModel(playlist: playlist, startIndex: startIndex, seriesName: seriesName, isShuffled: isShuffled, appState: appState))
    }
    
    var body: some View {
        ZStack {
            DuoTabletopSplitLayout(isPartiallyFolded: isPartiallyFolded) {
                tabletopVideoPane
            } secondary: {
                tabletopDeckPane
            } normal: {
                normalPlayerContent
            }
            .duoHingeObservation(isPartiallyFolded: $isPartiallyFolded)
            
            if let error = vm.errorMessage {
                errorStateView(error)
                    .zIndex(20)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: vm.errorMessage != nil)
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .onAppear {
            vm.onPlaybackError = { msg in
                vm.errorMessage = msg
                self.onPlaybackError?(msg)
            }
            
            vm.onFinishedPlaylist = {
                dismiss()
            }
            if !UIDevice.isiPhoneDuo {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
                        windowScene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscapeRight))
                    }
                }
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
        }
        .onDisappear {
            vm.cleanup()
            AppDelegate.orientationLock = .portrait
            if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
                windowScene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait))
            }
        }
        .onChange(of: vm.controlsVisible) { _, visible in
            if visible && !showEpisodesDrawer { playerController?.resetAutoHideTimer() }
            else       { playerController?.cancelTimer() }
        }
        .onChange(of: vm.isCCEnabled) { _, enabled in
            vm.handleCCEnabledChanged(enabled)
        }
    }
    
    // MARK: - iPhone Duo Tabletop Panes
    
    private var tabletopVideoPane: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            if let url = vm.streamURL {
                DragonetPlayer(
                    player: vm.player,
                    streamURL: url,
                    isPiPActive: $vm.isPiPActive,
                    isCCEnabled: $vm.isCCEnabled,
                    controlsVisible: $vm.controlsVisible,
                    onPlaybackError: { msg in
                        vm.errorMessage = msg
                        self.onPlaybackError?(msg)
                    }
                ) { vc in
                    vc.updatesNowPlayingInfoCenter = false
                    playerController = vc
                }
                .ignoresSafeArea()
            }
            
            if vm.isBuffering && vm.errorMessage == nil {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    .scaleEffect(2.0)
                    .allowsHitTesting(false)
            }
            
            if !vm.currentSubtitleText.isEmpty {
                VStack {
                    Spacer()
                    Text(vm.currentSubtitleText)
                        .font(.system(size: 18, weight: .semibold, design: .rounded))
                        .foregroundColor(.white)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color.black.opacity(0.5))
                        )
                        .padding(.bottom, 20)
                        .shadow(color: .black.opacity(0.3), radius: 4, x: 0, y: 2)
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 40)
                .allowsHitTesting(false)
            }
            
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
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .foregroundStyle(.white)
                            .glassEffect(in: Capsule())
                        }
                    }
                    .padding(.trailing, 20)
                    .padding(.bottom, 16)
                }
            }
            
            if vm.showNextEpisodeCountdown {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Next Episode")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(.white.opacity(0.8))
                                Text("Playing in \(vm.nextEpisodeCountdown)s")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.white)
                            }
                            
                            Button {
                                vm.skipToNextEpisode()
                            } label: {
                                Image(systemName: "play.fill")
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundStyle(.black)
                                    .frame(width: 30, height: 30)
                                    .background(Color.white)
                                    .clipShape(Circle())
                            }
                            
                            Button {
                                vm.dismissCountdown()
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundStyle(.white)
                                    .frame(width: 26, height: 26)
                                    .background(Color.white.opacity(0.2))
                                    .clipShape(Circle())
                            }
                        }
                        .padding(.vertical, 8)
                        .padding(.horizontal, 14)
                        .glassEffect(in: RoundedRectangle(cornerRadius: 30, style: .continuous))
                    }
                    .padding(.trailing, 20)
                    .padding(.bottom, 16)
                }
            }
        }
    }
    
    private var tabletopDeckPane: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            PlanktonTabletopDeckView(
                vm: vm,
                appState: appState,
                dismiss: { vm.stopAndDismiss() },
                showEpisodesDrawer: $showEpisodesDrawer,
                playerController: playerController
            )
            
            if showEpisodesDrawer {
                episodeSwitchDrawer
                    .zIndex(4)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
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
            if showEpisodesDrawer {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    showEpisodesDrawer = false
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

    private var normalPlayerContent: some View {
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
                    onPlaybackError: { msg in
                        vm.errorMessage = msg
                        self.onPlaybackError?(msg)
                    }
                ) { vc in
                    vc.updatesNowPlayingInfoCenter = false
                    
                    vc.onTap = {
                        if showEpisodesDrawer {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                showEpisodesDrawer = false
                            }
                            return
                        }
                        withAnimation(.easeOut(duration: 0.2)) { vm.controlsVisible.toggle() }
                        if vm.controlsVisible { vc.resetAutoHideTimer() }
                    }
                    vc.onAutoHide = {
                        if !showEpisodesDrawer {
                            withAnimation(.easeOut(duration: 0.4)) { vm.controlsVisible = false }
                        }
                    }
                    playerController = vc
                    if vm.controlsVisible && !showEpisodesDrawer { vc.resetAutoHideTimer() }
                }
                .ignoresSafeArea()
            }
            
            // ── AirPlay Active Screen ──
            if vm.isExternalPlaybackActive {
                airplayActiveOverlay
            }
            
            // ── 2. Loading Indicator ──
            if vm.isBuffering && vm.errorMessage == nil {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    .scaleEffect(2.0)
                    .allowsHitTesting(false)
            }
            
            // ── 3. Custom Subtitles Overlay ──
            if !vm.isExternalPlaybackActive && !vm.currentSubtitleText.isEmpty {
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
                                .fill(Color.black.opacity(0.4))
                        )
                        .padding(.bottom, vm.controlsVisible ? 85 : 44)
                        .shadow(color: .black.opacity(0.3), radius: 4, x: 0, y: 2)
                }
                .allowsHitTesting(false)
            }
            
            // ── 4. Next Episode Auto-play Countdown Floating Pill ──
            if vm.showNextEpisodeCountdown {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        HStack(spacing: 12) {
                            Button {
                                vm.dismissCountdown()
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundStyle(.white.opacity(0.8))
                                    .frame(width: 28, height: 28)
                                    .background(Color.white.opacity(0.15))
                                    .clipShape(Circle())
                            }
                            
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Next episode in \(vm.nextEpisodeCountdown)s")
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundStyle(.white)
                                
                                Text(vm.hasNextEpisode && vm.playlist.indices.contains(vm.currentIndex + 1) ? (vm.playlist[vm.currentIndex + 1].Name) : "Next")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.7))
                                    .lineLimit(1)
                            }
                            
                            Button {
                                vm.skipToNextEpisode()
                            } label: {
                                Image(systemName: "play.fill")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundStyle(.black)
                                    .frame(width: 30, height: 30)
                                    .background(Color.white.opacity(0.2))
                                    .clipShape(Circle())
                            }
                        }
                        .padding(.vertical, 10)
                        .padding(.horizontal, 16)
                        .glassEffect(in: RoundedRectangle(cornerRadius: 40, style: .continuous))
                        .shadow(color: .black.opacity(0.4), radius: 10, x: 0, y: 4)
                    }
                    .padding(.horizontal, 32)
                    .padding(.bottom, vm.controlsVisible ? 85 : 50)
                    .safeAreaPadding(.horizontal)
                }
                .transition(.move(edge: .trailing).combined(with: .opacity))
                .animation(.spring(response: 0.4, dampingFraction: 0.8), value: vm.showNextEpisodeCountdown)
                .animation(.spring(response: 0.4, dampingFraction: 0.8), value: vm.controlsVisible)
            }
            
            // ── 5. Main Controls Overlay ──
            controlsOverlay
                .opacity(vm.controlsVisible && !showEpisodesDrawer ? 1 : 0)
                .allowsHitTesting(vm.controlsVisible && !showEpisodesDrawer)
            
            // ── 6. Episode Switcher Drawer ──
            if showEpisodesDrawer {
                episodeSwitchDrawer
                    .zIndex(4)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .gesture(
            DragGesture(minimumDistance: 25)
                .onEnded { value in
                    if value.translation.height < -40 && (vm.playlist.count > 1 || vm.isEpisode) {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                            showEpisodesDrawer = true
                        }
                        playerController?.cancelTimer()
                    } else if value.translation.height > 40 {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                            showEpisodesDrawer = false
                        }
                        if vm.controlsVisible {
                            playerController?.resetAutoHideTimer()
                        }
                    }
                }
        )
    }

    // MARK: - Episode Switcher Drawer (Quick Switch Style)

    private var episodeSwitchDrawer: some View {
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
                        showEpisodesDrawer = false
                    }
                }
                
                // Header Row
                HStack(alignment: .center, spacing: 10) {
                    Text(vm.isEpisode ? "Episodes" : "Playlist")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                    
                    Spacer()
                    
                    // Quick Action: If user switched to another season, allow playing from start directly
                    if vm.isEpisode, let selectedSeason = vm.selectedSeason,
                       let currentSeasonId = vm.currentItem?.SeasonId ?? vm.seasons.first(where: { $0.IndexNumber == vm.currentItem?.ParentIndexNumber })?.Id,
                       selectedSeason.Id != currentSeasonId {
                        Button {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                showEpisodesDrawer = false
                            }
                            vm.playSelectedSeasonFromBeginning()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "play.fill")
                                    .font(.system(size: 10, weight: .bold))
                                Text("Play Season")
                                    .font(.caption.weight(.bold))
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Color.blue)
                            .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                    }
                }
                .padding(.horizontal, 4)
                
                // Horizontal Season Pills Row (Direct Quick Switching)
                if vm.isEpisode && vm.seasons.count > 1 {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(vm.seasons) { season in
                                let isSelected = season.Id == vm.selectedSeasonId
                                Button {
                                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                        vm.selectSeason(season)
                                    }
                                } label: {
                                    Text(season.Name)
                                        .font(.caption.weight(isSelected ? .bold : .medium))
                                        .foregroundStyle(isSelected ? .white : .white.opacity(0.75))
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 5)
                                        .background(isSelected ? Color.blue : Color.white.opacity(0.12))
                                        .clipShape(Capsule())
                                        .overlay(
                                            Capsule()
                                                .stroke(isSelected ? Color.blue.opacity(0.8) : Color.white.opacity(0.15), lineWidth: 1)
                                        )
                                }
                                .buttonStyle(.plain)
                                .id(season.Id)
                            }
                        }
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                    }
                }

                if vm.isLoadingSeasonEpisodes {
                    HStack {
                        Spacer()
                        ProgressView()
                            .tint(.white)
                        Spacer()
                    }
                    .frame(height: 90)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(spacing: 12) {
                                ForEach(Array(vm.drawerEpisodes.enumerated()), id: \.element.Id) { index, item in
                                    let isCurrent = item.Id == vm.currentItem?.Id
                                    let s = item.ParentIndexNumber.map { String(format: "S%02d", $0) } ?? ""
                                    let e = item.IndexNumber.map { String(format: "E%02d", $0) } ?? ""
                                    let se = [s, e].filter { !$0.isEmpty }.joined()
                                    let targetImageId = item.ImageTags?["Primary"] != nil ? item.Id : item.effectiveImageItemId
                                    
                                    Button {
                                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                            showEpisodesDrawer = false
                                        }
                                        vm.playDrawerItem(item: item)
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
                                                colors: [.clear, Color.black.opacity(0.85)],
                                                startPoint: .top,
                                                endPoint: .bottom
                                            )
                                            
                                            VStack(alignment: .leading, spacing: 2) {
                                                HStack {
                                                    if !se.isEmpty {
                                                        Text(se)
                                                            .font(.system(size: 10, weight: .bold))
                                                            .foregroundStyle(.white)
                                                            .padding(.horizontal, 5)
                                                            .padding(.vertical, 2)
                                                            .background(Color.black.opacity(0.6))
                                                            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                                                    }
                                                    Spacer()
                                                    if item.UserData?.Played == true {
                                                        Image(systemName: "checkmark.circle.fill")
                                                            .font(.system(size: 12))
                                                            .foregroundStyle(Color.green)
                                                    }
                                                }
                                                
                                                Spacer()
                                                
                                                Text(item.Name)
                                                    .font(.system(size: 11, weight: .semibold))
                                                    .foregroundStyle(.white)
                                                    .lineLimit(1)
                                                
                                                if let playedTicks = item.UserData?.PlaybackPositionTicks,
                                                   let totalTicks = item.RunTimeTicks,
                                                   totalTicks > 0,
                                                   playedTicks > 0 {
                                                    let progress = min(max(Double(playedTicks) / Double(totalTicks), 0.0), 1.0)
                                                    GeometryReader { g in
                                                        ZStack(alignment: .leading) {
                                                            Capsule().fill(Color.white.opacity(0.3))
                                                            Capsule().fill(Color.blue).frame(width: g.size.width * CGFloat(progress))
                                                        }
                                                    }
                                                    .frame(height: 3)
                                                }
                                            }
                                            .padding(6)
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
                                    .id(item.Id)
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 2)
                        }
                        .frame(height: 90)
                        .onAppear {
                            if let curId = vm.currentItem?.Id, vm.drawerEpisodes.contains(where: { $0.Id == curId }) {
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                                    proxy.scrollTo(curId, anchor: .center)
                                }
                            }
                        }
                        .onChange(of: showEpisodesDrawer) { _, isShown in
                            if isShown {
                                if vm.isEpisode && vm.seasons.isEmpty {
                                    vm.fetchSeasons(for: vm.currentItem)
                                }
                                if let curId = vm.currentItem?.Id, vm.drawerEpisodes.contains(where: { $0.Id == curId }) {
                                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                        proxy.scrollTo(curId, anchor: .center)
                                    }
                                }
                            }
                        }
                        .onChange(of: vm.selectedSeasonId) { _, _ in
                            if let firstId = vm.drawerEpisodes.first?.Id {
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                    proxy.scrollTo(firstId, anchor: .leading)
                                }
                            }
                        }
                        .onChange(of: vm.drawerEpisodes.count) { _, _ in
                            if let curId = vm.currentItem?.Id, vm.drawerEpisodes.contains(where: { $0.Id == curId }) {
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                    proxy.scrollTo(curId, anchor: .center)
                                }
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
                            HStack(alignment: .center, spacing: 8) {
                                Text(series)
                                    .font(.title3.bold())
                                    .foregroundStyle(.white)
                                    .shadow(radius: 2)
                                
                                if vm.isShuffled {
                                    Image(systemName: "shuffle")
                                        .font(.system(size: 12, weight: .bold))
                                        .foregroundColor(.white)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 3)
                                        .background(Color.blue.opacity(0.8))
                                        .clipShape(Capsule())
                                }
                            }
                            
                            let s = vm.currentItem?.ParentIndexNumber.map { String(format: "S%02d", $0) } ?? ""
                            let e = vm.currentItem?.IndexNumber.map { String(format: "E%02d", $0) } ?? ""
                            let se = [s, e].filter { !$0.isEmpty }.joined()
                            let epName = vm.currentItem?.Name ?? ""
                            let subtitleText = se.isEmpty ? epName : "\(se) • \(epName)"
                            
                            HStack {
                                Text(subtitleText)
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(.white.opacity(0.85))
                                    .shadow(radius: 2)
                                
                                if vm.isShuffled {
                                    Text("— Shuffling Episodes")
                                        .font(.caption.weight(.medium))
                                        .foregroundStyle(.blue.opacity(0.9))
                                }
                            }
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
                        
                        DragonetAirPlayButton(player: vm.player) { presenting in
                            if presenting {
                                playerController?.cancelTimer()
                            } else {
                                if vm.controlsVisible && !showEpisodesDrawer {
                                    playerController?.resetAutoHideTimer()
                                }
                            }
                        }
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
    
    // MARK: - Error Screen
    
    private func errorStateView(_ error: String) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 60))
                .foregroundColor(.yellow)
            
            Text(error)
                .font(.headline)
                .foregroundColor(.gray)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            
            HStack(spacing: 16) {
                Button {
                    vm.retryPlayback()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.clockwise")
                        Text("Retry")
                    }
                    .font(.headline)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.bordered)
                .tint(.white)
                
                Button("Dismiss") {
                    dismiss()
                }
                .font(.headline)
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
                .buttonStyle(.borderedProminent)
            }
            .padding(.top, 8)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.ignoresSafeArea())
    }
}

// MARK: - Presentation helper

struct PlanktonPlayerModifier: ViewModifier {
    @Binding var isPresented: Bool
    let playlist: [JFItemDto]
    let startIndex: Int
    let seriesName: String?
    let isShuffled: Bool
    let onPlaybackError: ((String) -> Void)?
    
    @EnvironmentObject var appState: AppState
    
    func body(content: Content) -> some View {
        content
            .fullScreenCover(isPresented: $isPresented) {
                if !playlist.isEmpty {
                    PlanktonPlayerView(
                        playlist: playlist,
                        startIndex: startIndex,
                        seriesName: seriesName,
                        isShuffled: isShuffled,
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
    func planktonPlayer(
        isPresented: Binding<Bool>,
        playlist: [JFItemDto],
        startIndex: Int = 0,
        seriesName: String? = nil,
        isShuffled: Bool = false,
        onPlaybackError: ((String) -> Void)? = nil
    ) -> some View {
        self.modifier(PlanktonPlayerModifier(
            isPresented: isPresented,
            playlist: playlist,
            startIndex: startIndex,
            seriesName: seriesName,
            isShuffled: isShuffled,
            onPlaybackError: onPlaybackError
        ))
    }
}
