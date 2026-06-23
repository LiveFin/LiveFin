//
//  MediaView.swift
//  LiveFin
//
//  Created by KPGamingz on 5/22/26.
//

import SwiftUI
import UIKit

// MARK: - Stream Context for VOD
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
    @Published var seriesFirstEpisode: JFItemDto? = nil
    @Published var selectedSeasonId: String? = nil
    @Published var relatedItems: [JFItemDto] = []
    @Published var upcomingPrograms: [JFProgram] = []
    
    @Published var isLoadingEpisodes = false
    @Published var isLoadingRelated = false
    @Published var isLoadingUpcoming = false
    @Published var streamContext: StreamContext? = nil
    
    func loadSeriesData(seriesId: String, appState: AppState) async {
        async let nextUpTask: () = fetchNextUp(seriesId: seriesId, appState: appState)
        async let seasonsTask: () = fetchSeasons(seriesId: seriesId, appState: appState)
        
        _ = await (nextUpTask, seasonsTask)
        
        if nextUpEpisode == nil, let firstSeasonId = seasons.first?.Id {
            self.seriesFirstEpisode = await fetchFirstEpisode(seriesId: seriesId, seasonId: firstSeasonId, appState: appState)
        }
        
        if let targetSeason = nextUpEpisode?.SeasonId {
            self.selectedSeasonId = targetSeason
        } else if let firstSeason = seasons.first?.Id {
            self.selectedSeasonId = firstSeason
        }
        
        if let sid = selectedSeasonId {
            await loadEpisodes(seriesId: seriesId, seasonId: sid, appState: appState)
        }
    }
    
    func refreshAllData(item: JFItemDto, appState: AppState) async {
        if item.Type == "Series" {
            await loadSeriesData(seriesId: item.Id, appState: appState)
        }
        self.isLoadingRelated = true
        async let _ = fetchRelatedItems(itemId: item.Id, appState: appState, forceRefresh: true)
        async let _ = fetchUpcoming(item: item, appState: appState)
    }
    
    private nonisolated func fetchPrograms(serverURL: String, token: String, basePath: String, params: [URLQueryItem]) async -> [JFProgram] {
        guard !serverURL.isEmpty else { return [] }

        func attempt(_ items: [URLQueryItem]) async -> [JFProgram]? {
            guard let base = URL(string: serverURL)?.appendingPathComponent(basePath) else { return nil }
            var comps = URLComponents(url: base, resolvingAgainstBaseURL: false)
            comps?.queryItems = items
            guard let url = comps?.url else { return nil }
            var req = URLRequest(url: url)
            req.httpMethod = "GET"
            if !token.isEmpty { req.setValue(token, forHTTPHeaderField: "X-Emby-Token") }
            
            do {
                let (data, resp) = try await URLSession.shared.data(for: req)
                guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else { return nil }
                
                if let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                    return arr.compactMap { JFProgram(json: $0) }
                }
                if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    if let items = obj["Items"] as? [[String: Any]] { return items.compactMap { JFProgram(json: $0) } }
                    if let total = obj["TotalRecordCount"] as? Int, total == 0 { return [] }
                }
            } catch {
                return nil
            }
            return nil
        }

        if let list = await attempt(params) { return list }
        if let list = await attempt(params.map { qi in
            if qi.name == "MinStartDate" { return URLQueryItem(name: "StartDateUtc", value: qi.value) }
            if qi.name == "MaxStartDate" { return URLQueryItem(name: "EndDateUtc", value: qi.value) }
            return qi
        }) { return list }
        if let list = await attempt(params.map { qi in
            if qi.name == "MinStartDate" { return URLQueryItem(name: "startDate", value: qi.value) }
            if qi.name == "MaxStartDate" { return URLQueryItem(name: "endDate", value: qi.value) }
            return qi
        }) { return list }
        
        return []
    }
    
    func fetchUpcoming(item: JFItemDto, appState: AppState) async {
        self.isLoadingUpcoming = true
        defer { self.isLoadingUpcoming = false }

        let now = Date()
        guard let endWindow = Calendar.current.date(byAdding: .day, value: 14, to: now) else { return }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let nowStr = iso.string(from: now)
        let endStr = iso.string(from: endWindow)

        let term = item.Name
        let nameKey = normTitle(item.Name)
        
        let serverURL = appState.serverURL.hasSuffix("/") ? String(appState.serverURL.dropLast()) : appState.serverURL
        let token = appState.accessToken

        let baseParams: [URLQueryItem] = [
            URLQueryItem(name: "MinStartDate", value: nowStr),
            URLQueryItem(name: "MaxStartDate", value: endStr),
            URLQueryItem(name: "Limit", value: "400"),
            URLQueryItem(name: "Fields", value: "Overview,OfficialRating,Genres,SeriesName,EpisodeTitle,RunTimeTicks,ParentIndexNumber,IndexNumber,ChannelId,ChannelName,IsRepeat,SeriesId,ItemId")
        ]

        var allFound: [JFProgram] = []

        // Prong 1: Force EPG text search through global items
        async let searchFuture: [JFProgram] = {
            var p = baseParams
            p.append(URLQueryItem(name: "SearchTerm", value: term))
            p.append(URLQueryItem(name: "IncludeItemTypes", value: "Program"))
            p.append(URLQueryItem(name: "Recursive", value: "true"))
            if !appState.userID.isEmpty { p.append(URLQueryItem(name: "UserId", value: appState.userID)) }
            return await fetchPrograms(serverURL: serverURL, token: token, basePath: "/Items", params: p)
        }()

        // Prong 2: Explicit Library mapping
        async let seriesFuture: [JFProgram] = {
            var p = baseParams
            p.append(URLQueryItem(name: "librarySeriesId", value: item.Id))
            if !appState.userID.isEmpty { p.append(URLQueryItem(name: "UserId", value: appState.userID)) }
            return await fetchPrograms(serverURL: serverURL, token: token, basePath: "/LiveTv/Programs", params: p)
        }()

        // Prong 3: Name fallback on LiveTV endpoint
        async let nameFuture: [JFProgram] = {
            var p = baseParams
            p.append(URLQueryItem(name: "Name", value: term))
            if !appState.userID.isEmpty { p.append(URLQueryItem(name: "UserId", value: appState.userID)) }
            return await fetchPrograms(serverURL: serverURL, token: token, basePath: "/LiveTv/Programs", params: p)
        }()

        let (res1, res2, res3) = await (searchFuture, seriesFuture, nameFuture)
        allFound.append(contentsOf: res1)
        allFound.append(contentsOf: res2)
        allFound.append(contentsOf: res3)

        // Local filtering
        let matched = allFound.filter { p in
            guard let s = p.startDate, s > now else { return false }
            let pName = normTitle(p.name)
            let pSeries = p.seriesName.flatMap { $0.isEmpty ? nil : normTitle($0) }
            
            if item.Type == "Series" {
                if pSeries == nameKey { return true }
                if pName == nameKey { return true }
                if p.seriesId == item.Id { return true }
            } else {
                if pName == nameKey { return true }
            }
            return false
        }.sorted { ($0.startDate ?? .distantFuture) < ($1.startDate ?? .distantFuture) }

        var seen: Set<String> = []
        var finalUpcoming: [JFProgram] = []
        
        for p in matched {
            let key = p.id + "|" + (p.channelId ?? "") + "|" + String(Int(p.startDate?.timeIntervalSince1970 ?? 0))
            if seen.insert(key).inserted {
                finalUpcoming.append(p)
                if finalUpcoming.count >= 200 { break }
            }
        }
        
        self.upcomingPrograms = finalUpcoming
    }

    private func normTitle(_ s: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(.whitespaces)
        let filtered = s.lowercased().unicodeScalars.filter { allowed.contains($0) }
        return String(String.UnicodeScalarView(filtered))
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    func fetchRelatedItems(itemId: String, appState: AppState, forceRefresh: Bool = false) async {
        guard relatedItems.isEmpty || forceRefresh else { return }
        self.isLoadingRelated = true
        
        let base = appState.serverURL.hasSuffix("/") ? String(appState.serverURL.dropLast()) : appState.serverURL
        var components = URLComponents(string: "\(base)/Items/\(itemId)/Similar")
        components?.queryItems = [
            URLQueryItem(name: "UserId", value: appState.userID),
            URLQueryItem(name: "Limit", value: "12"),
            URLQueryItem(name: "Fields", value: "Overview,ImageTags,BackdropImageTags,RunTimeTicks,UserData,SeriesName,SeriesId")
        ]
        
        guard let url = components?.url else { return }
        var request = URLRequest(url: url)
        request.setValue(appState.accessToken, forHTTPHeaderField: "X-Emby-Token")
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                self.isLoadingRelated = false
                return
            }
            
            struct ItemsResponse: Decodable { let Items: [JFItemDto] }
            let decoded = try JSONDecoder().decode(ItemsResponse.self, from: data)
            self.relatedItems = decoded.Items
            self.isLoadingRelated = false
        } catch {
            print("MediaDetailVM: fetchRelated error: \(error)")
            self.isLoadingRelated = false
        }
    }
    
    func fetchNextUp(seriesId: String, appState: AppState) async {
        let base = appState.serverURL.hasSuffix("/") ? String(appState.serverURL.dropLast()) : appState.serverURL
        guard let url = URL(string: "\(base)/Shows/NextUp?userId=\(appState.userID)&seriesId=\(seriesId)&fields=Overview,ImageTags,BackdropImageTags,RunTimeTicks,UserData,SeriesName,SeriesId") else { return }
        
        var request = URLRequest(url: url)
        request.setValue(appState.accessToken, forHTTPHeaderField: "X-Emby-Token")
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                self.nextUpEpisode = nil
                return
            }
            struct NextUpWrapper: Decodable { let Items: [JFItemDto] }
            let decoded = try JSONDecoder().decode(NextUpWrapper.self, from: data)
            self.nextUpEpisode = decoded.Items.first
        } catch {
            print("MediaDetailVM: fetchNextUp error: \(error)")
            self.nextUpEpisode = nil
        }
    }
    
    func fetchFirstEpisode(seriesId: String, seasonId: String, appState: AppState) async -> JFItemDto? {
        let base = appState.serverURL.hasSuffix("/") ? String(appState.serverURL.dropLast()) : appState.serverURL
        var components = URLComponents(string: "\(base)/Shows/\(seriesId)/Episodes")
        components?.queryItems = [
            URLQueryItem(name: "seasonId", value: seasonId),
            URLQueryItem(name: "userId", value: appState.userID),
            URLQueryItem(name: "Fields", value: "Overview,ImageTags,UserData,SeriesName,SeriesId"),
            URLQueryItem(name: "Limit", value: "1")
        ]
        guard let url = components?.url else { return nil }
        var request = URLRequest(url: url)
        request.setValue(appState.accessToken, forHTTPHeaderField: "X-Emby-Token")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                struct EpisodesResponse: Decodable { let Items: [JFItemDto] }
                let decoded = try JSONDecoder().decode(EpisodesResponse.self, from: data)
                return decoded.Items.first
            }
        } catch {
            print("Failed to fetch first episode: \(error)")
        }
        return nil
    }
    
    func fetchSeasons(seriesId: String, appState: AppState) async {
        let base = appState.serverURL.hasSuffix("/") ? String(appState.serverURL.dropLast()) : appState.serverURL
        guard let url = URL(string: "\(base)/Shows/\(seriesId)/Seasons?userId=\(appState.userID)") else { return }
        
        var request = URLRequest(url: url)
        request.setValue(appState.accessToken, forHTTPHeaderField: "X-Emby-Token")
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else { return }
            
            struct ItemsResponse: Decodable { let Items: [JFItemDto] }
            let decoded = try JSONDecoder().decode(ItemsResponse.self, from: data)
            self.seasons = decoded.Items
        } catch {
            print("MediaDetailVM: fetchSeasons error: \(error)")
        }
    }
    
    private func loadEpisodes(seriesId: String, seasonId: String, appState: AppState) async {
        self.isLoadingEpisodes = true
        let base = appState.serverURL.hasSuffix("/") ? String(appState.serverURL.dropLast()) : appState.serverURL
        var components = URLComponents(string: "\(base)/Shows/\(seriesId)/Episodes")
        
        components?.queryItems = [
            URLQueryItem(name: "seasonId", value: seasonId),
            URLQueryItem(name: "userId", value: appState.userID),
            URLQueryItem(name: "Fields", value: "Overview,ImageTags,UserData,SeriesName,SeriesId")
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
        self.streamContext = StreamContext(playlist: [item], startIndex: 0)
    }
    
    func playEpisode(episodeId: String) {
        guard let index = episodes.firstIndex(where: { $0.Id == episodeId }) else { return }
        self.streamContext = StreamContext(playlist: episodes, startIndex: index)
    }
    
    func playNextUpDirectly() {
        guard let next = nextUpEpisode else { return }
        self.streamContext = StreamContext(playlist: [next], startIndex: 0)
    }
    
    func playSeriesFirstEpisode() {
        guard let first = seriesFirstEpisode else { return }
        self.streamContext = StreamContext(playlist: [first], startIndex: 0)
    }
}

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
                    
                    relatedContentSection
                    
                    upcomingSection
                }
                .padding(.horizontal)
                
                Spacer(minLength: 40)
            }
        }
        .background(blendedBackgroundColor)
        .ignoresSafeArea(.container, edges: .top)
        .toolbarBackground(.hidden, for: .navigationBar)
        .task {
            async let relatedTask: () = viewModel.fetchRelatedItems(itemId: item.Id, appState: appState)
            async let upcomingTask: () = viewModel.fetchUpcoming(item: item, appState: appState)
            
            if item.Type == "Series" {
                async let seriesTask: () = viewModel.loadSeriesData(seriesId: item.Id, appState: appState)
                _ = await (seriesTask, relatedTask, upcomingTask)
            } else {
                _ = await (relatedTask, upcomingTask)
            }
        }
        .fullScreenCover(item: Binding(
            get: { viewModel.streamContext },
            set: { newValue in
                if newValue == nil {
                    Task {
                        await viewModel.refreshAllData(item: item, appState: appState)
                    }
                }
                viewModel.streamContext = newValue
            }
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
            let isResume = (item.UserData?.PlaybackPositionTicks ?? 0) > 0
            Button {
                viewModel.playMovie(item: item)
            } label: {
                Label(isResume ? "Resume" : "Play", systemImage: "play.fill")
                    .font(.headline)
                    .foregroundColor(playButtonForegroundColor)
                    .frame(width: 240, height: 50)
                    .background(playButtonBackgroundColor)
                    .glassEffect(in: .rect(cornerRadius: 25.0))
            }
            .frame(maxWidth: .infinity, alignment: .center)
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
                        .font(.headline)
                        .foregroundColor(playButtonForegroundColor)
                        .frame(width: 260, height: 50)
                        .background(playButtonBackgroundColor)
                        .glassEffect(in: .rect(cornerRadius: 25.0))
                }
                .frame(maxWidth: .infinity, alignment: .center)
            } else if let firstEp = viewModel.seriesFirstEpisode {
                let s = firstEp.ParentIndexNumber.map { String(format: "%02d", $0) } ?? ""
                let e = firstEp.IndexNumber.map { String(format: "%02d", $0) } ?? ""
                let se = [s, e].filter { !$0.isEmpty }.joined(separator: ":")
                
                Button {
                    viewModel.playSeriesFirstEpisode()
                } label: {
                    Label("Play S\(se)", systemImage: "play.fill")
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

struct RelatedItemCard: View {
    let item: JFItemDto
    let baseServerURL: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .center) {
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
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(UIColor.secondarySystemBackground))
                
                if let tag = episode.primaryImageTag,
                   let url = URL(string: "\(baseServerURL)/Items/\(episode.Id)/Images/Primary?tag=\(tag)&maxWidth=300") {
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
                
                if episode.UserData?.Played == true {
                    ZStack {
                        Circle()
                            .fill(.black.opacity(0.6))
                            .frame(width: 24, height: 24)
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 20))
                            .foregroundColor(.green)
                    }
                    .padding(4)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                }
                
                if let ticks = episode.UserData?.PlaybackPositionTicks, ticks > 0,
                   let total = episode.RunTimeTicks, total > 0 {
                    let progress = CGFloat(ticks) / CGFloat(total)
                    Rectangle()
                        .fill(Color.blue)
                        .frame(width: thumbWidth * min(progress, 1.0), height: 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(width: thumbWidth, height: thumbHeight)
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
    func bottomAverageColor() async -> Color? {
        guard let cgImage = self.cgImage else { return nil }
        let cgWidth = cgImage.width
        let cgHeight = cgImage.height
        
        guard cgWidth > 0 && cgHeight > 0 else { return nil }
        
        let sampleRect = CGRect(
            x: 0,
            y: CGFloat(cgHeight) * 0.9,
            width: CGFloat(cgWidth),
            height: CGFloat(cgHeight) * 0.1
        )
        
        guard let cropped = cgImage.cropping(to: sampleRect) else { return nil }
        
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
