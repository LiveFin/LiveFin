import SwiftUI
#if os(iOS)
import UIKit
#endif

// MARK: - Stream URL Item

struct StreamURLItem: Identifiable, Equatable {
    let id: String
    let url: URL
    init(_ url: URL) {
        self.url = url
        self.id = url.absoluteString
    }
}

// MARK: - JFProgram Model

struct JFProgram: Identifiable, Hashable {
    let id: String
    let name: String
    let overview: String?
    let startDate: Date?
    let endDate: Date?
    let channelId: String?
    let channelName: String?
    let isMovie: Bool
    let isSeries: Bool
    let isNews: Bool
    let isSports: Bool
    let isKids: Bool
    let episodeTitle: String?
    let seriesName: String?
    let runTimeTicks: Int64?
    let officialRating: String?
    let genres: [String]?
    let parentIndexNumber: Int?
    let indexNumber: Int?
    let isRepeat: Bool?
    let seriesId: String?
    let itemId: String?

    var isLikelyMovie: Bool {
        if isMovie {
            if let ep = episodeTitle, !ep.isEmpty { return false }
            if let sn = seriesName, !sn.isEmpty { return false }
            if parentIndexNumber != nil { return false }
            return true
        }
        return false
    }

    var runTimeSeconds: TimeInterval {
        if let t = runTimeTicks { return Double(t) / 10_000_000.0 } else { return 0 }
    }

    var airingKey: String {
        id + "|" + (channelId ?? "") + "|" + String(Int(startDate?.timeIntervalSince1970 ?? 0))
    }

    init?(json: [String: Any]) {
        guard let id = json["Id"] as? String ?? json["ProgramId"] as? String else { return nil }
        self.id = id
        self.name = json["Name"] as? String ?? ""
        self.overview = json["Overview"] as? String

        let isoFrac = ISO8601DateFormatter(); isoFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter(); isoPlain.formatOptions = [.withInternetDateTime]
        func trimFractionTo3(_ s: String) -> String {
            guard let dot = s.firstIndex(of: ".") else { return s }
            let afterDot = s.index(after: dot)
            let tzIndex: String.Index = {
                if let z = s[afterDot...].firstIndex(of: "Z") { return z }
                if let plus = s[afterDot...].firstIndex(of: "Z") { return plus }
                if let minus = s[afterDot...].firstIndex(of: "-") { return minus }
                return s.endIndex
            }()
            return String(s[..<dot]) + "." + String(String(s[afterDot..<tzIndex]).prefix(3)) + String(s[tzIndex...])
        }
        func parse(_ sIn: String) -> Date? {
            if let d = isoFrac.date(from: sIn) ?? isoPlain.date(from: sIn) { return d }
            let trimmed = trimFractionTo3(sIn)
            if trimmed != sIn { return isoFrac.date(from: trimmed) ?? isoPlain.date(from: trimmed) }
            return nil
        }
        if let s = (json["StartDate"] as? String) ?? (json["StartDateUtc"] as? String) ?? (json["PremiereDate"] as? String) { self.startDate = parse(s) } else { self.startDate = nil }
        if let e = (json["EndDate"] as? String) ?? (json["EndDateUtc"] as? String) { self.endDate = parse(e) } else { self.endDate = nil }
        self.channelId = json["ChannelId"] as? String
        self.channelName = json["ChannelName"] as? String
        self.isMovie = (json["IsMovie"] as? Bool) ?? false
        self.isSeries = (json["IsSeries"] as? Bool) ?? false
        self.isNews = (json["IsNews"] as? Bool) ?? false
        self.isSports = (json["IsSports"] as? Bool) ?? false
        self.isKids = (json["IsKids"] as? Bool) ?? false
        self.episodeTitle = json["EpisodeTitle"] as? String ?? json["Subtitle"] as? String
        self.seriesName = json["SeriesName"] as? String
        if let ticks = json["RunTimeTicks"] as? Int64 { self.runTimeTicks = ticks }
        else if let n = json["RunTimeTicks"] as? NSNumber { self.runTimeTicks = n.int64Value }
        else { self.runTimeTicks = nil }
        self.officialRating = json["OfficialRating"] as? String
        if let gs = json["Genres"] as? [String] { self.genres = gs }
        else if let any = json["Genres"] as? [Any] { self.genres = any.compactMap { $0 as? String } }
        else { self.genres = nil }
        if let s = json["ParentIndexNumber"] as? Int { self.parentIndexNumber = s }
        else if let ns = json["ParentIndexNumber"] as? NSNumber { self.parentIndexNumber = ns.intValue }
        else { self.parentIndexNumber = nil }
        if let e = json["IndexNumber"] as? Int { self.indexNumber = e }
        else if let ne = json["IndexNumber"] as? NSNumber { self.indexNumber = ne.intValue }
        else { self.indexNumber = nil }
        self.isRepeat = json["IsRepeat"] as? Bool
        self.seriesId = json["SeriesId"] as? String
        self.itemId = json["ItemId"] as? String
    }

    init(copying other: JFProgram, channelName: String?) {
        self.id = other.id; self.name = other.name; self.overview = other.overview
        self.startDate = other.startDate; self.endDate = other.endDate
        self.channelId = other.channelId; self.channelName = channelName ?? other.channelName
        self.isMovie = other.isMovie; self.isSeries = other.isSeries
        self.isNews = other.isNews; self.isSports = other.isSports; self.isKids = other.isKids
        self.episodeTitle = other.episodeTitle; self.seriesName = other.seriesName
        self.runTimeTicks = other.runTimeTicks; self.officialRating = other.officialRating
        self.genres = other.genres; self.parentIndexNumber = other.parentIndexNumber
        self.indexNumber = other.indexNumber; self.isRepeat = other.isRepeat
        self.seriesId = other.seriesId; self.itemId = other.itemId
    }

    static func == (lhs: JFProgram, rhs: JFProgram) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - ProgramViewModel

@MainActor
final class ProgramViewModel: ObservableObject {

    @Published var extendedUpcoming: [JFProgram] = []
    @Published var channelSchedule: [JFProgram] = []
    @Published var relatedServer: [JFProgram] = []
    @Published var loadRelatedImages: Bool = false
    @Published var resolvedChannelId: String? = nil
    @Published var resolvedChannelName: String? = nil
    @Published var isLoadingUpcoming: Bool = true
    @Published var isLoadingRelated: Bool = true
    @Published var streamItem: StreamURLItem? = nil
    @Published var playbackErrorMessage: String? = nil

    let program: JFProgram
    private let appState: AppState

    init(program: JFProgram, appState: AppState) {
        self.program = program
        self.appState = appState
    }

    var effectiveChannelId: String? { program.channelId ?? resolvedChannelId }

    var channelName: String {
        if let name = resolvedChannelName, !name.isEmpty { return name }
        if let explicit = program.channelName, !explicit.isEmpty { return explicit }
        if let cid = effectiveChannelId, let cached = appState.channelNames[cid] { return cached }
        return "Unknown Channel"
    }

    var timeLine: String {
        guard let start = program.startDate else { return "" }
        let end: Date? = {
            if let e = program.endDate { return e }
            if let ticks = program.runTimeTicks { return start.addingTimeInterval(TimeInterval(Double(ticks) / 10_000_000.0)) }
            return nil
        }()
        let dateFmt = DateFormatter(); dateFmt.dateStyle = .medium; dateFmt.timeStyle = .none
        let timeFmt = DateFormatter(); timeFmt.dateStyle = .none; timeFmt.timeStyle = .short
        if let end {
            if Calendar.current.isDate(start, inSameDayAs: end) {
                return "\(dateFmt.string(from: start)) • \(timeFmt.string(from: start)) - \(timeFmt.string(from: end))"
            } else {
                return "\(dateFmt.string(from: start)) \(timeFmt.string(from: start)) - \(dateFmt.string(from: end)) \(timeFmt.string(from: end))"
            }
        } else {
            return "\(dateFmt.string(from: start)) • \(timeFmt.string(from: start))"
        }
    }

    var progressRatio: Double? {
        guard let start = program.startDate else { return nil }
        let end: Date? = program.endDate ?? (program.runTimeTicks.map { start.addingTimeInterval(TimeInterval(Double($0) / 10_000_000.0)) })
        guard let end, start <= Date(), Date() <= end else { return nil }
        let total = end.timeIntervalSince(start); guard total > 1 else { return nil }
        return min(max(Date().timeIntervalSince(start) / total, 0), 1)
    }

    var isLive: Bool { progressRatio != nil }

    var showNew: Bool {
        let notRepeat = (program.isRepeat == false) || (program.isRepeat == nil)
        let hasEpisodeOrSeries = (program.episodeTitle?.isEmpty == false)
            || (program.seriesName?.isEmpty == false)
            || (program.parentIndexNumber != nil)
        return notRepeat && hasEpisodeOrSeries
    }

    var relatedPrograms: [JFProgram] { relatedServer }

    private var upcomingLocal: [JFProgram] {
        let now = Date()
        let targetSeries = program.seriesName?.isEmpty == false ? program.seriesName : nil
        return channelSchedule.filter { p in
            guard p.id != program.id, let start = p.startDate, start > now else { return false }
            if let ts = targetSeries { return p.seriesName == ts }
            return p.name.caseInsensitiveCompare(program.name) == .orderedSame
        }.sorted { ($0.startDate ?? .distantFuture) < ($1.startDate ?? .distantFuture) }
    }

    var combinedUpcoming: [JFProgram] {
        let all = upcomingLocal + extendedUpcoming
        guard !all.isEmpty else { return [] }
        var seen: Set<String> = []
        var result: [JFProgram] = []
        for p in all.sorted(by: { ($0.startDate ?? .distantFuture) < ($1.startDate ?? .distantFuture) }) {
            guard let start = p.startDate else { continue }
            let key = p.id + "|" + (p.channelId ?? "") + "|" + String(Int(start.timeIntervalSince1970))
            if seen.insert(key).inserted {
                result.append(p)
                if result.count >= 200 { break }
            }
        }
        return result
    }

    func chips() -> [String] {
        var arr: [String] = []
        if program.isNews { arr.append("News") }
        if program.isSports { arr.append("Sports") }
        if program.isKids { arr.append("Kids") }
        if let genres = program.genres, !genres.isEmpty { arr.append(contentsOf: genres.prefix(3)) }
        return arr
    }

    func primarySubtitleLine() -> String? {
        var parts: [String] = []
        if let s = program.parentIndexNumber, let e = program.indexNumber {
            parts.append(String(format: "S%02dE%02d", s, e))
        }
        if let ep = program.episodeTitle, !ep.isEmpty { parts.append(ep) }
        else if let series = program.seriesName, !series.isEmpty, series != program.name { parts.append(series) }
        return parts.isEmpty ? nil : parts.joined(separator: " • ")
    }

    func buildChannel() -> LiveTvChannelDto? {
        guard let cid = effectiveChannelId else { return nil }
        return LiveTvChannelDto(
            id: cid, name: channelName, number: nil,
            startDate: program.startDate, endDate: program.endDate,
            baseURL: appState.serverURL
        )
    }

    func onAppear() {
        if resolvedChannelName == nil {
            if let explicit = program.channelName, !explicit.isEmpty {
                resolvedChannelName = explicit
            } else if let cid = program.channelId, let cached = appState.channelNames[cid], !cached.isEmpty {
                resolvedChannelName = cached
                resolvedChannelId = cid
            }
        }
    }

    func load() async {
        isLoadingUpcoming = true
        isLoadingRelated = true
        loadRelatedImages = false
        extendedUpcoming = []
        channelSchedule = []
        relatedServer = []

        await ensureProgramDetails()
        await ensureChannelName()
        async let a: Void = fetchExtendedUpcoming()
        async let b: Void = fetchChannelSchedule()
        async let c: Void = fetchRelatedPrograms()
        _ = await (a, b, c)

        isLoadingUpcoming = false
        isLoadingRelated = false
    }

    func startPlayback() async {
        guard let cid = effectiveChannelId else { return }
        if let streamURLString = await JFOpenLiveStreamService.resolveStreamURL(appState: appState, channelId: cid) {
            if let url = URL(string: streamURLString) {
                appState.currentProgramTitle = program.name
                appState.currentProgramSubtitle = primarySubtitleLine()
                appState.currentProgramId = program.itemId ?? program.id
                appState.currentProgramGenres = program.genres
                appState.currentProgramIsMovie = program.isLikelyMovie
                appState.currentProgramStartDate = program.startDate
                appState.currentProgramEndDate = program.endDate
                streamItem = StreamURLItem(url)
                playbackErrorMessage = nil
            } else {
                playbackErrorMessage = "Unable to play this channel. The stream URL is invalid."
            }
        } else {
            playbackErrorMessage = "Unable to play \(channelName). No stream is available."
        }
    }

    private nonisolated func normTitle(_ s: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(.whitespaces)
        let filtered = s.lowercased().unicodeScalars.filter { allowed.contains($0) }
        return String(String.UnicodeScalarView(filtered))
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private nonisolated func fetchPrograms(serverURL: String, authHeader: String, from basePath: String = "/LiveTv/Programs", params baseParams: [URLQueryItem]) async -> [JFProgram] {
        guard !serverURL.isEmpty else { return [] }

        func attempt(_ items: [URLQueryItem]) async -> [JFProgram]? {
            guard let base = URL(string: serverURL)?.appendingPathComponent(basePath) else { return nil }
            var comps = URLComponents(url: base, resolvingAgainstBaseURL: false)
            comps?.queryItems = items
            guard let url = comps?.url else { return nil }
            var req = URLRequest(url: url); req.httpMethod = "GET"
            if !authHeader.isEmpty { req.setValue(authHeader, forHTTPHeaderField: "Authorization") }
            
            do {
                let (data, resp) = try await URLSession.shared.data(for: req)
                guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else { return nil }
                
                if let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                    return arr.compactMap { JFProgram(json: $0) }
                }
                if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    if let items = obj["Items"] as? [[String: Any]] {
                        return items.compactMap { JFProgram(json: $0) }
                    }
                    if let total = obj["TotalRecordCount"] as? Int, total == 0 {
                        return []
                    }
                    return []
                }
            } catch {
                return nil
            }
            return nil
        }

        if let list = await attempt(baseParams) { return list }
        
        if let list = await attempt(baseParams.map { qi in
            if qi.name == "MinStartDate" { return URLQueryItem(name: "StartDateUtc", value: qi.value) }
            if qi.name == "MaxStartDate" { return URLQueryItem(name: "EndDateUtc", value: qi.value) }
            return qi
        }) { return list }
        
        if let list = await attempt(baseParams.map { qi in
            if qi.name == "MinStartDate" { return URLQueryItem(name: "startDate", value: qi.value) }
            if qi.name == "MaxStartDate" { return URLQueryItem(name: "endDate", value: qi.value) }
            return qi
        }) { return list }
        
        return []
    }

    private func ensureProgramDetails() async {
        if program.channelId != nil, (program.channelName?.isEmpty == false) { return }
        guard !appState.serverURL.isEmpty,
              let url = URL(string: appState.serverURL)?.appendingPathComponent("/Items/\(program.id)") else { return }
        var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        comps?.queryItems = [URLQueryItem(name: "fields", value: "ChannelId,ChannelName,RunTimeTicks,OfficialRating,Genres,SeriesName,EpisodeTitle,ParentIndexNumber,IndexNumber,IsRepeat,SeriesId,ItemId")]
        var req = URLRequest(url: comps?.url ?? url); req.httpMethod = "GET"
        if !appState.accessToken.isEmpty { req.setValue(appState.getAuthorizationHeader(), forHTTPHeaderField: "Authorization") }
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else { return }
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let cid = obj["ChannelId"] as? String { resolvedChannelId = cid }
                if let cname = obj["ChannelName"] as? String, !cname.isEmpty {
                    resolvedChannelName = cname
                    if let cid = resolvedChannelId { appState.channelNames[cid] = cname }
                }
            }
        } catch { }
    }

    private func ensureChannelName() async {
        guard let cid = effectiveChannelId else { return }
        if let name = appState.channelNames[cid], !name.isEmpty { return }
        guard !appState.serverURL.isEmpty,
              let url = URL(string: appState.serverURL)?.appendingPathComponent("/LiveTv/Channels/\(cid)") else { return }
        var req = URLRequest(url: url); req.httpMethod = "GET"
        if !appState.accessToken.isEmpty { req.setValue(appState.getAuthorizationHeader(), forHTTPHeaderField: "Authorization") }
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else { return }
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let name = obj["Name"] as? String {
                appState.channelNames[cid] = name
                resolvedChannelName = name
            }
        } catch { }
    }

    private func fetchChannelSchedule() async {
        if !channelSchedule.isEmpty { return }
        guard let cid = effectiveChannelId, !appState.serverURL.isEmpty else {
            isLoadingUpcoming = false; return
        }
        let now = Date()
        guard let end = Calendar.current.date(byAdding: .day, value: 14, to: now) else { return }
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime]
        var params: [URLQueryItem] = [
            URLQueryItem(name: "channelIds", value: cid),
            URLQueryItem(name: "MinStartDate", value: iso.string(from: now)),
            URLQueryItem(name: "MaxStartDate", value: iso.string(from: end)),
            URLQueryItem(name: "Limit", value: "5000"),
            URLQueryItem(name: "fields", value: "Overview,OfficialRating,Genres,SeriesName,EpisodeTitle,RunTimeTicks,ParentIndexNumber,IndexNumber,ChannelId,ChannelName,IsRepeat,SeriesId,ItemId")
        ]
        if let uid = appState.user?.id { params.append(URLQueryItem(name: "userId", value: uid)) }
        
        let authHeader = appState.getAuthorizationHeader()
        let parsed = await fetchPrograms(serverURL: appState.serverURL, authHeader: authHeader, params: params)
        
        channelSchedule = parsed.filter { ($0.startDate ?? .distantPast) > now }
        isLoadingUpcoming = false
    }

    private func fetchExtendedUpcoming() async {
        if !extendedUpcoming.isEmpty { return }
        let now = Date()
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime]
        let targetSeriesId = program.seriesId
        
        let term = program.seriesName?.isEmpty == false ? program.seriesName! : program.name
        let nameKey = normTitle(program.name)
        let seriesNameKey = program.seriesName.flatMap { $0.isEmpty ? nil : normTitle($0) }
        
        let serverURL = appState.serverURL
        let authHeader = appState.getAuthorizationHeader()

        guard let endWindow = Calendar.current.date(byAdding: .day, value: 14, to: now) else { return }

        let baseParams: [URLQueryItem] = [
            URLQueryItem(name: "MinStartDate", value: iso.string(from: now)),
            URLQueryItem(name: "MaxStartDate", value: iso.string(from: endWindow)),
            URLQueryItem(name: "Limit", value: "3000"),
            URLQueryItem(name: "Fields", value: "Overview,OfficialRating,Genres,SeriesName,EpisodeTitle,RunTimeTicks,ParentIndexNumber,IndexNumber,ChannelId,ChannelName,IsRepeat,SeriesId,ItemId")
        ]

        var allFound: [JFProgram] = []

        // Prong 1: Items Search (Forces text search through EPG across networks)
        async let searchFuture: [JFProgram] = {
            var p = baseParams
            p.append(URLQueryItem(name: "SearchTerm", value: term))
            p.append(URLQueryItem(name: "IncludeItemTypes", value: "Program"))
            p.append(URLQueryItem(name: "Recursive", value: "true"))
            if let uid = appState.user?.id { p.append(URLQueryItem(name: "userId", value: uid)) }
            return await fetchPrograms(serverURL: serverURL, authHeader: authHeader, from: "/Items", params: p)
        }()

        // Prong 2: Explicit ID search (Matches native Jellyfin series linking)
        async let seriesFuture: [JFProgram] = {
            guard let sid = targetSeriesId, !sid.isEmpty else { return [] }
            var p = baseParams
            p.append(URLQueryItem(name: "SeriesId", value: sid))
            p.append(URLQueryItem(name: "librarySeriesId", value: sid))
            if let uid = appState.user?.id { p.append(URLQueryItem(name: "userId", value: uid)) }
            return await fetchPrograms(serverURL: serverURL, authHeader: authHeader, from: "/LiveTv/Programs", params: p)
        }()
        
        // Prong 3: Name fallback (In case SearchTerm is unsupported but Name works)
        async let nameFuture: [JFProgram] = {
            var p = baseParams
            p.append(URLQueryItem(name: "Name", value: term))
            if let uid = appState.user?.id { p.append(URLQueryItem(name: "userId", value: uid)) }
            return await fetchPrograms(serverURL: serverURL, authHeader: authHeader, from: "/LiveTv/Programs", params: p)
        }()

        let (res1, res2, res3) = await (searchFuture, seriesFuture, nameFuture)
        allFound.append(contentsOf: res1)
        allFound.append(contentsOf: res2)
        allFound.append(contentsOf: res3)

        // Aggressive local client filter to wipe out irrelevant/random payloads
        let matched = allFound.filter { p in
            guard let s = p.startDate, s > now else { return false }
            if p.id == program.id { return false } // Don't show current block
            
            let pName = normTitle(p.name)
            let pSeries = p.seriesName.flatMap { $0.isEmpty ? nil : normTitle($0) }
            
            if pName == nameKey { return true }
            if let csk = seriesNameKey, let psk = pSeries, csk == psk { return true }
            if let csk = seriesNameKey, pName == csk { return true }
            if let sid = targetSeriesId, !sid.isEmpty, p.seriesId == sid { return true }
            
            return false
        }

        extendedUpcoming = dedupSorted(matched)
    }

    private func scoreAndFilter(pool: [JFProgram]) -> [JFProgram] {
        let baseGenres = Set(program.genres ?? [])
        let cid = effectiveChannelId
        let currentNameKey = normTitle(program.name)
        let currentSeriesKey = program.seriesName.flatMap { $0.isEmpty ? nil : normTitle($0) }

        var scored: [(JFProgram, Int)] = []
        for p in pool where p.id != program.id {
            let pNameKey = normTitle(p.name)
            let pSeriesKey = p.seriesName.flatMap { $0.isEmpty ? nil : normTitle($0) }

            if pNameKey == currentNameKey { continue }
            if let csk = currentSeriesKey, let psk = pSeriesKey, csk == psk { continue }
            if let csk = currentSeriesKey, pNameKey == csk { continue }
            if let psk = pSeriesKey, psk == currentNameKey { continue }

            var score = 0
            if let cid, let pcid = p.channelId, cid == pcid { score += 10 }
            let overlap = baseGenres.intersection(Set(p.genres ?? []))
            if !overlap.isEmpty { score += overlap.count * 6 }
            if program.isLikelyMovie && p.isLikelyMovie { score += 2 }
            if program.isSeries && p.isSeries { score += 2 }
            if program.isNews && p.isNews { score += 12 }
            if program.isSports && p.isSports { score += 12 }
            if program.isKids && p.isKids { score += 8 }
            if score > 0 { scored.append((p, score)) }
        }

        var seen: Set<String> = []
        var seenNames: Set<String> = []
        var result: [JFProgram] = []
        
        for (p, _) in scored.sorted(by: { lhs, rhs in
            lhs.1 == rhs.1 ? (lhs.0.startDate ?? .distantFuture) < (rhs.0.startDate ?? .distantFuture) : lhs.1 > rhs.1
        }) {
            let key = p.id + "|" + (p.channelId ?? "") + "|" + String(Int(p.startDate?.timeIntervalSince1970 ?? 0))
            guard seen.insert(key).inserted else { continue }

            let displayTitle = p.seriesName?.isEmpty == false ? normTitle(p.seriesName!) : normTitle(p.name)
            guard seenNames.insert(displayTitle).inserted else { continue }

            result.append(p)
            if result.count >= 20 { break }
        }
        return result
    }

    private func fetchRelatedPrograms() async {
        let now = Date()
        guard let past = Calendar.current.date(byAdding: .hour, value: -6, to: now),
              let future = Calendar.current.date(byAdding: .day, value: 7, to: now) else { return }
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime]
        var baseParams: [URLQueryItem] = [
            URLQueryItem(name: "MinStartDate", value: iso.string(from: past)),
            URLQueryItem(name: "MaxStartDate", value: iso.string(from: future)),
            URLQueryItem(name: "Limit", value: "300"),
            URLQueryItem(name: "fields", value: "Overview,OfficialRating,Genres,SeriesName,EpisodeTitle,RunTimeTicks,ParentIndexNumber,IndexNumber,ChannelId,ChannelName,IsRepeat,SeriesId,ItemId")
        ]
        
        let serverURL = appState.serverURL
        let authHeader = appState.getAuthorizationHeader()
        
        if let uid = appState.user?.id { baseParams.append(URLQueryItem(name: "userId", value: uid)) }

        var pool: [JFProgram] = []
        let tags = chips()
        let topGenres = Array(Set(program.genres ?? [])).prefix(2)
        let cId = effectiveChannelId

        async let similarFuture = fetchSimilarRelated(serverURL: serverURL, authHeader: authHeader)

        await withTaskGroup(of: [JFProgram].self) { group in
            for tag in tags {
                group.addTask {
                    var q = baseParams
                    switch tag.lowercased() {
                    case "news": q.append(URLQueryItem(name: "isNews", value: "true"))
                    case "sports": q.append(URLQueryItem(name: "isSports", value: "true"))
                    case "kids": q.append(URLQueryItem(name: "isKids", value: "true"))
                    default: q.append(URLQueryItem(name: "genres", value: tag))
                    }
                    return await self.fetchPrograms(serverURL: serverURL, authHeader: authHeader, params: q)
                }
            }

            if !topGenres.isEmpty {
                group.addTask {
                    var q = baseParams
                    q.append(URLQueryItem(name: "genres", value: topGenres.joined(separator: ",")))
                    if self.program.isLikelyMovie { q.append(URLQueryItem(name: "IsMovie", value: "true")) }
                    if self.program.isSeries { q.append(URLQueryItem(name: "IsSeries", value: "true")) }
                    return await self.fetchPrograms(serverURL: serverURL, authHeader: authHeader, params: q)
                }
            }

            if let channelId = cId {
                group.addTask {
                    var q = baseParams; q.append(URLQueryItem(name: "channelIds", value: channelId))
                    return await self.fetchPrograms(serverURL: serverURL, authHeader: authHeader, params: q)
                }
            }

            for await results in group {
                pool.append(contentsOf: results)
                if pool.count > 40 {
                    let newScores = self.scoreAndFilter(pool: pool)
                    if newScores.count >= 8 {
                        self.relatedServer = newScores
                        self.isLoadingRelated = false
                        self.loadRelatedImages = true
                    }
                }
            }
        }

        var final = scoreAndFilter(pool: pool)
        let similar = await similarFuture
        if !similar.isEmpty {
            final.insert(contentsOf: scoreAndFilter(pool: similar), at: 0)
        }

        if final.isEmpty {
            var seen: Set<String> = []
            var fallback: [JFProgram] = []
            for p in (channelSchedule + extendedUpcoming).filter({ $0.id != program.id }).sorted(by: { ($0.startDate ?? .distantFuture) < ($1.startDate ?? .distantFuture) }) {
                let key = p.id + "|" + (p.channelId ?? "") + "|" + String(Int(p.startDate?.timeIntervalSince1970 ?? 0))
                if seen.insert(key).inserted { fallback.append(p) }
                if fallback.count >= 30 { break }
            }
            final = scoreAndFilter(pool: fallback)
        }

        var seenNames: Set<String> = []
        final = final.filter { p in
            let displayTitle = p.seriesName?.isEmpty == false ? normTitle(p.seriesName!) : normTitle(p.name)
            return seenNames.insert(displayTitle).inserted
        }

        if !final.isEmpty { relatedServer = Array(final.prefix(20)) }
        isLoadingRelated = false
        loadRelatedImages = true
    }

    private nonisolated func fetchSimilarRelated(serverURL: String, authHeader: String) async -> [JFProgram] {
        guard !serverURL.isEmpty else { return [] }
        let targetId = program.itemId ?? program.id
        guard let base = URL(string: serverURL)?.appendingPathComponent("/Items/\(targetId)/Similar") else { return [] }
        var comps = URLComponents(url: base, resolvingAgainstBaseURL: false)
        var q: [URLQueryItem] = [URLQueryItem(name: "Limit", value: "40")]
        if program.isLikelyMovie { q.append(URLQueryItem(name: "IncludeItemTypes", value: "Movie")) }
        if program.isSeries { q.append(URLQueryItem(name: "IncludeItemTypes", value: "Series,Episode")) }
        comps?.queryItems = q
        guard let url = comps?.url else { return [] }
        var req = URLRequest(url: url); req.httpMethod = "GET"
        if !authHeader.isEmpty { req.setValue(authHeader, forHTTPHeaderField: "Authorization") }
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else { return [] }
            var out: [JFProgram] = []
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let items = obj["Items"] as? [[String: Any]] { out = items.compactMap { JFProgram(json: $0) } }
            else if let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] { out = arr.compactMap { JFProgram(json: $0) } }
            
            var seen: Set<String> = []
            let nameKey = normTitle(program.name)
            let seriesKey = program.seriesName.flatMap { $0.isEmpty ? nil : normTitle($0) }
            
            return Array(out
                .filter { seen.insert($0.id).inserted }
                .filter { p in
                    let pNameKey = normTitle(p.name)
                    let pSeriesKey = p.seriesName.flatMap { $0.isEmpty ? nil : normTitle($0) }
                    if pNameKey == nameKey { return false }
                    if let csk = seriesKey, let psk = pSeriesKey, csk == psk { return false }
                    if let csk = seriesKey, pNameKey == csk { return false }
                    if let psk = pSeriesKey, psk == nameKey { return false }
                    return true
                }
                .prefix(20))
        } catch { return [] }
    }

    private func dedupSorted(_ items: [JFProgram]) -> [JFProgram] {
        var seen: Set<String> = []
        return items
            .sorted { ($0.startDate ?? .distantFuture) < ($1.startDate ?? .distantFuture) }
            .filter { p in
                let key = p.id + "|" + (p.channelId ?? "") + "|" + String(Int(p.startDate?.timeIntervalSince1970 ?? 0))
                return seen.insert(key).inserted
            }
    }
}

// MARK: - Skeleton Views

struct UpcomingSkeletonRow: View {
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(UIColor.tertiarySystemFill))
                .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 8) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(UIColor.tertiarySystemFill))
                    .frame(width: 160, height: 14)
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(UIColor.tertiarySystemFill))
                    .frame(width: 100, height: 11)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .redacted(reason: .placeholder)
    }
}

struct UpcomingSkeletonView: View {
    var body: some View {
        VStack(spacing: 0) {
            ForEach(0..<3, id: \.self) { _ in
                UpcomingSkeletonRow()
                Divider().padding(.leading, 8)
            }
        }
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(UIColor.secondarySystemBackground)))
    }
}

struct RelatedSkeletonView: View {
    private let cardWidth: CGFloat = 140
    private let cardHeight: CGFloat = 90

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(0..<4, id: \.self) { _ in
                    VStack(alignment: .leading, spacing: 6) {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color(UIColor.tertiarySystemFill))
                            .frame(width: cardWidth, height: cardHeight)
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color(UIColor.tertiarySystemFill))
                            .frame(width: cardWidth * 0.7, height: 11)
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color(UIColor.tertiarySystemFill))
                            .frame(width: cardWidth * 0.5, height: 10)
                    }
                    .redacted(reason: .placeholder)
                }
            }
            .padding(.horizontal, 2)
        }
    }
}

// MARK: - Reusable UI Components

struct LiveBadge: View {
    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(Color.red).frame(width: 10, height: 10)
            Text("LIVE").font(.caption).foregroundColor(.red).bold()
        }
    }
}

struct UpcomingProgramRow: View {
    let program: JFProgram
    let referenceName: String
    let referenceStart: Date?
    @EnvironmentObject private var appState: AppState

    @State private var fetchedChannelName: String? = nil

    private var showName: Bool { program.name.caseInsensitiveCompare(referenceName) != .orderedSame }
    private var seasonEpisode: String? {
        if let s = program.parentIndexNumber, let e = program.indexNumber { return String(format: "S%02dE%02d", s, e) }
        return nil
    }
    private var subtitle: String? {
        if let ep = program.episodeTitle, !ep.isEmpty { return ep }
        if let series = program.seriesName, !series.isEmpty, series != program.name { return series }
        return nil
    }
    
    private var displayChannelName: String? {
        if let name = program.channelName, !name.isEmpty { return name }
        if let id = program.channelId, let cached = appState.channelNames[id], !cached.isEmpty { return cached }
        return fetchedChannelName
    }
    
    private var showNew: Bool {
        let notRepeat = (program.isRepeat == false) || (program.isRepeat == nil)
        let hasEpisodeOrSeries = (program.episodeTitle?.isEmpty == false)
            || (program.seriesName?.isEmpty == false)
            || (program.parentIndexNumber != nil)
        return notRepeat && hasEpisodeOrSeries
    }
    @ViewBuilder private var newBadge: some View {
        Text("New").font(.caption2).foregroundColor(.white)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Color.blue).cornerRadius(4)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if let cid = program.channelId {
                ChannelImageView(baseUrl: appState.serverURL, apiKey: appState.apiKey, channelId: cid)
                    .frame(width: 44, height: 44)
            } else {
                Color.clear.frame(width: 44, height: 44)
            }
            VStack(alignment: .leading, spacing: 4) {
                if showName {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(program.name).font(.headline).lineLimit(2)
                        if showNew { newBadge }
                    }
                } else if showNew { newBadge }
                let lineParts = [seasonEpisode, subtitle].compactMap { $0 }
                if !lineParts.isEmpty {
                    Text(lineParts.joined(separator: " • "))
                        .font(.subheadline).foregroundColor(.secondary).lineLimit(2)
                }
                if let s = program.startDate {
                    let e = program.endDate ?? program.startDate?.addingTimeInterval(program.runTimeSeconds)
                    let includeDate: Bool = {
                        if let ref = referenceStart, !Calendar.current.isDate(s, inSameDayAs: ref) { return true }
                        if let e, !Calendar.current.isDate(s, inSameDayAs: e) { return true }
                        return false
                    }()
                    if let e {
                        Text(includeDate
                             ? "\(s.formatted(date: .abbreviated, time: .shortened)) - \(e.formatted(date: .abbreviated, time: .shortened))"
                             : "\(s.formatted(date: .omitted, time: .shortened)) - \(e.formatted(date: .omitted, time: .shortened))")
                            .font(.caption).foregroundColor(.secondary)
                    } else {
                        Text(includeDate
                             ? s.formatted(date: .abbreviated, time: .shortened)
                             : s.formatted(date: .omitted, time: .shortened))
                            .font(.caption).foregroundColor(.secondary)
                    }
                }
                if let cn = displayChannelName, !cn.isEmpty {
                    Text(cn).font(.caption2).foregroundColor(.secondary)
                }
            }
            Spacer()
            if (program.startDate ?? .distantPast) > Date() {
                Image(systemName: "chevron.right").font(.caption).foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .task(id: program.channelId) {
            await fetchMissingChannelName()
        }
    }
    
    private func fetchMissingChannelName() async {
        guard let cid = program.channelId else { return }
        if program.channelName?.isEmpty == false { return }
        if appState.channelNames[cid] != nil { return }
        
        guard !appState.serverURL.isEmpty,
              let url = URL(string: appState.serverURL)?.appendingPathComponent("/LiveTv/Channels/\(cid)") else { return }
        var req = URLRequest(url: url); req.httpMethod = "GET"
        if !appState.accessToken.isEmpty { req.setValue(appState.getAuthorizationHeader(), forHTTPHeaderField: "Authorization") }
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else { return }
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let name = obj["Name"] as? String {
                await MainActor.run {
                    appState.channelNames[cid] = name
                    self.fetchedChannelName = name
                }
            }
        } catch { }
    }
}

struct RelatedProgramCard: View {
    let program: JFProgram
    let loadImages: Bool
    @EnvironmentObject private var appState: AppState
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass: UserInterfaceSizeClass?
    #if os(iOS)
    private var isiPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }
    #else
    private var isiPad: Bool { false }
    #endif
    private var isiPadOrMac: Bool {
        #if os(macOS) || targetEnvironment(macCatalyst)
        return true
        #else
        return isiPad || horizontalSizeClass == .regular
        #endif
    }
    private var isMovie: Bool { program.isLikelyMovie }
    private var imageWidth: CGFloat { isMovie ? 120 : 220 }
    private var imageHeight: CGFloat { isMovie ? 180 : 124 }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                if loadImages, let url = imageURL() {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .empty: ZStack { Color(UIColor.secondarySystemBackground); ProgressView() }
                        case .success(let img):
                            ZStack {
                                // 1. Blurred background filling the box
                                img.resizable().scaledToFill()
                                    .frame(width: imageWidth, height: imageHeight)
                                    .blur(radius: 15)
                                    .opacity(0.6)
                                    .clipped()
                                
                                // 2. The actual image fitted cleanly inside the box
                                img.resizable().scaledToFit()
                                    .frame(width: imageWidth, height: imageHeight)
                            }
                        case .failure: placeholder
                        @unknown default: placeholder
                        }
                    }
                } else { placeholder }
            }
            .frame(width: imageWidth, height: imageHeight)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            Text(program.name).font(.caption).lineLimit(2).frame(width: imageWidth, alignment: .leading)
            if let ep = program.episodeTitle, !ep.isEmpty, !isMovie {
                Text(ep).font(.caption2).foregroundColor(.secondary).lineLimit(1)
            }
        }
        .frame(width: imageWidth)
    }
    private var placeholder: some View {
        ZStack { Color(UIColor.secondarySystemBackground); Image(systemName: "film").foregroundColor(.secondary) }
    }
    private func imageURL() -> URL? {
        guard !appState.serverURL.isEmpty, !appState.apiKey.isEmpty else { return nil }
        let base = appState.serverURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var comps = URLComponents(string: base + "/Items/\(program.id)/Images/Primary")
        #if os(macOS)
        let maxWidth = isMovie ? "1200" : "800"
        #elseif targetEnvironment(macCatalyst)
        let maxWidth = isMovie ? "1000" : "700"
        #else
        let maxWidth = (UIDevice.current.userInterfaceIdiom == .pad) ? "700" : (isMovie ? "600" : "600")
        #endif
        comps?.queryItems = [
            URLQueryItem(name: "maxWidth", value: maxWidth),
            URLQueryItem(name: "ApiKey", value: appState.apiKey)
        ]
        return comps?.url
    }
}

struct ProgramDetailImage: View {
    let program: JFProgram
    let refreshSeed: Int
    let preferredWidth: Int?
    @EnvironmentObject private var appState: AppState
    @Environment(\.displayScale) private var displayScale
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass: UserInterfaceSizeClass?
    #if os(iOS)
    private var isiPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }
    #else
    private var isiPad: Bool { false }
    #endif
    private var isiPadOrMac: Bool {
        #if os(macOS) || targetEnvironment(macCatalyst)
        return true
        #else
        return isiPad || horizontalSizeClass == .regular
        #endif
    }

    var body: some View {
        GeometryReader { geo in
            let baseWidth = (preferredWidth != nil && preferredWidth! > 0) ? preferredWidth! : max(200, Int(geo.size.width))
            let requestedMaxWidth = max(200, Int(Double(baseWidth) * max(displayScale, 1.0) * 1.2))
            if let url = imageURL(maxWidth: requestedMaxWidth) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .empty:
                        ZStack { ProgressView() }
                            .frame(width: geo.size.width, height: geo.size.height)
                            .background(Color(UIColor.secondarySystemBackground))
                    case .success(let img):
                        ZStack {
                            // 1. Massive blurred background for the main header poster
                            img.resizable().scaledToFill()
                                .frame(width: geo.size.width, height: geo.size.height)
                                .blur(radius: 30)
                                .opacity(0.6)
                                .clipped()
                            
                            // 2. The crisp, perfectly fitted poster/thumbnail
                            img.resizable().scaledToFit()
                                .frame(width: geo.size.width, height: geo.size.height)
                        }
                    case .failure:
                        placeholder.frame(width: geo.size.width, height: geo.size.height)
                    @unknown default:
                        placeholder.frame(width: geo.size.width, height: geo.size.height)
                    }
                }
            } else {
                placeholder.frame(width: geo.size.width, height: geo.size.height)
            }
        }
    }
    private var placeholder: some View {
        ZStack { Image(systemName: "film").imageScale(.large).foregroundColor(.secondary) }
            .background(Color(UIColor.secondarySystemBackground))
    }
    private func imageURL(maxWidth: Int = 800) -> URL? {
        guard !appState.serverURL.isEmpty, !appState.apiKey.isEmpty else { return nil }
        let base = appState.serverURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var comps = URLComponents(string: base + "/Items/\(program.id)/Images/Primary")
        comps?.queryItems = [
            URLQueryItem(name: "maxWidth", value: String(maxWidth)),
            URLQueryItem(name: "ApiKey", value: appState.apiKey),
            URLQueryItem(name: "t", value: String(Int(Date().timeIntervalSince1970))),
            URLQueryItem(name: "seed", value: String(refreshSeed))
        ]
        return comps?.url
    }
}
