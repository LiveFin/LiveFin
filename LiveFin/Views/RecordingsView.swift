//
//  RecordingsView.swift
//  LiveFin
//
//  Created by KPGamingz on 7/6/26.
//

import SwiftUI

// Tracks which timer is actively being edited in the modal
enum ActiveEditTimer: Identifiable {
    case single(String)
    case series(String)
    var id: String {
        switch self {
        case .single(let id): return "single_\(id)"
        case .series(let id): return "series_\(id)"
        }
    }
}

struct RecordingsView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var viewModel: RecordingsViewModel
    @State private var selectedTab = 0
    
    @State private var activeEditTimer: ActiveEditTimer?
    
    // Stream Resolving States
    @State private var activeStreamURLItem: StreamURLItem?
    @State private var activeStreamChannel: LiveTvChannelDto?
    @State private var activeStreamProgram: JFProgram?
    @State private var isResolvingStreamId: String? = nil
    
    init(appState: AppState) {
        _viewModel = StateObject(wrappedValue: RecordingsViewModel(appState: appState))
    }
    
    private var inProgressTimers: [JFTimer] {
        viewModel.scheduledTimers.filter { $0.Status == "InProgress" }
    }
    
    private var upcomingTimers: [JFTimer] {
        viewModel.scheduledTimers.filter { $0.Status != "InProgress" }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Recordings", selection: $selectedTab) {
                    Text("Scheduled").tag(0)
                    Text("Recorded").tag(1)
                }
                .pickerStyle(.segmented)
                .padding()
                
                if viewModel.isInitialLoad && viewModel.scheduledTimers.isEmpty && viewModel.pastRecordings.isEmpty {
                    Spacer()
                    ProgressView("Loading DVR...")
                    Spacer()
                } else if selectedTab == 0 {
                    scheduledList
                } else {
                    recordedList
                }
            }
            .navigationTitle("DVR")
            .task {
                await viewModel.fetchAll()
            }
            .refreshable {
                await viewModel.fetchAll()
            }
            .sheet(item: $activeEditTimer) { editType in
                switch editType {
                case .single(let id):
                    TimerEditView(timerId: id, isSeries: false) {
                        Task { await viewModel.fetchAll() }
                    }
                    .environmentObject(appState)
                case .series(let id):
                    TimerEditView(timerId: id, isSeries: true) {
                        Task { await viewModel.fetchAll() }
                    }
                    .environmentObject(appState)
                }
            }
            .fullScreenCover(item: $activeStreamURLItem) { item in
                DragonetPlayerView(
                    streamURL: item.url,
                    channel: activeStreamChannel,
                    program: activeStreamProgram,
                    appState: appState,
                    onPlaybackError: { _ in activeStreamURLItem = nil }
                )
                .environmentObject(appState)
            }
        }
    }
    
    private func getChannelDto(for timer: JFTimer) -> LiveTvChannelDto? {
        guard let id = timer.ChannelId else { return nil }
        let name = timer.ChannelName ?? "Live TV"
        let jsonStr = """
        {"Id": "\(id)", "Name": "\(name)"}
        """
        guard let data = jsonStr.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(LiveTvChannelDto.self, from: data)
    }
    
    private func imageURL(for timer: JFSeriesTimer, base: String) -> URL? {
        if let itemId = timer.ParentPrimaryImageItemId, let tag = timer.ParentPrimaryImageTag {
            return URL(string: "\(base)/Items/\(itemId)/Images/Primary?maxWidth=400&tag=\(tag)")
        }
        if let itemId = timer.ParentThumbItemId, let tag = timer.ParentThumbImageTag {
            return URL(string: "\(base)/Items/\(itemId)/Images/Thumb?maxWidth=400&tag=\(tag)")
        }
        if let programId = timer.ProgramId, let tag = timer.ImageTags?["Primary"] {
            return URL(string: "\(base)/Items/\(programId)/Images/Primary?maxWidth=400&tag=\(tag)")
        }
        return nil
    }
    
    private func getProgramDto(for timer: JFTimer) -> JFProgram? {
        var dict: [String: Any] = [:]
        dict["Id"] = timer.ProgramId ?? UUID().uuidString
        dict["Name"] = timer.Name ?? "Unknown Program"
        if let overview = timer.Overview { dict["Overview"] = overview }
        if let start = timer.StartDate { dict["StartDate"] = start }
        if let end = timer.EndDate { dict["EndDate"] = end }
        dict["ChannelId"] = timer.ChannelId
        dict["ChannelName"] = timer.ChannelName
        return JFProgram(json: dict)
    }
    
    private var scheduledList: some View {
        List {
            if viewModel.scheduledTimers.isEmpty && viewModel.scheduledSeriesTimers.isEmpty {
                Text("No upcoming recordings scheduled.")
                    .foregroundColor(.secondary)
                    .listRowBackground(Color.clear)
            }
            
            if !viewModel.scheduledSeriesTimers.isEmpty {
                Section(header: Text("Series")) {
                    ForEach(viewModel.scheduledSeriesTimers) { timer in
                        Button {
                            activeEditTimer = .series(timer.Id)
                        } label: {
                            HStack(alignment: .top, spacing: 12) {
                                let base = appState.serverURL.hasSuffix("/") ? String(appState.serverURL.dropLast()) : appState.serverURL
                                
                                CachedAsyncImage(url: imageURL(for: timer, base: base)) { phase in
                                    switch phase {
                                    case .success(let image):
                                        image.resizable().scaledToFill()
                                    case .failure, .empty:
                                        Color.gray.opacity(0.3)
                                            .overlay(Image(systemName: "tv").foregroundColor(.secondary))
                                    @unknown default:
                                        Color.gray.opacity(0.3)
                                    }
                                }
                                .frame(width: 80, height: 120) // Portrait 2:3, matches series Primary poster art
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(timer.Name ?? "Unknown Series")
                                        .font(.headline)
                                    
                                    HStack {
                                        if timer.RecordNewOnly == true {
                                            Text("New Only")
                                                .font(.caption2)
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 2)
                                                .background(Color.blue.opacity(0.2))
                                                .foregroundColor(.blue)
                                                .cornerRadius(4)
                                        }
                                        if timer.RecordAnyTime == true {
                                            Text("Any Time")
                                                .font(.caption2)
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 2)
                                                .background(Color.green.opacity(0.2))
                                                .foregroundColor(.green)
                                                .cornerRadius(4)
                                        }
                                        Spacer()
                                    }
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.vertical, 6)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                Task { await viewModel.cancelSeriesTimer(id: timer.Id) }
                            } label: {
                                Label("Cancel", systemImage: "trash")
                            }
                        }
                    }
                }
            }
            
            if !inProgressTimers.isEmpty {
                Section(header: Text("Recording Now")) {
                    ForEach(inProgressTimers) { timer in
                        timerRow(for: timer, isInProgress: true)
                    }
                }
            }
            
            if !upcomingTimers.isEmpty {
                Section(header: Text("Upcoming Events")) {
                    ForEach(upcomingTimers) { timer in
                        timerRow(for: timer, isInProgress: false)
                    }
                }
            }
        }
        .listStyle(.plain)
    }
    
    @ViewBuilder
    private func timerRow(for timer: JFTimer, isInProgress: Bool) -> some View {
        Button {
            if isInProgress {
                Task {
                    isResolvingStreamId = timer.Id
                    defer { isResolvingStreamId = nil }
                    
                    if let cid = timer.ChannelId,
                       let urlStr = await JFOpenLiveStreamService.resolveStreamURL(appState: appState, channelId: cid),
                       let url = URL(string: urlStr) {
                        activeStreamChannel = getChannelDto(for: timer)
                        activeStreamProgram = getProgramDto(for: timer)
                        activeStreamURLItem = StreamURLItem(url)
                    }
                }
            } else {
                activeEditTimer = .single(timer.Id)
            }
        } label: {
            HStack(alignment: .top, spacing: 12) {
                if let cid = timer.ChannelId {
                    ChannelImageView(baseUrl: appState.serverURL, apiKey: appState.apiKey, channelId: cid)
                        .frame(width: 44, height: 44)
                } else {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.gray.opacity(0.3))
                        .frame(width: 44, height: 44)
                        .overlay(Image(systemName: "tv").foregroundColor(.secondary))
                }
                
                VStack(alignment: .leading, spacing: 6) {
                    Text(timer.Name ?? "Unknown Program")
                        .font(.headline)
                    
                    if let channel = timer.ChannelName {
                        Text(channel)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    
                    if let start = timer.parsedStartDate, let end = timer.parsedEndDate {
                        Text("\(start.formatted(date: .abbreviated, time: .shortened)) - \(end.formatted(date: .omitted, time: .shortened))")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    if let overview = timer.Overview, !overview.isEmpty {
                        Text(overview)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                    }
                }
                
                Spacer()
                
                if isInProgress {
                    if isResolvingStreamId == timer.Id {
                        ProgressView().scaleEffect(0.8)
                    } else {
                        HStack(spacing: 4) {
                            Circle().fill(Color.red).frame(width: 8, height: 8)
                            Text("Recording").font(.caption).bold().foregroundColor(.red)
                        }
                        .padding(.top, 4)
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isResolvingStreamId != nil)
        .padding(.vertical, 6)
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                Task { await viewModel.cancelTimer(id: timer.Id) }
            } label: {
                Label("Cancel", systemImage: "trash")
            }
        }
    }
    
    private var recordedList: some View {
        List {
            if viewModel.pastRecordings.isEmpty {
                Text("No past recordings found.")
                    .foregroundColor(.secondary)
                    .listRowBackground(Color.clear)
            }
            
            ForEach(viewModel.pastRecordings) { item in
                NavigationLink(destination: RecordingDestinationWrapper(item: item).environmentObject(appState)) {
                    HStack(alignment: .top, spacing: 12) {
                        let base = appState.serverURL.hasSuffix("/") ? String(appState.serverURL.dropLast()) : appState.serverURL
                        
                        let isLandscape = item.Type.lowercased() == "episode" || item.Type.lowercased() == "program"
                        let imgWidth: CGFloat = isLandscape ? 144 : 80
                        let imgHeight: CGFloat = isLandscape ? 81 : 120
                        
                        if let tag = item.primaryImageTag {
                            CachedAsyncImage(url: URL(string: "\(base)/Items/\(item.Id)/Images/Primary?tag=\(tag)&maxWidth=400")) { phase in
                                switch phase {
                                case .success(let image):
                                    image.resizable().scaledToFill()
                                case .failure, .empty:
                                    Color.gray.opacity(0.3)
                                @unknown default:
                                    Color.gray.opacity(0.3)
                                }
                            }
                            .frame(width: imgWidth, height: imgHeight)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        } else {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.gray.opacity(0.3))
                                .frame(width: imgWidth, height: imgHeight)
                                .overlay(Image(systemName: "film").font(.title2).foregroundColor(.secondary))
                        }
                        
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.Name)
                                .font(.headline)
                            
                            if let year = item.ProductionYear {
                                Text(String(year))
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                            }
                            
                            if let overview = item.Overview, !overview.isEmpty {
                                Text(overview)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .lineLimit(2)
                            }
                        }
                        .padding(.vertical, 6)
                    }
                }
            }
        }
        .listStyle(.plain)
    }
}

// MARK: - Dedicated Timer Editor

struct TimerEditView: View {
    let timerId: String
    let isSeries: Bool
    let onSave: () -> Void
    
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var rawPayload: [String: Any] = [:]
    
    @State private var prePaddingSeconds: Int = 0
    @State private var postPaddingSeconds: Int = 0
    @State private var recordAnyTime: Bool = false
    @State private var recordNewOnly: Bool = false
    @State private var recordAnyChannel: Bool = false

    var body: some View {
        NavigationStack {
            Form {
                if isLoading {
                    HStack {
                        Spacer()
                        ProgressView("Loading Configuration...")
                        Spacer()
                    }
                    .padding()
                } else {
                    if isSeries {
                        Section(header: Text("Recording Type")) {
                            Toggle("Record New Episodes Only", isOn: $recordNewOnly)
                            Toggle("Record at Any Time", isOn: $recordAnyTime)
                            Toggle("Record on Any Channel", isOn: $recordAnyChannel)
                        }
                    }
                    
                    Section(header: Text("Padding")) {
                        Stepper("Start Early: \(prePaddingSeconds / 60) min", value: Binding(
                            get: { prePaddingSeconds / 60 },
                            set: { prePaddingSeconds = $0 * 60 }
                        ), in: 0...30)
                        
                        Stepper("End Late: \(postPaddingSeconds / 60) min", value: Binding(
                            get: { postPaddingSeconds / 60 },
                            set: { postPaddingSeconds = $0 * 60 }
                        ), in: 0...60)
                    }
                }
            }
            .navigationTitle("Edit Recording")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Label("Cancel", systemImage: "xmark.circle")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(isLoading || isSaving)
                }
            }
            .task {
                await load()
            }
        }
    }
    
    private func load() async {
        let cleanBaseURL = appState.serverURL.hasSuffix("/") ? String(appState.serverURL.dropLast()) : appState.serverURL
        guard let baseUrl = URL(string: cleanBaseURL) else { return }
        
        let endpoint = isSeries ? "LiveTv/SeriesTimers/\(timerId)" : "LiveTv/Timers/\(timerId)"
        let getUrl = baseUrl.appendingPathComponent(endpoint)
        
        var req = URLRequest(url: getUrl)
        req.setValue(appState.accessToken, forHTTPHeaderField: "X-Emby-Token")
        
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            if let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                self.rawPayload = payload
                self.prePaddingSeconds = payload["PrePaddingSeconds"] as? Int ?? 0
                self.postPaddingSeconds = payload["PostPaddingSeconds"] as? Int ?? 0
                
                if isSeries {
                    self.recordAnyTime = payload["RecordAnyTime"] as? Bool ?? false
                    self.recordNewOnly = payload["RecordNewOnly"] as? Bool ?? false
                    self.recordAnyChannel = payload["RecordAnyChannel"] as? Bool ?? false
                }
            }
        } catch {
            print("Failed to load timer: \(error)")
        }
        isLoading = false
    }
    
    private func save() {
        Task {
            isSaving = true
            let cleanBaseURL = appState.serverURL.hasSuffix("/") ? String(appState.serverURL.dropLast()) : appState.serverURL
            guard let baseUrl = URL(string: cleanBaseURL) else { return }
            
            let endpoint = isSeries ? "LiveTv/SeriesTimers/\(timerId)" : "LiveTv/Timers/\(timerId)"
            let postUrl = baseUrl.appendingPathComponent(endpoint)
            
            var payload = self.rawPayload
            payload["PrePaddingSeconds"] = prePaddingSeconds
            payload["PostPaddingSeconds"] = postPaddingSeconds
            
            if isSeries {
                payload["RecordAnyTime"] = recordAnyTime
                payload["RecordNewOnly"] = recordNewOnly
                payload["RecordAnyChannel"] = recordAnyChannel
            }
            
            var req = URLRequest(url: postUrl)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue(appState.accessToken, forHTTPHeaderField: "X-Emby-Token")
            req.httpBody = try? JSONSerialization.data(withJSONObject: payload)
            
            _ = try? await URLSession.shared.data(for: req)
            
            isSaving = false
            onSave() // Triggers the parent view to fetch latest changes instantly
            dismiss()
        }
    }
}

// MARK: - Existing Wrappers

struct RecordingDestinationWrapper: View {
    let item: JFItemDto
    @EnvironmentObject var appState: AppState
    @State private var targetItem: JFItemDto? = nil
    @State private var isLoading = true
    
    var body: some View {
        Group {
            if isLoading {
                VStack {
                    Spacer()
                    ProgressView("Resolving Media...")
                    Spacer()
                }
            } else {
                MediaItemDetailView(item: targetItem ?? item)
            }
        }
        .task {
            await resolveTarget()
        }
    }
    
    private func resolveTarget() async {
        guard let seriesId = item.SeriesId, !seriesId.isEmpty,
              let baseUrl = URL(string: appState.serverURL) else {
            isLoading = false
            return
        }
        
        let url = baseUrl.appendingPathComponent("Items/\(seriesId)")
        var request = URLRequest(url: url)
        if !appState.accessToken.isEmpty {
            request.setValue(appState.accessToken, forHTTPHeaderField: "X-Emby-Token")
        }
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                targetItem = try JSONDecoder().decode(JFItemDto.self, from: data)
            }
        } catch {
            print("Failed to resolve series item: \(error)")
        }
        isLoading = false
    }
}
