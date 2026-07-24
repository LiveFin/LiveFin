//
//  TVLibraryView.swift
//  LiveFin
//
//  Created by Kervens on 7/19/26.
//

import SwiftUI
import Foundation

// MARK: - TVLibraryView

/// The primary tvOS Library View. Designed to adapt beautifully to the 10-foot UI,
/// making use of the native Focus Engine and `.card` styling for media carousels.
struct TVLibraryView: View {
    @EnvironmentObject var appState: AppState
    
    // We reuse the existing LibraryViewModel that powers the iOS side
    @StateObject private var viewModel = LibraryViewModel()
    
    var body: some View {
        NavigationStack {
            ZStack {
                let isCompletelyEmpty = viewModel.views.isEmpty && viewModel.continueWatching.isEmpty && viewModel.upNext.isEmpty && viewModel.recentlyAdded.isEmpty
                
                if viewModel.isLoading && isCompletelyEmpty {
                    VStack {
                        ProgressView("Loading Library...")
                            .scaleEffect(1.5)
                            .padding()
                    }
                } else if isCompletelyEmpty {
                    // Global empty state shown when no media is available
                    VStack(spacing: 32) {
                        Image(systemName: "tv.slash")
                            .font(.system(size: 100))
                            .foregroundColor(.secondary)
                        
                        Text("Library Not Available")
                            .font(.title)
                            .fontWeight(.bold)
                            .foregroundColor(.primary)
                        
                        Text("Scan or add your user on your Admin Dashboard to access your media library")
                            .font(.headline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 100)
                    }
                } else {
                    // Main Scrolling Content
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 60) {
                            
                            // MY MEDIA (LIBRARIES)
                            if !viewModel.views.isEmpty {
                                TVLibrarySection(title: "My Media") {
                                    TVHorizontalLibrariesRow(views: viewModel.views)
                                        .environmentObject(appState)
                                }
                            }
                            
                            // CONTINUE WATCHING
                            if !viewModel.continueWatching.isEmpty {
                                TVLibrarySection(title: "Continue Watching") {
                                    TVHorizontalItemsRow(items: viewModel.continueWatching, isLandscape: true, playDirectly: true)
                                        .environmentObject(appState)
                                }
                            }
                            
                            // UP NEXT
                            if !viewModel.upNext.isEmpty {
                                TVLibrarySection(title: "Up Next") {
                                    TVHorizontalItemsRow(items: viewModel.upNext, isLandscape: true, playDirectly: true)
                                        .environmentObject(appState)
                                }
                            }
                            
                            // RECENTLY ADDED
                            if !viewModel.recentlyAdded.isEmpty {
                                TVLibrarySection(title: "Recently Added") {
                                    TVHorizontalItemsRow(items: viewModel.recentlyAdded, isLandscape: false)
                                        .environmentObject(appState)
                                }
                            }
                        }
                        .padding(.top, 40)
                        .padding(.bottom, 80)
                    }
                }
            }
            .navigationDestination(for: JFItemDto.self) { item in
                TVMediaItemDetailView(item: item)
                    .environmentObject(appState)
            }
            .task {
                if viewModel.views.isEmpty {
                    await viewModel.loadLibraryContent(appState: appState)
                }
            }
        }
    }
}

// MARK: - Reusable Section Container

/// Wraps a horizontal scrolling row with a standardized title for tvOS
struct TVLibrarySection<Content: View>: View {
    let title: String
    let content: Content
    
    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text(title)
                .font(.title3)
                .fontWeight(.bold)
                .foregroundColor(.primary)
                .padding(.horizontal, 60)
            
            content
        }
    }
}

// MARK: - Row Views

struct TVHorizontalLibrariesRow: View {
    let views: [JFViewDto]
    @EnvironmentObject var appState: AppState
    
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 40) {
                ForEach(views) { viewDto in
                    NavigationLink(destination: TVLibraryCategoryView(viewDto: viewDto).environmentObject(appState)) {
                        TVLibraryCard(viewDto: viewDto)
                            .environmentObject(appState)
                    }
                    .buttonStyle(.card)
                }
            }
            .padding(.horizontal, 60)
            .padding(.vertical, 30) // Important to pad for the scaled focus state
        }
        // Offset negative margin to allow edge-to-edge scrolling while maintaining safe area alignment
        .padding(.horizontal, -60)
        .safeAreaPadding(.horizontal, 60)
    }
}

struct TVLibraryCard: View {
    let viewDto: JFViewDto
    @EnvironmentObject var appState: AppState
    
    var body: some View {
        let base = appState.serverURL.hasSuffix("/") ? String(appState.serverURL.dropLast()) : appState.serverURL
        let width: CGFloat = 380
        let height: CGFloat = 220
        
        ZStack {
            if let tag = viewDto.primaryImageTag,
               let url = URL(string: "\(base)/Items/\(viewDto.Id)/Images/Primary?tag=\(tag)&maxWidth=\(Int(width))") {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Color.gray.opacity(0.3)
                    }
                }
            } else {
                Color.gray.opacity(0.3)
                Image(systemName: iconFor(view: viewDto))
                    .font(.system(size: 70))
                    .foregroundColor(.white.opacity(0.8))
            }
            
            // Text overlay gradient
            VStack {
                Spacer()
                LinearGradient(colors: [.black.opacity(0.85), .clear], startPoint: .bottom, endPoint: .top)
                    .frame(height: 100)
                    .overlay(
                        Text(viewDto.Name)
                            .font(.headline)
                            .fontWeight(.bold)
                            .foregroundColor(.white)
                            .padding(.bottom, 20)
                            .padding(.horizontal, 24)
                        , alignment: .bottomLeading
                    )
            }
        }
        .frame(width: width, height: height)
    }
    
    private func iconFor(view: JFViewDto) -> String {
        let type = view.CollectionType?.lowercased() ?? ""
        if type == "movies" || view.Name.lowercased().contains("movie") { return "film" }
        if type == "tvshows" || view.Name.lowercased().contains("tv") { return "tv" }
        return "play.rectangle.on.rectangle"
    }
}

struct TVHorizontalItemsRow: View {
    let items: [JFItemDto]
    let isLandscape: Bool
    var playDirectly: Bool = false
    @EnvironmentObject var appState: AppState
    @State private var streamContext: StreamContext?
    
    var body: some View {
        ZStack {
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 40) {
                    ForEach(items) { item in
                        // Note: We use NavigationLink around just the image, and place the title text
                        // outside so it doesn't get distorted during the 3D tvOS parallax transformation.
                        VStack(alignment: .leading, spacing: 16) {
                            Group {
                                if playDirectly {
                                    Button {
                                        streamContext = StreamContext(playlist: [item], startIndex: 0)
                                    } label: {
                                        TVMediaItemCardImage(item: item, isLandscape: isLandscape)
                                            .environmentObject(appState)
                                    }
                                    .buttonStyle(.card)
                                } else {
                                    NavigationLink(destination: TVMediaItemDetailView(item: item).environmentObject(appState)) {
                                        TVMediaItemCardImage(item: item, isLandscape: isLandscape)
                                            .environmentObject(appState)
                                    }
                                    .buttonStyle(.card)
                                }
                            }
                            
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.displayName)
                                    .font(.caption)
                                    .fontWeight(.semibold)
                                    .foregroundColor(.primary)
                                    .lineLimit(1)
                                
                                if item.Type == "Episode" {
                                    let seasonStr = item.ParentIndexNumber.map { "S\($0)" }
                                    let episodeStr = item.IndexNumber.map { "E\($0)" }
                                    let seNumber = [seasonStr, episodeStr].compactMap { $0 }.joined(separator: "")
                                    
                                    let subtitleText: String = {
                                        if !seNumber.isEmpty && !item.Name.isEmpty {
                                            return "\(seNumber) • \(item.Name)"
                                        } else if !seNumber.isEmpty {
                                            return seNumber
                                        } else {
                                            return item.Name
                                        }
                                    }()

                                    Text(subtitleText)
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            .frame(width: isLandscape ? 400 : 260, alignment: .leading)
                        }
                    }
                }
                .padding(.horizontal, 60)
                .padding(.vertical, 30) // Room for focus scale bounce
            }
            .padding(.horizontal, -60)
            .safeAreaPadding(.horizontal, 60)
        }
        .fullScreenCover(item: $streamContext) { context in
            TVPlayerView(item: context.playlist[context.startIndex])
                .environmentObject(appState)
        }
    }
}

struct TVMediaItemCardImage: View {
    let item: JFItemDto
    let isLandscape: Bool
    @EnvironmentObject var appState: AppState
    
    var body: some View {
        let width: CGFloat = isLandscape ? 400 : 260
        let height: CGFloat = isLandscape ? 225 : 390
        let base = appState.serverURL.hasSuffix("/") ? String(appState.serverURL.dropLast()) : appState.serverURL
        let tag = isLandscape ? item.effectiveBackdropImageTag : item.effectivePrimaryImageTag
        let type = isLandscape ? "Backdrop/0" : "Primary"
        let imageItemId = item.effectiveImageItemId
        
        ZStack {
            Color(white: 0.15) // Subtle dark background placeholder
            
            if let tag = tag,
               let url = URL(string: "\(base)/Items/\(imageItemId)/Images/\(type)?tag=\(tag)&maxWidth=\(Int(width))") {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().aspectRatio(contentMode: .fill)
                    } else if phase.error != nil {
                        fallbackIcon
                    } else {
                        ProgressView()
                    }
                }
            } else {
                fallbackIcon
            }
            
            // Progress Bar Overlay for Continue Watching
            if let ticks = item.UserData?.PlaybackPositionTicks, ticks > 0,
               let total = item.RunTimeTicks, total > 0 {
                let progress = CGFloat(ticks) / CGFloat(total)
                VStack {
                    Spacer()
                    Rectangle()
                        .fill(Color.blue)
                        .frame(width: width * min(progress, 1.0), height: 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(width: width, height: height)
        .clipped()
    }
    
    @ViewBuilder
    private var fallbackIcon: some View {
        Image(systemName: item.Type == "Series" ? "tv" : "film")
            .font(.system(size: 80))
            .foregroundColor(.gray)
    }
}

// MARK: - Library Category Grid View

struct TVLibraryCategoryView: View {
    let viewDto: JFViewDto
    @EnvironmentObject var appState: AppState
    
    @StateObject private var viewModel = CategoryViewModel()
    
    var itemTypeToFetch: String {
        let type = viewDto.CollectionType?.lowercased() ?? ""
        if type == "movies" { return "Movie" }
        if type == "tvshows" { return "Series" }
        return "Movie,Series"
    }
    
    let columns = [GridItem(.adaptive(minimum: 260), spacing: 60)]
    
    var body: some View {
        ScrollView {
            if viewModel.isLoading && viewModel.items.isEmpty {
                ProgressView()
                    .scaleEffect(1.5)
                    .padding(.top, 150)
            } else if viewModel.items.isEmpty {
                Text("No media found.")
                    .font(.title3)
                    .foregroundColor(.secondary)
                    .padding(.top, 150)
            } else {
                LazyVGrid(columns: columns, spacing: 80) {
                    ForEach(viewModel.filteredItems) { item in
                        VStack(alignment: .leading, spacing: 16) {
                            NavigationLink(destination: TVMediaItemDetailView(item: item).environmentObject(appState)) {
                                TVMediaItemCardImage(item: item, isLandscape: false)
                                    .environmentObject(appState)
                            }
                            .buttonStyle(.card)
                            .task {
                                await viewModel.loadMoreIfNeeded(currentItem: item)
                            }
                            
                            Text(item.Name)
                                .font(.caption)
                                .fontWeight(.medium)
                                .foregroundColor(.primary)
                                .lineLimit(1)
                                .frame(width: 260, alignment: .leading)
                        }
                    }
                }
                .padding(.horizontal, 80)
                .padding(.top, 40)
                .padding(.bottom, 100)
                
                if viewModel.isFetchingMore {
                    ProgressView()
                        .padding(.vertical, 40)
                }
            }
        }
        .navigationTitle(viewDto.Name)
        .task {
            // Initiate the Category load for this view context
            await viewModel.loadItems(viewId: viewDto.Id, itemType: itemTypeToFetch, appState: appState, isInitial: !viewModel.isFetchingMore)
        }
    }
}
