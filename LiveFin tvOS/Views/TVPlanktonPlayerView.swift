//
//  TVPlanktonPlayerView.swift
//  LiveFin
//
//  Created by KPGamingz on 7/22/26.
//

import SwiftUI
import AVKit
import AVFoundation
import Combine
import JellyfinAPI

// MARK: - Jellyfin Track Models

struct PlanktonMediaStream: Decodable, Hashable {
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
        if let lang = Language, !lang.isEmpty {
            return Locale.current.localizedString(forLanguageCode: lang)?.capitalized ?? lang.uppercased()
        }
        return "Unknown Track"
    }
}

struct PlanktonMediaSource: Decodable {
    let Id: String?
    let Container: String?
    let MediaStreams: [PlanktonMediaStream]?
}

struct PlanktonItemMediaData: Decodable {
    let MediaSources: [PlanktonMediaSource]?
}

struct PlanktonVTTCue: Identifiable, Hashable {
    let id = UUID()
    let startTime: Double
    let endTime: Double
    let text: String
}

// MARK: - Custom Player ViewController Representable

class PlanktonAVPlayerViewController: AVPlayerViewController {
    var onPlayPause: (() -> Void)?
    var onBack: (() -> Void)?

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        for press in presses {
            if press.type == .playPause {
                onPlayPause?()
                handled = true
            } else if press.type == .menu {
                onBack?()
                handled = true
            }
        }

        if !handled {
            super.pressesBegan(presses, with: event)
        }
    }
}

struct PlanktonVideoPlayer: UIViewControllerRepresentable {
    let player: AVPlayer
    var onPlayPause: (() -> Void)?
    var onBack: (() -> Void)?

    func makeUIViewController(context: Context) -> PlanktonAVPlayerViewController {
        let vc = PlanktonAVPlayerViewController()
        vc.player = player
        vc.showsPlaybackControls = false
        vc.allowsPictureInPicturePlayback = false
        vc.onPlayPause = onPlayPause
        vc.onBack = onBack
        return vc
    }

    func updateUIViewController(_ uiViewController: PlanktonAVPlayerViewController, context: Context) {
        uiViewController.onPlayPause = onPlayPause
        uiViewController.onBack = onBack
        if uiViewController.player != player {
            uiViewController.player = player
        }
    }
}

// MARK: - TVPlanktonPlayerView

struct TVPlanktonPlayerView: View {
    let playlist: [JFItemDto]
    let initialIndex: Int

    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var currentIndex: Int
    @State private var activeItem: JFItemDto?

    @State private var player: AVPlayer?
    @State private var isPlaying = true
    @State private var isBuffering = true
    @State private var errorMessage: String? = nil

    @State private var controlsVisible = true
    @State private var showSettingsPanel = false
    @State private var showEpisodes = false
    @State private var hideControlsTask: Task<Void, Never>?

    @State private var episodes: [JFItemDto] = []

    // Scrubber state
    @State private var currentSeconds: Double = 0
    @State private var durationSeconds: Double = 0
    @State private var isScrubbing = false
    @State private var timeObserverToken: Any?
    @State private var endObserverToken: NSObjectProtocol?
    @State private var scrubPreviewSeconds: Double?
    @State private var scrubCommitTask: Task<Void, Never>?
    @FocusState private var isScrubberFocused: Bool

    // Jellyfin-native track metadata
    @State private var mediaSourceId: String?
    @State private var mediaSourceContainer: String?
    @State private var availableAudioTracks: [PlanktonMediaStream] = []
    @State private var selectedAudioTrack: PlanktonMediaStream?
    @State private var availableSubtitleTracks: [PlanktonMediaStream] = []
    @State private var selectedSubtitleTrack: PlanktonMediaStream?

    // Native HLS subtitle group
    @State private var nativeSubtitleGroup: AVMediaSelectionGroup?
    @State private var nativeSubtitleOptions: [AVMediaSelectionOption] = []

    // Custom overlay captions
    @State private var vttCues: [PlanktonVTTCue] = []
    @State private var currentSubtitleText: String = ""

    // Playback monitors
    let playbackMonitorTimer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()
    let sessionProgressTimer = Timer.publish(every: 10.0, on: .main, in: .common).autoconnect()

    var baseServerURL: String {
        appState.serverURL.hasSuffix("/") ? String(appState.serverURL.dropLast()) : appState.serverURL
    }

    init(playlist: [JFItemDto], startIndex: Int = 0) {
        self.playlist = playlist
        self.initialIndex = startIndex
        _currentIndex = State(initialValue: startIndex)
        if playlist.indices.contains(startIndex) {
            _activeItem = State(initialValue: playlist[startIndex])
        }
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let player = player {
                PlanktonVideoPlayer(
                    player: player,
                    onPlayPause: {
                        togglePlay()
                        withAnimation(.easeOut(duration: 0.3)) { controlsVisible = true }
                        resetHideTimer()
                    },
                    onBack: {
                        dismissStream()
                    }
                )
                .ignoresSafeArea()

                if !controlsVisible && !showSettingsPanel && !showEpisodes {
                    Color.black.opacity(0.001)
                        .contentShape(Rectangle())
                        .focusable()
                        .onMoveCommand { _ in
                            withAnimation(.easeOut(duration: 0.3)) { controlsVisible = true }
                            resetHideTimer()
                        }
                        .onTapGesture {
                            withAnimation(.easeOut(duration: 0.3)) { controlsVisible = true }
                            resetHideTimer()
                        }
                }

                if isBuffering && errorMessage == nil {
                    ProgressView()
                        .scaleEffect(2.0)
                        .tint(.white)
                }

                if !currentSubtitleText.isEmpty {
                    VStack {
                        Spacer()
                        Text(currentSubtitleText)
                            .font(.title3.bold())
                            .foregroundColor(.white)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 10)
                            .background(Color.black.opacity(0.75))
                            .cornerRadius(8)
                            .padding(.bottom, controlsVisible ? 260 : 80)
                    }
                    .allowsHitTesting(false)
                }

                if controlsVisible {
                    overlayControls
                        .transition(.opacity)
                }

                if showSettingsPanel {
                    settingsPanel
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }

                if showEpisodes {
                    episodesOverlay
                        .transition(.opacity)
                }
            } else if let error = errorMessage {
                errorStateView(error)
            } else {
                loadingStateView
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .onExitCommand {
            dismissStream()
        }
        .onPlayPauseCommand {
            togglePlay()
            withAnimation(.easeOut(duration: 0.3)) { controlsVisible = true }
            resetHideTimer()
        }
        .task { await setupPlayer() }
        .onDisappear {
            detachTimeObserver()
            detachEndObserver()
            player?.pause()
            if let item = activeItem {
                Task { await appState.reportPlaybackStopped(itemId: item.Id, positionTicks: ticks(fromSeconds: currentSeconds)) }
            }
        }
        .onReceive(playbackMonitorTimer) { _ in
            guard let player = player else { return }
            let buffering = player.timeControlStatus == .waitingToPlayAtSpecifiedRate
            if isBuffering != buffering {
                withAnimation { isBuffering = buffering }
            }
        }
        .onReceive(sessionProgressTimer) { _ in
            reportProgress()
        }
    }

    private var overlayControls: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .center, spacing: 28) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(activeItem?.SeriesName ?? activeItem?.Name ?? "")
                            .font(.title2.bold())
                            .foregroundColor(.white)
                            .lineLimit(2)
                            .shadow(radius: 4)

                        if activeItem?.Type == "Episode" {
                            Text(activeItem?.Name ?? "")
                                .font(.subheadline)
                                .foregroundColor(.white.opacity(0.75))
                                .lineLimit(2)
                                .shadow(radius: 4)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Spacer()

                    Button(action: {
                        togglePlay()
                        resetHideTimer()
                    }) {
                        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 26))
                            .frame(width: 54, height: 54)
                    }
                    .buttonStyle(.card)

                    Button(action: {
                        withAnimation(.spring()) {
                            showSettingsPanel = true
                            controlsVisible = false
                        }
                        hideControlsTask?.cancel()
                    }) {
                        Image(systemName: (selectedSubtitleTrack != nil) ? "captions.bubble.fill" : "captions.bubble")
                            .font(.system(size: 24))
                            .frame(width: 54, height: 54)
                    }
                    .buttonStyle(.card)

                    if activeItem?.Type == "Episode" && !episodes.isEmpty {
                        Button(action: {
                            showEpisodes = true
                            controlsVisible = false
                            hideControlsTask?.cancel()
                        }) {
                            Label("Episodes", systemImage: "list.bullet.rectangle")
                                .font(.callout.bold())
                                .padding(.horizontal, 14)
                                .frame(height: 54)
                        }
                        .buttonStyle(.card)
                    }
                }

                scrubberSection
            }
            .padding(.horizontal, 60)
            .padding(.top, 40)
            .padding(.bottom, 50)
            .background(LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .top, endPoint: .bottom))
        }
        .ignoresSafeArea()
    }

    @ViewBuilder
    private var scrubberSection: some View {
        VStack(spacing: 8) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.25))
                        .frame(height: 8)

                    Capsule()
                        .fill(Color.blue)
                        .frame(width: max(geo.size.width * scrubberProgress, 0))
                        .frame(height: 8)

                    Rectangle()
                        .fill(Color.white)
                        .frame(width: 4, height: 24)
                        .cornerRadius(2)
                        .offset(x: max((geo.size.width * scrubberProgress) - 2, 0))
                }
                .frame(maxHeight: .infinity, alignment: .center)
            }
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 14).fill(isScrubberFocused ? Color.white.opacity(0.15) : Color.clear))
            .focusable()
            .focused($isScrubberFocused)
            .onMoveCommand { handleScrub(direction: $0) }

            HStack {
                Text(formatted(scrubPreviewSeconds ?? currentSeconds))
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.75))
                Spacer()
                Text(formatted(durationSeconds))
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.75))
            }
        }
    }

    private var scrubberProgress: Double {
        guard durationSeconds > 0 else { return 0 }
        return min(max((scrubPreviewSeconds ?? currentSeconds) / durationSeconds, 0), 1)
    }

    private func handleScrub(direction: MoveCommandDirection) {
        guard durationSeconds > 0 else { return }
        let step: Double = 15
        let base = scrubPreviewSeconds ?? currentSeconds
        let newValue: Double
        switch direction {
        case .left: newValue = max(0, base - step)
        case .right: newValue = min(durationSeconds, base + step)
        default: return
        }

        isScrubbing = true
        scrubPreviewSeconds = newValue
        resetHideTimer()

        scrubCommitTask?.cancel()
        scrubCommitTask = Task {
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled, let player = player else { return }
            let target = CMTime(seconds: newValue, preferredTimescale: 600)
            player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
                Task { @MainActor in
                    currentSeconds = newValue
                    scrubPreviewSeconds = nil
                    isScrubbing = false
                }
            }
        }
    }

    private func formatted(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    private var settingsPanel: some View {
        HStack {
            Spacer()
            VStack(alignment: .leading, spacing: 30) {
                HStack {
                    Label("Playback Settings", systemImage: "slider.horizontal.3")
                        .font(.title2.bold())
                        .foregroundColor(.white)
                    Spacer()
                    Button(action: {
                        withAnimation(.spring()) { showSettingsPanel = false }
                        resetHideTimer()
                    }) {
                        Image(systemName: "xmark")
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.card)
                }

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 40) {
                        // Audio Section
                        VStack(alignment: .leading, spacing: 16) {
                            Text("Audio Tracks")
                                .font(.headline)
                                .foregroundColor(.white.opacity(0.6))
                                .padding(.leading, 20)

                            if availableAudioTracks.count < 2 {
                                Text("Default System Audio")
                                    .font(.body)
                                    .foregroundColor(.gray)
                                    .padding(.leading, 20)
                            } else {
                                VStack(spacing: 8) {
                                    ForEach(availableAudioTracks, id: \.self) { track in
                                        let isSelected = selectedAudioTrack == track
                                        Button(action: {
                                            selectAudioTrack(track)
                                            resetHideTimer()
                                        }) {
                                            HStack {
                                                Text(track.safeDisplayName)
                                                    .foregroundColor(.white)
                                                Spacer()
                                                if isSelected {
                                                    Image(systemName: "checkmark")
                                                        .foregroundColor(.blue)
                                                        .bold()
                                                }
                                            }
                                            .padding(.horizontal, 20)
                                            .frame(height: 50)
                                        }
                                        .buttonStyle(.card)
                                    }
                                }
                            }
                        }

                        // Subtitles Section
                        VStack(alignment: .leading, spacing: 16) {
                            Text("Captions / Subtitles")
                                .font(.headline)
                                .foregroundColor(.white.opacity(0.6))
                                .padding(.leading, 20)

                            VStack(spacing: 8) {
                                let isOffSelected = selectedSubtitleTrack == nil
                                Button(action: {
                                    selectSubtitleTrack(nil)
                                    resetHideTimer()
                                }) {
                                    HStack {
                                        Text("Off")
                                            .foregroundColor(.white)
                                        Spacer()
                                        if isOffSelected {
                                            Image(systemName: "checkmark")
                                                .foregroundColor(.blue)
                                                .bold()
                                        }
                                    }
                                    .padding(.horizontal, 20)
                                    .frame(height: 50)
                                }
                                .buttonStyle(.card)

                                ForEach(availableSubtitleTracks, id: \.self) { track in
                                    let isSelected = selectedSubtitleTrack == track
                                    Button(action: {
                                        selectSubtitleTrack(track)
                                        resetHideTimer()
                                    }) {
                                        HStack {
                                            Text(track.safeDisplayName)
                                                .foregroundColor(.white)
                                            Spacer()
                                            if isSelected {
                                                Image(systemName: "checkmark")
                                                    .foregroundColor(.blue)
                                                    .bold()
                                            }
                                        }
                                        .padding(.horizontal, 20)
                                        .frame(height: 50)
                                    }
                                    .buttonStyle(.card)
                                }
                            }
                        }
                    }
                    .padding(.trailing, 10)
                }
            }
            .padding(44)
            .frame(width: 600)
            .background(Color.black.opacity(0.95))
            .shadow(color: .black.opacity(0.5), radius: 20)
        }
        .ignoresSafeArea()
    }

    @ViewBuilder private var episodesOverlay: some View {
        ZStack {
            Color.black.opacity(0.95).ignoresSafeArea()

            VStack(alignment: .leading, spacing: 40) {
                HStack {
                    Text("Episodes")
                        .font(.system(size: 64, weight: .bold))
                        .foregroundColor(.white)
                    Spacer()
                    Button(action: {
                        showEpisodes = false
                        resetHideTimer()
                    }) {
                        Image(systemName: "xmark")
                            .frame(width: 54, height: 54)
                    }
                    .buttonStyle(.card)
                }

                ScrollView {
                    LazyVStack(spacing: 24) {
                        ForEach(episodes) { ep in
                            Button(action: {
                                playNew(item: ep)
                            }) {
                                EpisodeRowView(episode: ep, baseServerURL: baseServerURL)
                                    .padding(20)
                                    .background(Color.white.opacity(0.05))
                                    .cornerRadius(16)
                            }
                            .buttonStyle(.card)
                        }
                    }
                    .padding(.horizontal, 40)
                    .padding(.bottom, 60)
                }
                .padding(.horizontal, -40)
            }
            .padding(80)
        }
    }

    private func errorStateView(_ error: String) -> some View {
        VStack(spacing: 24) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 64)).foregroundColor(.red)
            Text("Playback Failed").font(.title2).foregroundColor(.white).bold()
            Text(error).foregroundColor(.gray).multilineTextAlignment(.center)
        }
    }

    private var loadingStateView: some View {
        VStack(spacing: 24) {
            ProgressView().scaleEffect(1.5)
            Text("Loading \(activeItem?.Name ?? "")...").font(.title3).foregroundColor(.gray)
        }
    }

    private func setupPlayer() async {
        guard let item = activeItem else { return }
        await MainActor.run {
            self.isBuffering = true
            self.errorMessage = nil
        }

        await fetchMediaStreams(for: item)

        let resumeSeconds: Double?
        if let ticks = item.UserData?.PlaybackPositionTicks, ticks > 0 {
            resumeSeconds = seconds(fromTicks: ticks)
        } else {
            resumeSeconds = nil
        }

        await playCurrentSelection(resumeAt: resumeSeconds)
        await fetchEpisodes()
    }

    private func fetchMediaStreams(for item: JFItemDto) async {
        await MainActor.run {
            self.mediaSourceId = nil
            self.mediaSourceContainer = nil
            self.availableAudioTracks = []
            self.selectedAudioTrack = nil
            self.availableSubtitleTracks = []
            self.selectedSubtitleTrack = nil
            self.nativeSubtitleGroup = nil
            self.nativeSubtitleOptions = []
            self.vttCues = []
            self.currentSubtitleText = ""
        }

        guard let url = URL(string: "\(baseServerURL)/Users/\(appState.userID)/Items/\(item.Id)?Fields=MediaSources") else { return }
        var req = URLRequest(url: url)
        req.setValue(appState.accessToken, forHTTPHeaderField: "X-Emby-Token")

        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            let decoded = try JSONDecoder().decode(PlanktonItemMediaData.self, from: data)
            guard let source = decoded.MediaSources?.first else { return }

            await MainActor.run {
                self.mediaSourceId = source.Id
                self.mediaSourceContainer = source.Container?.lowercased()
                if let streams = source.MediaStreams {
                    self.availableAudioTracks = streams.filter { $0.type?.lowercased() == "audio" }
                    self.selectedAudioTrack = self.availableAudioTracks.first(where: { $0.IsDefault == true }) ?? self.availableAudioTracks.first

                    self.availableSubtitleTracks = streams.filter { $0.type?.lowercased() == "subtitle" }
                    self.selectedSubtitleTrack = self.availableSubtitleTracks.first(where: { $0.IsDefault == true || $0.IsForced == true })
                }
            }
        } catch {
            print("TVPlanktonPlayerView: Failed to fetch MediaSources: \(error)")
        }
    }

    private func isTextSub(_ sub: PlanktonMediaStream) -> Bool {
        let codec = sub.Codec?.lowercased() ?? ""
        return codec == "subrip" || codec == "srt" || codec == "vtt" || codec == "webvtt"
    }

    private func playCurrentSelection(resumeAt: Double?) async {
        guard let item = activeItem else { return }
        let base = baseServerURL

        await MainActor.run {
            self.isBuffering = true
        }

        let subtitleStreamIndexToTranscode: Int?
        if let selectedSub = selectedSubtitleTrack, !isTextSub(selectedSub) {
            subtitleStreamIndexToTranscode = selectedSub.Index
        } else {
            subtitleStreamIndexToTranscode = nil
        }

        do {
            // Let the server's DeviceProfile decide what's safe to direct play, the
            // same way the iOS player does, instead of pre-filtering on a client-side
            // container guess (which had no fallback if it guessed wrong).
            let (playbackInfo, turl, mediaSourceIdOut, _) = try await JFPlaybackInfoService.fetchPlaybackInfoWithTranscodingUrl(
                itemId: item.Id,
                userId: appState.userID,
                serverURL: appState.serverURL,
                accessToken: appState.accessToken,
                deviceId: appState.deviceId,
                deviceName: appState.clientDevice,
                clientVersion: appState.clientVersion,
                enableDirectPlay: false,
                enableDirectStream: false,
                enableTranscoding: true,
                audioCodec: "aac,ac3,eac3,mp3,alac,flac",
                videoCodec: "hevc,h265,h264",
                subtitleStreamIndex: subtitleStreamIndexToTranscode,
                mediaSourceId: mediaSourceId,
                debug: true,
                isLiveTV: false
            )

            // Resolve the exact URL provided by Jellyfin PlaybackInfo
            let primarySource = playbackInfo.mediaSources?.first
            let rawUrlPath: String

            if primarySource?.isSupportsDirectPlay == true, let path = primarySource?.path, path.hasPrefix("http") {
                rawUrlPath = path
            } else if let turl = turl, !turl.isEmpty {
                rawUrlPath = turl
            } else {
                await MainActor.run {
                    self.errorMessage = "Server did not return a playable stream URL for this item."
                    self.isBuffering = false
                }
                return
            }

            let streamPath = rawUrlPath

            let fullUrlString: String
            if streamPath.hasPrefix("http://") || streamPath.hasPrefix("https://") {
                fullUrlString = streamPath
            } else {
                let leadingSlash = streamPath.hasPrefix("/") ? "" : "/"
                fullUrlString = "\(base)\(leadingSlash)\(streamPath)"
            }

            var components = URLComponents(string: fullUrlString)
            var queryItems = components?.queryItems ?? []

            if !queryItems.contains(where: { $0.name.lowercased() == "api_key" || $0.name.lowercased() == "apikey" }) {
                queryItems.append(URLQueryItem(name: "api_key", value: appState.accessToken))
            }

            components?.queryItems = queryItems
            guard let url = components?.url else {
                await MainActor.run { self.errorMessage = "Unable to build stream URL from PlaybackInfo." }
                return
            }

            let headers: [String: String] = [
                "X-Emby-Token": appState.accessToken,
                "Authorization": "MediaBrowser Token=\"\(appState.accessToken)\""
            ]
            let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
            let playerItem = AVPlayerItem(asset: asset)

            await MainActor.run {
                detachTimeObserver()
                detachEndObserver()

                if let existingPlayer = self.player {
                    existingPlayer.replaceCurrentItem(with: playerItem)
                } else {
                    let newPlayer = AVPlayer(playerItem: playerItem)
                    self.player = newPlayer
                }

                self.mediaSourceId = mediaSourceIdOut ?? self.mediaSourceId
                observeEndOfItem(playerItem)
                self.player?.play()
                self.isPlaying = true
                self.attachTimeObserver()
                self.loadNativeSubtitleGroup(asset: asset)
                withAnimation(.easeOut(duration: 0.3)) { controlsVisible = true }
                self.resetHideTimer()

                if let target = resumeAt, target > 1 {
                    let cmTarget = CMTime(seconds: target, preferredTimescale: 600)
                    self.player?.seek(to: cmTarget, toleranceBefore: .zero, toleranceAfter: .zero)
                    self.currentSeconds = target
                }

                Task { await appState.reportPlaybackStart(itemId: item.Id) }

                if let sub = self.selectedSubtitleTrack, self.isTextSub(sub) {
                    self.fetchExternalSubtitlePayload(sub)
                }
            }
        } catch {
            print("TVPlanktonPlayerView: PlaybackInfo fetch failed: \(error)")
            await MainActor.run {
                self.isBuffering = false
                self.errorMessage = error.localizedDescription
            }
        }
    }

    private func observeEndOfItem(_ playerItem: AVPlayerItem) {
        detachEndObserver()
        endObserverToken = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: playerItem,
            queue: .main
        ) { _ in
            self.playNextInPlaylist()
        }
    }

    private func detachEndObserver() {
        if let token = endObserverToken {
            NotificationCenter.default.removeObserver(token)
            endObserverToken = nil
        }
    }

    private func attachTimeObserver() {
        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        timeObserverToken = player?.addPeriodicTimeObserver(forInterval: interval, queue: .main) { time in
            guard !self.isScrubbing else { return }
            let t = time.seconds.isFinite ? time.seconds : 0
            self.currentSeconds = t

            if let item = self.player?.currentItem, item.duration.isNumeric, !item.duration.seconds.isNaN, item.duration.seconds > 0 {
                self.durationSeconds = item.duration.seconds
            } else if let ticks = self.activeItem?.RunTimeTicks, ticks > 0 {
                self.durationSeconds = self.seconds(fromTicks: ticks)
            }

            self.updateSubtitleOverlay(at: t)
        }
    }

    private func detachTimeObserver() {
        if let token = timeObserverToken {
            player?.removeTimeObserver(token)
            timeObserverToken = nil
        }
        scrubCommitTask?.cancel()
    }

    private func reportProgress() {
        guard let item = activeItem else { return }
        let positionTicks = ticks(fromSeconds: currentSeconds)
        let base = baseServerURL
        guard let url = URL(string: "\(base)/Sessions/Playing/Progress") else { return }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(appState.accessToken, forHTTPHeaderField: "X-Emby-Token")

        let body: [String: Any] = [
            "ItemId": item.Id,
            "PositionTicks": positionTicks,
            "IsPaused": !isPlaying,
            "EventName": "timeupdate"
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: req).resume()
    }

    private func selectAudioTrack(_ track: PlanktonMediaStream) {
        guard selectedAudioTrack != track else { return }
        selectedAudioTrack = track
        Task { await playCurrentSelection(resumeAt: currentSeconds) }
    }

    private func selectSubtitleTrack(_ option: PlanktonMediaStream?) {
        guard selectedSubtitleTrack != option else { return }
        selectedSubtitleTrack = option

        vttCues = []
        currentSubtitleText = ""

        if let group = nativeSubtitleGroup {
            player?.currentItem?.select(nil, in: group)
        }

        guard let selectedSub = option else { return }

        if let group = nativeSubtitleGroup,
           let nativeOption = nativeSubtitleOptions.first(where: {
               $0.displayName == selectedSub.safeDisplayName || $0.extendedLanguageTag == selectedSub.Language
           }) {
            player?.currentItem?.select(nativeOption, in: group)
            return
        }

        if isTextSub(selectedSub) {
            fetchExternalSubtitlePayload(selectedSub)
        } else {
            Task { await playCurrentSelection(resumeAt: currentSeconds) }
        }
    }

    private func loadNativeSubtitleGroup(asset: AVAsset) {
        Task {
            if let group = try? await asset.loadMediaSelectionGroup(for: .legible) {
                await MainActor.run {
                    self.nativeSubtitleGroup = group
                    self.nativeSubtitleOptions = group.options
                }
            }
        }
    }

    private func fetchExternalSubtitlePayload(_ option: PlanktonMediaStream) {
        guard let item = activeItem else { return }
        let base = baseServerURL

        let subtitleUrlString: String
        if let deliveryUrl = option.DeliveryUrl, !deliveryUrl.isEmpty {
            let prefix = deliveryUrl.hasPrefix("/") ? "" : "/"
            subtitleUrlString = "\(base)\(prefix)\(deliveryUrl)\(deliveryUrl.contains("?") ? "&" : "?")api_key=\(appState.accessToken)"
        } else {
            guard let sourceId = mediaSourceId else { return }
            subtitleUrlString = "\(base)/Videos/\(item.Id)/\(sourceId)/Subtitles/\(option.Index ?? 0)/0/Stream.vtt?api_key=\(appState.accessToken)"
        }

        guard let url = URL(string: subtitleUrlString) else { return }

        Task {
            do {
                var req = URLRequest(url: url)
                req.setValue(appState.accessToken, forHTTPHeaderField: "X-Emby-Token")
                let (data, response) = try await URLSession.shared.data(for: req)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                      let vttText = String(data: data, encoding: .utf8) else { return }
                let cues = parseVTT(vttText)
                await MainActor.run { self.vttCues = cues }
            } catch {
                print("TVPlanktonPlayerView: Failed to fetch WebVTT stream: \(error)")
            }
        }
    }

    private func updateSubtitleOverlay(at time: Double) {
        guard !vttCues.isEmpty else { return }
        if let cue = vttCues.first(where: { time >= $0.startTime && time <= $0.endTime }) {
            if currentSubtitleText != cue.text { currentSubtitleText = cue.text }
        } else if !currentSubtitleText.isEmpty {
            currentSubtitleText = ""
        }
    }

    private func parseVTTTime(_ timeString: String) -> Double? {
        let cleanString = timeString.trimmingCharacters(in: .whitespacesAndNewlines)
        let timeParts = cleanString.components(separatedBy: CharacterSet(charactersIn: ".,"))
        let mainTime = timeParts[0]
        let fraction = timeParts.count > 1 ? (Double("0." + timeParts[1]) ?? 0.0) : 0.0

        let parts = mainTime.components(separatedBy: ":")
        var secondsValue: Double = 0
        if parts.count == 3 {
            secondsValue += (Double(parts[0]) ?? 0) * 3600
            secondsValue += (Double(parts[1]) ?? 0) * 60
            secondsValue += (Double(parts[2]) ?? 0)
        } else if parts.count == 2 {
            secondsValue += (Double(parts[0]) ?? 0) * 60
            secondsValue += (Double(parts[1]) ?? 0)
        } else {
            return nil
        }
        return secondsValue + fraction
    }

    private func parseVTT(_ vttText: String) -> [PlanktonVTTCue] {
        var cues: [PlanktonVTTCue] = []
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
                            cues.append(PlanktonVTTCue(startTime: start, endTime: end, text: cleanText))
                        }
                        continue
                    }
                }
            }
            i += 1
        }
        return cues
    }

    private func fetchEpisodes() async {
        guard let item = activeItem, item.Type == "Episode", let seriesId = item.SeriesId else { return }

        guard let url = URL(string: "\(baseServerURL)/Shows/\(seriesId)/Episodes?userId=\(appState.userID)&Fields=Overview,ImageTags,UserData,RunTimeTicks") else { return }
        var req = URLRequest(url: url)
        req.setValue(appState.accessToken, forHTTPHeaderField: "X-Emby-Token")

        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            struct Resp: Decodable { let Items: [JFItemDto] }
            let decoded = try JSONDecoder().decode(Resp.self, from: data)
            await MainActor.run { self.episodes = decoded.Items }
        } catch {
            print("TVPlanktonPlayerView: Failed to fetch episodes menu data")
        }
    }

    private func playNew(item: JFItemDto) {
        if let idx = playlist.firstIndex(where: { $0.Id == item.Id }) {
            currentIndex = idx
        }
        let previousItem = activeItem
        activeItem = item
        showEpisodes = false
        Task {
            if let previous = previousItem {
                await appState.reportPlaybackStopped(itemId: previous.Id, positionTicks: ticks(fromSeconds: currentSeconds))
            }
            await setupPlayer()
        }
    }

    private func playNextInPlaylist() {
        let previousItem = activeItem
        if currentIndex + 1 < playlist.count {
            currentIndex += 1
            activeItem = playlist[currentIndex]
            Task {
                if let previous = previousItem {
                    await appState.reportPlaybackStopped(itemId: previous.Id, positionTicks: 0)
                }
                await setupPlayer()
            }
        } else {
            Task {
                if let previous = previousItem {
                    await appState.reportPlaybackStopped(itemId: previous.Id, positionTicks: 0)
                }
                await MainActor.run { dismissStream() }
            }
        }
    }

    // MARK: - Transport

    private func togglePlay() {
        isPlaying.toggle()
        isPlaying ? player?.play() : player?.pause()
    }
    
    private func dismissStream() {
        player?.pause()
        if let item = activeItem {
            Task { await appState.reportPlaybackStopped(itemId: item.Id, positionTicks: ticks(fromSeconds: currentSeconds)) }
        }
        dismiss()
    }

    private func resetHideTimer() {
        hideControlsTask?.cancel()
        guard !showSettingsPanel && !showEpisodes else { return }
        hideControlsTask = Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if !Task.isCancelled { await MainActor.run { withAnimation { controlsVisible = false } } }
        }
    }

    // MARK: - Tick helpers

    private func ticks(fromSeconds seconds: Double) -> Int64 {
        Int64(max(0, seconds) * 10_000_000)
    }

    private func seconds(fromTicks ticks: Int64) -> Double {
        Double(ticks) / 10_000_000.0
    }
}
