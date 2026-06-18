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
    var id: String { Id }
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
    @Published var isLoading = true
    
    func loadViews(appState: AppState) async {
        guard !appState.serverURL.isEmpty, !appState.accessToken.isEmpty, !appState.userID.isEmpty else { return }
        isLoading = true
        
        let base = appState.serverURL.hasSuffix("/") ? String(appState.serverURL.dropLast()) : appState.serverURL
        guard let url = URL(string: "\(base)/Users/\(appState.userID)/Views") else { return }
        
        var request = URLRequest(url: url)
        request.setValue(appState.accessToken, forHTTPHeaderField: "X-Emby-Token")
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                isLoading = false
                return
            }
            
            struct ViewsResponse: Decodable { let Items: [JFViewDto] }
            let decoded = try JSONDecoder().decode(ViewsResponse.self, from: data)
            
            self.views = decoded.Items.filter { view in
                let type = (view.CollectionType ?? "").lowercased()
                let name = view.Name.lowercased()
                
                // Exclude Live TV views to avoid duplication in the Library tab
                if type == "livetv" || name.contains("live") {
                    return false
                }
                
                return type == "movies" || type == "tvshows" || name.contains("movie") || name.contains("tv") || name.contains("show")
            }
            self.isLoading = false
        } catch {
            print("Failed to load views: \(error)")
            self.isLoading = false
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
            URLQueryItem(name: "Fields", value: "Overview,ImageTags,BackdropImageTags,Genres,ProductionYear,OfficialRating")
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
            List {
                if viewModel.isLoading {
                    ProgressView("Loading...")
                        .frame(maxWidth: .infinity, alignment: .center)
                        .listRowBackground(Color.clear)
                } else if viewModel.views.isEmpty {
                    Text("No Movie or TV Show libraries found.")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(viewModel.views) { view in
                        let isMovie = (view.CollectionType?.lowercased() == "movies" || view.Name.lowercased().contains("movie"))
                        
                        if isMovie {
                            NavigationLink(destination: MoviesView(viewDto: view).environmentObject(appState)) {
                                LibraryRowItem(title: view.Name, icon: "film")
                            }
                        } else {
                            NavigationLink(destination: ShowsView(viewDto: view).environmentObject(appState)) {
                                LibraryRowItem(title: view.Name, icon: "tv")
                            }
                        }
                    }
                }
            }
            .navigationTitle("Library")
            .task {
                if viewModel.views.isEmpty { await viewModel.loadViews(appState: appState) }
            }
            .refreshable {
                await viewModel.loadViews(appState: appState)
            }
        }
    }
}

struct LibraryRowItem: View {
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

// MARK: - Category Views (Movies & Shows)

struct MoviesView: View {
    let viewDto: JFViewDto
    @EnvironmentObject var appState: AppState
    @StateObject private var viewModel = CategoryViewModel()
    
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    
    // Explicitly lock into 3 columns for iPhone, adaptable for iPad
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
        .task { if viewModel.items.isEmpty { await viewModel.loadItems(viewId: viewDto.Id, itemType: "Movie", appState: appState) } }
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

struct ShowsView: View {
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
        .task { if viewModel.items.isEmpty { await viewModel.loadItems(viewId: viewDto.Id, itemType: "Series", appState: appState) } }
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
            // Instantly defines a perfect 2:3 container size footprint based on column width
            Color(UIColor.secondarySystemBackground)
                .aspectRatio(2/3, contentMode: .fit)
                .overlay(
                    Group {
                        if let tag = item.primaryImageTag,
                           let url = URL(string: "\(base)/Items/\(item.Id)/Images/Primary?tag=\(tag)&maxWidth=400") {
                            // Upgraded to use our customized CachedAsyncImage
                            CachedAsyncImage(url: url) { phase in
                                switch phase {
                                case .success(let image):
                                    image
                                        .resizable()
                                        .aspectRatio(contentMode: .fill) // Fills and centers non-standard dimensions smoothly
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
            
            // Constrains Title height to 34pt, forcing 1-line and 2-line title rows to match layout lines
            Text(item.Name)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(height: 34, alignment: .topLeading) // Guarantees perfect column baseline alignment
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
