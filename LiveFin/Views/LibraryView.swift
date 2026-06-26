//
//  LibraryView.swift
//  LiveFin
//
//  Created by KPGamingz on 1/24/26.
//

import SwiftUI

// MARK: - DTOs
struct JFViewDto: Identifiable, Decodable {
    let Id: String
    let Name: String
    let CollectionType: String?
    let ImageTags: [String: String]?
    
    var id: String { Id }
    var primaryImageTag: String? { ImageTags?["Primary"] }
}

struct JFUserData: Decodable, Hashable {
    let PlaybackPositionTicks: Int64?
    let Played: Bool?
}

struct JFItemDto: Identifiable, Decodable, Hashable {
    let Id: String
    let Name: String
    let `Type`: String
    let Overview: String?
    let ImageTags: [String: String]?
    let BackdropImageTags: [String]?
    let RunTimeTicks: Int64?
    let Genres: [String]?
    let IndexNumber: Int?
    let ParentIndexNumber: Int?
    let UserData: JFUserData?
    
    // Additional Metadata
    let ProductionYear: Int?
    let OfficialRating: String?
    let SeasonId: String? // Added for season mapping
    let SeriesName: String? // Parent series content title
    let SeriesId: String? // Parent series ID
    
    var id: String { Id }
    
    var primaryImageTag: String? { ImageTags?["Primary"] }
    var backdropImageTag: String? { BackdropImageTags?.first }
    var logoImageTag: String? { ImageTags?["Logo"] }
    
    // Helper to format runtime to minutes
    var runtimeMinutes: Int? {
        guard let ticks = RunTimeTicks else { return nil }
        return Int(ticks / 600_000_000)
    }
}

// MARK: - ViewModels

@MainActor
class LibraryViewModel: ObservableObject {
    @Published var views: [JFViewDto] = []
    @Published var continueWatching: [JFItemDto] = []
    @Published var upNext: [JFItemDto] = []
    @Published var recentlyAdded: [JFItemDto] = []
    @Published var isLoading = true
    
    func loadLibraryContent(appState: AppState) async {
        guard !appState.serverURL.isEmpty, !appState.accessToken.isEmpty, !appState.userID.isEmpty else { return }
        
        let isInitialLoad = self.views.isEmpty && self.continueWatching.isEmpty && self.upNext.isEmpty && self.recentlyAdded.isEmpty
        if isInitialLoad {
            isLoading = true
        }
        
        async let viewsTask = fetchViews(appState: appState)
        async let cwTask = fetchContinueWatching(appState: appState)
        async let unTask = fetchUpNext(appState: appState)
        async let raTask = fetchRecentlyAdded(appState: appState)
        
        let (v, cw, un, ra) = await (viewsTask, cwTask, unTask, raTask)
        
        if let v = v { self.views = v }
        if let cw = cw { self.continueWatching = cw }
        if let un = un { self.upNext = un }
        if let ra = ra { self.recentlyAdded = ra }
        
        self.isLoading = false
    }
    
    private func fetchViews(appState: AppState) async -> [JFViewDto]? {
        let base = appState.serverURL.hasSuffix("/") ? String(appState.serverURL.dropLast()) : appState.serverURL
        guard let url = URL(string: "\(base)/Users/\(appState.userID)/Views") else { return nil }
        
        var request = URLRequest(url: url)
        request.setValue(appState.accessToken, forHTTPHeaderField: "X-Emby-Token")
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else { return nil }
            
            struct ViewsResponse: Decodable { let Items: [JFViewDto] }
            let decoded = try JSONDecoder().decode(ViewsResponse.self, from: data)
            
            return decoded.Items.filter { view in
                let type = (view.CollectionType ?? "").lowercased()
                let name = view.Name.lowercased()
                
                if type == "livetv" || name.contains("live") {
                    return false
                }
                
                // Allowed library types expanded to support mixed media/home videos
                return ["movies", "tvshows", "mixed", "homevideos"].contains(type) ||
                       name.contains("movie") || name.contains("tv") || name.contains("show") || name.contains("mixed")
            }
        } catch {
            print("Failed to load views: \(error)")
            return nil
        }
    }
    
    private func fetchContinueWatching(appState: AppState) async -> [JFItemDto]? {
        let base = appState.serverURL.hasSuffix("/") ? String(appState.serverURL.dropLast()) : appState.serverURL
        guard let url = URL(string: "\(base)/Users/\(appState.userID)/Items/Resume?limit=12&fields=Overview,ImageTags,BackdropImageTags,Genres,ProductionYear,OfficialRating,UserData,RunTimeTicks,SeriesName,SeriesId") else { return nil }
        
        var request = URLRequest(url: url)
        request.setValue(appState.accessToken, forHTTPHeaderField: "X-Emby-Token")
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else { return nil }
            struct ItemsResponse: Decodable { let Items: [JFItemDto] }
            let decoded = try JSONDecoder().decode(ItemsResponse.self, from: data)
            return decoded.Items
        } catch {
            print("LibraryViewModel: fetchContinueWatching error: \(error)")
            return nil
        }
    }

    private func fetchUpNext(appState: AppState) async -> [JFItemDto]? {
        let base = appState.serverURL.hasSuffix("/") ? String(appState.serverURL.dropLast()) : appState.serverURL
        guard let url = URL(string: "\(base)/Shows/NextUp?userId=\(appState.userID)&limit=12&fields=Overview,ImageTags,BackdropImageTags,Genres,ProductionYear,OfficialRating,UserData,RunTimeTicks,SeriesName,SeriesId") else { return nil }
        
        var request = URLRequest(url: url)
        request.setValue(appState.accessToken, forHTTPHeaderField: "X-Emby-Token")
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else { return nil }
            struct ItemsResponse: Decodable { let Items: [JFItemDto] }
            let decoded = try JSONDecoder().decode(ItemsResponse.self, from: data)
            return decoded.Items
        } catch {
            print("LibraryViewModel: fetchUpNext error: \(error)")
            return nil
        }
    }

    private func fetchRecentlyAdded(appState: AppState) async -> [JFItemDto]? {
        let base = appState.serverURL.hasSuffix("/") ? String(appState.serverURL.dropLast()) : appState.serverURL
        guard let url = URL(string: "\(base)/Users/\(appState.userID)/Items?sortBy=DateCreated&sortOrder=Descending&recursive=true&limit=25&includeItemTypes=Movie,Series&fields=Overview,ImageTags,BackdropImageTags,Genres,ProductionYear,OfficialRating,UserData,RunTimeTicks,SeriesName,SeriesId") else { return nil }
        
        var request = URLRequest(url: url)
        request.setValue(appState.accessToken, forHTTPHeaderField: "X-Emby-Token")
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else { return nil }
            struct ItemsResponse: Decodable { let Items: [JFItemDto] }
            let decoded = try JSONDecoder().decode(ItemsResponse.self, from: data)
            return decoded.Items
        } catch {
            print("LibraryViewModel: fetchRecentlyAdded error: \(error)")
            return nil
        }
    }
}

@MainActor
class CategoryViewModel: ObservableObject {
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
    
    func loadItems(viewId: String, itemType: String, appState: AppState) async {
        guard !appState.serverURL.isEmpty, !appState.accessToken.isEmpty, !appState.userID.isEmpty else { return }
        isLoading = true
        
        let base = appState.serverURL.hasSuffix("/") ? String(appState.serverURL.dropLast()) : appState.serverURL
        var components = URLComponents(string: "\(base)/Users/\(appState.userID)/Items")
        
        components?.queryItems = [
            URLQueryItem(name: "ParentId", value: viewId),
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "SortBy", value: "SortName"),
            URLQueryItem(name: "SortOrder", value: "Ascending"),
            URLQueryItem(name: "IncludeItemTypes", value: itemType),
            URLQueryItem(name: "Fields", value: "Overview,ImageTags,BackdropImageTags,Genres,ProductionYear,OfficialRating,SeriesName,SeriesId")
        ]
        
        guard let url = components?.url else { return }
        var request = URLRequest(url: url)
        request.setValue(appState.accessToken, forHTTPHeaderField: "X-Emby-Token")
        
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
            print("Failed to fetch category items/decoding error: \(error)")
            self.isLoading = false
        }
    }
}

// MARK: - Views

struct LibraryView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var viewModel = LibraryViewModel()
    
    var body: some View {
        NavigationStack {
            ZStack {
                let isCompletelyEmpty = viewModel.views.isEmpty && viewModel.continueWatching.isEmpty && viewModel.upNext.isEmpty && viewModel.recentlyAdded.isEmpty
                
                if viewModel.isLoading && isCompletelyEmpty {
                    VStack {
                        Spacer()
                        ProgressView("Loading Library...")
                            .scaleEffect(1.2)
                        Spacer()
                    }
                } else if isCompletelyEmpty {
                    // Global empty state shown when no media is available at all
                    ScrollView {
                        VStack(spacing: 12) {
                            Image(systemName: "tv.slash")
                                .font(.system(size: 48))
                                .foregroundColor(.secondary)
                                .padding(.bottom, 8)
                            
                            Text("Library Not Available")
                                .font(.title2.bold())
                                .foregroundColor(.primary)
                            
                            Text("Scan or add your user on your Admin Dashboard to access your content")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 32)
                        }
                        .padding(.top, 120)
                    }
                    .refreshable {
                        await viewModel.loadLibraryContent(appState: appState)
                    }
                } else {
                    // Main Content
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            
                            if !viewModel.views.isEmpty {
                                SectionHeader("My Media")
                                HorizontalLibrariesRow(views: viewModel.views)
                                    .environmentObject(appState)
                            }
                            
                            // CONTINUE WATCHING
                            if !viewModel.continueWatching.isEmpty {
                                SectionHeader("Continue Watching")
                                HorizontalLibraryItemsRow(items: viewModel.continueWatching, style: .landscape, playDirectly: true)
                                    .environmentObject(appState)
                            }
                            
                            // UP NEXT
                            if !viewModel.upNext.isEmpty {
                                SectionHeader("Up Next")
                                HorizontalLibraryItemsRow(items: viewModel.upNext, style: .landscape, playDirectly: true)
                                    .environmentObject(appState)
                            }
                            
                            // RECENTLY ADDED
                            if !viewModel.recentlyAdded.isEmpty {
                                SectionHeader("Recently Added")
                                HorizontalLibraryItemsRow(items: viewModel.recentlyAdded, style: .portrait, playDirectly: false)
                                    .environmentObject(appState)
                                    .padding(.bottom, 12)
                            }
                        }
                        .padding(.top, 8)
                        .padding(.bottom, 24)
                    }
                    .refreshable {
                        await viewModel.loadLibraryContent(appState: appState)
                    }
                }
            }
            .navigationTitle("Library")
            .task {
                if viewModel.views.isEmpty {
                    await viewModel.loadLibraryContent(appState: appState)
                }
            }
        }
    }
}

// MARK: - Horizontal Libraries Row

struct HorizontalLibrariesRow: View {
    let views: [JFViewDto]
    @EnvironmentObject private var appState: AppState

    private func rainbowColor(for index: Int) -> Color {
        let hue = Double(index) / Double(max(views.count, 1))
        return Color(hue: hue, saturation: 0.8, brightness: 1.0)
    }
    
    private func iconFor(view: JFViewDto) -> String {
        let type = view.CollectionType?.lowercased() ?? ""
        if type == "movies" || view.Name.lowercased().contains("movie") { return "film" }
        if type == "tvshows" || view.Name.lowercased().contains("tv") { return "tv" }
        return "play.rectangle.on.rectangle" // Generic Mixed/HomeVideos Icon
    }

    var body: some View {
        let base = appState.serverURL.hasSuffix("/") ? String(appState.serverURL.dropLast()) : appState.serverURL
        
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .center, spacing: 12) {
                ForEach(Array(views.enumerated()), id: \.element.id) { index, view in
                    
                    NavigationLink(destination: LibraryCategoryView(viewDto: view).environmentObject(appState)) {
                        Group {
                            // Library Image or Fallback View
                            if let tag = view.primaryImageTag,
                               let url = URL(string: "\(base)/Items/\(view.Id)/Images/Primary?tag=\(tag)&maxWidth=400") {
                                CachedAsyncImage(url: url) { phase in
                                    switch phase {
                                    case .success(let image):
                                        // Just the image, no text needed if we have a valid library cover
                                        image
                                            .resizable()
                                            .aspectRatio(contentMode: .fill)
                                    case .failure, .empty:
                                        fallbackView(for: view, index: index)
                                    @unknown default:
                                        fallbackView(for: view, index: index)
                                    }
                                }
                            } else {
                                fallbackView(for: view, index: index)
                            }
                        }
                        // Increased sizing for the Library Row Items
                        .frame(width: 160, height: 104)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .accessibilityLabel(Text(view.Name))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)
            .frame(minHeight: 110)
        }
    }
    
    @ViewBuilder
    private func fallbackView(for view: JFViewDto, index: Int) -> some View {
        ZStack {
            if #available(iOS 26.0, *) {
                Rectangle() // The clipShape handles the cornerRadius
                    .glassEffect(.regular.tint(rainbowColor(for: index).opacity(0.45)).interactive(), in: .rect(cornerRadius: 16.0))
            } else {
                Rectangle()
                    .fill(.ultraThinMaterial)
            }
            
            VStack(spacing: 8) {
                Image(systemName: iconFor(view: view))
                    .font(.title) // Increased icon size
                    .foregroundColor(.white)
                Text(view.Name)
                    .font(.system(size: 15, weight: .bold)) // Increased text size
                    .foregroundColor(.white)
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
        }
    }
}

struct DemoLibraryRowItem: View {
    let title: String
    let icon: String
    
    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(.blue)
                .frame(width: 32)
            Text(title)
                .font(.title3.weight(.medium))
            Spacer()
        }
        .padding(.vertical, 8)
    }
}

// MARK: - Generic Library Category View

struct LibraryCategoryView: View {
    let viewDto: JFViewDto
    @EnvironmentObject var appState: AppState
    @StateObject private var viewModel = CategoryViewModel()
    
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    
    var columns: [GridItem] {
        if horizontalSizeClass == .compact {
            return Array(repeating: GridItem(.flexible(), spacing: 14), count: 3)
        } else {
            return [GridItem(.adaptive(minimum: 140), spacing: 16)]
        }
    }
    
    var itemTypeToFetch: String {
        let type = viewDto.CollectionType?.lowercased() ?? ""
        if type == "movies" { return "Movie" }
        if type == "tvshows" { return "Series" }
        // Fetch both if the type is "mixed", "homevideos", or undetermined
        return "Movie,Series"
    }
    
    var body: some View {
        ScrollView {
            if viewModel.isLoading {
                ProgressView().padding(.top, 50)
            } else if viewModel.items.isEmpty {
                Text("No media found in this library.")
                    .foregroundColor(.secondary)
                    .padding(.top, 50)
            } else {
                LazyVGrid(columns: columns, spacing: 22) {
                    ForEach(viewModel.filteredItems) { item in
                        NavigationLink(destination: MediaItemDetailView(item: item).environmentObject(appState)) {
                            LibraryPosterCard(item: item)
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
                await viewModel.loadItems(viewId: viewDto.Id, itemType: itemTypeToFetch, appState: appState)
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

struct LibraryPosterCard: View {
    let item: JFItemDto
    @EnvironmentObject var appState: AppState
    
    var body: some View {
        let base = appState.serverURL.hasSuffix("/") ? String(appState.serverURL.dropLast()) : appState.serverURL
        
        VStack(alignment: .leading, spacing: 8) {
            Color(UIColor.secondarySystemBackground)
                .aspectRatio(2/3, contentMode: .fit)
                .overlay(
                    Group {
                        if let tag = item.primaryImageTag,
                           let url = URL(string: "\(base)/Items/\(item.Id)/Images/Primary?tag=\(tag)&maxWidth=400") {
                            CachedAsyncImage(url: url) { phase in
                                switch phase {
                                case .success(let image):
                                    image
                                        .resizable()
                                        .aspectRatio(contentMode: .fill)
                                case .failure:
                                    fallbackPlaceholder
                                case .empty:
                                    ProgressView()
                                        .scaleEffect(0.8)
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
