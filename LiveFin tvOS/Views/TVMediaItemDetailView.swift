//
//  TVMediaItemDetailView.swift
//  LiveFin
//
//  Created by Kervens on 7/19/26.
//

import SwiftUI

struct TVMediaItemDetailView: View {
    let item: JFItemDto
    @EnvironmentObject var appState: AppState
    @StateObject private var viewModel = MediaItemDetailViewModel()
    
    var baseServerURL: String { appState.serverURL.hasSuffix("/") ? String(appState.serverURL.dropLast()) : appState.serverURL }
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 60) {
                heroSection
                
                if item.Type == "Series" {
                    seasonsSection
                    episodesSection
                }
                
                castSection
                relatedSection
            }
            .padding(.bottom, 100)
        }
        .ignoresSafeArea()
        .background(
            ZStack {
                Color.black.ignoresSafeArea()
                if let backdropTag = item.backdropImageTag ?? item.primaryImageTag,
                   let url = URL(string: "\(baseServerURL)/Items/\(item.Id)/Images/\(item.backdropImageTag != nil ? "Backdrop/0" : "Primary")?tag=\(backdropTag)&maxWidth=1920") {
                    AsyncImage(url: url) { phase in
                        if let image = phase.image {
                            image.resizable().aspectRatio(contentMode: .fill)
                        } else {
                            Color.clear
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                    .overlay(
                        LinearGradient(
                            gradient: Gradient(colors: [.black.opacity(0.8), .black.opacity(0.4), .clear]),
                            startPoint: .bottom,
                            endPoint: .top
                        )
                    )
                    .overlay(
                        LinearGradient(
                            gradient: Gradient(colors: [.black.opacity(0.9), .black.opacity(0.3), .clear]),
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                }
            }
            .ignoresSafeArea()
        )
        .task {
            await viewModel.loadInitialData(item: item, appState: appState)
        }
        .fullScreenCover(item: $viewModel.streamContext, onDismiss: {
            Task { await viewModel.refreshPlaybackMetadata(item: item, appState: appState) }
        }) { context in
            TVPlanktonPlayerView(playlist: context.playlist, startIndex: context.startIndex)
                .environmentObject(appState)
        }
    }
    
    // MARK: - Sections
    
    @ViewBuilder private var heroSection: some View {
        VStack(alignment: .leading, spacing: 24) {
            Spacer().frame(height: 100)
            
            // Logo or Title Text
            if let logoTag = item.logoImageTag,
               let url = URL(string: "\(baseServerURL)/Items/\(item.Id)/Images/Logo?tag=\(logoTag)&maxWidth=800") {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().aspectRatio(contentMode: .fit)
                    } else {
                        EmptyView()
                    }
                }
                .frame(height: 180) // Larger logo
                .frame(maxWidth: 800, alignment: .leading)
            } else {
                Text(item.Name)
                    .font(.system(size: 72, weight: .bold))
                    .foregroundColor(.white)
                    .lineLimit(2)
            }
            
            // Metadata Line
            HStack(spacing: 20) {
                if let year = item.ProductionYear {
                    Text(String(year))
                }
                
                if let rating = item.OfficialRating {
                    Text(rating)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Color.white.opacity(0.2))
                        .cornerRadius(8)
                }
                
                if let minutes = item.runtimeMinutes {
                    Text("\(minutes) min")
                }
                
                if let genres = item.Genres, !genres.isEmpty {
                    Text(genres.joined(separator: " • "))
                }
            }
            .font(.system(size: 24, weight: .medium)) // Fixed sizing
            .foregroundColor(.white.opacity(0.8))
            
            // Action Buttons
            HStack(spacing: 24) {
                if item.Type == "Movie" || item.Type == "Recording" {
                    let isResume = (item.UserData?.PlaybackPositionTicks ?? 0) > 0
                    Button {
                        viewModel.playMovie(item: item)
                    } label: {
                        Label(isResume ? "Resume" : "Play", systemImage: "play.fill")
                            .padding(.horizontal, 40)
                            .padding(.vertical, 16)
                    }
                } else if item.Type == "Series" {
                    if let next = viewModel.nextUpEpisode {
                        let s = next.ParentIndexNumber.map { String(format: "%02d", $0) } ?? ""
                        let e = next.IndexNumber.map { String(format: "%02d", $0) } ?? ""
                        let se = [s, e].filter { !$0.isEmpty }.joined(separator: ":")
                        let isResume = (next.UserData?.PlaybackPositionTicks ?? 0) > 0
                        
                        Button {
                            viewModel.playNextUpDirectly()
                        } label: {
                            Label(isResume ? "Resume S\(se)" : "Play S\(se)", systemImage: "play.fill")
                                .padding(.horizontal, 40)
                                .padding(.vertical, 16)
                        }
                    } else if viewModel.seriesFirstEpisode != nil {
                        Button {
                            viewModel.playSeriesFirstEpisode()
                        } label: {
                            Label("Play Episode 1", systemImage: "play.fill")
                                .padding(.horizontal, 40)
                                .padding(.vertical, 16)
                        }
                    }
                    
                    Button {
                        Task { await viewModel.playShuffle(seriesId: item.Id, appState: appState) }
                    } label: {
                        Label("Shuffle", systemImage: "shuffle")
                            .padding(.horizontal, 40)
                            .padding(.vertical, 16)
                    }
                }
            }
            .padding(.top, 16)
            
            // Overview Box
            if let overview = item.Overview, !overview.isEmpty {
                Text(overview)
                    .font(.system(size: 26)) // Explicit sizing to stop it blowing up
                    .foregroundColor(.white.opacity(0.7))
                    .lineLimit(5)
                    .frame(maxWidth: 1000, alignment: .leading)
                    .padding(.top, 16)
            }
        }
        .padding(.horizontal, 80)
        .padding(.top, 120)
    }
    
    @ViewBuilder private var seasonsSection: some View {
        if !viewModel.seasons.isEmpty {
            VStack(alignment: .leading, spacing: 24) {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 20) {
                        ForEach(viewModel.seasons) { season in
                            let isSelected = viewModel.selectedSeasonId == season.Id
                            Button {
                                viewModel.changeSeason(seasonId: season.Id, seriesId: item.Id, appState: appState)
                            } label: {
                                Text(season.Name)
                                    .font(.system(size: 26, weight: .medium)) // Fixed explicit sizing
                                    .padding(.horizontal, 32)
                                    .padding(.vertical, 12)
                            }
                            // Only tint if it's the actively selected season to keep focus behavior intact
                            .background(isSelected ? Color.white.opacity(0.3) : Color.clear)
                            .clipShape(Capsule())
                        }
                    }
                    .padding(.horizontal, 80)
                    .padding(.vertical, 20)
                }
            }
        }
    }
    
    @ViewBuilder private var episodesSection: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Episodes")
                .font(.system(size: 38, weight: .bold)) // Uniform header size
                .padding(.horizontal, 80)
            
            if viewModel.isLoadingEpisodes {
                ProgressView().padding(.horizontal, 80)
            } else if viewModel.episodes.isEmpty {
                Text("No episodes found.")
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 80)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 40) {
                        ForEach(viewModel.episodes) { episode in
                            VStack(alignment: .leading, spacing: 16) {
                                Button {
                                    viewModel.playEpisode(episodeId: episode.Id)
                                } label: {
                                    TVEpisodeCardImage(episode: episode, baseServerURL: baseServerURL)
                                }
                                .buttonStyle(.card)
                                
                                Text(episode.Name)
                                    .font(.system(size: 24, weight: .medium)) // Fixed sizing
                                    .lineLimit(1)
                                    .frame(width: 320, alignment: .leading)
                                
                                if let minutes = episode.runtimeMinutes {
                                    Text("\(minutes) min")
                                        .font(.system(size: 20))
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 80)
                    .padding(.vertical, 40) // Increased padding for tvOS focus scaling bounds
                }
            }
        }
    }
    
    @ViewBuilder private var castSection: some View {
        if !viewModel.cast.isEmpty {
            VStack(alignment: .leading, spacing: 24) {
                Text("Cast & Crew")
                    .font(.system(size: 38, weight: .bold)) // Uniform header size
                    .padding(.horizontal, 80)
                
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 40) {
                        ForEach(viewModel.cast) { person in
                            TVCastMemberCard(person: person, baseServerURL: baseServerURL)
                        }
                    }
                    .padding(.horizontal, 80)
                    .padding(.vertical, 30)
                }
            }
        }
    }
    
    @ViewBuilder private var relatedSection: some View {
        if !viewModel.relatedItems.isEmpty {
            VStack(alignment: .leading, spacing: 24) {
                Text("More Like This")
                    .font(.system(size: 38, weight: .bold)) // Uniform header size
                    .padding(.horizontal, 80)
                
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 40) {
                        ForEach(viewModel.relatedItems) { relatedItem in
                            VStack(alignment: .leading, spacing: 16) {
                                NavigationLink(destination: TVMediaItemDetailView(item: relatedItem).environmentObject(appState)) {
                                    TVMediaItemCardImage(item: relatedItem, isLandscape: false)
                                        .environmentObject(appState)
                                }
                                .buttonStyle(.card)
                                
                                Text(relatedItem.Name)
                                    .font(.system(size: 24, weight: .medium)) // Fixed sizing
                                    .lineLimit(1)
                                    .frame(width: 260, alignment: .leading)
                            }
                        }
                    }
                    .padding(.horizontal, 80)
                    .padding(.vertical, 40) // Increased padding for tvOS focus scaling bounds
                }
            }
        }
    }
}

// MARK: - TV Specific Sub-Components

struct TVEpisodeCardImage: View {
    let episode: JFItemDto
    let baseServerURL: String
    
    var body: some View {
        let width: CGFloat = 320
        let height: CGFloat = 180
        
        ZStack {
            Color(white: 0.15)
            
            if let tag = episode.primaryImageTag,
               let url = URL(string: "\(baseServerURL)/Items/\(episode.Id)/Images/Primary?tag=\(tag)&maxWidth=\(Int(width))") {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().aspectRatio(contentMode: .fill)
                    } else if phase.error != nil {
                        Image(systemName: "tv").font(.largeTitle).foregroundColor(.gray)
                    } else {
                        ProgressView()
                    }
                }
            } else {
                Image(systemName: "tv").font(.largeTitle).foregroundColor(.gray)
            }
            
            // Progress Bar Overlay for partially watched episodes
            if let ticks = episode.UserData?.PlaybackPositionTicks, ticks > 0,
               let total = episode.RunTimeTicks, total > 0 {
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
}

struct TVCastMemberCard: View {
    let person: JFPersonDto
    let baseServerURL: String
    @FocusState private var isFocused: Bool
    
    var body: some View {
        // Plain button style with custom focus scaling removes the gray background
        Button {
            // Action placeholder for future routing
        } label: {
            VStack(spacing: 12) {
                ZStack {
                    Circle().fill(Color.white.opacity(0.1))
                    if let tag = person.resolvedPrimaryImageTag,
                       let url = URL(string: "\(baseServerURL)/Items/\(person.Id ?? "")/Images/Primary?tag=\(tag)&maxWidth=200") {
                        AsyncImage(url: url) { phase in
                            if let image = phase.image {
                                image.resizable().aspectRatio(contentMode: .fill)
                            } else if phase.error != nil {
                                Image(systemName: "person.fill").foregroundColor(.gray)
                            } else {
                                ProgressView()
                            }
                        }
                    } else {
                        Image(systemName: "person.fill")
                            .font(.system(size: 50))
                            .foregroundColor(.gray)
                    }
                }
                .frame(width: 140, height: 140)
                .clipShape(Circle())
                .overlay(
                    Circle()
                        .stroke(Color.white, lineWidth: isFocused ? 4 : 0)
                        .padding(-2)
                )
                .scaleEffect(isFocused ? 1.15 : 1.0)
                .shadow(color: isFocused ? Color.black.opacity(0.4) : Color.clear, radius: 10, x: 0, y: 5)
                .animation(.easeOut(duration: 0.2), value: isFocused)
                
                Text(person.Name ?? "Unknown")
                    .font(.system(size: 22, weight: .semibold)) // Explicit size
                    .foregroundColor(.white)
                    .lineLimit(1)
                
                if let role = person.Role, !role.isEmpty {
                    Text(role)
                        .font(.system(size: 18)) // Explicit size
                        .foregroundColor(.gray)
                        .lineLimit(1)
                }
            }
            .frame(width: 160)
            .padding(.vertical, 20) // Give room for the scale effect
        }
        .buttonStyle(.plain)
        .focused($isFocused)
    }
}
