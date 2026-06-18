//
//  MediaView.swift
//  LiveFin
//
//  Created by KPGamingz on 5/22/26.
//

import SwiftUI
import UIKit

// MARK: - Stream Context for VOD
// Passes the playlist and starting index to the new LibraryPlayer
struct StreamContext: Identifiable {
    let id = UUID()
    let playlist: [JFItemDto]
    let startIndex: Int
}

// MARK: - ViewModel
@MainActor
class MediaItemDetailViewModel: ObservableObject {
    @Published var episodes: [JFItemDto] = []
    @Published var seasons: [JFItemDto] = []
    @Published var nextUpEpisode: JFItemDto? = nil
    @Published var selectedSeasonId: String? = nil
    @Published var relatedItems: [JFItemDto] = [] // Holds "More Like This" similar content
    
    @Published var isLoadingEpisodes = false
    @Published var isLoadingRelated = false // Tracks loading state for related media
    @Published var streamContext: StreamContext? = nil
    
    func loadSeriesData(seriesId: String, appState: AppState) async {
        async let nextUpTask = fetchNextUp(seriesId: seriesId, appState: appState)
        async let seasonsTask = fetchSeasons(seriesId: seriesId, appState: appState)
        
        _ = await (nextUpTask, seasonsTask)
        
        if let targetSeason = nextUpEpisode?.SeasonId {
            self.selectedSeasonId = targetSeason
        } else if let firstSeason = seasons.first?.Id {
            self.selectedSeasonId = firstSeason
        }
        
        if let sid = selectedSeasonId {
            await loadEpisodes(seriesId: seriesId, seasonId: sid, appState: appState)
        }
    }
    
    /// Fetches similar/related content from the Jellyfin backend
    func fetchRelatedItems(itemId: String, appState: AppState) async {
        guard relatedItems.isEmpty else { return }
        self.isLoadingRelated = true
        
        let base = appState.serverURL.hasSuffix("/") ? String(appState.serverURL.dropLast()) : appState.serverURL
        var components = URLComponents(string: "\(base)/Items/\(itemId)/Similar")
        components?.queryItems = [
            URLQueryItem(name: "userId", value: appState.userID),
            URLQueryItem(name: "Fields", value: "Overview,ImageTags,UserData"),
            URLQueryItem(name: "Limit", value: "12")
        ]
        
        guard let url = components?.url else {
            self.isLoadingRelated = false
            return
        }
        
        var request = URLRequest(url: url)
        request.setValue(appState.accessToken, forHTTPHeaderField: "X-Emby-Token")
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                struct SimilarResponse: Decodable { let Items: [JFItemDto] }
                let decoded = try JSONDecoder().decode(SimilarResponse.self, from: data)
                self.relatedItems = decoded.Items
            }
        } catch {
            print("Failed to fetch related content: \(error)")
        }
        self.isLoadingRelated = false
    }
    
    private func fetchNextUp(seriesId: String, appState: AppState) async {
        let base = appState.serverURL.hasSuffix("/") ? String(appState.serverURL.dropLast()) : appState.serverURL
        var components = URLComponents(string: "\(base)/Shows/NextUp")
        components?.queryItems = [
            URLQueryItem(name: "userId", value: appState.userID),
            URLQueryItem(name: "seriesId", value: seriesId),
            URLQueryItem(name: "Fields", value: "Overview,ImageTags,UserData")
        ]
        
        guard let url = components?.url else { return }
        var request = URLRequest(url: url)
        request.setValue(appState.accessToken, forHTTPHeaderField: "X-Emby-Token")
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                struct NextUpResponse: Decodable { let Items: [JFItemDto] }
                let decoded = try JSONDecoder().decode(NextUpResponse.self, from: data)
                self.nextUpEpisode = decoded.Items.first
            }
        } catch {
            print("Failed to fetch NextUp: \(error)")
        }
    }
    
    private func fetchSeasons(seriesId: String, appState: AppState) async {
        let base = appState.serverURL.hasSuffix("/") ? String(appState.serverURL.dropLast()) : appState.serverURL
        var components = URLComponents(string: "\(base)/Shows/\(seriesId)/Seasons")
        components?.queryItems = [
            URLQueryItem(name: "userId", value: appState.userID),
            URLQueryItem(name: "Fields", value: "ImageTags")
        ]
        
        guard let url = components?.url else { return }
        var request = URLRequest(url: url)
        request.setValue(appState.accessToken, forHTTPHeaderField: "X-Emby-Token")
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                struct SeasonsResponse: Decodable { let Items: [JFItemDto] }
                let decoded = try JSONDecoder().decode(SeasonsResponse.self, from: data)
                self.seasons = decoded.Items
            }
        } catch {
            print("Failed to fetch Seasons: \(error)")
        }
    }
    
    private func loadEpisodes(seriesId: String, seasonId: String, appState: AppState) async {
        self.isLoadingEpisodes = true
        let base = appState.serverURL.hasSuffix("/") ? String(appState.serverURL.dropLast()) : appState.serverURL
        var components = URLComponents(string: "\(base)/Shows/\(seriesId)/Episodes")
        
        components?.queryItems = [
            URLQueryItem(name: "seasonId", value: seasonId),
            URLQueryItem(name: "userId", value: appState.userID),
            URLQueryItem(name: "Fields", value: "Overview,ImageTags,UserData")
        ]
        
        guard let url = components?.url else { return }
        var request = URLRequest(url: url)
        request.setValue(appState.accessToken, forHTTPHeaderField: "X-Emby-Token")
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                struct EpisodesResponse: Decodable { let Items: [JFItemDto] }
                let decoded = try JSONDecoder().decode(EpisodesResponse.self, from: data)
                self.episodes = decoded.Items
            }
            self.isLoadingEpisodes = false
        } catch {
            print("Failed to fetch episodes: \(error)")
            self.isLoadingEpisodes = false
        }
    }
    
    func changeSeason(seasonId: String, seriesId: String, appState: AppState) {
        guard self.selectedSeasonId != seasonId else { return }
        self.selectedSeasonId = seasonId
        Task {
            await loadEpisodes(seriesId: seriesId, seasonId: seasonId, appState: appState)
        }
    }
    
    func playMovie(item: JFItemDto) {
        // Movies are just a playlist of 1
        self.streamContext = StreamContext(playlist: [item], startIndex: 0)
    }
    
    func playEpisode(episodeId: String) {
        // Pass the entire season's episodes so the player can Auto-Play the next one
        guard let index = episodes.firstIndex(where: { $0.Id == episodeId }) else { return }
        self.streamContext = StreamContext(playlist: episodes, startIndex: index)
    }
}

// MARK: - Views
struct MediaItemDetailView: View {
    let item: JFItemDto
    @EnvironmentObject var appState: AppState
    @StateObject private var viewModel = MediaItemDetailViewModel()
    
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.colorScheme) private var colorScheme
    
    // Tracks the raw parsed backdrop bottom color
    @State private var rawBackdropColor: Color? = nil
    
    // Dynamically computes a safe, high-contrast background based on system color scheme and image analysis
    var blendedBackgroundColor: Color {
        let baseColor = rawBackdropColor ?? (colorScheme == .dark ? Color.black : Color(UIColor.systemBackground))
        if colorScheme == .dark {
            // Blend a maximum of 25% of the poster color with 75% deep dark grey to keep backdrop safe for white text
            return baseColor.blended(with: Color(red: 0.08, green: 0.08, blue: 0.09), ratio: 0.75)
        } else {
            // Blend a maximum of 15% of the poster color with 85% clean light gray to keep backdrop safe for dark text
            return baseColor.blended(with: Color(red: 0.96, green: 0.96, blue: 0.98), ratio: 0.85)
        }
    }
    
    // Adaptive action button colors ensuring highest legibility across both light and dark systems
    var playButtonBackgroundColor: Color {
        colorScheme == .dark ? .clear : .clear
    }
    
    var playButtonForegroundColor: Color {
        colorScheme == .dark ? .white : .black
    }
    
    // Adaptive picker colors for the active/selected state
    var selectedSeasonBackgroundColor: Color {
        colorScheme == .dark ? .clear : .clear
    }
    
    var selectedSeasonForegroundColor: Color {
        colorScheme == .dark ? .white : .black
    }
    
    // Adaptive picker colors for the unselected states to match premium iOS overlay conventions
    var unselectedSeasonBackgroundColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.12) : Color.black.opacity(0.06)
    }
    
    var unselectedSeasonForegroundColor: Color {
        .primary
    }
    
    var baseServerURL: String {
        appState.serverURL.hasSuffix("/") ? String(appState.serverURL.dropLast()) : appState.serverURL
    }
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                headerSection
                
                VStack(alignment: .leading, spacing: 24) {
                    metadataSection
                    
                    actionButtons
                    
                    if let overview = item.Overview, !overview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(overview)
                            .font(.body)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    
                    if item.Type == "Series" {
                        seasonsPickerSection
                        episodesSection
                    }
                    
                    // Unified Related Content Section ("More Like This")
                    relatedContentSection
                }
                .padding(.horizontal)
                
                Spacer(minLength: 40)
            }
        }
        // Blends the scroll view seamlessly into the mathematically balanced adaptive color context
        .background(blendedBackgroundColor)
        // Ignores the top safe area of the screen, pushing the background backdrop image completely edge-to-edge
        .ignoresSafeArea(.container, edges: .top)
        // Hidden navigation background when navigating in stacks, avoiding solid navigation/top bars
        .toolbarBackground(.hidden, for: .navigationBar)
        .task {
            // Simultaneously fetch associated media datasets in parallel
            async let relatedTask: () = viewModel.fetchRelatedItems(itemId: item.Id, appState: appState)
            
            if item.Type == "Series" {
                async let seriesTask: () = viewModel.loadSeriesData(seriesId: item.Id, appState: appState)
                _ = await (seriesTask, relatedTask)
            } else {
                _ = await relatedTask
            }
        }
        // Changed to use the new LibraryPlayerView
        .fullScreenCover(item: Binding(
            get: { viewModel.streamContext },
            set: { if $0 == nil { viewModel.streamContext = nil } }
        )) { context in
            PlanktonPlayerView(
                playlist: context.playlist,
                startIndex: context.startIndex,
                seriesName: item.Type == "Series" ? item.Name : nil,
                appState: appState
            )
            .environmentObject(appState)
        }
    }
    
    @ViewBuilder private var headerSection: some View {
        let backdropHeight: CGFloat = horizontalSizeClass == .compact ? 260 : 380
        
        ZStack(alignment: .bottom) {
            GeometryReader { geo in
                ZStack {
                    if let backdropTag = item.backdropImageTag,
                       let url = URL(string: "\(baseServerURL)/Items/\(item.Id)/Images/Backdrop/0?tag=\(backdropTag)&maxWidth=1200") {
                        // Custom lazy loader that extracts color properties asynchronously
                        DynamicBackdropImageView(
                            url: url,
                            rawColor: $rawBackdropColor,
                            height: backdropHeight
                        )
                        .frame(width: geo.size.width, height: backdropHeight)
                        .clipped()
                    } else {
                        Rectangle()
                            .fill(Color(UIColor.secondarySystemBackground))
                            .frame(width: geo.size.width, height: backdropHeight)
                    }
                }
                .frame(width: geo.size.width, height: backdropHeight)
                .clipped()
            }
            .frame(height: backdropHeight)
            
            LinearGradient(
                gradient: Gradient(colors: [.clear, blendedBackgroundColor]),
                startPoint: .center,
                endPoint: .bottom
            )
            .frame(height: backdropHeight)
            
            VStack {
                if let logoTag = item.logoImageTag,
                   let url = URL(string: "\(baseServerURL)/Items/\(item.Id)/Images/Logo?tag=\(logoTag)&maxWidth=600") {
                    AsyncImage(url: url) { phase in
                        if let image = phase.image {
                            image.resizable().aspectRatio(contentMode: .fit)
                        } else {
                            EmptyView()
                        }
                    }
                    .frame(maxWidth: horizontalSizeClass == .compact ? 240 : 400, maxHeight: 100)
                    .padding(.bottom, 16)
                } else {
                    Text(item.Name)
                        .font(.system(size: horizontalSizeClass == .compact ? 28 : 34, weight: .bold))
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                        .minimumScaleFactor(0.6)
                        .padding(.bottom, 16)
                        .padding(.horizontal)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity)
    }
    
    @ViewBuilder private var metadataSection: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                if let year = item.ProductionYear {
                    Text(String(year))
                }
                
                if let rating = item.OfficialRating {
                    Text(rating)
                        .font(.caption.bold())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.2))
                        .cornerRadius(4)
                }
                
                if let minutes = item.runtimeMinutes {
                    Text("\(minutes) min")
                }
            }
            .font(.subheadline)
            .foregroundColor(.secondary)
            
            if let genres = item.Genres, !genres.isEmpty {
                Text(genres.joined(separator: " • "))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
    }
    
    @ViewBuilder private var actionButtons: some View {
        if item.Type == "Movie" || item.Type == "Recording" {
            Button {
                viewModel.playMovie(item: item)
            } label: {
                Label("Play Movie", systemImage: "play.fill")
                    .font(.headline)
                    .foregroundColor(playButtonForegroundColor)
                    .frame(width: 240, height: 50)
                    .background(playButtonBackgroundColor)
                    .glassEffect(in: .rect(cornerRadius: 25.0))
            }
            .frame(maxWidth: .infinity, alignment: .center)
        } else if item.Type == "Series" {
            if let next = viewModel.nextUpEpisode {
                Button {
                    viewModel.playEpisode(episodeId: next.Id)
                } label: {
                    let s = next.ParentIndexNumber.map { "S\($0)" } ?? ""
                    let e = next.IndexNumber.map { "E\($0)" } ?? ""
                    let se = [s, e].filter { !$0.isEmpty }.joined(separator: ":")
                    let isResume = (next.UserData?.PlaybackPositionTicks ?? 0) > 0
                    
                    Label(isResume ? "Resume \(se)" : "Play \(se)", systemImage: "play.fill")
                        .font(.headline)
                        .foregroundColor(playButtonForegroundColor)
                        .frame(width: 240, height: 50)
                        .background(playButtonBackgroundColor)
                        .glassEffect(in: .rect(cornerRadius: 25.0))
                }
                .frame(maxWidth: .infinity, alignment: .center)
            } else if let firstEp = viewModel.episodes.first {
                Button {
                    viewModel.playEpisode(episodeId: firstEp.Id)
                } label: {
                    Label("Play Series", systemImage: "play.fill")
                        .font(.headline)
                        .foregroundColor(playButtonForegroundColor)
                        .frame(width: 240, height: 50)
                        .background(playButtonBackgroundColor)
                        .glassEffect(in: .rect(cornerRadius: 25.0))
                }
                .frame(maxWidth: .infinity, alignment: .center)
            }
        }
    }
    
    @ViewBuilder private var seasonsPickerSection: some View {
        if !viewModel.seasons.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(viewModel.seasons) { season in
                        let isSelected = viewModel.selectedSeasonId == season.Id
                        Button {
                            viewModel.changeSeason(seasonId: season.Id, seriesId: item.Id, appState: appState)
                        } label: {
                            Text(season.Name)
                                .fontWeight(isSelected ? .bold : .medium)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .background(isSelected ? selectedSeasonBackgroundColor : unselectedSeasonBackgroundColor)
                                .foregroundColor(isSelected ? selectedSeasonForegroundColor : unselectedSeasonForegroundColor)
                                .glassEffect(in: .rect(cornerRadius: 16.0))
                        }
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }
    
    @ViewBuilder private var episodesSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Episodes")
                .font(.title2.bold())
                .padding(.top, 4)
            
            if viewModel.isLoadingEpisodes {
                ProgressView()
                    .frame(maxWidth: .infinity)
            } else if viewModel.episodes.isEmpty {
                Text("No episodes found.")
                    .foregroundColor(.secondary)
            } else {
                LazyVStack(spacing: 16) {
                    ForEach(viewModel.episodes) { episode in
                        Button {
                            viewModel.playEpisode(episodeId: episode.Id)
                        } label: {
                            EpisodeRowView(episode: episode, baseServerURL: baseServerURL)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
    
    @ViewBuilder private var relatedContentSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("More Like This")
                .font(.title2.bold())
                .padding(.top, 8)
            
            if viewModel.isLoadingRelated {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
                .padding(.vertical, 20)
            } else if viewModel.relatedItems.isEmpty {
                Text("No related titles found.")
                    .font(.body)
                    .foregroundColor(.secondary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 16) {
                        ForEach(viewModel.relatedItems) { relatedItem in
                            // Deep push into a subsequent MediaItemDetailView layout instance on item select
                            NavigationLink(destination: MediaItemDetailView(item: relatedItem)) {
                                RelatedItemCard(item: relatedItem, baseServerURL: baseServerURL)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Components

/// A card representation for similar content utilizing the existing CachedAsyncImage component
struct RelatedItemCard: View {
    let item: JFItemDto
    let baseServerURL: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .center) {
                // Background color placeholder
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(UIColor.secondarySystemBackground))
                
                if let tag = item.primaryImageTag,
                   let url = URL(string: "\(baseServerURL)/Items/\(item.Id)/Images/Primary?tag=\(tag)&maxWidth=300") {
                    CachedAsyncImage(url: url) { phase in
                        if let image = phase.image {
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 120, height: 180)
                                .clipped()
                        } else if phase.error != nil {
                            fallbackPlaceholder
                        } else {
                            ProgressView()
                        }
                    }
                } else {
                    fallbackPlaceholder
                }
            }
            .frame(width: 120, height: 180)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .shadow(color: Color.black.opacity(0.12), radius: 3, x: 0, y: 1.5)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(item.Name)
                    .font(.caption)
                    .fontWeight(.bold)
                    .foregroundColor(.primary)
                    .lineLimit(1)
                
                if let year = item.ProductionYear {
                    Text(String(year))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                } else {
                    Text("")
                        .font(.caption2)
                }
            }
            .frame(width: 120, alignment: .leading)
        }
        .contentShape(Rectangle())
    }
    
    private var fallbackPlaceholder: some View {
        VStack {
            Image(systemName: item.Type == "Series" ? "tv" : "film")
                .foregroundColor(.gray)
                .font(.system(size: 28))
        }
        .frame(width: 120, height: 180)
    }
}

/// A customizable Backdrop view that loads the remote picture, analyzes its bottom-edge color on a cooperative background worker,
/// and updates the shared raw binding.
struct DynamicBackdropImageView: View {
    let url: URL?
    @Binding var rawColor: Color?
    let height: CGFloat
    
    @State private var image: UIImage? = nil
    @State private var isLoading = false
    
    var body: some View {
        ZStack {
            if let image = image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(height: height)
                    .clipped()
            } else {
                Rectangle()
                    .fill(Color(UIColor.secondarySystemBackground))
                    .frame(height: height)
                
                if isLoading {
                    ProgressView()
                }
            }
        }
        .task(id: url) {
            guard let url = url else { return }
            isLoading = true
            
            // Try cache first synchronously to prevent re-downloads of detail backdrops
            if let cached = ImageCacheManager.shared.imageIfCached(for: url) {
                self.image = cached
                isLoading = false
                if let extractedColor = await cached.bottomAverageColor() {
                    withAnimation(.easeInOut(duration: 0.35)) {
                        self.rawColor = extractedColor
                    }
                }
                return
            }
            
            // Asynchronously fetch and save to disk
            await withCheckedContinuation { continuation in
                ImageCacheManager.shared.load(url) { fetchedImage in
                    if let fetchedImage = fetchedImage {
                        self.image = fetchedImage
                        Task {
                            if let extractedColor = await fetchedImage.bottomAverageColor() {
                                withAnimation(.easeInOut(duration: 0.35)) {
                                    self.rawColor = extractedColor
                                }
                            }
                        }
                    }
                    isLoading = false
                    continuation.resume()
                }
            }
        }
    }
}

struct EpisodeRowView: View {
    let episode: JFItemDto
    let baseServerURL: String
    
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    
    var body: some View {
        let thumbWidth: CGFloat = horizontalSizeClass == .compact ? 120 : 160
        let thumbHeight: CGFloat = thumbWidth * (9/16)
        
        HStack(alignment: .top, spacing: 16) {
            ZStack(alignment: .bottomLeading) {
                // Background color placeholder
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(UIColor.secondarySystemBackground))
                
                // Thumbnail poster image loading
                if let tag = episode.primaryImageTag,
                   let url = URL(string: "\(baseServerURL)/Items/\(episode.Id)/Images/Primary?tag=\(tag)&maxWidth=300") {
                    // Upgraded to use our customized CachedAsyncImage
                    CachedAsyncImage(url: url) { phase in
                        if let image = phase.image {
                            image.resizable()
                                 .aspectRatio(contentMode: .fill)
                                 .frame(width: thumbWidth, height: thumbHeight)
                                 .clipped()
                        } else if phase.error != nil {
                            VStack {
                                Image(systemName: "tv")
                                    .foregroundColor(.gray)
                                    .font(.system(size: 24))
                            }
                            .frame(width: thumbWidth, height: thumbHeight)
                        } else {
                            ProgressView()
                                .frame(width: thumbWidth, height: thumbHeight)
                        }
                    }
                } else {
                    VStack {
                        Image(systemName: "tv")
                            .foregroundColor(.gray)
                            .font(.system(size: 24))
                    }
                    .frame(width: thumbWidth, height: thumbHeight)
                }
                
                // Playback progress overlay
                if let ticks = episode.UserData?.PlaybackPositionTicks, ticks > 0,
                   let total = episode.RunTimeTicks, total > 0 {
                    let progress = CGFloat(ticks) / CGFloat(total)
                    Rectangle()
                        .fill(Color.blue)
                        .frame(width: thumbWidth * min(progress, 1.0), height: 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(width: thumbWidth, height: thumbHeight) // Forces exact bounding layout limits
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .shadow(color: Color.black.opacity(0.08), radius: 2, x: 0, y: 1)
            
            VStack(alignment: .leading, spacing: 6) {
                Text(episode.Name)
                    .font(.headline)
                    .foregroundColor(.primary)
                    .lineLimit(2)
                
                if let minutes = episode.runtimeMinutes {
                    Text("\(minutes) min")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    }
                
                if let overview = episode.Overview, !overview.isEmpty {
                    Text(overview)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer()
        }
        .contentShape(Rectangle())
    }
}

// MARK: - Extensions

extension Color {
    /// Mathematically blends this color with another target Color by a given blend ratio (0.0 to 1.0)
    func blended(with other: Color, ratio: CGFloat) -> Color {
        let uiColor1 = UIColor(self)
        let uiColor2 = UIColor(other)
        
        var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
        var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
        
        guard uiColor1.getRed(&r1, green: &g1, blue: &b1, alpha: &a1),
              uiColor2.getRed(&r2, green: &g2, blue: &b2, alpha: &a2) else {
            return self
        }
        
        let clampedRatio = min(max(ratio, 0.0), 1.0)
        
        return Color(
            .sRGB,
            red: Double(r1 * (1 - clampedRatio) + r2 * clampedRatio),
            green: Double(g1 * (1 - clampedRatio) + g2 * clampedRatio),
            blue: Double(b1 * (1 - clampedRatio) + b2 * clampedRatio),
            opacity: Double(a1 * (1 - clampedRatio) + a2 * clampedRatio)
        )
    }
}

extension UIImage {
    /// Safely crops the bottom 10% of an image and extracts its average color in a cooperative background Task.
    func bottomAverageColor() async -> Color? {
        guard let cgImage = self.cgImage else { return nil }
        let cgWidth = cgImage.width
        let cgHeight = cgImage.height
        
        guard cgWidth > 0 && cgHeight > 0 else { return nil }
        
        // Isolate the bottom 10% bounding region of the image
        let sampleRect = CGRect(
            x: 0,
            y: CGFloat(cgHeight) * 0.9,
            width: CGFloat(cgWidth),
            height: CGFloat(cgHeight) * 0.1
        )
        
        guard let cropped = cgImage.cropping(to: sampleRect) else { return nil }
        
        // Spin up background computing to prevent blocking the UI layout thread
        return await Task.detached(priority: .userInitiated) {
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            var pixelData = [UInt8](repeating: 0, count: 4)
            
            guard let context = CGContext(
                data: &pixelData,
                width: 1,
                height: 1,
                bitsPerComponent: 8,
                bytesPerRow: 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return nil }
            
            context.draw(cropped, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            
            let r = Double(pixelData[0]) / 255.0
            let g = Double(pixelData[1]) / 255.0
            let b = Double(pixelData[2]) / 255.0
            let a = Double(pixelData[3]) / 255.0
            
            return Color(.sRGB, red: r, green: g, blue: b, opacity: a)
        }.value
    }
}
