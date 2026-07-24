//
//  MediaComponents.swift
//  LiveFin
//
//  Created by KPGamingz on 7/17/26.
//

import SwiftUI
import UIKit
import Combine

// MARK: - Cross-Platform Color Helpers

extension Color {
    /// `UIColor.secondarySystemBackground` isn't available on tvOS, so this
    /// falls back to a comparable translucent gray there.
    static var libFinSecondaryBackground: Color {
        #if os(tvOS)
        return Color.gray.opacity(0.2)
        #else
        return Color(UIColor.secondarySystemBackground)
        #endif
    }
}

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
    var UserData: JFUserData?
    
    // Additional Metadata
    let ProductionYear: Int?
    let OfficialRating: String?
    let SeasonId: String? // Added for season mapping
    let SeriesName: String? // Parent series content title
    let SeriesId: String? // Parent series ID
    
    // Parent/series image fallbacks — episodes usually don't carry their own
    // Primary/Backdrop images, so these let us fall back to the series' art.
    let SeriesPrimaryImageTag: String?
    let ParentBackdropItemId: String?
    let ParentBackdropImageTags: [String]?
    
    var id: String { Id }
    
    var primaryImageTag: String? { ImageTags?["Primary"] }
    var backdropImageTag: String? { BackdropImageTags?.first }
    var logoImageTag: String? { ImageTags?["Logo"] }
    
    /// Display name for rows like Continue Watching/Up Next, where an episode's
    /// own Name (e.g. "Chapter 3") is meaningless without the series context.
    var displayName: String {
        if Type == "Episode", let seriesName = SeriesName, !seriesName.isEmpty {
            return seriesName
        }
        return Name
    }
    
    /// Item id to source Primary/Backdrop images from — falls back to the
    /// parent series for episodes, which almost never have their own art.
    var effectiveImageItemId: String {
        if Type == "Episode", let seriesId = SeriesId {
            return seriesId
        }
        return Id
    }
    
    var effectivePrimaryImageTag: String? {
        if Type == "Episode" {
            return SeriesPrimaryImageTag ?? primaryImageTag
        }
        return primaryImageTag
    }
    
    var effectiveBackdropImageTag: String? {
        if Type == "Episode" {
            return ParentBackdropImageTags?.first ?? SeriesPrimaryImageTag
        }
        return backdropImageTag
    }
    
    // Helper to format runtime to minutes
    var runtimeMinutes: Int? {
        guard let ticks = RunTimeTicks else { return nil }
        return Int(ticks / 600_000_000)
    }
}

struct JFPersonDto: Decodable, Identifiable {
    var id: String { Id ?? UUID().uuidString }
    let Id: String?
    let Name: String?
    let Role: String?
    let type: String? // "Actor", "Director", etc.
    let PrimaryImageTag: String?
    let ImageTags: [String: String]?
    
    // Additional fields for detail view
    var Overview: String?
    var PremiereDate: String?
    
    var resolvedPrimaryImageTag: String? {
        PrimaryImageTag ?? ImageTags?["Primary"]
    }
    
    enum CodingKeys: String, CodingKey {
        case Id
        case Name
        case Role
        case type = "Type"
        case PrimaryImageTag
        case ImageTags
        case Overview
        case PremiereDate
    }
}

// MARK: - Stream Context for VOD

struct StreamContext: Identifiable {
    let id = UUID()
    let playlist: [JFItemDto]
    let startIndex: Int
    var isShuffled: Bool = false
}

// MARK: - Shared ViewModels

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
            URLQueryItem(name: "Fields", value: "Overview,ImageTags,BackdropImageTags,RunTimeTicks,UserData,SeriesName,SeriesId,ParentIndexNumber,IndexNumber")
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
            
            // Filter to only show visible cast members
            self.cast = decoded.People?.filter { $0.type == "Actor" || $0.type == "GuestStar" } ?? []
        } catch {
            print("MediaDetailVM: fetchCast error: \(error)")
        }
    }
    
    func fetchNextUp(seriesId: String, appState: AppState) async {
        let base = appState.serverURL.hasSuffix("/") ? String(appState.serverURL.dropLast()) : appState.serverURL
        guard let url = URL(string: "\(base)/Shows/NextUp?userId=\(appState.userID)&seriesId=\(seriesId)&fields=Overview,ImageTags,BackdropImageTags,RunTimeTicks,UserData,SeriesName,SeriesId,ParentIndexNumber,IndexNumber") else { return }
        
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
            URLQueryItem(name: "Fields", value: "Overview,ImageTags,UserData,SeriesName,SeriesId,ParentIndexNumber,IndexNumber"),
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
            URLQueryItem(name: "Fields", value: "Overview,ImageTags,UserData,SeriesName,SeriesId,ParentIndexNumber,IndexNumber")
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
            URLQueryItem(name: "Fields", value: "Overview,ImageTags,UserData,SeriesName,SeriesId,ParentIndexNumber,IndexNumber"),
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
        guard let url = URL(string: "\(base)/Users/\(appState.userID)/Items/Resume?limit=12&fields=Overview,ImageTags,BackdropImageTags,Genres,ProductionYear,OfficialRating,UserData,RunTimeTicks,SeriesName,SeriesId,ParentIndexNumber,IndexNumber") else { return nil }
        
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
        guard let url = URL(string: "\(base)/Shows/NextUp?userId=\(appState.userID)&limit=12&fields=Overview,ImageTags,BackdropImageTags,Genres,ProductionYear,OfficialRating,UserData,RunTimeTicks,SeriesName,SeriesId,ParentIndexNumber,IndexNumber") else { return nil }
        
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
        guard let url = URL(string: "\(base)/Users/\(appState.userID)/Items?sortBy=DateCreated&sortOrder=Descending&recursive=true&limit=25&includeItemTypes=Movie,Series&fields=Overview,ImageTags,BackdropImageTags,Genres,ProductionYear,OfficialRating,UserData,RunTimeTicks,SeriesName,SeriesId,ParentIndexNumber,IndexNumber") else { return nil }
        
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
    @Published var isFetchingMore = false
    @Published var availableGenres: [String] = []
    @Published var selectedGenre: String = "All"
    @Published var searchText: String = ""
    
    private var currentViewId = ""
    private var currentItemType = ""
    private var currentAppState: AppState?
    
    private var startIndex = 0
    private let limit = 50
    private var hasMoreItems = true
    
    var filteredItems: [JFItemDto] {
        if selectedGenre == "All" {
            return items
        }
        return items.filter { $0.Genres?.contains(selectedGenre) == true }
    }
    
    func loadItems(viewId: String, itemType: String, appState: AppState, isInitial: Bool = true) async {
        self.currentViewId = viewId
        self.currentItemType = itemType
        self.currentAppState = appState
        
        guard !appState.serverURL.isEmpty, !appState.accessToken.isEmpty, !appState.userID.isEmpty else { return }
        
        if isInitial {
            isLoading = true
            items.removeAll()
        }
        
        startIndex = 0
        hasMoreItems = true
        
        await fetchBatch(replace: true)
        isLoading = false
    }
    
    func loadMoreIfNeeded(currentItem item: JFItemDto) async {
        guard hasMoreItems, !isFetchingMore, !isLoading, let appState = currentAppState else { return }
        
        // Trigger next batch when user is within 9 items from the bottom
        guard let index = items.firstIndex(where: { $0.id == item.id }),
              index >= items.count - 9 else { return }
        
        isFetchingMore = true
        startIndex += limit
        
        await fetchBatch(replace: false)
        isFetchingMore = false
    }
    
    private func fetchBatch(replace: Bool) async {
        guard let appState = currentAppState else { return }
        
        let base = appState.serverURL.hasSuffix("/") ? String(appState.serverURL.dropLast()) : appState.serverURL
        var components = URLComponents(string: "\(base)/Users/\(appState.userID)/Items")
        
        var queryItems = [
            URLQueryItem(name: "ParentId", value: currentViewId),
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "SortBy", value: "SortName"),
            URLQueryItem(name: "SortOrder", value: "Ascending"),
            URLQueryItem(name: "IncludeItemTypes", value: currentItemType),
            URLQueryItem(name: "StartIndex", value: String(startIndex)),
            URLQueryItem(name: "Limit", value: String(limit)),
            URLQueryItem(name: "Fields", value: "Overview,ImageTags,BackdropImageTags,Genres,ProductionYear,OfficialRating,SeriesName,SeriesId,ParentIndexNumber,IndexNumber")
        ]
        
        if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            queryItems.append(URLQueryItem(name: "SearchTerm", value: searchText))
        }
        
        components?.queryItems = queryItems
        
        guard let url = components?.url else { return }
        var request = URLRequest(url: url)
        request.setValue(appState.accessToken, forHTTPHeaderField: "X-Emby-Token")
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else { return }
            
            struct ItemsResponse: Decodable { let Items: [JFItemDto] }
            let decoded = try JSONDecoder().decode(ItemsResponse.self, from: data)
            
            if replace {
                self.items = decoded.Items
            } else {
                self.items.append(contentsOf: decoded.Items)
            }
            
            // If the server returns fewer items than the current limit, we've exhausted the collection
            if decoded.Items.count < limit {
                hasMoreItems = false
            }
            
            let allGenres = self.items.compactMap { $0.Genres }.flatMap { $0 }
            self.availableGenres = Array(Set(allGenres)).sorted()
        } catch {
            print("Failed to fetch category items/decoding error: \(error)")
        }
    }
}

// MARK: - Library Components (from LibraryView.swift)

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
            LazyHStack(alignment: .center, spacing: 8) {
                ForEach(Array(views.enumerated()), id: \.element.id) { index, view in
                    
                    #if os(tvOS)
                    NavigationLink(destination: Text("\(view.Name) Category").environmentObject(appState)) {
                        cardContent(for: view, index: index, base: base)
                    }
                    .buttonStyle(.plain)
                    #else
                    NavigationLink(destination: LibraryCategoryView(viewDto: view).environmentObject(appState)) {
                        cardContent(for: view, index: index, base: base)
                    }
                    .buttonStyle(.plain)
                    #endif
                }
            }
            .padding(.horizontal)
            .frame(minHeight: 110)
        }
    }
    
    @ViewBuilder
    private func cardContent(for view: JFViewDto, index: Int, base: String) -> some View {
        Group {
            // Library Image or Fallback View
            if let tag = view.primaryImageTag,
               let url = URL(string: "\(base)/Items/\(view.Id)/Images/Primary?tag=\(tag)&maxWidth=400") {
                CachedAsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
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
        .frame(width: 180, height: 104)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityLabel(Text(view.Name))
    }
    
    @ViewBuilder
    private func fallbackView(for view: JFViewDto, index: Int) -> some View {
        ZStack {
            if #available(iOS 26.0, tvOS 26.0, *) {
                Rectangle()
                    .glassEffect(.regular.tint(rainbowColor(for: index).opacity(0.45)).interactive(), in: .rect(cornerRadius: 16.0))
            } else {
                Rectangle()
                    .fill(.ultraThinMaterial)
            }
            
            VStack(spacing: 8) {
                Image(systemName: iconFor(view: view))
                    .font(.title)
                    .foregroundColor(.white)
                Text(view.Name)
                    .font(.system(size: 15, weight: .bold))
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

struct LibraryPosterCard: View {
    let item: JFItemDto
    @EnvironmentObject var appState: AppState
    
    var body: some View {
        let base = appState.serverURL.hasSuffix("/") ? String(appState.serverURL.dropLast()) : appState.serverURL
        
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                Color.libFinSecondaryBackground
                
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
            .aspectRatio(2/3, contentMode: .fit)
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.libFinSecondaryBackground)
    }
}

// MARK: - Media Detail Components (from MediaView.swift)

struct RelatedItemCard: View {
    let item: JFItemDto
    let baseServerURL: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .center) {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.libFinSecondaryBackground)
                
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
                    .fill(Color.libFinSecondaryBackground)
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
                    .fill(Color.libFinSecondaryBackground)
                
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

struct CastMemberCard: View {
    let person: JFPersonDto
    let baseServerURL: String
    
    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(Color.libFinSecondaryBackground)
                
                if let tag = person.resolvedPrimaryImageTag,
                   let url = URL(string: "\(baseServerURL)/Items/\(person.Id ?? "")/Images/Primary?tag=\(tag)&maxWidth=200") {
                    CachedAsyncImage(url: url) { phase in
                        if let image = phase.image {
                            image.resizable()
                                 .aspectRatio(contentMode: .fill)
                        } else if phase.error != nil {
                            Image(systemName: "person.fill").foregroundColor(.gray)
                        } else {
                            ProgressView()
                        }
                    }
                } else {
                    Image(systemName: "person.fill")
                        .font(.system(size: 40))
                        .foregroundColor(.gray)
                }
            }
            .frame(width: 100, height: 100)
            .clipShape(Circle())
            .shadow(color: Color.black.opacity(0.1), radius: 3, x: 0, y: 1.5)
            
            VStack(spacing: 2) {
                Text(person.Name ?? "Unknown")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                
                if let role = person.Role, !role.isEmpty {
                    Text(role)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(width: 100)
        }
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
