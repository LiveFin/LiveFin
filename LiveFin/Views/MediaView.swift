//
//  MediaView.swift
//  LiveFin
//
//  Created by KPGamingz on 5/22/26.
//

import SwiftUI

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
    
    @Published var isLoadingEpisodes = false
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
    
    var baseServerURL: String {
        appState.serverURL.hasSuffix("/") ? String(appState.serverURL.dropLast()) : appState.serverURL
    }
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                headerSection
                
                VStack(alignment: .leading, spacing: 16) {
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
                }
                .padding(.horizontal)
                
                Spacer(minLength: 40)
            }
        }
        .ignoresSafeArea(edges: .top)
        .task {
            if item.Type == "Series" {
                await viewModel.loadSeriesData(seriesId: item.Id, appState: appState)
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
                        AsyncImage(url: url) { phase in
                            if let image = phase.image {
                                image.resizable().aspectRatio(contentMode: .fill)
                            } else {
                                Rectangle().fill(Color(UIColor.secondarySystemBackground))
                            }
                        }
                    } else {
                        Rectangle()
                            .fill(Color(UIColor.secondarySystemBackground))
                    }
                }
                .frame(width: geo.size.width, height: backdropHeight)
                .clipped()
            }
            .frame(height: backdropHeight)
            
            LinearGradient(
                gradient: Gradient(colors: [.clear, Color(UIColor.systemBackground)]),
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
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(12)
            }
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
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(12)
                }
            } else if let firstEp = viewModel.episodes.first {
                Button {
                    viewModel.playEpisode(episodeId: firstEp.Id)
                } label: {
                    Label("Play Series", systemImage: "play.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(12)
                }
            }
        }
    }
    
    @ViewBuilder private var seasonsPickerSection: some View {
        if !viewModel.seasons.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(viewModel.seasons) { season in
                        Button {
                            viewModel.changeSeason(seasonId: season.Id, seriesId: item.Id, appState: appState)
                        } label: {
                            Text(season.Name)
                                .fontWeight(viewModel.selectedSeasonId == season.Id ? .bold : .medium)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .background(viewModel.selectedSeasonId == season.Id ? Color.blue : Color(UIColor.secondarySystemBackground))
                                .foregroundColor(viewModel.selectedSeasonId == season.Id ? .white : .primary)
                                .cornerRadius(8)
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
}

// MARK: - Components
struct EpisodeRowView: View {
    let episode: JFItemDto
    let baseServerURL: String
    
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    
    var body: some View {
        let thumbWidth: CGFloat = horizontalSizeClass == .compact ? 120 : 160
        let thumbHeight: CGFloat = thumbWidth * (9/16)
        
        HStack(alignment: .top, spacing: 16) {
            ZStack(alignment: .bottomLeading) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(UIColor.secondarySystemBackground))
                    .frame(width: thumbWidth, height: thumbHeight)
                
                if let tag = episode.primaryImageTag,
                   let url = URL(string: "\(baseServerURL)/Items/\(episode.Id)/Images/Primary?tag=\(tag)&maxWidth=300") {
                    AsyncImage(url: url) { phase in
                        if let image = phase.image {
                            image.resizable().aspectRatio(contentMode: .fill)
                        } else if phase.error != nil {
                            Image(systemName: "tv").foregroundColor(.gray)
                        }
                    }
                    .frame(width: thumbWidth, height: thumbHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    Image(systemName: "tv").foregroundColor(.gray)
                        .frame(width: thumbWidth, height: thumbHeight)
                }
                
                if let ticks = episode.UserData?.PlaybackPositionTicks, ticks > 0,
                   let total = episode.RunTimeTicks, total > 0 {
                    GeometryReader { geo in
                        Rectangle()
                            .fill(Color.blue)
                            .frame(width: geo.size.width * CGFloat(ticks) / CGFloat(total), height: 4)
                    }
                    .frame(height: 4)
                    .background(Color.black.opacity(0.4))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            
            VStack(alignment: .leading, spacing: 6) {
                Text(episode.Name)
                    .font(.headline)
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
