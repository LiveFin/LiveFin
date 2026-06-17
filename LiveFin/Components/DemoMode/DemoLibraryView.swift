//
//  DemoLibraryView.swift
//  LiveFin
//
//  Created by KPGamingz on 6/15/26
//

import SwiftUI

// MARK: - ViewModels

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
            // Step 1: Programmatically login to the public Jellyfin stable demo server
            try await authenticateDemoUser()
            // Step 2: Fetch public libraries
            try await fetchDemoViews()
            
            isLoading = false
        } catch {
            print("Jellyfin Demo Session setup failed: \(error)")
            self.authError = "Unable to connect to demo.jellyfin.org. Ensure your device is online."
            self.isLoading = false
        }
    }
    
    private func authenticateDemoUser() async throws {
        guard let url = URL(string: "\(demoServerURL)/Users/AuthenticateByName") else {
            throw URLError(.badURL)
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        // Emby/Jellyfin custom auth headers
        let authHeader = "MediaBrowser Client=\"LiveFin Demo\", Device=\"Reviewer iPhone\", DeviceId=\"AppleReviewerDemoDevice\", Version=\"1.0.0\""
        request.setValue(authHeader, forHTTPHeaderField: "X-Emby-Authorization")
        
        let body: [String: String] = [
            "Username": "demo",
            "Pw": ""
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        
        struct DemoAuthResponse: Decodable {
            struct UserFields: Decodable {
                let Id: String
            }
            let AccessToken: String
            let User: UserFields
        }
        
        let decoded = try JSONDecoder().decode(DemoAuthResponse.self, from: data)
        self.demoAccessToken = decoded.AccessToken
        self.demoUserID = decoded.User.Id
    }
    
    private func fetchDemoViews() async throws {
        guard !demoAccessToken.isEmpty, !demoUserID.isEmpty else { return }
        guard let url = URL(string: "\(demoServerURL)/Users/\(demoUserID)/Views") else {
            throw URLError(.badURL)
        }
        
        var request = URLRequest(url: url)
        request.setValue(demoAccessToken, forHTTPHeaderField: "X-Emby-Token")
        
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        
        struct ViewsResponse: Decodable { let Items: [JFViewDto] }
        let decoded = try JSONDecoder().decode(ViewsResponse.self, from: data)
        
        self.views = decoded.Items.filter { view in
            let type = (view.CollectionType ?? "").lowercased()
            let name = view.Name.lowercased()
            
            if type == "livetv" || name.contains("live") {
                return false
            }
            
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
        if selectedGenre == "All" {
            return items
        }
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
                self.isLoading = false
                return
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

// MARK: - Main Demo Library View

struct DemoLibraryView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var viewModel = DemoLibraryViewModel()
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Attribution Banner / Courtesy Note for Reviewers
                VStack(spacing: 4) {
                    HStack {
                        Image(systemName: "info.circle.fill")
                            .foregroundColor(.accentColor)
                        Text("Jellyfin Demo Mode")
                            .font(.headline)
                        Spacer()
                    }
                    Text("App Store Sandbox content provided as a courtesy via the public Jellyfin Demo project (demo.jellyfin.org). No registration or local server setup is required.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding()
                .background(Color(UIColor.secondarySystemBackground).opacity(0.6))
                .cornerRadius(12)
                .padding(.horizontal)
                .padding(.top, 8)
                
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
            .navigationTitle("Demo Library")
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
                                    image
                                        .resizable()
                                        .aspectRatio(contentMode: .fill)
                                case .failure:
                                    fallbackPlaceholder
                                case .empty:
                                    ProgressView().scaleEffect(0.8)
                                @unknown default:
                                    EmptyView()
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
    
    @State private var showPlayer = false
    @State private var playURL: URL? = nil
    @State private var playbackErrorMessage: String? = nil
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Backdrop / Main Card Block
                ZStack(alignment: .bottomLeading) {
                    if let backdropTag = item.backdropImageTag,
                       let url = URL(string: "\(serverURL)/Items/\(item.Id)/Images/Backdrop?tag=\(backdropTag)&maxWidth=1000") {
                        AsyncImage(url: url) { phase in
                            if case .success(let image) = phase {
                                image
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
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
                    
                    // Gradient overlay to make text highly visible
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
                    
                    // Overview / Plot
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
                            // Direct Play video stream URL format for Jellyfin
                            let streamString = "\(serverURL)/Videos/\(item.Id)/stream?static=true&api_key=\(token)"
                            if let url = URL(string: streamString) {
                                playURL = url
                                showPlayer = true
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
                    
                    // Series Section (Seasons & Episodes)
                    if item.Type.lowercased() == "series" {
                        Text("Seasons")
                            .font(.headline)
                        
                        if isLoadingSeasons {
                            ProgressView()
                        } else if seasons.isEmpty {
                            Text("No seasons available.")
                                .foregroundColor(.secondary)
                        } else {
                            // Custom Horizontal Season Picker
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
                            
                            // Episodes List
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
                                                playURL = url
                                                showPlayer = true
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
        .fullScreenCover(isPresented: $showPlayer) {
            if let url = playURL {
                VideoPlayerView(
                    streamURL: url,
                    channel: nil,
                    onPlaybackError: { msg in
                        showPlayer = false
                        playbackErrorMessage = msg
                    }
                )
                .environmentObject(appState)
            }
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
                isLoadingSeasons = false
                return
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
            print("Failed to fetch seasons: \(error)")
            isLoadingSeasons = false
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
                isLoadingEpisodes = false
                return
            }
            
            struct EpisodesResponse: Decodable { let Items: [JFItemDto] }
            let decoded = try JSONDecoder().decode(EpisodesResponse.self, from: data)
            self.episodes = decoded.Items
            isLoadingEpisodes = false
        } catch {
            print("Failed to fetch episodes: \(error)")
            isLoadingEpisodes = false
        }
    }
}

```
