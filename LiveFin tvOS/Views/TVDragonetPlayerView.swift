//
//  TVDragonetPlayerView.swift
//  LiveFin
//
//  Created by KPGamingz on 7/22/26.
//

import SwiftUI
import Combine
import AVKit
import AVFoundation

struct DragonetPlayerPlayer: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> DragonetPlayerUIView {
        let view = DragonetPlayerUIView()
        view.player = player
        return view
    }

    func updateUIView(_ uiView: DragonetPlayerUIView, context: Context) {
        uiView.player = player
    }
}

class DragonetPlayerUIView: UIView {
    var player: AVPlayer? {
        get { playerLayer.player }
        set {
            if playerLayer.player !== newValue {
                playerLayer.player = newValue
            }
            playerLayer.videoGravity = .resizeAspect
        }
    }
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    private var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

struct TVDragonetPlayerView: View {
    let initialChannel: JFChannel
    
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    
    @State private var currentChannel: JFChannel
    @State private var player: AVPlayer?
    @State private var errorMessage: String? = nil
    @State private var isBuffering = true
    
    @State private var controlsVisible = true
    @State private var isPlaying = true
    @State private var showMultiView = false
    @State private var showChannelPicker = false
    @State private var showSettingsPanel = false
    @State private var hideControlsTask: Task<Void, Never>?
    
    // Scrubber state & program timing
    @State private var streamStartAbsoluteDate: Date = Date()
    @State private var currentSeconds: Double = 0
    @State private var durationSeconds: Double = 0
    @State private var isScrubbing = false
    @State private var timeObserverToken: Any?
    @State private var scrubPreviewSeconds: Double?
    @State private var scrubCommitTask: Task<Void, Never>?
    @FocusState private var isScrubberFocused: Bool
    
    // Track selection state
    @State private var legibleGroup: AVMediaSelectionGroup?
    @State private var audibleGroup: AVMediaSelectionGroup?
    @State private var legibleOptions: [AVMediaSelectionOption] = []
    @State private var audibleOptions: [AVMediaSelectionOption] = []
    @State private var selectedLegibleOption: AVMediaSelectionOption? = nil
    @State private var selectedAudibleOption: AVMediaSelectionOption? = nil
    
    // Playback monitor
    let playbackMonitorTimer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()
    
    init(channel: JFChannel) {
        self.initialChannel = channel
        self._currentChannel = State(initialValue: channel)
    }
    
    // MARK: - Program Time Properties
    private var programStartDate: Date {
        appState.currentProgramStartDate ?? streamStartAbsoluteDate.addingTimeInterval(-1800)
    }
    
    private var programEndDate: Date {
        appState.currentProgramEndDate ?? programStartDate.addingTimeInterval(3600)
    }
    
    private var totalProgramDuration: Double {
        max(programEndDate.timeIntervalSince(programStartDate), 1)
    }
    
    private var currentAbsoluteDate: Date {
        streamStartAbsoluteDate.addingTimeInterval(scrubPreviewSeconds ?? currentSeconds)
    }
    
    private var programProgress: Double {
        let elapsed = currentAbsoluteDate.timeIntervalSince(programStartDate)
        return min(max(elapsed / totalProgramDuration, 0), 1)
    }
    
    private var userStreamStartProgress: Double {
        let elapsed = streamStartAbsoluteDate.timeIntervalSince(programStartDate)
        return min(max(elapsed / totalProgramDuration, 0), 1)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            if let player = player {
                DragonetPlayerPlayer(player: player)
                    .ignoresSafeArea()
                
                if !controlsVisible && !showSettingsPanel && !showChannelPicker {
                    // Transparent interaction layer preventing white focus highlight
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
                
                if controlsVisible {
                    overlayControls
                        .transition(.opacity)
                }
                
                if showSettingsPanel {
                    settingsPanel
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            } else if let error = errorMessage {
                errorStateView(error)
            } else {
                loadingStateView
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .task { await setupPlayer() }
        .onChange(of: currentChannel.id) { oldId, newId in
            if oldId != newId {
                detachTimeObserver()
                player?.pause()
                appState.stopEPGPolling()
                Task {
                    await appState.reportPlaybackStopped(itemId: oldId, positionTicks: 0)
                    await MainActor.run {
                        self.player = nil
                        self.errorMessage = nil
                        self.isBuffering = true
                        self.showSettingsPanel = false
                    }
                    await setupPlayer()
                }
            }
        }
        .onDisappear {
            detachTimeObserver()
            player?.pause()
            appState.stopEPGPolling()
            Task { await appState.reportPlaybackStopped(itemId: currentChannel.id, positionTicks: 0) }
        }
        .onReceive(playbackMonitorTimer) { _ in
            guard let player = player else { return }
            
            let buffering = player.timeControlStatus == .waitingToPlayAtSpecifiedRate
            if isBuffering != buffering {
                withAnimation { isBuffering = buffering }
            }
            
            if player.status == .failed || player.currentItem?.status == .failed {
                Task {
                    player.pause()
                    self.isBuffering = true
                    await setupPlayer()
                }
            }
        }
        .fullScreenCover(isPresented: $showMultiView) {
            TVMultiViewPlayerView(channel: currentChannel)
                .environmentObject(appState)
        }
        .sheet(isPresented: $showChannelPicker) {
            TVLiveChannelPickerView(appState: appState) { selectedChannel in
                self.currentChannel = selectedChannel
                self.controlsVisible = true
                self.resetHideTimer()
            }
        }
    }
    
    private func setupPlayer() async {
        Task { await appState.reportPlaybackStart(itemId: currentChannel.id) }
        appState.startEPGPolling(for: currentChannel.id)
        
        let resolved = await JFOpenLiveStreamService.resolveStreamURLWithSession(
            appState: appState,
            channelId: currentChannel.id,
            debug: true
        )
        
        guard let urlString = resolved.url, let url = URL(string: urlString) else {
            await MainActor.run { self.errorMessage = "Unable to resolve stream." }
            return
        }
        
        await MainActor.run {
            self.streamStartAbsoluteDate = Date()
            self.currentSeconds = 0
            self.scrubPreviewSeconds = nil
            
            let newPlayer = AVPlayer(url: url)
            self.player = newPlayer
            newPlayer.play()
            self.attachTimeObserver()
            self.loadMediaSelectionOptions(asset: newPlayer.currentItem?.asset)
            self.resetHideTimer()
        }
    }
    
    private func attachTimeObserver() {
        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        timeObserverToken = player?.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak player] time in
            guard !self.isScrubbing else { return }
            self.currentSeconds = time.seconds.isFinite ? time.seconds : 0
            
            if let item = player?.currentItem {
                if item.duration.isNumeric {
                    self.durationSeconds = item.duration.seconds
                } else if let range = item.seekableTimeRanges.last?.timeRangeValue {
                    self.durationSeconds = range.end.seconds
                } else {
                    self.durationSeconds = 0
                }
            }
        }
    }

    private func detachTimeObserver() {
        if let token = timeObserverToken {
            player?.removeTimeObserver(token)
            timeObserverToken = nil
        }
        scrubCommitTask?.cancel()
    }
    
    private func loadMediaSelectionOptions(asset: AVAsset?) {
        guard let asset = asset else { return }
        Task {
            if let group = try? await asset.loadMediaSelectionGroup(for: .legible) {
                await MainActor.run {
                    self.legibleGroup = group
                    self.legibleOptions = group.options
                    self.updateSelectedOptions()
                }
            }
            if let group = try? await asset.loadMediaSelectionGroup(for: .audible) {
                await MainActor.run {
                    self.audibleGroup = group
                    self.audibleOptions = group.options
                    self.updateSelectedOptions()
                }
            }
        }
    }
    
    private func updateSelectedOptions() {
        guard let currentItem = player?.currentItem else { return }
        let selection = currentItem.currentMediaSelection
        if let g = legibleGroup {
            selectedLegibleOption = selection.selectedMediaOption(in: g)
        }
        if let g = audibleGroup {
            selectedAudibleOption = selection.selectedMediaOption(in: g)
        }
    }
    
    private func resetHideTimer() {
        hideControlsTask?.cancel()
        guard !showSettingsPanel && !showChannelPicker else { return }
        hideControlsTask = Task {
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            if !Task.isCancelled { await MainActor.run { withAnimation { controlsVisible = false } } }
        }
    }
    
    private var settingsPanel: some View {
        HStack {
            Spacer()
            VStack(alignment: .leading, spacing: 30) {
                HStack {
                    Label("Live Stream Settings", systemImage: "slider.horizontal.3")
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
                                .padding(.horizontal, 10)
                            
                            if audibleOptions.count < 2 {
                                Text("Default System Audio")
                                    .font(.body)
                                    .foregroundColor(.gray)
                                    .padding(.horizontal, 10)
                            } else {
                                VStack(spacing: 8) {
                                    ForEach(audibleOptions, id: \.self) { option in
                                        let isSelected = selectedAudibleOption == option
                                        Button(action: {
                                            if let g = audibleGroup {
                                                player?.currentItem?.select(option, in: g)
                                                selectedAudibleOption = option
                                            }
                                            resetHideTimer()
                                        }) {
                                            HStack {
                                                Text(option.displayName)
                                                    .foregroundColor(.white)
                                                Spacer()
                                                if isSelected {
                                                    Image(systemName: "checkmark")
                                                        .foregroundColor(.blue)
                                                        .bold()
                                                }
                                            }
                                            .padding(.horizontal, 16)
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
                                .padding(.horizontal, 10)
                            
                            VStack(spacing: 8) {
                                let isOffSelected = selectedLegibleOption == nil
                                Button(action: {
                                    if let g = legibleGroup {
                                        player?.currentItem?.select(nil, in: g)
                                        selectedLegibleOption = nil
                                    }
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
                                    .padding(.horizontal, 16)
                                    .frame(height: 50)
                                }
                                .buttonStyle(.card)
                                
                                ForEach(legibleOptions, id: \.self) { option in
                                    let isSelected = selectedLegibleOption == option
                                    Button(action: {
                                        if let g = legibleGroup {
                                            player?.currentItem?.select(option, in: g)
                                            selectedLegibleOption = option
                                        }
                                        resetHideTimer()
                                    }) {
                                        HStack {
                                            Text(option.displayName)
                                                .foregroundColor(.white)
                                            Spacer()
                                            if isSelected {
                                                Image(systemName: "checkmark")
                                                    .foregroundColor(.blue)
                                                    .bold()
                                            }
                                        }
                                        .padding(.horizontal, 16)
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
            .padding(50)
            .frame(width: 620)
            .background(Color.black.opacity(0.95))
            .shadow(color: .black.opacity(0.5), radius: 20)
        }
        .ignoresSafeArea()
    }
    
    private var overlayControls: some View {
        VStack(spacing: 0) {
            Spacer()
            
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .center, spacing: 28) {
                    ChannelImageView(baseUrl: appState.serverURL, apiKey: appState.apiKey, channelId: currentChannel.id)
                        .frame(width: 90, height: 90)
                        .cornerRadius(12)
                    
                    VStack(alignment: .leading, spacing: 6) {
                        Text(appState.currentProgramTitle ?? currentChannel.name)
                            .font(.title2.bold())
                            .foregroundColor(.white)
                            .lineLimit(2)
                            .shadow(radius: 4)
                        
                        if let subtitle = appState.currentProgramSubtitle {
                            Text(subtitle)
                                .font(.subheadline)
                                .foregroundColor(.white.opacity(0.75))
                                .lineLimit(2)
                                .shadow(radius: 4)
                        } else {
                            Text(appState.currentProgramTitle != nil ? currentChannel.name : "Live TV")
                                .font(.subheadline)
                                .foregroundColor(.white.opacity(0.75))
                                .lineLimit(1)
                                .shadow(radius: 4)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    
                    Spacer()
                    
                    Button(action: {
                        isPlaying.toggle()
                        isPlaying ? player?.play() : player?.pause()
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
                        Image(systemName: (selectedLegibleOption != nil) ? "captions.bubble.fill" : "captions.bubble")
                            .font(.system(size: 24))
                            .frame(width: 54, height: 54)
                    }
                    .buttonStyle(.card)
                    
                    Button(action: {
                        showChannelPicker = true
                        controlsVisible = false
                    }) {
                        Label("Channels", systemImage: "list.bullet")
                            .font(.callout.bold())
                            .padding(.horizontal, 14)
                            .frame(height: 54)
                    }
                    .buttonStyle(.card)
                    
                    Button(action: {
                        showMultiView = true
                        controlsVisible = false
                    }) {
                        Label("MultiView", systemImage: "square.grid.2x2")
                            .font(.callout.bold())
                            .padding(.horizontal, 14)
                            .frame(height: 54)
                    }
                    .buttonStyle(.card)
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
                let width = geo.size.width
                
                ZStack(alignment: .leading) {
                    // Full program track background (Program Start to Finish)
                    Capsule()
                        .fill(Color.white.opacity(0.25))
                        .frame(height: 8)
                    
                    // Progression fill up to current playhead
                    Capsule()
                        .fill(Color.red)
                        .frame(width: max(width * programProgress, 0))
                        .frame(height: 8)
                    
                    // User Stream Start position indicator marker
                    Rectangle()
                        .fill(Color.blue)
                        .frame(width: 3, height: 16)
                        .cornerRadius(1.5)
                        .offset(x: max((width * userStreamStartProgress) - 1.5, 0))
                    
                    // Current playhead scrubber handle
                    Rectangle()
                        .fill(Color.white)
                        .frame(width: 4, height: 24)
                        .cornerRadius(2)
                        .offset(x: max((width * programProgress) - 2, 0))
                }
                .frame(maxHeight: .infinity, alignment: .center)
            }
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 14).fill(isScrubberFocused ? Color.white.opacity(0.15) : Color.clear))
            .focusable()
            .focused($isScrubberFocused)
            .onMoveCommand { handleScrub(direction: $0) }
            
            HStack {
                // Program Start Time
                Text(formattedClockTime(programStartDate))
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.75))
                
                Spacer()
                
                // Current User Time / Status
                HStack(spacing: 6) {
                    Text(formattedClockTime(currentAbsoluteDate))
                        .font(.caption.bold())
                        .foregroundColor(.white)
                    
                    let isLiveEdge = abs(currentAbsoluteDate.timeIntervalSince(Date())) < 5
                    Text(isLiveEdge ? "LIVE" : "PAST")
                        .font(.caption2.bold())
                        .foregroundColor(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(isLiveEdge ? Color.red : Color.gray))
                }
                
                Spacer()
                
                // Program End Time
                Text(formattedClockTime(programEndDate))
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.75))
            }
        }
    }
    
    private func handleScrub(direction: MoveCommandDirection) {
        let step: Double = 15
        let base = scrubPreviewSeconds ?? currentSeconds
        let maxSeekable = durationSeconds > 0 ? durationSeconds : max(0, Date().timeIntervalSince(streamStartAbsoluteDate))
        
        let newValue: Double
        switch direction {
        case .left: newValue = max(0, base - step)
        case .right: newValue = min(maxSeekable, base + step)
        default: return
        }

        isScrubbing = true
        scrubPreviewSeconds = newValue
        resetHideTimer()

        scrubCommitTask?.cancel()
        scrubCommitTask = Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
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
    
    private func formattedClockTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: date)
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
            Text("Loading \(currentChannel.name)...").font(.title3).foregroundColor(.gray)
        }
    }
}

struct TVLiveChannelPickerView: View {
    @ObservedObject var appState: AppState
    var onSelect: (JFChannel) -> Void
    
    @State private var channels: [JFItemDto] = []
    @State private var isLoading = true
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationStack {
            ZStack {
                if isLoading {
                    ProgressView().scaleEffect(1.5)
                } else {
                    List(channels, id: \.Id) { item in
                        Button {
                            let dict: [String: Any] = ["Id": item.Id, "Name": item.Name]
                            if let channel = JFChannel(json: dict) {
                                onSelect(channel)
                            }
                            dismiss()
                        } label: {
                            HStack(spacing: 16) {
                                ChannelImageView(baseUrl: appState.serverURL, apiKey: appState.apiKey, channelId: item.Id)
                                    .frame(width: 80, height: 45)
                                    .cornerRadius(8)
                                Text(item.Name).font(.headline)
                                Spacer()
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
            .navigationTitle("Select Channel")
            .task { await fetchChannels() }
        }
    }
    
    private func fetchChannels() async {
        if let url = URL(string: "\(appState.serverURL)/LiveTv/Channels?api_key=\(appState.apiKey)"),
           let (data, _) = try? await URLSession.shared.data(from: url) {
            let response = try? JSONDecoder().decode(JFItemsResponse.self, from: data)
            self.channels = response?.Items ?? []
        }
        self.isLoading = false
    }
}

@MainActor
class TVMultiViewModel: ObservableObject {
    struct StreamItem: Identifiable {
        let id = UUID()
        let player: AVPlayer
        let channel: JFChannel?
        let libraryItem: JFItemDto?
        
        var title: String { channel?.name ?? libraryItem?.Name ?? "Stream" }
        var itemId: String { channel?.id ?? libraryItem?.Id ?? "" }
    }

    @Published var streams: [StreamItem] = []
    @Published var activeAudioId: UUID?
    @Published var isShowingPicker = false
    
    init() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
    }
    
    func addChannel(_ channel: JFChannel, appState: AppState) async {
        guard streams.count < 6 else { return }
        let resolved = await JFOpenLiveStreamService.resolveStreamURLWithSession(appState: appState, channelId: channel.id, debug: true)
        guard let urlStr = resolved.url, let url = URL(string: urlStr) else { return }
        let item = StreamItem(player: AVPlayer(url: url), channel: channel, libraryItem: nil)
        addStream(item)
        Task { await appState.reportPlaybackStart(itemId: channel.id) }
    }
    
    func addLibraryItem(_ libItem: JFItemDto, appState: AppState) async {
        guard streams.count < 6 else { return }
        let playbackResult = try? await JFPlaybackInfoService.fetchPlaybackInfoWithTranscodingUrl(
            appState: appState, itemId: libItem.Id, isLiveTV: false
        )
        
        let base = appState.serverURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var finalUrlStr = "\(base)/Videos/\(libItem.Id)/stream?static=true"
        
        if let result = playbackResult, let tUrl = result.1, !tUrl.isEmpty {
            finalUrlStr = tUrl.hasPrefix("http") ? tUrl : base + (tUrl.hasPrefix("/") ? "" : "/") + tUrl
        }
        
        if !finalUrlStr.contains("api_key") && !finalUrlStr.contains("ApiKey") {
            finalUrlStr += (finalUrlStr.contains("?") ? "&" : "?") + "api_key=\(appState.accessToken)"
        }
        guard let url = URL(string: finalUrlStr) else { return }
        
        let headers = [
            "X-Emby-Token": appState.accessToken,
            "Authorization": "MediaBrowser Token=\"\(appState.accessToken)\""
        ]
        let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
        let playerItem = AVPlayerItem(asset: asset)
        
        let item = StreamItem(player: AVPlayer(playerItem: playerItem), channel: nil, libraryItem: libItem)
        addStream(item)
        Task { await appState.reportPlaybackStart(itemId: libItem.Id) }
    }
    
    private func addStream(_ item: StreamItem) {
        streams.append(item)
        if streams.count == 1 { activeAudioId = item.id }
        updateAudio()
        item.player.play()
    }
    
    func removeStream(_ id: UUID, appState: AppState) {
        guard let index = streams.firstIndex(where: { $0.id == id }) else { return }
        let removed = streams.remove(at: index)
        removed.player.pause()
        Task { await appState.reportPlaybackStopped(itemId: removed.itemId, positionTicks: 0) }
        if activeAudioId == id { activeAudioId = streams.first?.id }
        updateAudio()
    }
    
    func updateAudio() {
        for stream in streams { stream.player.isMuted = (stream.id != activeAudioId) }
    }
    
    func cleanup(appState: AppState) {
        for stream in streams {
            stream.player.pause()
            let iid = stream.itemId
            Task { await appState.reportPlaybackStopped(itemId: iid, positionTicks: 0) }
        }
        streams.removeAll()
    }
}

struct TVMultiViewPlayerView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var vm = TVMultiViewModel()
    
    var channel: JFChannel? = nil
    var libraryItem: JFItemDto? = nil
    
    @Environment(\.dismiss) private var dismiss
    @State private var streamActionId: UUID?
    
    var dynamicColumns: [GridItem] {
        let count = vm.streams.count
        if count <= 1 { return [GridItem(.flexible())] }
        if count <= 2 { return Array(repeating: GridItem(.flexible(), spacing: 40), count: count) }
        if count <= 4 { return Array(repeating: GridItem(.flexible(), spacing: 40), count: 2) }
        return Array(repeating: GridItem(.flexible(), spacing: 40), count: 3)
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()
            
            VStack {
                if vm.streams.isEmpty {
                    VStack(spacing: 20) {
                        Image(systemName: "play.square.stack.fill").font(.system(size: 120)).foregroundColor(.white.opacity(0.8))
                        Text("MultiView Setup Hub").font(.title2).foregroundColor(.white)
                        Button("Select First Stream") { vm.isShowingPicker = true }.buttonStyle(.borderedProminent).padding(.top, 20)
                    }
                    .frame(maxHeight: .infinity)
                } else {
                    LazyVGrid(columns: dynamicColumns, spacing: 40) {
                        ForEach(vm.streams) { stream in streamTile(for: stream) }
                    }
                    .padding(.horizontal, 60)
                    .padding(.top, 120)
                    .padding(.bottom, 40)
                }
            }
            
            if !vm.streams.isEmpty {
                HStack {
                    Text("MultiView").font(.headline).foregroundColor(.white.opacity(0.5))
                    Spacer()
                    if vm.streams.count < 6 {
                        Button { vm.isShowingPicker = true } label: { Label("Add Stream", systemImage: "plus.rectangle.on.rectangle") }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .padding(.horizontal, 60)
                .padding(.top, 40)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .task {
            if vm.streams.isEmpty {
                if let c = channel {
                    await vm.addChannel(c, appState: appState)
                    vm.isShowingPicker = true
                }
                else if let l = libraryItem {
                    await vm.addLibraryItem(l, appState: appState)
                    vm.isShowingPicker = true
                }
                else { vm.isShowingPicker = true }
            }
        }
        .onDisappear { vm.cleanup(appState: appState) }
        .sheet(isPresented: $vm.isShowingPicker) { TVStreamPickerView(vm: vm, appState: appState) }
        .confirmationDialog("Stream Options", isPresented: Binding(
            get: { streamActionId != nil },
            set: { if !$0 { streamActionId = nil } }
        )) {
            if let actionId = streamActionId {
                Button("Remove", role: .destructive) {
                    vm.removeStream(actionId, appState: appState)
                    streamActionId = nil
                    if vm.streams.isEmpty { dismiss() }
                }
                Button("Cancel", role: .cancel) { streamActionId = nil }
            }
        }
    }
    
    @ViewBuilder private func streamTile(for stream: TVMultiViewModel.StreamItem) -> some View {
        let isActiveAudio = vm.activeAudioId == stream.id
        Button {
            if isActiveAudio { streamActionId = stream.id } else { vm.activeAudioId = stream.id; vm.updateAudio() }
        } label: {
            ZStack(alignment: .bottomLeading) {
                DragonetPlayerPlayer(player: stream.player)
                    .aspectRatio(16/9, contentMode: .fit)
                    .background(Color.black)
                    
                HStack {
                    if isActiveAudio { Image(systemName: "speaker.wave.2.fill").foregroundColor(.white).padding(6).background(Circle().fill(Color.blue)) }
                    Text(stream.title).font(.caption).bold().foregroundColor(.white).padding(.horizontal, 8).padding(.vertical, 4).background(Capsule().fill(Color.black.opacity(0.6)))
                }
                .padding(16)
            }
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(isActiveAudio ? Color.blue : Color.clear, lineWidth: 6))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.card)
    }
}

struct JFItemsResponse: Decodable {
    let Items: [JFItemDto]
}

struct TVStreamPickerView: View {
    @ObservedObject var vm: TVMultiViewModel
    @ObservedObject var appState: AppState
    
    @State private var channels: [JFItemDto] = []
    @State private var continueWatching: [JFItemDto] = []
    @State private var isLoading = true
    
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationStack {
            ZStack {
                if isLoading {
                    ProgressView().scaleEffect(1.5)
                } else {
                    List {
                        if !channels.isEmpty {
                            Section("Live Channels") {
                                // Filter out channels already streaming in the MultiView to prevent duplicates
                                let activeChannelIds = Set(vm.streams.compactMap { $0.channel?.id })
                                ForEach(channels.filter { !activeChannelIds.contains($0.Id) }, id: \.Id) { item in
                                    Button {
                                        Task {
                                            let dict: [String: Any] = ["Id": item.Id, "Name": item.Name]
                                            if let channel = JFChannel(json: dict) { await vm.addChannel(channel, appState: appState) }
                                            dismiss()
                                        }
                                    } label: {
                                        HStack(spacing: 16) {
                                            ChannelImageView(baseUrl: appState.serverURL, apiKey: appState.apiKey, channelId: item.Id).frame(width: 80, height: 45).cornerRadius(8)
                                            Text(item.Name).font(.headline)
                                            Spacer()
                                        }
                                        .padding(.vertical, 4)
                                    }
                                }
                            }
                        }
                        if !continueWatching.isEmpty {
                            Section("Library Content") {
                                // Filter out library content already streaming in the MultiView
                                let activeLibraryIds = Set(vm.streams.compactMap { $0.libraryItem?.Id })
                                ForEach(continueWatching.filter { !activeLibraryIds.contains($0.Id) }, id: \.Id) { item in
                                    Button {
                                        Task { await vm.addLibraryItem(item, appState: appState); dismiss() }
                                    } label: {
                                        HStack(spacing: 16) {
                                            Image(systemName: "film").font(.title2).foregroundColor(.accentColor).frame(width: 80)
                                            VStack(alignment: .leading) {
                                                Text(item.Name).font(.headline)
                                                if let type = item.Type as String? { Text(type).font(.caption).foregroundColor(.secondary) }
                                            }
                                            Spacer()
                                        }
                                        .padding(.vertical, 4)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Add Stream to MultiView")
            .task { await fetchPickerData() }
        }
    }
    
    private func fetchPickerData() async {
        if let url = URL(string: "\(appState.serverURL)/LiveTv/Channels?api_key=\(appState.apiKey)"),
           let (data, _) = try? await URLSession.shared.data(from: url) {
            let response = try? JSONDecoder().decode(JFItemsResponse.self, from: data)
            self.channels = response?.Items ?? []
        }
        
        var userId = ""
        if let url = URL(string: "\(appState.serverURL)/Users/Me?api_key=\(appState.apiKey)"),
           let (data, _) = try? await URLSession.shared.data(from: url),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let id = json["Id"] as? String {
            userId = id
        }
        
        if !userId.isEmpty {
            if let url = URL(string: "\(appState.serverURL)/Users/\(userId)/Items/Resume?Limit=10&api_key=\(appState.apiKey)"),
               let (data, _) = try? await URLSession.shared.data(from: url) {
                let response = try? JSONDecoder().decode(JFItemsResponse.self, from: data)
                self.continueWatching = response?.Items ?? []
            }
        }
        self.isLoading = false
    }
}
