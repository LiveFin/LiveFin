//
//  MediaView.swift
//  LiveFin
//
//  Created by KPGamingz on 5/22/26.
//

import SwiftUI
import UIKit

// Note: JFPersonDto now lives in MediaComponents.swift

// MARK: - Stream Context for VOD
struct StreamContext: Identifiable {
    let id = UUID()
    let playlist: [JFItemDto]
    let startIndex: Int
    var isShuffled: Bool = false
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
    @Published var cast: [JFPersonDto] = []
    
    @Published var isLoadingEpisodes = false
    @Published var isLoadingRelated = false
    @Published var isLoadingUpcoming = false
    @Published var isLoadingCast = false
    @Published var streamContext: StreamContext? = nil
    
    private var isInitialLoadComplete = false
    
    func loadInitialData(item: JFItemDto, appState: AppState) async {
        guard !isInitialLoadComplete else { return }
        isInitialLoadComplete = true
        
        async let relatedTask: () = fetchRelatedItems(itemId: item.Id, appState: appState)
        async let upcomingTask: () = fetchUpcoming(item: item, appState: appState)
        async let castTask: () = fetchCast(itemId: item.Id, appState: appState)
        
        if item.Type == "Series" {
            async let seriesTask: () = loadSeriesData(seriesId: item.Id, appState: appState)
            _ = await (seriesTask, relatedTask, upcomingTask, castTask)
        } else {
            _ = await (relatedTask, upcomingTask, castTask)
        }
    }
    
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
        async let _ = fetchCast(itemId: item.Id, appState: appState)
    }
    
    /// Lightweight refresh used after playback ends. Re-fetches only UserData
    /// (played state, resume position) for items already on screen, and merges
    /// it in place rather than re-fetching and re-rendering the episode/season
    /// lists themselves. This avoids the episodes grid flickering/reloading
    /// every time the player is dismissed.
    func refreshPlaybackMetadata(item: JFItemDto, appState: AppState) async {
        var ids = Set<String>()
        ids.insert(item.Id)
        episodes.forEach { ids.insert($0.Id) }
        relatedItems.forEach { ids.insert($0.Id) }
        if let next = nextUpEpisode { ids.insert(next.Id) }
        if let first = seriesFirstEpisode { ids.insert(first.Id) }
        guard !ids.isEmpty else { return }
        
        let base = appState.serverURL.hasSuffix("/") ? String(appState.serverURL.dropLast()) : appState.serverURL
        var components = URLComponents(string: "\(base)/Users/\(appState.userID)/Items")
        components?.queryItems = [
            URLQueryItem(name: "Ids", value: ids.joined(separator: ",")),
            URLQueryItem(name: "Fields", value: "UserData")
        ]
        
        guard let url = components?.url else { return }
        var request = URLRequest(url: url)
        request.setValue(appState.accessToken, forHTTPHeaderField: "X-Emby-Token")
        
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            struct ItemsResponse: Decodable { let Items: [JFItemDto] }
            let decoded = try JSONDecoder().decode(ItemsResponse.self, from: data)
            let userDataById = Dictionary(uniqueKeysWithValues: decoded.Items.map { ($0.Id, $0.UserData) })
            
            self.episodes = self.episodes.map { ep in
                guard let updatedUserData = userDataById[ep.Id] else { return ep }
                var merged = ep
                merged.UserData = updatedUserData
                return merged
            }
            
            self.relatedItems = self.relatedItems.map { related in
                guard let updatedUserData = userDataById[related.Id] else { return related }
                var merged = related
                merged.UserData = updatedUserData
                return merged
            }
            
            if let next = nextUpEpisode, let updatedUserData = userDataById[next.Id] {
                var merged = next
                merged.UserData = updatedUserData
                self.nextUpEpisode = merged
            }
            
            if let first = seriesFirstEpisode, let updatedUserData = userDataById[first.Id] {
                var merged = first
                merged.UserData = updatedUserData
                self.seriesFirstEpisode = merged
            }
        } catch {
            print("MediaDetailVM: refreshPlaybackMetadata error: \(error)")
        }
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
    
    func fetchCast(itemId: String, appState: AppState) async {
        self.isLoadingCast = true
        defer { self.isLoadingCast = false }
        
        let base = appState.serverURL.hasSuffix("/") ? String(appState.serverURL.dropLast()) : appState.serverURL
        guard let url = URL(string: "\(base)/Users/\(appState.userID)/Items/\(itemId)?Fields=People") else { return }
        
        var request = URLRequest(url: url)
        request.setValue(appState.accessToken, forHTTPHeaderField: "X-Emby-Token")
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else { return }
            
            struct ItemWithPeople: Decodable { let People: [JFPersonDto]? }
            let decoded = try JSONDecoder().decode(ItemWithPeople.self, from: data)
            
            // Filter to only show visible cast members (you can expand this to Directors/Writers)
            self.cast = decoded.People?.filter { $0.type == "Actor" || $0.type == "GuestStar" } ?? []
        } catch {
            print("MediaDetailVM: fetchCast error: \(error)")
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
        
        if let index = episodes.firstIndex(where: { $0.Id == next.Id }) {
            self.streamContext = StreamContext(playlist: episodes, startIndex: index)
        } else {
            self.streamContext = StreamContext(playlist: [next], startIndex: 0)
        }
    }
    
    func playSeriesFirstEpisode() {
        guard let first = seriesFirstEpisode else { return }
        
        if let index = episodes.firstIndex(where: { $0.Id == first.Id }) {
            self.streamContext = StreamContext(playlist: episodes, startIndex: index)
        } else {
            self.streamContext = StreamContext(playlist: [first], startIndex: 0)
        }
    }
    
    func playShuffle(seriesId: String, appState: AppState) async {
        let base = appState.serverURL.hasSuffix("/") ? String(appState.serverURL.dropLast()) : appState.serverURL
        var components = URLComponents(string: "\(base)/Users/\(appState.userID)/Items")
        
        // Jellyfin/Emby native API for randomizing children items
        components?.queryItems = [
            URLQueryItem(name: "ParentId", value: seriesId),
            URLQueryItem(name: "IncludeItemTypes", value: "Episode"),
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "SortBy", value: "Random"),
            URLQueryItem(name: "Fields", value: "Overview,ImageTags,UserData,SeriesName,SeriesId"),
            URLQueryItem(name: "Limit", value: "200")
        ]
        
        guard let url = components?.url else { return }
        var request = URLRequest(url: url)
        request.setValue(appState.accessToken, forHTTPHeaderField: "X-Emby-Token")
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else { return }
            
            struct ShuffleResponse: Decodable { let Items: [JFItemDto] }
            let decoded = try JSONDecoder().decode(ShuffleResponse.self, from: data)
            
            if !decoded.Items.isEmpty {
                self.streamContext = StreamContext(playlist: decoded.Items, startIndex: 0, isShuffled: true)
            }
        } catch {
            print("MediaDetailVM: fetchShuffle error: \(error)")
        }
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
