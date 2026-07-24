//
//  MediaView.swift
//  LiveFin
//
//  Created by KPGamingz on 5/22/26.
//

import SwiftUI
import UIKit

// Note: JFPersonDto, StreamContext, and MediaItemDetailViewModel
// now live in MediaComponents.swift

// MARK: - Views
struct MediaItemDetailView: View {
    let item: JFItemDto
    @EnvironmentObject var appState: AppState
    @StateObject private var viewModel = MediaItemDetailViewModel()
    
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.colorScheme) private var colorScheme
    
    @State private var rawBackdropColor: Color? = nil
    
    var blendedBackgroundColor: Color {
        let baseColor = rawBackdropColor ?? (colorScheme == .dark ? Color.black : Color(UIColor.systemBackground))
        if colorScheme == .dark {
            return baseColor.blended(with: Color(red: 0.08, green: 0.08, blue: 0.09), ratio: 0.75)
        } else {
            return baseColor.blended(with: Color(red: 0.96, green: 0.96, blue: 0.98), ratio: 0.85)
        }
    }
    
    var playButtonBackgroundColor: Color { .clear }
    var playButtonForegroundColor: Color { colorScheme == .dark ? .white : .black }
    var selectedSeasonBackgroundColor: Color { .clear }
    var selectedSeasonForegroundColor: Color { colorScheme == .dark ? .white : .black }
    var unselectedSeasonBackgroundColor: Color { colorScheme == .dark ? Color.white.opacity(0.12) : Color.black.opacity(0.06) }
    var unselectedSeasonForegroundColor: Color { .primary }
    var baseServerURL: String { appState.serverURL.hasSuffix("/") ? String(appState.serverURL.dropLast()) : appState.serverURL }
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                headerSection
                
                VStack(alignment: .leading, spacing: 24) {
                    metadataSection
                        .padding(.top, 16)
                        .padding(.horizontal)
                    
                    actionButtons
                        .padding(.horizontal)
                    
                    if let overview = item.Overview, !overview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(overview)
                            .font(.body)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal)
                    }
                    
                    if item.Type == "Series" {
                        seasonsPickerSection
                        episodesSection
                    }
                    
                    castSection
                    
                    relatedContentSection
                    
                    upcomingSection
                        .padding(.horizontal)
                }
                
                Spacer(minLength: 40)
            }
        }
        .background(blendedBackgroundColor)
        .ignoresSafeArea(.container, edges: .top)
        .toolbarBackground(.hidden, for: .navigationBar)
        .task {
            await viewModel.loadInitialData(item: item, appState: appState)
        }
        .fullScreenCover(item: Binding(
            get: { viewModel.streamContext },
            set: { newValue in
                if newValue == nil {
                    Task {
                        await viewModel.refreshPlaybackMetadata(item: item, appState: appState)
                    }
                }
                viewModel.streamContext = newValue
            }
        )) { context in
            PlanktonPlayerView(
                playlist: context.playlist,
                startIndex: context.startIndex,
                seriesName: item.Type == "Series" ? item.Name : nil,
                isShuffled: context.isShuffled,
                appState: appState
            )
            .environmentObject(appState)
        }
    }
    
    @ViewBuilder private var headerSection: some View {
        let backdropHeight: CGFloat = horizontalSizeClass == .compact ? 300 : 420
        
        ZStack(alignment: .bottom) {
            GeometryReader { geo in
                ZStack {
                    if let backdropTag = item.backdropImageTag,
                       let url = URL(string: "\(baseServerURL)/Items/\(item.Id)/Images/Backdrop/0?tag=\(backdropTag)&maxWidth=1200") {
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
                    .padding(.bottom, 0)
                    .offset(y: 12)
                } else {
                    Text(item.Name)
                        .font(.system(size: horizontalSizeClass == .compact ? 28 : 34, weight: .bold))
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                        .minimumScaleFactor(0.6)
                        .padding(.bottom, 0)
                        .offset(y: 12)
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
            let isResume = (item.UserData?.PlaybackPositionTicks ?? 0) > 0
            Button {
                viewModel.playMovie(item: item)
            } label: {
                Label(isResume ? "Resume" : "Play", systemImage: "play.fill")
                    .font(.headline.bold())
                    .foregroundColor(playButtonForegroundColor)
                    .frame(width: 180, height: 50)
                    .background(playButtonBackgroundColor)
                    .glassEffect(in: .rect(cornerRadius: 25.0))
            }
            .frame(maxWidth: .infinity, alignment: .center)
        } else if item.Type == "Series" {
            HStack(spacing: 16) {
                if let next = viewModel.nextUpEpisode {
                    let s = next.ParentIndexNumber.map { String(format: "%02d", $0) } ?? ""
                    let e = next.IndexNumber.map { String(format: "%02d", $0) } ?? ""
                    let se = [s, e].filter { !$0.isEmpty }.joined(separator: ":")
                    let isResume = (next.UserData?.PlaybackPositionTicks ?? 0) > 0
                    
                    Button {
                        viewModel.playNextUpDirectly()
                    } label: {
                        Label(isResume ? "Resume S\(se)" : "Play S\(se)", systemImage: "play.fill")
                            .font(.headline.bold())
                            .foregroundColor(playButtonForegroundColor)
                            .frame(width: 180, height: 50)
                            .background(playButtonBackgroundColor)
                            .glassEffect(in: .rect(cornerRadius: 25.0))
                    }
                } else if let firstEp = viewModel.seriesFirstEpisode {
                    let s = firstEp.ParentIndexNumber.map { String(format: "%02d", $0) } ?? ""
                    let e = firstEp.IndexNumber.map { String(format: "%02d", $0) } ?? ""
                    let se = [s, e].filter { !$0.isEmpty }.joined(separator: ":")
                    
                    Button {
                        viewModel.playSeriesFirstEpisode()
                    } label: {
                        Label("Play S\(se)", systemImage: "play.fill")
                            .font(.headline.bold())
                            .foregroundColor(playButtonForegroundColor)
                            .frame(width: 180, height: 50)
                            .background(playButtonBackgroundColor)
                            .glassEffect(in: .rect(cornerRadius: 25.0))
                    }
                }
                
                Button {
                    Task { await viewModel.playShuffle(seriesId: item.Id, appState: appState) }
                } label: {
                    Image(systemName: "shuffle")
                        .font(.headline.bold())
                        .foregroundColor(playButtonForegroundColor)
                        .frame(width: 50, height: 50)
                        .background(playButtonBackgroundColor)
                        .glassEffect(in: .rect(cornerRadius: 25.0))
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }
    
    @ViewBuilder private var upcomingSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Upcoming on Live TV")
                .font(.title2.bold())
                .padding(.top, 8)
            
            if viewModel.isLoadingUpcoming {
                UpcomingSkeletonView()
            } else if viewModel.upcomingPrograms.isEmpty {
                Text("No upcoming airings found.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(viewModel.upcomingPrograms, id: \.airingKey) { up in
                        NavigationLink(
                            destination: ProgramView(program: up, appState: appState)
                                .environmentObject(appState)
                        ) {
                            UpcomingProgramRow(
                                program: up,
                                referenceName: item.Name,
                                referenceStart: Date()
                            )
                            .environmentObject(appState)
                        }
                        .buttonStyle(.plain)
                        
                        Divider().padding(.leading, 8)
                    }
                }
                .background(RoundedRectangle(cornerRadius: 12).fill(Color(UIColor.secondarySystemBackground)))
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
                .padding(.horizontal)
            }
            .padding(.vertical, 4)
        }
    }
    
    @ViewBuilder private var episodesSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Episodes")
                .font(.title2.bold())
                .padding(.top, 4)
                .padding(.horizontal)
            
            if viewModel.isLoadingEpisodes {
                ProgressView()
                    .frame(maxWidth: .infinity)
            } else if viewModel.episodes.isEmpty {
                Text("No episodes found.")
                    .foregroundColor(.secondary)
                    .padding(.horizontal)
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
                .padding(.horizontal)
            }
        }
    }
    
    @ViewBuilder private var castSection: some View {
        if viewModel.isLoadingCast {
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
        } else if !viewModel.cast.isEmpty {
            VStack(alignment: .leading, spacing: 16) {
                Text("Cast & Crew")
                    .font(.title2.bold())
                    .padding(.top, 8)
                    .padding(.horizontal)
                
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 16) {
                        ForEach(viewModel.cast) { person in
                            NavigationLink(destination: CastDetailView(person: person, baseServerURL: baseServerURL).environmentObject(appState)) {
                                CastMemberCard(person: person, baseServerURL: baseServerURL)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal)
                }
            }
        }
    }
    
    @ViewBuilder private var relatedContentSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("More Like This")
                .font(.title2.bold())
                .padding(.top, 8)
                .padding(.horizontal)
            
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
                    .padding(.horizontal)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 16) {
                        ForEach(viewModel.relatedItems) { relatedItem in
                            NavigationLink(destination: MediaItemDetailView(item: relatedItem)) {
                                RelatedItemCard(item: relatedItem, baseServerURL: baseServerURL)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal)
                }
            }
        }
    }
}

// Note: RelatedItemCard, DynamicBackdropImageView, EpisodeRowView, and CastMemberCard
// now live in MediaComponents.swift

struct CastDetailView: View {
    let person: JFPersonDto
    let baseServerURL: String
    @EnvironmentObject var appState: AppState
    
    @State private var items: [JFItemDto] = []
    @State private var detailedPerson: JFPersonDto? = nil
    @State private var isLoading = true
    @State private var isDataLoaded = false
    
    let columns = [GridItem(.adaptive(minimum: 120), spacing: 16)]
    
    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                let displayPerson = detailedPerson ?? person
                
                CastMemberCard(person: displayPerson, baseServerURL: baseServerURL)
                    .scaleEffect(1.2)
                    .padding(.top, 32)
                
                if let bio = displayPerson.Overview, !bio.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Biography")
                            .font(.headline)
                        
                        Text(bio)
                            .font(.body)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                
                if isLoading {
                    ProgressView()
                        .padding(.top, 40)
                } else if items.isEmpty {
                    Text("No content found for this person.")
                        .foregroundColor(.secondary)
                        .padding(.top, 40)
                } else {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Movies and Shows")
                            .font(.title2.bold())
                            .padding(.horizontal)
                        
                        LazyVGrid(columns: columns, spacing: 20) {
                            ForEach(items) { item in
                                NavigationLink(destination: MediaItemDetailView(item: item).environmentObject(appState)) {
                                    RelatedItemCard(item: item, baseServerURL: baseServerURL)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal)
                    }
                }
            }
        }
        .navigationTitle(person.Name ?? "Cast Member")
        .navigationBarTitleDisplayMode(.inline)
        .background(Color(UIColor.systemBackground).ignoresSafeArea())
        .task {
            guard !isDataLoaded else { return }
            
            async let itemsTask: () = fetchPersonContent()
            async let detailsTask: () = fetchPersonDetails()
            
            _ = await (itemsTask, detailsTask)
            
            isDataLoaded = true
        }
    }
    
    private func fetchPersonDetails() async {
        guard let id = person.Id else { return }
        
        let urlString = "\(baseServerURL)/Users/\(appState.userID)/Items/\(id)"
        guard let url = URL(string: urlString) else { return }
        
        var request = URLRequest(url: url)
        request.setValue(appState.accessToken, forHTTPHeaderField: "X-Emby-Token")
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else { return }
            
            let decoded = try JSONDecoder().decode(JFPersonDto.self, from: data)
            await MainActor.run {
                self.detailedPerson = decoded
            }
        } catch {
            print("CastDetailView: Failed to fetch person details: \(error)")
        }
    }
    
    private func fetchPersonContent() async {
        guard let id = person.Id else { return }
        
        var components = URLComponents(string: "\(baseServerURL)/Users/\(appState.userID)/Items")
        components?.queryItems = [
            URLQueryItem(name: "PersonIds", value: id),
            URLQueryItem(name: "IncludeItemTypes", value: "Movie,Series"),
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "Fields", value: "Overview,ImageTags,UserData,SeriesName,SeriesId,PrimaryImageAspectRatio")
        ]
        
        guard let url = components?.url else { return }
        var request = URLRequest(url: url)
        request.setValue(appState.accessToken, forHTTPHeaderField: "X-Emby-Token")
        
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            struct ItemsResponse: Decodable { let Items: [JFItemDto] }
            let decoded = try JSONDecoder().decode(ItemsResponse.self, from: data)
            
            await MainActor.run {
                self.items = decoded.Items
                self.isLoading = false
            }
        } catch {
            print("CastDetailView: Failed to fetch items: \(error)")
            await MainActor.run { self.isLoading = false }
        }
    }
}

// Note: Color.blended(with:ratio:) and UIImage.bottomAverageColor() extensions
// now live in MediaComponents.swift
