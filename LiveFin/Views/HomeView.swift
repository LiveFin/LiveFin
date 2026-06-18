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
    @State private var nowTimer = Timer.publish(every: 600, on: .main, in: .common).autoconnect()
    @State private var hasAppeared: Bool = false

    var body: some View {
        NavigationStack {
            ZStack {
                #if os(iOS)
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Hi, \(appState.username)")
                            .font(.largeTitle).bold()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal)
                            .padding(.top, 8)

                        let hasChannels = !vm.channels.isEmpty
                        let hasPrograms = !(vm.onNow.isEmpty && vm.shows.isEmpty && vm.movies.isEmpty && vm.news.isEmpty && vm.sports.isEmpty && vm.kids.isEmpty)

                        if vm.isLoading == false && !hasChannels && !hasPrograms && vm.lastSuccessfulFetch == nil {
                            VStack(alignment: .leading, spacing: 8) {
                                SectionHeader("Live TV not configured")
                                Text("Check your server settings or add channels/program data to your Jellyfin server.")
                                    .foregroundColor(.secondary)
                                    .padding(.horizontal)
                            }
                        } else if hasChannels && !hasPrograms {
                            SectionHeader("Channels")
                            HorizontalChannelsRow(channels: vm.channels)
                                .environmentObject(appState)

                            if vm.isLoading == false {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("No program data available")
                                        .font(.headline)
                                        .padding(.horizontal)
                                    Text("For the best Live TV experience, consider enabling an Electronic Program Guide (EPG) on your server.")
                                        .foregroundColor(.secondary)
                                        .padding(.horizontal)
                                }
                            }
                        } else {
                            SectionHeader("On Now")
                            if !vm.onNow.isEmpty {
                                HorizontalProgramsRow(programs: vm.onNow, style: .landscape)
                                    .environmentObject(vm)
                                    .padding(.bottom, 12)
                            } else {
                                EmptySectionPlaceholder()
                            }

                            SectionHeader("Channels")
                            if !vm.channels.isEmpty {
                                HorizontalChannelsRow(channels: vm.channels)
                                    .environmentObject(appState)
                            } else {
                                EmptySectionPlaceholder()
                            }

                            SectionHeader("Shows")
                            if !vm.shows.isEmpty {
                                HorizontalProgramsRow(programs: vm.shows, style: .landscape)
                                    .environmentObject(vm)
                            } else {
                                EmptySectionPlaceholder()
                            }

                            SectionHeader("Movies")
                            if !vm.movies.isEmpty {
                                HorizontalProgramsRow(programs: vm.movies, style: .portrait)
                                    .environmentObject(vm)
                            } else {
                                EmptySectionPlaceholder()
                            }

                            SectionHeader("News")
                            if !vm.news.isEmpty {
                                HorizontalProgramsRow(programs: vm.news, style: .landscape)
                                    .environmentObject(vm)
                            } else {
                                EmptySectionPlaceholder()
                            }

                            SectionHeader("Sports")
                            if !vm.sports.isEmpty {
                                HorizontalProgramsRow(programs: vm.sports, style: .landscape)
                                    .environmentObject(vm)
                            } else {
                                EmptySectionPlaceholder()
                            }

                            SectionHeader("Kids")
                            if !vm.kids.isEmpty {
                                HorizontalProgramsRow(programs: vm.kids, style: .landscape)
                                    .environmentObject(vm)
                                    .padding(.bottom, 12)
                            } else {
                                EmptySectionPlaceholder()
                            }
                        }
                    }
                    .padding(.bottom, 24)
                }
                .refreshable { await performRefresh(force: true) }
                #else
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Hi, \(appState.username)")
                            .font(.largeTitle).bold()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal)
                            .padding(.top, 8)

                        let hasChannels = !vm.channels.isEmpty
                        let hasPrograms = !(vm.onNow.isEmpty && vm.shows.isEmpty && vm.movies.isEmpty && vm.news.isEmpty && vm.sports.isEmpty && vm.kids.isEmpty)

                        if vm.isLoading == false && !hasChannels && !hasPrograms && vm.lastSuccessfulFetch == nil {
                            VStack(alignment: .leading, spacing: 8) {
                                SectionHeader("Live TV not configured")
                                Text("Live TV isn't set up — no channels or program listings were found. Check your server settings or add channels/program data to your Jellyfin server.")
                                    .foregroundColor(.secondary)
                                    .padding(.horizontal)
                            }
                        } else if hasChannels && !hasPrograms {
                            SectionHeader("Channels")
                            HorizontalChannelsRow(channels: vm.channels)
                                .environmentObject(appState)

                            if vm.isLoading == false {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("No program data available")
                                        .font(.headline)
                                        .padding(.horizontal)
                                    Text("No program listings were found. For the best Live TV experience, consider enabling an Electronic Program Guide (EPG) on your server.")
                                        .foregroundColor(.secondary)
                                        .padding(.horizontal)
                                }
                            }
                        } else {
                            SectionHeader("On Now")
                            if !vm.onNow.isEmpty {
                                HorizontalProgramsRow(programs: vm.onNow, style: .landscape)
                                    .environmentObject(vm)
                                    .padding(.bottom, 12)
                            } else {
                                EmptySectionPlaceholder()
                            }

                            SectionHeader("Channels")
                            if !vm.channels.isEmpty {
                                HorizontalChannelsRow(channels: vm.channels)
                                    .environmentObject(appState)
                            } else {
                                EmptySectionPlaceholder()
                            }

                            SectionHeader("Shows")
                            if !vm.shows.isEmpty {
                                HorizontalProgramsRow(programs: vm.shows, style: .landscape)
                                    .environmentObject(vm)
                            } else {
                                EmptySectionPlaceholder()
                            }

                            SectionHeader("Movies")
                            if !vm.movies.isEmpty {
                                HorizontalProgramsRow(programs: vm.movies, style: .portrait)
                                    .environmentObject(vm)
                            } else {
                                EmptySectionPlaceholder()
                            }

                            SectionHeader("News")
                            if !vm.news.isEmpty {
                                HorizontalProgramsRow(programs: vm.news, style: .landscape)
                                    .environmentObject(vm)
                            } else {
                                EmptySectionPlaceholder()
                            }

                            SectionHeader("Sports")
                            if !vm.sports.isEmpty {
                                HorizontalProgramsRow(programs: vm.sports, style: .landscape)
                                    .environmentObject(vm)
                            } else {
                                EmptySectionPlaceholder()
                            }

                            SectionHeader("Kids")
                            if !vm.kids.isEmpty {
                                HorizontalProgramsRow(programs: vm.kids, style: .landscape)
                                    .environmentObject(vm)
                                    .padding(.bottom, 12)
                            } else {
                                EmptySectionPlaceholder()
                            }
                        }
                    }
                    .padding(.bottom, 24)
                }
                .refreshable { await performRefresh(force: true) }
                #endif

                // Loading overlay when content already exists
                if vm.isLoading && (!vm.channels.isEmpty || !vm.onNow.isEmpty || !vm.shows.isEmpty || !vm.movies.isEmpty || !vm.news.isEmpty || !vm.sports.isEmpty || !vm.kids.isEmpty) {
                    Color.black.opacity(0.25).ignoresSafeArea()
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        .scaleEffect(1.4)
                }

                // Full-page spinner on first load with no cached content
                if vm.isLoading && vm.channels.isEmpty && vm.onNow.isEmpty && vm.shows.isEmpty && vm.movies.isEmpty && vm.news.isEmpty && vm.sports.isEmpty && vm.kids.isEmpty {
                    VStack {
                        Spacer()
                        HStack { Spacer(); ProgressView().scaleEffect(1.2); Spacer() }
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, minHeight: 200)
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
    @Published var isLoading: Bool = false
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
        // Cancel any in-flight refresh and start a fresh one
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
        isLoading = true
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

        let (names, channels, onNow, shows, movies, news, sports, kids) = await (namesA, chansA, onNowA, showsA, moviesA, newsA, sportsA, kidsA)

        guard !Task.isCancelled else { if debugLog { print("HomeView.refresh cancelled after fetch") }; return }

        if debugLog { print("HomeView.refresh fetched: names=\(names.count) channels=\(channels.count) onNow=\(onNow.count) shows=\(shows.count) movies=\(movies.count) news=\(news.count) sports=\(sports.count) kids=\(kids.count)") }

        let fetchedAny = !(names.isEmpty && channels.isEmpty && onNow.isEmpty && shows.isEmpty && movies.isEmpty && news.isEmpty && sports.isEmpty && kids.isEmpty)

        let hadChannelsBefore = !self.channels.isEmpty || !self.channelNames.isEmpty
        if !names.isEmpty || !channels.isEmpty || !hadChannelsBefore {
            self.channelNames = names
            self.channels = channels
        }

        // Resolve missing channel names from local maps
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
        self.onNow  = ensureChannelNames(onNow)
        self.shows  = ensureChannelNames(shows)
        self.movies = ensureChannelNames(movies)
        self.news   = ensureChannelNames(news)
        self.sports = ensureChannelNames(sports)
        self.kids   = ensureChannelNames(kids)

        if fetchedAny { self.lastSuccessfulFetch = Date() }
        if debugLog { print("HomeView: Section counts -> OnNow: \(self.onNow.count), Shows: \(self.shows.count), Movies: \(self.movies.count), News: \(self.news.count), Sports: \(self.sports.count), Kids: \(self.kids.count), Channels: \(self.channels.count)") }
    }

    // MARK: - Private Fetch Helpers

    private func fetchChannelNames(appState: AppState) async -> [String: String] {
        do {
            guard let base = URL(string: appState.serverURL)?.appendingPathComponent("/LiveTv/Channels") else { return [:] }
            var comps = URLComponents(url: base, resolvingAgainstBaseURL: false)
            comps?.queryItems = [URLQueryItem(name: "Limit", value: "500"), URLQueryItem(name: "StartIndex", value: "0")]
            var req = URLRequest(url: comps?.url ?? base)
            req.httpMethod = "GET"
            if !appState.accessToken.isEmpty { req.setValue(appState.accessToken, forHTTPHeaderField: "X-Emby-Token") }
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else { return [:] }
            var map: [String: String] = [:]
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let items = obj["Items"] as? [[String: Any]] {
                for item in items { if let id = item["Id"] as? String, let name = item["Name"] as? String { map[id] = name } }
            } else if let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                for item in arr { if let id = item["Id"] as? String, let name = item["Name"] as? String { map[id] = name } }
            }
            return map
        } catch {
            print("HomeView: fetchChannelNames error: \(error.localizedDescription)")
            return [:]
        }
    }

    private func fetchChannels(appState: AppState) async -> [JFChannel] {
        do {
            guard let base = URL(string: appState.serverURL)?.appendingPathComponent("/LiveTv/Channels") else { return [] }
            var comps = URLComponents(url: base, resolvingAgainstBaseURL: false)
            comps?.queryItems = [URLQueryItem(name: "Limit", value: "500"), URLQueryItem(name: "StartIndex", value: "0")]
            var req = URLRequest(url: comps?.url ?? base)
            req.httpMethod = "GET"
            if !appState.accessToken.isEmpty { req.setValue(appState.accessToken, forHTTPHeaderField: "X-Emby-Token") }
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else { return [] }
            var list: [JFChannel] = []
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let items = obj["Items"] as? [[String: Any]] {
                for item in items { if let ch = JFChannel(json: item) { list.append(ch) } }
            } else if let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                for item in arr { if let ch = JFChannel(json: item) { list.append(ch) } }
            }
            return list.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        } catch {
            print("HomeView: fetchChannels error: \(error.localizedDescription)")
            return []
        }
    }

    private func fetchOnNow(appState: AppState) async -> [JFProgram] {
        do {
            guard let base = URL(string: appState.serverURL)?.appendingPathComponent("/LiveTv/Programs") else { return [] }
            var comps = URLComponents(url: base, resolvingAgainstBaseURL: false)
            var q: [URLQueryItem] = [
                URLQueryItem(name: "IsAiring", value: "true"),
                URLQueryItem(name: "Limit", value: "120"),
                URLQueryItem(name: "fields", value: "Overview,OfficialRating,Genres,SeriesName,EpisodeTitle,RunTimeTicks,ParentIndexNumber,IndexNumber")
            ]
            if let uid = appState.user?.id { q.append(URLQueryItem(name: "userId", value: uid)) }
            comps?.queryItems = q
            guard let url = comps?.url else { return [] }
            var req = URLRequest(url: url)
            req.httpMethod = "GET"
            if !appState.accessToken.isEmpty { req.setValue(appState.accessToken, forHTTPHeaderField: "X-Emby-Token") }
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else { return [] }
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
            return []
        }
    }

    private func fetchCategory(appState: AppState, filter: FilterKind) async -> [JFProgram] {
        do {
            guard let base = URL(string: appState.serverURL)?.appendingPathComponent("/LiveTv/Programs") else { return [] }
            let now = Date()
            let start = now.addingTimeInterval(-6 * 3600)  // include currently-airing programs
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
                // Fixed Jellyfin API parameters (was startDate/endDate)
                URLQueryItem(name: "minStartDate", value: iso.string(from: start)),
                URLQueryItem(name: "maxStartDate", value: iso.string(from: end)),
                URLQueryItem(name: "Limit",        value: "250"),
                URLQueryItem(name: "fields",       value: "Overview,OfficialRating,Genres,SeriesName,EpisodeTitle,RunTimeTicks,ParentIndexNumber,IndexNumber")
            ]
            filterParam(into: &q)
            if let uid = appState.user?.id { q.append(URLQueryItem(name: "userId", value: uid)) }

            var comps = URLComponents(url: base, resolvingAgainstBaseURL: false)
            comps?.queryItems = q
            guard let url = comps?.url else { return [] }
            var req = URLRequest(url: url)
            req.httpMethod = "GET"
            if !appState.accessToken.isEmpty { req.setValue(appState.accessToken, forHTTPHeaderField: "X-Emby-Token") }
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else { return [] }
            var items = parsePrograms(data: data).filter { notEnded($0, now: Date()) }
            if debugLog { print("HomeView: fetchCategory raw count (\(filter)): \(items.count)") }

            // UTC fallback (Old Emby / Older Jellyfin servers)
            if items.isEmpty {
                var qUtc: [URLQueryItem] = [
                    URLQueryItem(name: "minStartDate", value: iso.string(from: start)),
                    URLQueryItem(name: "maxStartDate", value: iso.string(from: end)),
                    URLQueryItem(name: "Limit",        value: "250"),
                    URLQueryItem(name: "fields",       value: "Overview,OfficialRating,Genres,SeriesName,EpisodeTitle,RunTimeTicks,ParentIndexNumber,IndexNumber")
                ]
                filterParam(into: &qUtc)
                if let uid = appState.user?.id { qUtc.append(URLQueryItem(name: "userId", value: uid)) }
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


            return items.sorted { a, b in
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
            return []
        }
    }

    /// Returns true if the program hasn't fully ended yet.
    /// Uses endDate if available, falls back to start + runTimeTicks, then keeps
    /// anything with no timing info rather than silently dropping it.
    private func notEnded(_ p: JFProgram, now: Date) -> Bool {
        if let end = p.endDate { return end > now }
        if let start = p.startDate, let ticks = p.runTimeTicks {
            return start.addingTimeInterval(TimeInterval(Double(ticks) / 10_000_000.0)) > now
        }
        return true  // no timing info — don't discard
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
    init?(json: [String: Any]) {
        guard let id = json["Id"] as? String else { return nil }
        self.id = id
        self.name = (json["Name"] as? String) ?? "Channel"
    }
}

extension JFChannel {
    func asLiveDto(baseURL: String) -> LiveTvChannelDto {
        LiveTvChannelDto(id: id, name: name, number: nil, startDate: nil, endDate: nil, baseURL: baseURL)
    }
}
