//
//  DemoMode.swift
//  LiveFin
//
//  Created by KPGamingz on 6/26/26.
//

import SwiftUI
import Foundation
import AVKit

// MARK: - Models & Data

struct DemoChannel: Identifiable, Codable {
    let id: String
    let name: String
    let number: String
    let imageName: String
    let description: String
}

struct DemoChannelsData {
    static let channels: [DemoChannel] = [
        DemoChannel(id: "1", name: "Demo News", number: "101", imageName: "newspaper", description: "24/7 news coverage for demo purposes."),
        DemoChannel(id: "2", name: "Demo Sports", number: "102", imageName: "sportscourt", description: "Live sports highlights and demo games."),
        DemoChannel(id: "3", name: "Demo Kids", number: "103", imageName: "person.3.sequence", description: "Fun and educational content for kids."),
        DemoChannel(id: "4", name: "Demo Movies", number: "104", imageName: "film", description: "Blockbuster movies for demo viewing."),
        DemoChannel(id: "5", name: "Demo Music", number: "105", imageName: "music.note", description: "Non-stop music and demo concerts.")
    ]
}

struct DemoStreamURLItem: Identifiable {
    let id = UUID()
    let url: URL
}

// MARK: - Demo Home View

struct DemoHomeView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    // Greeting
                    Text("Hi, \(appState.username.isEmpty ? "Reviewer" : appState.username)")
                        .font(.largeTitle).bold()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal)
                        .padding(.top, 8)

                    // On Now (simple demo cards derived from channels)
                    SectionHeader("On Now")
                    if !DemoChannelsData.channels.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(alignment: .top, spacing: 12) {
                                ForEach(DemoChannelsData.channels) { channel in
                                    NavigationLink(destination: DemoChannelDetailView(channel: channel)) {
                                        DemoNowCard(channel: channel)
                                            .frame(width: 220)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal)
                        }
                    }

                    // Channels (logos)
                    SectionHeader("Channels")
                    DemoHorizontalChannelsRow(channels: DemoChannelsData.channels)

                    // Shows
                    SectionHeader("Shows")
                    if !DemoChannelsData.channels.isEmpty {
                        HorizontalDemoSimpleRow(items: DemoChannelsData.channels.map { "\($0.name) — Best of" })
                    }

                    // Movies
                    SectionHeader("Movies")
                    if !DemoChannelsData.channels.isEmpty {
                        HorizontalDemoSimpleRow(items: DemoChannelsData.channels.map { "\($0.name) — Movie" })
                    }

                    Spacer(minLength: 24)
                }
                .padding(.bottom, 24)
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: { appState.logout() }) {
                        Label("Exit", systemImage: "xmark.circle")
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    ToolbarView()
                }
            }
        }
    }
}

// MARK: - Demo Subviews

private struct SectionHeader: View {
    let title: String
    init(_ title: String) { self.title = title }
    var body: some View {
        Text(title)
            .font(.title2.bold())
            .padding(.horizontal)
    }
}

private struct DemoNowCard: View {
    let channel: DemoChannel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .bottomLeading) {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(UIColor.secondarySystemBackground))
                    .frame(height: 120)
                HStack(spacing: 12) {
                    Image(systemName: channel.imageName)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 48, height: 48)
                        .foregroundColor(.accentColor)
                        .padding(.leading, 12)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Live: \(channel.name)")
                            .font(.headline)
                        Text("Channel \(channel.number)")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                }
                .padding(.vertical, 12)
            }
            Text(channel.description)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .lineLimit(2)
        }
    }
}

private struct DemoHorizontalChannelsRow: View {
    let channels: [DemoChannel]
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .center, spacing: 16) {
                ForEach(channels) { channel in
                    NavigationLink(destination: DemoChannelDetailView(channel: channel)) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(Color(.secondarySystemBackground))
                                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.secondary.opacity(0.15), lineWidth: 1))
                            Image(systemName: channel.imageName)
                                .resizable()
                                .scaledToFit()
                                .frame(width: 40, height: 40)
                                .foregroundColor(.accentColor)
                        }
                        .frame(width: 84, height: 84)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)
            .frame(minHeight: 100)
        }
    }
}

private struct HorizontalDemoSimpleRow: View {
    let items: [String]
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(items, id: \.self) { item in
                    VStack(alignment: .leading, spacing: 6) {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color(UIColor.secondarySystemBackground))
                            .frame(width: 140, height: 80)
                            .overlay(Image(systemName: "film").foregroundColor(.secondary).font(.title2))
                        Text(item)
                            .font(.subheadline)
                            .lineLimit(1)
                    }
                    .frame(width: 140)
                }
            }
            .padding(.horizontal)
        }
    }
}

// MARK: - Demo Channels View

struct DemoChannelsView: View {
    @EnvironmentObject var appState: AppState
    
    var body: some View {
        NavigationView {
            List(DemoChannelsData.channels) { channel in
                NavigationLink(destination: DemoChannelDetailView(channel: channel)) {
                    HStack(spacing: 16) {
                        // Styled like the main ChannelRowView
                        ZStack {
                            Circle()
                                .fill(Color(UIColor.secondarySystemBackground))
                                .frame(width: 50, height: 50)
                            Image(systemName: channel.imageName)
                                .resizable()
                                .scaledToFit()
                                .frame(width: 24, height: 24)
                                .foregroundColor(.accentColor)
                        }
                        
                        VStack(alignment: .leading, spacing: 4) {
                            Text(channel.name)
                                .font(.headline)
                            HStack(spacing: 4) {
                                Text("Channel \(channel.number)")
                                    .font(.subheadline)
                                    .foregroundColor(.gray)
                                Text("• \(channel.description)")
                                    .font(.subheadline)
                                    .foregroundColor(.red)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .listStyle(.plain)
            .navigationTitle("Channels")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: { appState.logout() }) {
                        Label("Exit", systemImage: "xmark.circle")
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    ToolbarView()
                }
            }
        }
    }
}

// MARK: - Demo Guide View

private struct DemoProgram: Identifiable {
    let id: String
    let name: String
    let start: Date
    let end: Date
    let episodeTitle: String?
}

struct DemoGuideView: View {
    @EnvironmentObject var appState: AppState
    @State private var selectedDay: Date = Date()

    private func programs(for channel: DemoChannel) -> [DemoProgram] {
        let now = Date()
        let cal = Calendar.current
        let hour = cal.component(.hour, from: now)
        let startOfHour = cal.date(bySettingHour: hour, minute: 0, second: 0, of: now) ?? now
        var out: [DemoProgram] = []
        for i in 0..<4 {
            let s = cal.date(byAdding: .minute, value: i * 30, to: startOfHour) ?? now
            let e = cal.date(byAdding: .minute, value: (i + 1) * 30, to: startOfHour) ?? s.addingTimeInterval(30*60)
            let title = "\(channel.name) Live"
            out.append(DemoProgram(id: "\(channel.id)-p-\(i)", name: title, start: s, end: e, episodeTitle: "Segment \(i + 1)"))
        }
        return out
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Day Selector mapping to the new GuideView capsule styling
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        let today = Calendar.current.startOfDay(for: Date())
                        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: today)!
                        
                        DayCapsuleButton(title: "Today", isSelected: Calendar.current.isDateInToday(selectedDay)) {
                            selectedDay = today
                        }
                        DayCapsuleButton(title: "Tomorrow", isSelected: Calendar.current.isDateInTomorrow(selectedDay)) {
                            selectedDay = tomorrow
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 12)
                }
                
                Divider()

                List {
                    ForEach(DemoChannelsData.channels) { channel in
                        Section(header:
                            HStack(spacing: 12) {
                                Image(systemName: channel.imageName)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 24, height: 24)
                                    .foregroundColor(.accentColor)
                                VStack(alignment: .leading) {
                                    Text(channel.name).font(.headline.bold())
                                    Text("CH \(channel.number)").font(.caption).foregroundColor(.secondary)
                                }
                                Spacer()
                            }
                            .padding(.bottom, 4)
                        ) {
                            ForEach(programs(for: channel)) { prog in
                                NavigationLink(destination: DemoChannelDetailView(channel: channel)) {
                                    // Adopting the "RenderBlock" styling from the main GuideView
                                    HStack(spacing: 12) {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(prog.name)
                                                .font(.subheadline)
                                                .bold()
                                                .lineLimit(1)
                                            if let ep = prog.episodeTitle {
                                                Text(ep)
                                                    .font(.caption2)
                                                    .foregroundColor(.secondary)
                                            }
                                        }
                                        Spacer()
                                        VStack(alignment: .trailing, spacing: 2) {
                                            Text(prog.start.formatted(date: .omitted, time: .shortened)).font(.caption2).bold()
                                            Text(prog.end.formatted(date: .omitted, time: .shortened)).font(.caption2).foregroundColor(.secondary)
                                        }
                                    }
                                    .padding(10)
                                    .background(Color.accentColor.opacity(0.12))
                                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.accentColor.opacity(0.2), lineWidth: 1))
                                }
                                .listRowSeparator(.hidden)
                                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                            }
                        }
                    }
                }
                .listStyle(.plain)
            }
            .navigationTitle("Guide")
            .toolbar { ToolbarView() }
        }
    }
}

private struct DayCapsuleButton: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.footnote)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(isSelected ? Color.accentColor : Color(UIColor.secondarySystemBackground))
                .foregroundColor(isSelected ? .white : .primary)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Demo Channel Detail View

struct DemoChannelDetailView: View {
    let channel: DemoChannel
    @State private var selectedStreamItem: DemoStreamURLItem? = nil
    @State private var playbackErrorMessage: String? = nil
    @EnvironmentObject var appState: AppState
    
    private var demoStreamURL: URL? {
        switch channel.id {
        case "1": return URL(string: "https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8")
        case "2": return URL(string: "https://bitdash-a.akamaihd.net/content/sintel/hls/playlist.m3u8")
        case "3": return URL(string: "https://mojenovosti.com/stream/test.m3u8")
        case "4": return URL(string: "https://cph-p2p-msl.akamaized.net/hls/live/2000341/test/master.m3u8")
        case "5": return URL(string: "https://test-streams.mux.dev/pts_shift/master.m3u8")
        default: return URL(string: "https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8")
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                ZStack {
                    Circle()
                        .fill(Color(UIColor.secondarySystemBackground))
                        .frame(width: 160, height: 160)
                        .shadow(color: .black.opacity(0.1), radius: 10, y: 5)
                    Image(systemName: channel.imageName)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 70, height: 70)
                        .foregroundColor(.accentColor)
                }
                .padding(.top, 40)
                
                VStack(spacing: 8) {
                    Text(channel.name)
                        .font(.largeTitle)
                        .bold()
                    Text("Channel \(channel.number)")
                        .font(.title3)
                        .foregroundColor(.secondary)
                }
                
                Text(channel.description)
                    .font(.body)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                    .foregroundColor(.secondary)
                
                Button(action: {
                    if let url = demoStreamURL {
                        selectedStreamItem = DemoStreamURLItem(url: url)
                    }
                }) {
                    HStack {
                        Image(systemName: "play.fill")
                            .resizable()
                            .frame(width: 16, height: 16)
                        Text("Play Demo Stream")
                            .font(.headline)
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .foregroundColor(.white)
                    .background(Color.accentColor)
                    .cornerRadius(14)
                    .padding(.horizontal, 32)
                }
                Spacer()
            }
        }
        .navigationTitle(channel.name)
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(item: $selectedStreamItem) { item in
            // Map DemoChannel to LiveTvChannelDto to satisfy DragonetPlayerView signature
            let mappedChannel = LiveTvChannelDto(
                id: channel.id,
                name: channel.name,
                number: channel.number,
                startDate: nil,
                endDate: nil,
                baseURL: "https://demo.jellyfin.org"
            )
            
            DragonetPlayerView(
                streamURL: item.url,
                channel: mappedChannel,
                appState: appState,
                onPlaybackError: { msg in
                    playbackErrorMessage = msg
                }
            )
            .environmentObject(appState)
        }
        .alert("Playback Error", isPresented: Binding(get: { playbackErrorMessage != nil }, set: { if !$0 { playbackErrorMessage = nil } })) {
            Button("OK", role: .cancel) { playbackErrorMessage = nil }
        } message: {
            Text(playbackErrorMessage ?? "An unknown error occurred while trying to play the demo stream.")
        }
    }
}

// MARK: - Demo Library ViewModels

@MainActor
class DemoLibraryViewModel: ObservableObject {
    @Published var views: [JFViewDto] = []
    @Published var isLoading = true
    @Published var authError: String? = nil
    
    @Published var demoAccessToken: String = ""
    @Published var demoUserID: String = ""
    let demoServerURL = "https://demo.jellyfin.org/stable"
    
    func loadDemoSession() async {
        guard views.isEmpty else { return }
        isLoading = true
        authError = nil
        
        do {
            try await authenticateDemoUser()
            try await fetchDemoViews()
            isLoading = false
        } catch {
            print("Jellyfin Demo Session setup failed: \(error)")
            self.authError = "Unable to connect to demo.jellyfin.org. Ensure your device is online."
            self.isLoading = false
        }
    }
    
    private func authenticateDemoUser() async throws {
        guard let url = URL(string: "\(demoServerURL)/Users/AuthenticateByName") else { throw URLError(.badURL) }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let authHeader = "MediaBrowser Client=\"LiveFin Demo\", Device=\"Reviewer iPhone\", DeviceId=\"AppleReviewerDemoDevice\", Version=\"1.0.0\""
        request.setValue(authHeader, forHTTPHeaderField: "X-Emby-Authorization")
        
        let body: [String: String] = ["Username": "demo", "Pw": ""]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else { throw URLError(.badServerResponse) }
        
        struct DemoAuthResponse: Decodable {
            struct UserFields: Decodable { let Id: String }
            let AccessToken: String
            let User: UserFields
        }
        let decoded = try JSONDecoder().decode(DemoAuthResponse.self, from: data)
        self.demoAccessToken = decoded.AccessToken
        self.demoUserID = decoded.User.Id
    }
    
    private func fetchDemoViews() async throws {
        guard !demoAccessToken.isEmpty, !demoUserID.isEmpty else { return }
        guard let url = URL(string: "\(demoServerURL)/Users/\(demoUserID)/Views") else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.setValue(demoAccessToken, forHTTPHeaderField: "X-Emby-Token")
        
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else { throw URLError(.badServerResponse) }
        
        struct ViewsResponse: Decodable { let Items: [JFViewDto] }
        let decoded = try JSONDecoder().decode(ViewsResponse.self, from: data)
        
        self.views = decoded.Items.filter { view in
            let type = (view.CollectionType ?? "").lowercased()
            let name = view.Name.lowercased()
            if type == "livetv" || name.contains("live") { return false }
            return type == "movies" || type == "tvshows" || name.contains("movie") || name.contains("tv") || name.contains("show")
        }
    }
}

@MainActor
class DemoCategoryViewModel: ObservableObject {
    @Published var items: [JFItemDto] = []
    @Published var isLoading = true
    @Published var availableGenres: [String] = []
    @Published var selectedGenre: String = "All"
    
    var filteredItems: [JFItemDto] {
        if selectedGenre == "All" { return items }
        return items.filter { $0.Genres?.contains(selectedGenre) == true }
    }
    
    func loadDemoItems(viewId: String, itemType: String, serverURL: String, token: String, userId: String) async {
        guard !serverURL.isEmpty, !token.isEmpty, !userId.isEmpty else { return }
        isLoading = true
        var components = URLComponents(string: "\(serverURL)/Users/\(userId)/Items")
        components?.queryItems = [
            URLQueryItem(name: "ParentId", value: viewId),
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "SortBy", value: "SortName"),
            URLQueryItem(name: "SortOrder", value: "Ascending"),
            URLQueryItem(name: "IncludeItemTypes", value: itemType),
            URLQueryItem(name: "Fields", value: "Overview,ImageTags,BackdropImageTags,Genres,ProductionYear,OfficialRating")
        ]
        
        guard let url = components?.url else { return }
        var request = URLRequest(url: url)
        request.setValue(token, forHTTPHeaderField: "X-Emby-Token")
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                self.isLoading = false; return
            }
            struct ItemsResponse: Decodable { let Items: [JFItemDto] }
            let decoded = try JSONDecoder().decode(ItemsResponse.self, from: data)
            self.items = decoded.Items
            let allGenres = decoded.Items.compactMap { $0.Genres }.flatMap { $0 }
            self.availableGenres = Array(Set(allGenres)).sorted()
            self.isLoading = false
        } catch {
            print("Failed to fetch demo category items: \(error)")
            self.isLoading = false
        }
    }
}

// MARK: - Demo Library View

struct DemoLibraryView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var viewModel = DemoLibraryViewModel()
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Prominent Public Domain Notice
                VStack(spacing: 10) {
                    HStack {
                        Image(systemName: "building.columns.fill")
                            .foregroundColor(.accentColor)
                            .font(.title3)
                        Text("Public Domain Library")
                            .font(.headline)
                        Spacer()
                    }
                    Text("All media in this Library is entirely Public Domain and is provided as a courtesy via the public Jellyfin project (demo.jellyfin.org). No registration or local server setup is required.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding()
                .background(Color(.secondarySystemBackground).opacity(0.8))
                .cornerRadius(12)
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.accentColor.opacity(0.3), lineWidth: 1))
                .padding(.horizontal)
                .padding(.top, 16)
                .padding(.bottom, 8)
                
                List {
                    if viewModel.isLoading {
                        HStack {
                            Spacer()
                            ProgressView("Connecting to Demo Server...")
                                .padding()
                            Spacer()
                        }
                        .listRowBackground(Color.clear)
                    } else if let error = viewModel.authError {
                        VStack(spacing: 12) {
                            Text(error)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                            Button("Try Again") {
                                Task { await viewModel.loadDemoSession() }
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .listRowBackground(Color.clear)
                    } else if viewModel.views.isEmpty {
                        Text("No demo libraries found.")
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(viewModel.views) { view in
                            let isMovie = (view.CollectionType?.lowercased() == "movies" || view.Name.lowercased().contains("movie"))
                            
                            if isMovie {
                                NavigationLink(
                                    destination: DemoMoviesView(
                                        viewDto: view,
                                        serverURL: viewModel.demoServerURL,
                                        token: viewModel.demoAccessToken,
                                        userId: viewModel.demoUserID
                                    )
                                ) {
                                    LibraryRowItem(title: view.Name, icon: "film")
                                }
                            } else {
                                NavigationLink(
                                    destination: DemoShowsView(
                                        viewDto: view,
                                        serverURL: viewModel.demoServerURL,
                                        token: viewModel.demoAccessToken,
                                        userId: viewModel.demoUserID
                                    )
                                ) {
                                    LibraryRowItem(title: view.Name, icon: "tv")
                                }
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
            .navigationTitle("Library")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: { appState.logout() }) {
                        Label("Exit", systemImage: "xmark.circle")
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    ToolbarView()
                }
            }
            .task {
                await viewModel.loadDemoSession()
            }
            .refreshable {
                await viewModel.loadDemoSession()
            }
        }
    }
}

// MARK: - Dummy LibraryRowItem
// Assuming it exists in your main codebase, provided here to ensure standalone compilation capability
struct LibraryRowItem: View {
    let title: String
    let icon: String
    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .foregroundColor(.accentColor)
                .font(.title2)
                .frame(width: 32)
            Text(title)
                .font(.headline)
        }
        .padding(.vertical, 8)
    }
}

// MARK: - Demo Category Pages

struct DemoMoviesView: View {
    let viewDto: JFViewDto
    let serverURL: String
    let token: String
    let userId: String
    
    @StateObject private var viewModel = DemoCategoryViewModel()
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    
    var columns: [GridItem] {
        if horizontalSizeClass == .compact {
            return Array(repeating: GridItem(.flexible(), spacing: 14), count: 3)
        } else {
            return [GridItem(.adaptive(minimum: 140), spacing: 16)]
        }
    }
    
    var body: some View {
        ScrollView {
            if viewModel.isLoading {
                ProgressView().padding(.top, 50)
            } else if viewModel.items.isEmpty {
                Text("No movies found in this library.")
                    .foregroundColor(.secondary)
                    .padding(.top, 50)
            } else {
                LazyVGrid(columns: columns, spacing: 22) {
                    ForEach(viewModel.filteredItems) { item in
                        NavigationLink(
                            destination: DemoMediaItemDetailView(
                                item: item,
                                serverURL: serverURL,
                                token: token,
                                userId: userId
                            )
                        ) {
                            DemoLibraryPosterCard(item: item, serverURL: serverURL)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
        }
        .navigationTitle(viewDto.Name)
        .toolbar { genrePicker }
        .task {
            if viewModel.items.isEmpty {
                await viewModel.loadDemoItems(viewId: viewDto.Id, itemType: "Movie", serverURL: serverURL, token: token, userId: userId)
            }
        }
    }
    
    @ToolbarContentBuilder private var genrePicker: some ToolbarContent {
        ToolbarItem(placement: .navigationBarTrailing) {
            Menu {
                Picker("Genre", selection: $viewModel.selectedGenre) {
                    Text("All").tag("All")
                    ForEach(viewModel.availableGenres, id: \.self) { genre in
                        Text(genre).tag(genre)
                    }
                }
            } label: {
                Label("Filter", systemImage: "line.3.horizontal.decrease.circle")
            }
        }
    }
}

struct DemoShowsView: View {
    let viewDto: JFViewDto
    let serverURL: String
    let token: String
    let userId: String
    
    @StateObject private var viewModel = DemoCategoryViewModel()
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    
    var columns: [GridItem] {
        if horizontalSizeClass == .compact {
            return Array(repeating: GridItem(.flexible(), spacing: 14), count: 3)
        } else {
            return [GridItem(.adaptive(minimum: 140), spacing: 16)]
        }
    }
    
    var body: some View {
        ScrollView {
            if viewModel.isLoading {
                ProgressView().padding(.top, 50)
            } else if viewModel.items.isEmpty {
                Text("No shows found in this library.")
                    .foregroundColor(.secondary)
                    .padding(.top, 50)
            } else {
                LazyVGrid(columns: columns, spacing: 22) {
                    ForEach(viewModel.filteredItems) { item in
                        NavigationLink(
                            destination: DemoMediaItemDetailView(
                                item: item,
                                serverURL: serverURL,
                                token: token,
                                userId: userId
                            )
                        ) {
                            DemoLibraryPosterCard(item: item, serverURL: serverURL)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
        }
        .navigationTitle(viewDto.Name)
        .toolbar { genrePicker }
        .task {
            if viewModel.items.isEmpty {
                await viewModel.loadDemoItems(viewId: viewDto.Id, itemType: "Series", serverURL: serverURL, token: token, userId: userId)
            }
        }
    }
    
    @ToolbarContentBuilder private var genrePicker: some ToolbarContent {
        ToolbarItem(placement: .navigationBarTrailing) {
            Menu {
                Picker("Genre", selection: $viewModel.selectedGenre) {
                    Text("All").tag("All")
                    ForEach(viewModel.availableGenres, id: \.self) { genre in
                        Text(genre).tag(genre)
                    }
                }
            } label: {
                Label("Filter", systemImage: "line.3.horizontal.decrease.circle")
            }
        }
    }
}

// MARK: - Reusable Poster Card

struct DemoLibraryPosterCard: View {
    let item: JFItemDto
    let serverURL: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Color(UIColor.secondarySystemBackground)
                .aspectRatio(2/3, contentMode: .fit)
                .overlay(
                    Group {
                        if let tag = item.primaryImageTag,
                           let url = URL(string: "\(serverURL)/Items/\(item.Id)/Images/Primary?tag=\(tag)&maxWidth=400") {
                            AsyncImage(url: url) { phase in
                                switch phase {
                                case .success(let image):
                                    image.resizable().aspectRatio(contentMode: .fill)
                                case .failure: fallthrough
                                case .empty: ProgressView().scaleEffect(0.8)
                                @unknown default: EmptyView()
                                }
                            }
                        } else {
                            fallbackPlaceholder
                        }
                    }
                )
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .shadow(color: Color.black.opacity(0.12), radius: 4, x: 0, y: 2)
            
            Text(item.Name)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(height: 34, alignment: .topLeading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)
        }
    }
    
    @ViewBuilder
    private var fallbackPlaceholder: some View {
        VStack(spacing: 8) {
            Image(systemName: "film")
                .font(.system(size: 24))
                .foregroundColor(.secondary)
            Text(item.Name)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .padding(.horizontal, 6)
        }
    }
}

// MARK: - Custom Detail and Playback View

struct DemoMediaItemDetailView: View {
    let item: JFItemDto
    let serverURL: String
    let token: String
    let userId: String
    
    @EnvironmentObject var appState: AppState
    @State private var seasons: [JFItemDto] = []
    @State private var episodes: [JFItemDto] = []
    @State private var selectedSeasonId: String = ""
    @State private var isLoadingSeasons = false
    @State private var isLoadingEpisodes = false
    
    @State private var selectedStreamItem: DemoStreamURLItem? = nil
    @State private var playbackErrorMessage: String? = nil
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Backdrop Block
                ZStack(alignment: .bottomLeading) {
                    if let backdropTag = item.backdropImageTag,
                       let url = URL(string: "\(serverURL)/Items/\(item.Id)/Images/Backdrop?tag=\(backdropTag)&maxWidth=1000") {
                        AsyncImage(url: url) { phase in
                            if case .success(let image) = phase {
                                image.resizable().aspectRatio(contentMode: .fill)
                            } else {
                                Color.black.opacity(0.4)
                            }
                        }
                        .frame(height: 220)
                        .clipped()
                    } else {
                        Color(UIColor.secondarySystemBackground)
                            .frame(height: 220)
                    }
                    
                    LinearGradient(
                        colors: [Color.black.opacity(0.85), Color.black.opacity(0.1)],
                        startPoint: .bottom,
                        endPoint: .top
                    )
                    .frame(height: 220)
                    
                    VStack(alignment: .leading, spacing: 6) {
                        Text(item.Name)
                            .font(.title2)
                            .bold()
                            .foregroundColor(.white)
                        
                        HStack(spacing: 12) {
                            if let year = item.ProductionYear {
                                Text("\(String(year))")
                                    .foregroundColor(.white.opacity(0.9))
                            }
                            if let rating = item.OfficialRating {
                                Text(rating)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.white.opacity(0.25))
                                    .cornerRadius(4)
                                    .foregroundColor(.white)
                            }
                            if let runtime = item.runtimeMinutes {
                                Text("\(runtime) min")
                                    .foregroundColor(.white.opacity(0.9))
                            }
                        }
                        .font(.subheadline)
                    }
                    .padding()
                }
                
                VStack(alignment: .leading, spacing: 16) {
                    // Genres
                    if let genres = item.Genres, !genres.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(genres, id: \.self) { genre in
                                    Text(genre)
                                        .font(.caption)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 4)
                                        .background(Color.accentColor.opacity(0.15))
                                        .cornerRadius(8)
                                        .foregroundColor(.accentColor)
                                }
                            }
                        }
                    }
                    
                    // Overview
                    if let overview = item.Overview, !overview.isEmpty {
                        Text("Overview")
                            .font(.headline)
                        Text(overview)
                            .font(.body)
                            .foregroundColor(.secondary)
                    }
                    
                    // Movie Action
                    if item.Type.lowercased() == "movie" {
                        Button(action: {
                            let streamString = "\(serverURL)/Videos/\(item.Id)/stream?static=true&api_key=\(token)"
                            if let url = URL(string: streamString) {
                                selectedStreamItem = DemoStreamURLItem(url: url)
                            }
                        }) {
                            HStack {
                                Image(systemName: "play.fill")
                                Text("Play Movie")
                            }
                            .font(.headline)
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.accentColor)
                            .cornerRadius(12)
                        }
                    }
                    
                    // Series Section
                    if item.Type.lowercased() == "series" {
                        Text("Seasons")
                            .font(.headline)
                        
                        if isLoadingSeasons {
                            ProgressView()
                        } else if seasons.isEmpty {
                            Text("No seasons available.")
                                .foregroundColor(.secondary)
                        } else {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 10) {
                                    ForEach(seasons) { season in
                                        Button(action: {
                                            selectedSeasonId = season.Id
                                            Task { await fetchEpisodes(seasonId: season.Id) }
                                        }) {
                                            Text(season.Name)
                                                .font(.subheadline)
                                                .padding(.horizontal, 14)
                                                .padding(.vertical, 8)
                                                .background(selectedSeasonId == season.Id ? Color.accentColor : Color(UIColor.secondarySystemBackground))
                                                .foregroundColor(selectedSeasonId == season.Id ? .white : .primary)
                                                .cornerRadius(10)
                                        }
                                    }
                                }
                            }
                            
                            Text("Episodes")
                                .font(.headline)
                                .padding(.top, 8)
                            
                            if isLoadingEpisodes {
                                ProgressView()
                            } else if episodes.isEmpty {
                                Text("Select a season to view episodes.")
                                    .foregroundColor(.secondary)
                            } else {
                                LazyVStack(spacing: 12) {
                                    ForEach(episodes) { ep in
                                        Button(action: {
                                            let streamString = "\(serverURL)/Videos/\(ep.Id)/stream?static=true&api_key=\(token)"
                                            if let url = URL(string: streamString) {
                                                selectedStreamItem = DemoStreamURLItem(url: url)
                                            }
                                        }) {
                                            HStack(spacing: 12) {
                                                Image(systemName: "play.circle.fill")
                                                    .font(.title)
                                                    .foregroundColor(.accentColor)
                                                
                                                VStack(alignment: .leading, spacing: 4) {
                                                    let epNumber = ep.IndexNumber != nil ? "E\(ep.IndexNumber!) — " : ""
                                                    Text("\(epNumber)\(ep.Name)")
                                                        .font(.subheadline.weight(.semibold))
                                                        .multilineTextAlignment(.leading)
                                                        .foregroundColor(.primary)
                                                    
                                                    if let plot = ep.Overview, !plot.isEmpty {
                                                        Text(plot)
                                                            .font(.caption)
                                                            .foregroundColor(.secondary)
                                                            .lineLimit(2)
                                                            .multilineTextAlignment(.leading)
                                                    }
                                                }
                                                Spacer()
                                            }
                                            .padding()
                                            .background(Color(UIColor.secondarySystemBackground).opacity(0.8))
                                            .cornerRadius(10)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if item.Type.lowercased() == "series" && seasons.isEmpty {
                await fetchSeasons()
            }
        }
        .fullScreenCover(item: $selectedStreamItem) { item in
            DragonetPlayerView(
                streamURL: item.url,
                channel: nil,
                appState: appState,
                onPlaybackError: { msg in
                    playbackErrorMessage = msg
                }
            )
            .environmentObject(appState)
        }
        .alert("Playback Error", isPresented: Binding(get: { playbackErrorMessage != nil }, set: { if !$0 { playbackErrorMessage = nil } })) {
            Button("OK", role: .cancel) { playbackErrorMessage = nil }
        } message: {
            Text(playbackErrorMessage ?? "Could not initiate stream from the public demo server.")
        }
    }
    
    // MARK: - API Calls for Series
    
    private func fetchSeasons() async {
        isLoadingSeasons = true
        guard let url = URL(string: "\(serverURL)/Shows/\(item.Id)/Seasons?userId=\(userId)&Fields=ImageTags") else { return }
        
        var request = URLRequest(url: url)
        request.setValue(token, forHTTPHeaderField: "X-Emby-Token")
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                isLoadingSeasons = false; return
            }
            struct SeasonsResponse: Decodable { let Items: [JFItemDto] }
            let decoded = try JSONDecoder().decode(SeasonsResponse.self, from: data)
            self.seasons = decoded.Items
            if let firstSeason = decoded.Items.first {
                self.selectedSeasonId = firstSeason.Id
                await fetchEpisodes(seasonId: firstSeason.Id)
            }
            isLoadingSeasons = false
        } catch {
            print("Failed to fetch seasons: \(error)"); isLoadingSeasons = false
        }
    }
    
    private func fetchEpisodes(seasonId: String) async {
        isLoadingEpisodes = true
        guard let url = URL(string: "\(serverURL)/Users/\(userId)/Items?ParentId=\(seasonId)&Fields=Overview,ImageTags,UserData,RunTimeTicks") else { return }
        var request = URLRequest(url: url)
        request.setValue(token, forHTTPHeaderField: "X-Emby-Token")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                isLoadingEpisodes = false; return
            }
            struct EpisodesResponse: Decodable { let Items: [JFItemDto] }
            let decoded = try JSONDecoder().decode(EpisodesResponse.self, from: data)
            self.episodes = decoded.Items
            isLoadingEpisodes = false
        } catch {
            print("Failed to fetch episodes: \(error)"); isLoadingEpisodes = false
        }
    }
}
