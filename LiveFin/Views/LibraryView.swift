//
//  LibraryView.swift
//  LiveFin
//
//  Created by KPGamingz on 1/24/26.
//

import SwiftUI

// Note: JFViewDto, JFUserData, JFItemDto, LibraryViewModel, and CategoryViewModel now live in MediaComponents.swift

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
                            
                            Text("Scan or add your user on your Admin Dashboard to access your media library")
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

// MARK: - Generic Library Category View
// Note: HorizontalLibrariesRow and DemoLibraryRowItem now live in MediaComponents.swift

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
        return "Movie,Series"
    }
    
    var body: some View {
        ScrollView {
            if viewModel.isLoading && viewModel.items.isEmpty {
                ProgressView().padding(.top, 50)
            } else if viewModel.items.isEmpty {
                Text("No media found matching your criteria.")
                    .foregroundColor(.secondary)
                    .padding(.top, 50)
                    .frame(maxWidth: .infinity, alignment: .center)
            } else {
                LazyVGrid(columns: columns, spacing: 22) {
                    ForEach(viewModel.filteredItems) { item in
                        NavigationLink(destination: MediaItemDetailView(item: item).environmentObject(appState)) {
                            LibraryPosterCard(item: item)
                        }
                        .buttonStyle(.plain)
                        .task {
                            // Infinite scrolling pagination hook
                            await viewModel.loadMoreIfNeeded(currentItem: item)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                
                if viewModel.isFetchingMore {
                    ProgressView()
                        .padding(.vertical, 16)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .navigationTitle(viewDto.Name)
        .searchable(text: $viewModel.searchText, prompt: "Search \(viewDto.Name)")
        .toolbar { genrePicker }
        .task(id: viewModel.searchText) {
            // Native SwiftUI optimization: This cancels the previous task execution automatically when typing changes
            let isTyping = !viewModel.searchText.isEmpty
            if isTyping {
                try? await Task.sleep(nanoseconds: 300_000_000) // 300ms debounce
            }
            await viewModel.loadItems(viewId: viewDto.Id, itemType: itemTypeToFetch, appState: appState, isInitial: !viewModel.isFetchingMore)
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
