//
//  HomeView.swift
//  LiveFin
//
//  Created by KPGamingz on 9/12/25.
//

import SwiftUI
import Combine

// MARK: - HomeView

struct HomeView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var vm = HomeViewModel()
    
    let nowTimer = Timer.publish(every: 600, on: .main, in: .common).autoconnect()
    
    @State private var hasAppeared: Bool = false

    var body: some View {
        NavigationStack {
            ZStack {
                let hasChannels = !vm.channels.isEmpty
                let hasPrograms = !(vm.onNow.isEmpty && vm.shows.isEmpty && vm.movies.isEmpty && vm.news.isEmpty && vm.sports.isEmpty && vm.kids.isEmpty)
                let hasLibrary = !(vm.continueWatching.isEmpty && vm.upNext.isEmpty && vm.recentlyAdded.isEmpty)
                let isCompletelyEmpty = !hasChannels && !hasPrograms && !hasLibrary

                if vm.isLoading && isCompletelyEmpty {
                    VStack {
                        Spacer()
                        ProgressView().scaleEffect(1.2)
                        Spacer()
                    }
                } else if vm.isOffline && isCompletelyEmpty {
                    // Offline / Error State
                    ScrollView {
                        VStack(spacing: 12) {
                            Image(systemName: "network.slash")
                                .font(.system(size: 48))
                                .foregroundColor(.secondary)
                                .padding(.bottom, 8)
                            
                            Text("Cannot connect to your server. Please try again")
                                .font(.title2.bold())
                                .foregroundColor(.primary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 32)
                        }
                        .padding(.top, 120)
                    }
                    .refreshable { await performRefresh(force: true) }
                } else if !hasChannels && !hasLibrary {
                    // Jellyfin Not Configured State
                    ScrollView {
                        VStack(spacing: 12) {
                            Image(systemName: "pc")
                                .font(.system(size: 48))
                                .foregroundColor(.secondary)
                                .padding(.bottom, 8)
                            
                            Text("Jellyfin Not Configured")
                                .font(.title2.bold())
                                .foregroundColor(.primary)
                            
                            Text("Finish setting up your Jellyfin server with Live TV fully configured on the Admin Dashboard")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 32)
                        }
                        .padding(.top, 120)
                    }
                    .refreshable { await performRefresh(force: true) }
                } else {
                    // Main Content State
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            Text("Hi, \(appState.username)")
                                .font(.largeTitle).bold()
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal)
                                .padding(.top, 8)

                            // No Guide Data Warning
                            if hasChannels && !hasPrograms {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("For the best experience, add EPG data on your Admin Dashboard")
                                        .font(.subheadline)
                                        .foregroundColor(.secondary)
                                        .padding(.horizontal)
                                }
                            }

                            // Dynamic Sections (No Placeholders)
                            if !vm.onNow.isEmpty {
                                SectionHeader("On Now")
                                HorizontalProgramsRow(programs: vm.onNow, style: .landscapeLarge) // Applied new large style
                                    .environmentObject(vm)
                                    .padding(.bottom, 12)
                            }

                            if !vm.channels.isEmpty {
                                SectionHeader("Channels")
                                HorizontalChannelsRow(channels: vm.channels)
                                    .environmentObject(appState)
                            }

                            if !vm.continueWatching.isEmpty {
                                SectionHeader("Continue Watching")
                                HorizontalLibraryItemsRow(items: vm.continueWatching, style: .landscape, playDirectly: true)
                                    .environmentObject(appState)
                            }

                            if !vm.upNext.isEmpty {
                                SectionHeader("Up Next")
                                HorizontalLibraryItemsRow(items: vm.upNext, style: .landscape, playDirectly: true)
                                    .environmentObject(appState)
                            }

                            if !vm.shows.isEmpty {
                                SectionHeader("Shows")
                                HorizontalProgramsRow(programs: vm.shows, style: .landscape)
                                    .environmentObject(vm)
                            }

                            if !vm.movies.isEmpty {
                                SectionHeader("Movies")
                                HorizontalProgramsRow(programs: vm.movies, style: .portrait)
                                    .environmentObject(vm)
                            }

                            if !vm.news.isEmpty {
                                SectionHeader("News")
                                HorizontalProgramsRow(programs: vm.news, style: .landscape)
                                    .environmentObject(vm)
                            }

                            if !vm.sports.isEmpty {
                                SectionHeader("Sports")
                                HorizontalProgramsRow(programs: vm.sports, style: .landscape)
                                    .environmentObject(vm)
                            }

                            if !vm.kids.isEmpty {
                                SectionHeader("Kids")
                                HorizontalProgramsRow(programs: vm.kids, style: .landscape)
                                    .environmentObject(vm)
                                    .padding(.bottom, 12)
                            }

                            if !vm.recentlyAdded.isEmpty {
                                SectionHeader("Recently Added")
                                HorizontalLibraryItemsRow(items: vm.recentlyAdded, style: .portrait, playDirectly: false)
                                    .environmentObject(appState)
                                    .padding(.bottom, 12)
                            }
                        }
                        .padding(.bottom, 24)
                    }
                    .refreshable { await performRefresh(force: true) }
                }
            }
            .task {
                guard !appState.serverURL.isEmpty else { return }
                if !hasAppeared {
                    hasAppeared = true
                    await vm.refresh(appState: appState, force: true)
                }
            }
            .onChange(of: appState.serverURL) { old, new in
                if old != new { Task { await vm.refresh(appState: appState, force: true) } }
            }
            .onChange(of: appState.isLoggedIn) { old, new in
                if new {
                    hasAppeared = false
                    Task { await vm.refresh(appState: appState, force: true) }
                }
            }
            .onReceive(nowTimer) { _ in Task { await vm.refresh(appState: appState) } }
            .toolbar { ToolbarView() }
        }
    }

    @MainActor
    private func performRefresh(force: Bool = true) async {
        await vm.refresh(appState: appState, force: force)
    }
}

// MARK: - ViewModel

final class HomeViewModel: ObservableObject {
    @Published var onNow: [JFProgram] = []
    @Published var shows: [JFProgram] = []
    @Published var movies: [JFProgram] = []
    @Published var news: [JFProgram] = []
    @Published var sports: [JFProgram] = []
    @Published var kids: [JFProgram] = []
    @Published var channelNames: [String: String] = [:]
    @Published var channels: [JFChannel] = []
    
    // Core Library Sections
    @Published var continueWatching: [JFItemDto] = []
    @Published var upNext: [JFItemDto] = []
    @Published var recentlyAdded: [JFItemDto] = []
    
    @Published var isLoading: Bool = false
    @Published var isOffline: Bool = false
    @Published var lastSuccessfulFetch: Date? = nil

    private let iso = ISO8601DateFormatter()
    private let debugLog = true
    private let cacheDuration: TimeInterval = 60
    private var currentRefreshTask: Task<Void, Never>? = nil

    init() {
        iso.formatOptions = [.withInternetDateTime]
    }

    func channelName(for id: String?) -> String? {
        guard let id = id else { return nil }
        return channelNames[id]
    }

    enum FilterKind { case shows, movies, news, sports, kids }

    @MainActor
    func refresh(appState: AppState, force: Bool = false) async {
        guard !appState.serverURL.isEmpty else { return }
        if !force, let last = lastSuccessfulFetch, Date().timeIntervalSince(last) < cacheDuration {
            if debugLog { print("HomeView: skipping refresh (cached)") }
            return
        }
        currentRefreshTask?.cancel()
        let task = Task {
            await performRefreshWork(appState: appState, force: force)
        }
        currentRefreshTask = task
        await task.value
    }

    @MainActor
    private func performRefreshWork(appState: AppState, force: Bool) async {
        guard !Task.isCancelled else { return }
        
        let isInitialLoad = self.channels.isEmpty && self.onNow.isEmpty && self.shows.isEmpty && self.movies.isEmpty && self.continueWatching.isEmpty
        if isInitialLoad {
            isLoading = true
        }
        
        if debugLog { print("HomeView.refresh start force=\(force)") }
        defer { isLoading = false; if debugLog { print("HomeView.refresh end") } }

        async let namesA   = fetchChannelNames(appState: appState)
        async let chansA   = fetchChannels(appState: appState)
        async let onNowA   = fetchOnNow(appState: appState)
        async let showsA   = fetchCategory(appState: appState, filter: .shows)
        async let moviesA  = fetchCategory(appState: appState, filter: .movies)
        async let newsA    = fetchCategory(appState: appState, filter: .news)
        async let sportsA  = fetchCategory(appState: appState, filter: .sports)
        async let kidsA    = fetchCategory(appState: appState, filter: .kids)
        
        async let continueWatchingA = fetchContinueWatching(appState: appState)
        async let upNextA           = fetchUpNext(appState: appState)
        async let recentlyAddedA    = fetchRecentlyAdded(appState: appState)

        let (names, channels, onNow, shows, movies, news, sports, kids, continueWatching, upNext, recentlyAdded) = await (namesA, chansA, onNowA, showsA, moviesA, newsA, sportsA, kidsA, continueWatchingA, upNextA, recentlyAddedA)

        guard !Task.isCancelled else { if debugLog { print("HomeView.refresh cancelled after fetch") }; return }
        
        // Detect offline/error state if essential fetches all returned nil
        let offlineCheck = (channels == nil && onNow == nil && continueWatching == nil && recentlyAdded == nil)
        self.isOffline = offlineCheck

        if let names = names, let channels = channels {
            self.channelNames = names
            self.channels = channels
        }

        func ensureChannelNames(_ programs: [JFProgram]) -> [JFProgram] {
            programs.map { p in
                if let name = p.channelName, !name.isEmpty { return p }
                if let cid = p.channelId {
                    if let cached = self.channelNames[cid], !cached.isEmpty { return JFProgram(copying: p, channelName: cached) }
                    if let ch = self.channels.first(where: { $0.id == cid }) { return JFProgram(copying: p, channelName: ch.name) }
                }
                return p
            }
        }
        
        if let onNow = onNow { self.onNow = ensureChannelNames(onNow) }
        if let shows = shows { self.shows = ensureChannelNames(shows) }
        if let movies = movies { self.movies = ensureChannelNames(movies) }
        if let news = news { self.news = ensureChannelNames(news) }
        if let sports = sports { self.sports = ensureChannelNames(sports) }
        if let kids = kids { self.kids = ensureChannelNames(kids) }
        
        if let continueWatching = continueWatching { self.continueWatching = continueWatching }
        if let upNext = upNext { self.upNext = upNext }
        if let recentlyAdded = recentlyAdded { self.recentlyAdded = recentlyAdded }

        if !offlineCheck {
            self.lastSuccessfulFetch = Date()
        }
    }

    // MARK: - Private Fetch Helpers

    private func fetchChannelNames(appState: AppState) async -> [String: String]? {
        do {
            guard let base = URL(string: appState.serverURL)?.appendingPathComponent("/LiveTv/Channels") else { return nil }
            var comps = URLComponents(url: base, resolvingAgainstBaseURL: false)
            comps?.queryItems = [URLQueryItem(name: "Limit", value: "500"), URLQueryItem(name: "StartIndex", value: "0")]
            var req = URLRequest(url: comps?.url ?? base)
            req.httpMethod = "GET"
            if !appState.accessToken.isEmpty { req.setValue(appState.accessToken, forHTTPHeaderField: "X-Emby-Token") }
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            var map: [String: String] = [:]
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let items = obj["Items"] as? [[String: Any]] {
                for item in items { if let id = item["Id"] as? String, let name = item["Name"] as? String { map[id] = name } }
            } else if let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                for item in arr { if let id = item["Id"] as? String, let name = item["Name"] as? String { map[id] = name } }
            }
            return map
        } catch {
            print("HomeView: fetchChannelNames error: \(error.localizedDescription)")
            return nil
        }
    }

    private func fetchChannels(appState: AppState) async -> [JFChannel]? {
        do {
            guard let base = URL(string: appState.serverURL)?.appendingPathComponent("/LiveTv/Channels") else { return nil }
            var comps = URLComponents(url: base, resolvingAgainstBaseURL: false)
            comps?.queryItems = [
                URLQueryItem(name: "Limit", value: "500"),
                URLQueryItem(name: "StartIndex", value: "0"),
                URLQueryItem(name: "EnableUserData", value: "true"),
                URLQueryItem(name: "userId", value: appState.userID)
            ]
            var req = URLRequest(url: comps?.url ?? base)
            req.httpMethod = "GET"
            if !appState.accessToken.isEmpty { req.setValue(appState.accessToken, forHTTPHeaderField: "X-Emby-Token") }
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            var list: [JFChannel] = []
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let items = obj["Items"] as? [[String: Any]] {
                for item in items { if let ch = JFChannel(json: item) { list.append(ch) } }
            } else if let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                for item in arr { if let ch = JFChannel(json: item) { list.append(ch) } }
            }
            return list.sorted { a, b in
                if a.isFavorite != b.isFavorite { return a.isFavorite }
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
        } catch {
            print("HomeView: fetchChannels error: \(error.localizedDescription)")
            return nil
        }
    }

    private func fetchOnNow(appState: AppState) async -> [JFProgram]? {
        do {
            guard let base = URL(string: appState.serverURL)?.appendingPathComponent("/LiveTv/Programs") else { return nil }
            var comps = URLComponents(url: base, resolvingAgainstBaseURL: false)
            var q: [URLQueryItem] = [
                URLQueryItem(name: "IsAiring", value: "true"),
                URLQueryItem(name: "Limit", value: "500"),
                URLQueryItem(name: "fields", value: "Overview,OfficialRating,Genres,SeriesName,EpisodeTitle,RunTimeTicks,ParentIndexNumber,IndexNumber,TimerId,SeriesTimerId")
            ]
            if !appState.userID.isEmpty { q.append(URLQueryItem(name: "userId", value: appState.userID)) }
            comps?.queryItems = q
            guard let url = comps?.url else { return nil }
            var req = URLRequest(url: url)
            req.httpMethod = "GET"
            if !appState.accessToken.isEmpty { req.setValue(appState.accessToken, forHTTPHeaderField: "X-Emby-Token") }
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            let now = Date()
            let items = parsePrograms(data: data).filter { notEnded($0, now: now) }
            return items.sorted { a, b in
                let la = a.startDate ?? Date.distantFuture
                let lb = b.startDate ?? Date.distantFuture
                if la == lb {
                    let ca = a.channelName ?? channelName(for: a.channelId) ?? ""
                    let cb = b.channelName ?? channelName(for: b.channelId) ?? ""
                    return ca.localizedCaseInsensitiveCompare(cb) == .orderedAscending
                }
                return la < lb
            }
        } catch {
            print("HomeView: fetchOnNow error: \(error.localizedDescription)")
            return nil
        }
    }

    private func fetchCategory(appState: AppState, filter: FilterKind) async -> [JFProgram]? {
        do {
            guard let base = URL(string: appState.serverURL)?.appendingPathComponent("/LiveTv/Programs") else { return nil }
            let now = Date()
            let end = now.addingTimeInterval(24 * 3600)

            func filterParam(into q: inout [URLQueryItem]) {
                switch filter {
                case .shows:  q.append(URLQueryItem(name: "IsSeries", value: "true"))
                case .movies: q.append(URLQueryItem(name: "IsMovie",  value: "true"))
                case .news:   q.append(URLQueryItem(name: "IsNews",   value: "true"))
                case .sports: q.append(URLQueryItem(name: "IsSports", value: "true"))
                case .kids:   q.append(URLQueryItem(name: "IsKids",   value: "true"))
                }
            }

            var q: [URLQueryItem] = [
                URLQueryItem(name: "minEndDate",   value: iso.string(from: now)),
                URLQueryItem(name: "maxStartDate", value: iso.string(from: end)),
                URLQueryItem(name: "Limit",        value: "500"),
                URLQueryItem(name: "fields",       value: "Overview,OfficialRating,Genres,SeriesName,EpisodeTitle,RunTimeTicks,ParentIndexNumber,IndexNumber,TimerId,SeriesTimerId")
            ]
            filterParam(into: &q)
            if !appState.userID.isEmpty { q.append(URLQueryItem(name: "userId", value: appState.userID)) }

            var comps = URLComponents(url: base, resolvingAgainstBaseURL: false)
            comps?.queryItems = q
            guard let url = comps?.url else { return nil }
            var req = URLRequest(url: url)
            req.httpMethod = "GET"
            if !appState.accessToken.isEmpty { req.setValue(appState.accessToken, forHTTPHeaderField: "X-Emby-Token") }
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            var items = parsePrograms(data: data).filter { notEnded($0, now: Date()) }
            if debugLog { print("HomeView: fetchCategory raw count (\(filter)): \(items.count)") }

            if items.isEmpty {
                var qUtc: [URLQueryItem] = [
                    URLQueryItem(name: "minEndDate",   value: iso.string(from: now)),
                    URLQueryItem(name: "maxStartDate", value: iso.string(from: end)),
                    URLQueryItem(name: "Limit",        value: "500"),
                    URLQueryItem(name: "fields",       value: "Overview,OfficialRating,Genres,SeriesName,EpisodeTitle,RunTimeTicks,ParentIndexNumber,IndexNumber,TimerId,SeriesTimerId")
                ]
                filterParam(into: &qUtc)
                if !appState.userID.isEmpty { qUtc.append(URLQueryItem(name: "userId", value: appState.userID)) }
                var compsUtc = URLComponents(url: base, resolvingAgainstBaseURL: false)
                compsUtc?.queryItems = qUtc
                if let urlUtc = compsUtc?.url {
                    var reqUtc = URLRequest(url: urlUtc)
                    reqUtc.httpMethod = "GET"
                    if !appState.accessToken.isEmpty { reqUtc.setValue(appState.accessToken, forHTTPHeaderField: "X-Emby-Token") }
                    let (dataUtc, respUtc) = try await URLSession.shared.data(for: reqUtc)
                    if let httpUtc = respUtc as? HTTPURLResponse, httpUtc.statusCode == 200 {
                        items = parsePrograms(data: dataUtc).filter { notEnded($0, now: Date()) }
                        if debugLog { print("HomeView: fetchCategory UTC count (\(filter)): \(items.count)") }
                    }
                }
            }

            // Deduplicate by SeriesName or Name to ensure a wide variety of shows instead of a marathon taking up the row
            var uniquePrograms: [JFProgram] = []
            var seenTitles: Set<String> = []
            
            for item in items {
                let title = item.seriesName ?? item.name
                if !seenTitles.contains(title) {
                    seenTitles.insert(title)
                    uniquePrograms.append(item)
                }
            }

            return uniquePrograms.sorted { a, b in
                let la = a.startDate ?? Date.distantFuture
                let lb = b.startDate ?? Date.distantFuture
                if la == lb {
                    let ca = a.channelName ?? channelName(for: a.channelId) ?? ""
                    let cb = b.channelName ?? channelName(for: b.channelId) ?? ""
                    return ca.localizedCaseInsensitiveCompare(cb) == .orderedAscending
                }
                return la < lb
            }.prefixed(40)
        } catch {
            print("HomeView: fetchCategory error: \(error.localizedDescription)")
            return nil
        }
    }

    private func fetchContinueWatching(appState: AppState) async -> [JFItemDto]? {
        guard !appState.serverURL.isEmpty, !appState.accessToken.isEmpty, !appState.userID.isEmpty else { return nil }
        let base = appState.serverURL.hasSuffix("/") ? String(appState.serverURL.dropLast()) : appState.serverURL
        guard let url = URL(string: "\(base)/Users/\(appState.userID)/Items/Resume?limit=12&fields=Overview,ImageTags,BackdropImageTags,Genres,ProductionYear,OfficialRating,UserData,RunTimeTicks,SeriesName,SeriesId") else { return nil }
        
        var request = URLRequest(url: url)
        request.setValue(appState.accessToken, forHTTPHeaderField: "X-Emby-Token")
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else { return nil }
            
            struct ItemsResponse: Decodable { let Items: [JFItemDto] }
            let decoded = try JSONDecoder().decode(ItemsResponse.self, from: data)
            return decoded.Items
        } catch {
            print("HomeViewModel: fetchContinueWatching error: \(error)")
            return nil
        }
    }

    private func fetchUpNext(appState: AppState) async -> [JFItemDto]? {
        guard !appState.serverURL.isEmpty, !appState.accessToken.isEmpty, !appState.userID.isEmpty else { return nil }
        let base = appState.serverURL.hasSuffix("/") ? String(appState.serverURL.dropLast()) : appState.serverURL
        guard let url = URL(string: "\(base)/Shows/NextUp?userId=\(appState.userID)&limit=12&fields=Overview,ImageTags,BackdropImageTags,Genres,ProductionYear,OfficialRating,UserData,RunTimeTicks,SeriesName,SeriesId") else { return nil }
        
        var request = URLRequest(url: url)
        request.setValue(appState.accessToken, forHTTPHeaderField: "X-Emby-Token")
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else { return nil }
            
            struct ItemsResponse: Decodable { let Items: [JFItemDto] }
            let decoded = try JSONDecoder().decode(ItemsResponse.self, from: data)
            return decoded.Items
        } catch {
            print("HomeViewModel: fetchUpNext error: \(error)")
            return nil
        }
    }

    private func fetchRecentlyAdded(appState: AppState) async -> [JFItemDto]? {
        guard !appState.serverURL.isEmpty, !appState.accessToken.isEmpty, !appState.userID.isEmpty else { return nil }
        let base = appState.serverURL.hasSuffix("/") ? String(appState.serverURL.dropLast()) : appState.serverURL
        guard let url = URL(string: "\(base)/Users/\(appState.userID)/Items?sortBy=DateCreated&sortOrder=Descending&recursive=true&limit=25&includeItemTypes=Movie,Series&fields=Overview,ImageTags,BackdropImageTags,Genres,ProductionYear,OfficialRating,UserData,RunTimeTicks,SeriesName,SeriesId") else { return nil }
        
        var request = URLRequest(url: url)
        request.setValue(appState.accessToken, forHTTPHeaderField: "X-Emby-Token")
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else { return nil }
            
            struct ItemsResponse: Decodable { let Items: [JFItemDto] }
            let decoded = try JSONDecoder().decode(ItemsResponse.self, from: data)
            return decoded.Items
        } catch {
            print("HomeViewModel: fetchRecentlyAdded error: \(error)")
            return nil
        }
    }

    private func notEnded(_ p: JFProgram, now: Date) -> Bool {
        if let end = p.endDate { return end > now }
        if let start = p.startDate, let ticks = p.runTimeTicks {
            return start.addingTimeInterval(TimeInterval(Double(ticks) / 10_000_000.0)) > now
        }
        return true
    }

    private func parsePrograms(data: Data) -> [JFProgram] {
        if let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            return arr.compactMap { JFProgram(json: $0) }
        }
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let arr = obj["Items"] as? [[String: Any]] {
            return arr.compactMap { JFProgram(json: $0) }
        }
        return []
    }
}

// MARK: - Models

struct JFChannel: Identifiable, Hashable {
    let id: String
    let name: String
    let isFavorite: Bool
    
    init?(json: [String: Any]) {
        guard let id = json["Id"] as? String else { return nil }
        self.id = id
        self.name = (json["Name"] as? String) ?? "Channel"
        if let userData = json["UserData"] as? [String: Any], let isFav = userData["IsFavorite"] as? Bool {
            self.isFavorite = isFav
        } else {
            self.isFavorite = false
        }
    }
}

extension JFChannel {
    func asLiveDto(baseURL: String) -> LiveTvChannelDto {
        LiveTvChannelDto(id: id, name: name, number: nil, startDate: nil, endDate: nil, baseURL: baseURL, userData: UserDataDto(isFavorite: isFavorite))
    }
}
