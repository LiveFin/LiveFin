//
//  GuideView.swift
//  LiveFin
//

import SwiftUI
import Foundation

#if canImport(UIKit)
import UIKit
#endif

// Timeline layout constants
private let pxPerMinute: CGFloat = 6
private let channelLabelWidth: CGFloat = 86
private let rowHeight: CGFloat = 72
private let headerHeight: CGFloat = 28

// Caching TTLs (in seconds)
private let channelsCacheTTL: TimeInterval = 3600 // 1h
private let epgCacheTTL: TimeInterval = 30 * 60

// Cache pruning horizon (in days)
private let epgKeepDays: Int = 14

// MARK: - Helpers
private func startOfDay(_ date: Date) -> Date { Calendar.current.startOfDay(for: date) }
private func endOfDay(_ date: Date) -> Date { Calendar.current.date(byAdding: .day, value: 1, to: startOfDay(date)) ?? date.addingTimeInterval(24*3600) }

private struct LiveTvChannelsResponse: Codable { let items: [LiveTvChannelDto]?; enum CodingKeys: String, CodingKey { case items = "Items" } }
private struct EPGProgramsResponse: Codable { let items: [BaseItemDto]?; enum CodingKeys: String, CodingKey { case items = "Items" } }

// Cache definitions
private let guideCacheFolder = "GuideCache"
private let epgFilePrefix = "epg_day_"
private let epgFileExt = ".json"
private let channelsCacheFile = "channels.json"

#if canImport(UIKit)
private func guideBuildChannelLogoURL(baseURL: String, apiKey: String, channelId: String) -> URL? {
    let trimmed = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    let path = "/Items/\(channelId)/Images/Primary?maxWidth=200&api_key=\(apiKey)"
    return URL(string: trimmed + path)
}

private func guidePrefetchChannelLogos(_ channels: [LiveTvChannelDto], baseURL: String, apiKey: String) {
    let slice = channels.prefix(80)
    for ch in slice {
        guard let url = guideBuildChannelLogoURL(baseURL: baseURL, apiKey: apiKey, channelId: ch.id) else { continue }
        ImageCacheManager.shared.load(url) { _ in /* warm cache */ }
    }
}
#endif

private func guideCacheDirectory() throws -> URL {
    let fm = FileManager.default
    let base = try fm.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    let dir = base.appendingPathComponent(guideCacheFolder, isDirectory: true)
    if !fm.fileExists(atPath: dir.path) {
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    return dir
}

private func channelsCacheURL() throws -> URL { try guideCacheDirectory().appendingPathComponent(channelsCacheFile) }
private func epgCacheURL(forDayKey key: String) throws -> URL { try guideCacheDirectory().appendingPathComponent(epgFilePrefix + key + epgFileExt) }

private let dayFileFormatter: DateFormatter = {
    let df = DateFormatter()
    df.calendar = Calendar(identifier: .gregorian)
    df.locale = Locale(identifier: "en_US_POSIX")
    df.timeZone = .current
    df.dateFormat = "yyyy-MM-dd"
    return df
}()

private func dayKey(from date: Date) -> String { dayFileFormatter.string(from: startOfDay(date)) }
private func dateFromDayKey(_ key: String) -> Date? { dayFileFormatter.date(from: key) }

private let iso8601WithFractional: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()
private let iso8601Basic: ISO8601DateFormatter = ISO8601DateFormatter()
private let iso8601InternetDateTime: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f
}()

private let hourTickFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm"
    return f
}()

private let dayLabelFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateStyle = .medium
    f.timeStyle = .none
    return f
}()

private func formatDayLabel(_ d: Date) -> String {
    let cal = Calendar.current
    if cal.isDateInToday(d) { return "Today" }
    if cal.isDateInTomorrow(d) { return "Tomorrow" }
    return dayLabelFormatter.string(from: d)
}

private struct ChannelCacheFile: Codable { let timestamp: Date; let items: [LiveTvChannelDto] }
private struct EPGCacheFile: Codable { let dayKey: String; let timestamp: Date; let items: [BaseItemDto] }

// MARK: - Pure EPG layout helpers
private func epgClampedRange(for item: BaseItemDto, baseStart: Date, dayEnd: Date, grouped: [String: [BaseItemDto]]) -> (Date, Date) {
    let s0 = item.startDate ?? baseStart
    let inferredEnd: Date = {
        if let ed = item.endDate { return ed }
        let cid = item.channelId ?? ""
        if let list = grouped[cid],
           let next = list.first(where: { ($0.startDate ?? .distantPast) > s0 }) {
            return next.startDate ?? Calendar.current.date(byAdding: .minute, value: 30, to: s0) ?? s0.addingTimeInterval(1800)
        }
        return Calendar.current.date(byAdding: .minute, value: 30, to: s0) ?? s0.addingTimeInterval(1800)
    }()
    
    if inferredEnd <= baseStart { return (baseStart, baseStart) }
    if s0 >= dayEnd { return (dayEnd, dayEnd) }
    
    let s = max(s0, baseStart)
    let e = min(inferredEnd, dayEnd)
    return (s, max(s, e))
}

private func epgStabilizeItems(_ items: [BaseItemDto], baseStart: Date, dayEnd: Date, grouped: [String: [BaseItemDto]]) -> [BaseItemDto] {
    struct Candidate { let item: BaseItemDto; let s: Date; let e: Date; let duration: TimeInterval }
    
    let candidates: [Candidate] = items.compactMap { item in
        let (s, e) = epgClampedRange(for: item, baseStart: baseStart, dayEnd: dayEnd, grouped: grouped)
        if e.timeIntervalSince(s) < 60 { return nil }
        return Candidate(item: item, s: s, e: e, duration: e.timeIntervalSince(s))
    }
    
    let sorted = candidates.sorted {
        if abs($0.s.timeIntervalSince($1.s)) < 120 { return $0.duration > $1.duration }
        return $0.s < $1.s
    }
    
    var out: [Candidate] = []
    for cur in sorted {
        var isDuplicateStart = false
        if let last = out.last {
            if abs(cur.s.timeIntervalSince(last.s)) < 120 { isDuplicateStart = true }
        }
        if !isDuplicateStart { out.append(cur) }
    }
    return out.map { $0.item }
}

private func epgComputeRenderBlocks(_ items: [BaseItemDto], channelId: String, baseStart: Date, dayEnd: Date, visibleWidth: CGFloat, grouped: [String: [BaseItemDto]]) -> [RenderBlock] {
    struct Pre { let key: String; let item: BaseItemDto; let s: Date; let e: Date; let x: CGFloat; let w: CGFloat }
    
    let pres: [Pre] = items.compactMap { it in
        let (s, e) = epgClampedRange(for: it, baseStart: baseStart, dayEnd: dayEnd, grouped: grouped)
        if e.timeIntervalSince(s) < 60 { return nil }
        let x = CGFloat(s.timeIntervalSince(baseStart) / 60) * pxPerMinute
        let w = CGFloat(e.timeIntervalSince(s) / 60) * pxPerMinute
        let key = (it.id ?? "") + "|\(Int(s.timeIntervalSince1970))|\(Int(e.timeIntervalSince1970))"
        return Pre(key: key, item: it, s: s, e: e, x: x, w: w)
    }
    
    let sortedPres = pres.sorted { $0.x < $1.x }
    
    var out: [RenderBlock] = []
    let gap: CGFloat = 2
    let minDrawWidth: CGFloat = 6
    
    for (idx, cur) in sortedPres.enumerated() {
        var finalW = cur.w
        if idx + 1 < sortedPres.count {
            let nextX = sortedPres[idx + 1].x
            if nextX > cur.x { finalW = min(finalW, nextX - cur.x) }
        }
        finalW -= gap
        if finalW >= minDrawWidth {
            out.append(RenderBlock(id: cur.key, item: cur.item, s: cur.s, e: cur.e, x: cur.x, w: finalW))
        }
    }
    return out
}

private func channelNumericComponents(_ number: String?) -> [Int] {
    guard let number, !number.isEmpty else { return [Int.max] }
    let parts = number.split { !$0.isNumber }
    if parts.isEmpty { return [Int.max] }
    return parts.map { Int($0) ?? Int.max }
}

private nonisolated func channelLessThan(_ a: LiveTvChannelDto, _ b: LiveTvChannelDto) -> Bool {
    let aFav = a.userData?.isFavorite == true
    let bFav = b.userData?.isFavorite == true
    if aFav != bFav { return aFav }
    
    let aNum = a.number ?? ""; let bNum = b.number ?? ""
    let aHas = !aNum.isEmpty; let bHas = !bNum.isEmpty
    if aHas != bHas { return aHas }
    let ac = channelNumericComponents(aNum); let bc = channelNumericComponents(bNum)
    if ac != bc { return ac.lexicographicallyPrecedes(bc) }
    return (a.name ?? "") < (b.name ?? "")
}

// MARK: - App-Wide Cache Manager
@MainActor
class GuideViewModel: ObservableObject {
    static let shared = GuideViewModel()
    
    @Published var channels: [LiveTvChannelDto] = []
    @Published var sortedChannels: [LiveTvChannelDto] = []
    
    @Published var groupedPrograms: [Date: [String: [BaseItemDto]]] = [:]
    @Published var renderBlocks: [Date: [String: [RenderBlock]]] = [:]
    
    @Published var isLoading: Bool = false
    @Published var isRefreshing: Bool = false
    @Published var errorMessage: String?
    
    private var hasLoadedChannels = false
    private var fetchingDays: Set<Date> = []
    private var collapseTasks: [Date: Task<[String: [RenderBlock]], Never>] = [:]
    
    private init() {}
    
    func start(appState: AppState, baseStart: Date, visibleWidth: CGFloat) async {
        // Step 1: Instantly load from cache
        if !hasLoadedChannels {
            hasLoadedChannels = await loadChannelsFromCache()
        }
        
        let today = startOfDay(Date())
        if groupedPrograms[today] == nil {
            _ = await loadProgramsFromCache(for: today)
        }
        
        // Immediately render UI from cached data
        await scheduleCollapsePrograms(for: today, baseStart: baseStart, visibleWidth: visibleWidth)
        
        // Step 2: Background refresh data
        Task.detached {
            await self.loadChannels(appState: appState)
            
            if !self.epgCacheIsFresh(for: today) {
                await self.fetchEPG(for: today, appState: appState, updateUI: false)
                await self.scheduleCollapsePrograms(for: today, baseStart: baseStart, visibleWidth: visibleWidth)
            }
            
            await self.prefetchAdjacentDays(around: today, appState: appState)
            self.pruneOldEPGCacheFiles()
        }
    }
    
    func switchDay(_ day: Date, appState: AppState, visibleWidth: CGFloat, baseStart: Date) async {
        if groupedPrograms[day] == nil {
            _ = await loadProgramsFromCache(for: day)
        }
        
        if renderBlocks[day] == nil {
            await scheduleCollapsePrograms(for: day, baseStart: baseStart, visibleWidth: visibleWidth)
        }
        
        if !epgCacheIsFresh(for: day) {
            Task {
                await fetchEPG(for: day, appState: appState, updateUI: false)
                await scheduleCollapsePrograms(for: day, baseStart: baseStart, visibleWidth: visibleWidth)
            }
        }
        Task { await prefetchAdjacentDays(around: day, appState: appState) }
    }
    
    func manualRefresh(appState: AppState, currentDay: Date, baseStart: Date, visibleWidth: CGFloat) async {
        isRefreshing = true
        try? FileManager.default.removeItem(at: channelsCacheURL())
        if let url = try? epgCacheFileURL(for: currentDay) {
            try? FileManager.default.removeItem(at: url)
        }
        
        groupedPrograms[currentDay] = nil
        renderBlocks[currentDay] = nil
        
        async let c: () = loadChannels(appState: appState)
        async let e: () = fetchEPG(for: currentDay, appState: appState, updateUI: true)
        _ = await (c, e)
        
        await scheduleCollapsePrograms(for: currentDay, baseStart: baseStart, visibleWidth: visibleWidth)
        isRefreshing = false
    }
    
    func scheduleCollapsePrograms(for day: Date, baseStart: Date, visibleWidth: CGFloat) async {
        collapseTasks[day]?.cancel()
        
        let channelsSnapshot = self.sortedChannels
        let groupedSnapshot = self.groupedPrograms[day] ?? [:]
        let dayEnd = endOfDay(day)
        
        let task = Task.detached(priority: .userInitiated) {
            var newBlocks: [String: [RenderBlock]] = [:]
            for ch in channelsSnapshot {
                let items = groupedSnapshot[ch.id] ?? []
                if items.isEmpty { continue }
                let collapsed = epgStabilizeItems(items, baseStart: baseStart, dayEnd: dayEnd, grouped: groupedSnapshot)
                newBlocks[ch.id] = epgComputeRenderBlocks(
                    collapsed, channelId: ch.id, baseStart: baseStart, dayEnd: dayEnd,
                    visibleWidth: visibleWidth, grouped: groupedSnapshot)
            }
            return newBlocks
        }
        
        collapseTasks[day] = task
        let result = await task.value
        
        if !task.isCancelled {
            self.renderBlocks[day] = result
        }
    }

    func fetchEPG(for day: Date, appState: AppState, updateUI: Bool) async {
        guard let client = appState.client, !appState.accessToken.isEmpty else { return }
        if updateUI && groupedPrograms[day] == nil { isLoading = true }
        errorMessage = nil
        
        do {
            let start = startOfDay(day)
            let end = endOfDay(day)
            
            let programBase = client.configuration.url.appendingPathComponent("/LiveTv/Programs")
            var comps = URLComponents(url: programBase, resolvingAgainstBaseURL: false)
            comps?.queryItems = [
                URLQueryItem(name: "startDate", value: iso8601Basic.string(from: start)),
                URLQueryItem(name: "endDate", value: iso8601Basic.string(from: end)),
                URLQueryItem(name: "EnableImages", value: "false"),
                URLQueryItem(name: "EnableUserData", value: "true"),
                URLQueryItem(name: "fields", value: "Overview,OfficialRating,Genres,SeriesName,EpisodeTitle,ParentIndexNumber,IndexNumber,IsRepeat,IsMovie,ImageTags,ChannelId,ProgramId,TimerId,SeriesTimerId,SeriesId,IsSeries")
            ]
            if !appState.userID.isEmpty { comps?.queryItems?.append(URLQueryItem(name: "userId", value: appState.userID)) }
            guard let final = comps?.url else { return }
            
            var req = URLRequest(url: final)
            req.httpMethod = "GET"
            req.cachePolicy = .reloadIgnoringLocalCacheData
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            
            // Standard Authorization header (Jellyfin v12+ compatible)
            req.setValue("MediaBrowser Token=\"\(appState.accessToken)\"", forHTTPHeaderField: "Authorization")

            let dec = JSONDecoder()
            dec.dateDecodingStrategy = .custom { d in
                let c = try d.singleValueContainer(); let s = try c.decode(String.self)
                if let dt = iso8601WithFractional.date(from: s) { return dt }
                if let dt2 = iso8601Basic.date(from: s) { return dt2 }
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "Cannot parse date: \(s)")
            }

            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                throw NSError(domain: "", code: 0, userInfo: [NSLocalizedDescriptionKey: "Failed to fetch EPG"])
            }
            
            let decoded = try await Task.detached(priority: .userInitiated) {
                return try dec.decode(EPGProgramsResponse.self, from: data)
            }.value

            let items = decoded.items ?? []
            let newGrouped = await backgroundProcessAndGroup(programs: items, for: day)
            
            self.groupedPrograms[day] = newGrouped
            try? saveEPGToCache(for: day, items: items)
            
        } catch {
            if updateUI { self.errorMessage = error.localizedDescription }
        }
        if updateUI { isLoading = false }
    }

    private func loadChannels(appState: AppState) async {
        guard let client = appState.client, !appState.accessToken.isEmpty else { return }
        do {
            var urlComponents = URLComponents(url: client.configuration.url.appendingPathComponent("/LiveTv/Channels"), resolvingAgainstBaseURL: false)
            urlComponents?.queryItems = [
                URLQueryItem(name: "EnableUserData", value: "true"),
                URLQueryItem(name: "userId", value: appState.userID)
            ]
            guard let finalUrl = urlComponents?.url else { return }
            var req = URLRequest(url: finalUrl)
            req.httpMethod = "GET"
            req.cachePolicy = .reloadIgnoringLocalCacheData
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            
            // Standard Authorization header
            req.setValue("MediaBrowser Token=\"\(appState.accessToken)\"", forHTTPHeaderField: "Authorization")
            
            let (data, _) = try await URLSession.shared.data(for: req)
            let decoded = try JSONDecoder().decode(LiveTvChannelsResponse.self, from: data)
            let rawList = decoded.items ?? []
            let list = await Task.detached(priority: .userInitiated) { rawList.sorted(by: channelLessThan) }.value
            
            self.channels = list
            self.sortedChannels = list
            try? saveChannelsToCache(list)
            #if canImport(UIKit)
            guidePrefetchChannelLogos(list, baseURL: appState.serverURL, apiKey: appState.apiKey)
            #endif
        } catch {
            self.errorMessage = error.localizedDescription
        }
    }

    private func loadChannelsFromCache() async -> Bool {
        do {
            let url = try channelsCacheURL()
            let list = try await Task.detached(priority: .utility) {
                let data = try Data(contentsOf: url)
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let decoded = try decoder.decode(ChannelCacheFile.self, from: data)
                return decoded.items.sorted(by: channelLessThan)
            }.value
            self.channels = list
            self.sortedChannels = list
            return true
        } catch { return false }
    }

    private func loadProgramsFromCache(for day: Date) async -> Bool {
        do {
            let key = dayKey(from: day)
            let url = try epgCacheURL(forDayKey: key)
            let decoded = try await Task.detached(priority: .userInitiated) {
                let data = try Data(contentsOf: url)
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                return try decoder.decode(EPGCacheFile.self, from: data)
            }.value
            
            let grouped = await backgroundProcessAndGroup(programs: decoded.items, for: day)
            self.groupedPrograms[day] = grouped
            return true
        } catch { return false }
    }

    private func backgroundProcessAndGroup(programs: [BaseItemDto], for day: Date) async -> [String: [BaseItemDto]] {
        let start = startOfDay(day); let end = endOfDay(day)
        return await Task.detached(priority: .userInitiated) {
            let filtered = programs.filter { p in
                let s0 = p.startDate ?? start
                let defaultEnd = Calendar.current.date(byAdding: .minute, value: 30, to: s0) ?? s0.addingTimeInterval(30 * 60)
                let s = max(s0, start); let e = min(p.endDate ?? defaultEnd, end)
                return e > start && s < end
            }
            var grouped = Dictionary(grouping: filtered, by: { $0.channelId ?? "" })
            for (k, v) in grouped {
                grouped[k] = v.sorted { ($0.startDate ?? start) < ($1.startDate ?? start) }
            }
            return grouped
        }.value
    }

    private func prefetchAdjacentDays(around day: Date, appState: AppState) async {
        let cal = Calendar.current
        let offsets = [-1, 1, 2]
        
        var daysToFetch: [Date] = []
        for off in offsets {
            if let d = cal.date(byAdding: .day, value: off, to: day) {
                let sd = startOfDay(d)
                if !epgCacheIsFresh(for: d) && !fetchingDays.contains(sd) {
                    fetchingDays.insert(sd)
                    daysToFetch.append(d)
                }
            }
        }
        
        await withTaskGroup(of: Void.self) { group in
            for d in daysToFetch {
                group.addTask {
                    await self.fetchEPG(for: d, appState: appState, updateUI: false)
                    await MainActor.run {
                        self.fetchingDays.remove(startOfDay(d))
                    }
                }
            }
        }
    }

    nonisolated private func saveChannelsToCache(_ items: [LiveTvChannelDto]) throws {
        let payload = ChannelCacheFile(timestamp: Date(), items: items)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(payload)
        try data.write(to: try channelsCacheURL(), options: [.atomic])
    }

    nonisolated private func saveEPGToCache(for day: Date, items: [BaseItemDto]) throws {
        let payload = EPGCacheFile(dayKey: dayKey(from: day), timestamp: Date(), items: items)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(payload)
        let url = try epgCacheURL(forDayKey: payload.dayKey)
        Task.detached(priority: .utility) { try? data.write(to: url, options: [.atomic]) }
    }
    
    nonisolated private func epgCacheIsFresh(for day: Date) -> Bool {
        guard let url = try? epgCacheURL(forDayKey: dayKey(from: day)),
              let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modified = attrs[.modificationDate] as? Date else { return false }
        return Date().timeIntervalSince(modified) < epgCacheTTL
    }
    
    nonisolated private func pruneOldEPGCacheFiles() {
        do {
            let dir = try guideCacheDirectory()
            let fm = FileManager.default
            let files = try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            let horizon = startOfDay(Date())
            for url in files where url.lastPathComponent.hasPrefix(epgFilePrefix) && url.pathExtension == "json" {
                let name = url.deletingPathExtension().lastPathComponent
                let key = String(name.dropFirst(epgFilePrefix.count))
                if let d = dateFromDayKey(key), startOfDay(d) < horizon {
                    try? fm.removeItem(at: url)
                }
            }
        } catch { }
    }
    
    nonisolated func epgCacheFileURL(for day: Date) throws -> URL {
        return try epgCacheURL(forDayKey: dayKey(from: day))
    }
}


// MARK: - Main Guide View
struct GuideView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var vm = GuideViewModel.shared

    @State private var selectedDay: Date = startOfDay(Date())
    @State private var nowTick: Date = Date()
    @State private var cachedHourBoundaries: [Date] = []
    @State private var cachedHourBoundariesKey: Date = .distantPast

    private var availableDaysSorted: [Date] {
        let cal = Calendar.current
        let today = startOfDay(Date())
        return (0..<7).compactMap { cal.date(byAdding: .day, value: $0, to: today) }
    }

    private func computeBaseStart(for time: Date, day: Date) -> Date {
        let startD = startOfDay(day)
        guard Calendar.current.isDateInToday(day) else { return startD }
        let cal = Calendar.current
        let comps = cal.dateComponents([.year, .month, .day, .hour, .minute], from: time)
        
        var newComps = DateComponents()
        newComps.year = comps.year
        newComps.month = comps.month
        newComps.day = comps.day
        newComps.hour = comps.hour
        newComps.minute = (comps.minute ?? 0) >= 30 ? 30 : 0
        newComps.second = 0
        newComps.nanosecond = 0
        
        let aligned = cal.date(from: newComps) ?? time
        return max(startD, aligned)
    }
    
    private var baseStart: Date { computeBaseStart(for: nowTick, day: selectedDay) }
    private var visibleMinutes: Double { endOfDay(selectedDay).timeIntervalSince(baseStart) / 60.0 }
    private var visibleWidth: CGFloat { CGFloat(visibleMinutes) * pxPerMinute }
    
    private var nowX: CGFloat? {
        guard Calendar.current.isDateInToday(selectedDay) else { return nil }
        let now = nowTick
        if now <= baseStart || now >= endOfDay(selectedDay) { return nil }
        let mins = now.timeIntervalSince(baseStart) / 60.0
        return CGFloat(mins) * pxPerMinute
    }

    var body: some View {
        NavigationStack {
            Group {
                if vm.isLoading && vm.channels.isEmpty {
                    ProgressView("Loading Guide…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let msg = vm.errorMessage {
                    VStack(spacing: 16) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 48))
                            .foregroundColor(.orange)
                        
                        VStack(spacing: 8) {
                            Text("Unable to Load Guide")
                                .font(.title3.bold())
                            Text(msg)
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal)
                        }
                        
                        Button {
                            Task {
                                await vm.start(appState: appState, baseStart: baseStart, visibleWidth: visibleWidth)
                                await vm.switchDay(selectedDay, appState: appState, visibleWidth: visibleWidth, baseStart: baseStart)
                            }
                        } label: {
                            Text("Try Again")
                                .fontWeight(.semibold)
                                .padding(.horizontal, 24)
                                .padding(.vertical, 12)
                                .background(Color.accentColor)
                                .foregroundColor(.white)
                                .clipShape(Capsule())
                        }
                        .padding(.top, 8)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if vm.channels.isEmpty {
                    Text("No channels available").foregroundColor(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    VStack(spacing: 0) {
                        HStack(spacing: 0) {
                            ScrollViewReader { proxy in
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 8) {
                                        ForEach(availableDaysSorted, id: \.self) { day in
                                            let isSel = Calendar.current.isDate(day, inSameDayAs: selectedDay)
                                            Button {
                                                selectedDay = day
                                            } label: {
                                                if #available(iOS 26.0, *) {
                                                    Text(formatDayLabel(day))
                                                        .font(.footnote)
                                                        .padding(.horizontal, 12).padding(.vertical, 6)
                                                        .background(isSel ? Color.accentColor : Color(.secondarySystemBackground))
                                                        .foregroundColor(isSel ? .white : .primary)
                                                        .clipShape(Capsule())
                                                        .glassEffect()
                                                } else {
                                                    Text(formatDayLabel(day))
                                                        .font(.footnote)
                                                        .padding(.horizontal, 12).padding(.vertical, 6)
                                                        .background(isSel ? Color.accentColor : Color(.secondarySystemBackground))
                                                        .foregroundColor(isSel ? .white : .primary)
                                                        .clipShape(Capsule())
                                                }
                                            }
                                            .buttonStyle(.plain)
                                            .id(startOfDay(day))
                                        }
                                    }
                                    .padding(.horizontal)
                                    .padding(.vertical, 8)
                                }
                                .onChange(of: selectedDay) { _, new in
                                    withAnimation(.easeInOut) {
                                        proxy.scrollTo(startOfDay(new), anchor: .center)
                                    }
                                    Task {
                                        let newBaseStart = computeBaseStart(for: nowTick, day: new)
                                        let vWidth = CGFloat(endOfDay(new).timeIntervalSince(newBaseStart) / 60.0) * pxPerMinute
                                        await vm.switchDay(new, appState: appState, visibleWidth: vWidth, baseStart: newBaseStart)
                                    }
                                }
                            }
                            HStack(spacing: 4) {
                                Button {
                                    Task {
                                        let bStart = computeBaseStart(for: nowTick, day: selectedDay)
                                        let vWidth = CGFloat(endOfDay(selectedDay).timeIntervalSince(bStart) / 60.0) * pxPerMinute
                                        await vm.manualRefresh(appState: appState, currentDay: selectedDay, baseStart: bStart, visibleWidth: vWidth)
                                    }
                                } label: {
                                    if vm.isRefreshing {
                                        ProgressView().controlSize(.small).frame(width: 36, height: 36)
                                    } else {
                                        Image(systemName: "arrow.clockwise")
                                            .font(.system(size: 16, weight: .medium))
                                            .frame(width: 36, height: 36)
                                            .contentShape(Rectangle())
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.trailing, 8)
                        }
                        Divider()

                        ScrollView(.vertical, showsIndicators: true) {
                            HStack(alignment: .top, spacing: 0) {
                                VStack(spacing: 0) {
                                    Color.clear.frame(height: headerHeight)
                                    LazyVStack(spacing: 0) {
                                        ForEach(vm.sortedChannels, id: \.id) { ch in
                                            NavigationLink(
                                                destination: ChannelDetailView(channel: ch)
                                                    .environmentObject(appState)
                                            ) {
                                                GuideChannelHeader(channel: ch)
                                                    .environmentObject(appState)
                                                    .frame(width: channelLabelWidth, height: rowHeight, alignment: .leading)
                                            }
                                            .buttonStyle(.plain)
                                            .background(Color(.systemBackground))
                                            .overlay(Rectangle().fill(Color.secondary.opacity(0.1)).frame(height: 1), alignment: .bottom)
                                        }
                                    }
                                }
                                .frame(width: channelLabelWidth)

                                ScrollView(.horizontal, showsIndicators: true) {
                                    VStack(spacing: 0) {
                                        hourTicksView
                                            .background(Color(.systemBackground))
                                        Divider()
                                        LazyVStack(spacing: 0) {
                                            ForEach(vm.sortedChannels, id: \.id) { ch in
                                                let blocks = vm.renderBlocks[selectedDay]?[ch.id] ?? []
                                                
                                                ZStack(alignment: .topLeading) {
                                                    Color.clear.frame(width: visibleWidth, height: rowHeight)
                                                    
                                                    hourGridRow
                                                    
                                                    ForEach(blocks) { b in
                                                        self.renderProgramBlock(b, channel: ch)
                                                    }
                                                    
                                                    if let x = nowX {
                                                        Rectangle()
                                                            .fill(Color.red)
                                                            .frame(width: 2, height: rowHeight)
                                                            .offset(x: x)
                                                            .allowsHitTesting(false)
                                                    }
                                                }
                                                .frame(width: visibleWidth, height: rowHeight)
                                                .background(Color(.secondarySystemBackground))
                                                .clipped()
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Guide")
            .task {
                await vm.start(appState: appState, baseStart: baseStart, visibleWidth: visibleWidth)
                await vm.switchDay(selectedDay, appState: appState, visibleWidth: visibleWidth, baseStart: baseStart)
            }
            .onReceive(Timer.publish(every: 10, on: .main, in: .common).autoconnect()) { now in
                let oldBaseStart = computeBaseStart(for: self.nowTick, day: self.selectedDay)
                self.nowTick = now
                let newBaseStart = computeBaseStart(for: now, day: self.selectedDay)
                
                if newBaseStart != oldBaseStart {
                    if Calendar.current.isDateInToday(self.selectedDay) {
                        let newVisibleWidth = CGFloat(endOfDay(self.selectedDay).timeIntervalSince(newBaseStart) / 60.0) * pxPerMinute
                        Task {
                            await vm.scheduleCollapsePrograms(for: self.selectedDay, baseStart: newBaseStart, visibleWidth: newVisibleWidth)
                        }
                    }
                }
            }
            #if canImport(UIKit)
            .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
                Task { await vm.scheduleCollapsePrograms(for: self.selectedDay, baseStart: self.baseStart, visibleWidth: self.visibleWidth) }
            }
            #endif
        }
    }

    private var hourTicksView: some View {
        let end = endOfDay(selectedDay)
        return ZStack(alignment: .topLeading) {
            Color.clear.frame(width: visibleWidth, height: headerHeight)
            
            ForEach(hourBoundaries(from: baseStart, to: end), id: \.self) { ts in
                let mins = ts.timeIntervalSince(baseStart) / 60.0
                let x = CGFloat(mins) * pxPerMinute
                
                Rectangle()
                    .fill(Color.secondary.opacity(0.4))
                    .frame(width: 1, height: headerHeight)
                    .offset(x: x)
                
                Text(hourTickFormatter.string(from: ts))
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .offset(x: x + 6, y: 6)
            }
            if let x = nowX {
                Rectangle()
                    .fill(Color.red)
                    .frame(width: 2, height: headerHeight)
                    .offset(x: x)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: visibleWidth, height: headerHeight)
    }

    private var hourGridRow: some View {
        let end = endOfDay(selectedDay)
        return ZStack(alignment: .topLeading) {
            ForEach(hourBoundaries(from: baseStart, to: end), id: \.self) { ts in
                let mins = ts.timeIntervalSince(baseStart) / 60.0
                let x = CGFloat(mins) * pxPerMinute
                let w = 30 * pxPerMinute
                
                Rectangle()
                    .fill(Color.secondary.opacity(0.08))
                    .frame(width: w, height: rowHeight)
                    .overlay(
                        Rectangle().fill(Color.secondary.opacity(0.2)).frame(width: 1),
                        alignment: .leading
                    )
                    .offset(x: x)
            }
        }
    }
    
    private func hourBoundaries(from: Date, to: Date) -> [Date] {
        if from == cachedHourBoundariesKey && cachedHourBoundaries.last ?? .distantPast >= to { return cachedHourBoundaries }
        var result: [Date] = []
        var cur = from
        let cal = Calendar.current
        while cur < to {
            result.append(cur)
            cur = cal.date(byAdding: .minute, value: 30, to: cur) ?? to
        }
        DispatchQueue.main.async {
            self.cachedHourBoundaries = result
            self.cachedHourBoundariesKey = from
        }
        return result
    }

    private func colorForProgram(_ program: BaseItemDto) -> Color {
        if program.isMovie == true { return Color.purple }
        if let genres = program.genres {
            let lower = genres.map { $0.lowercased() }
            if lower.contains(where: { $0.contains("news") }) { return Color.orange }
            if lower.contains(where: { $0.contains("sport") }) { return Color.green }
            if lower.contains(where: { $0.contains("kid") || $0.contains("animation") }) { return Color.pink }
            if lower.contains(where: { $0.contains("documentary") }) { return Color.teal }
        }
        return Color.blue
    }

    @ViewBuilder
    private func renderProgramBlock(_ b: RenderBlock, channel: LiveTvChannelDto) -> some View {
        let jf: JFProgram = buildJFProgram(from: b.item, channel: channel, clampedStart: b.s, clampedEnd: b.e)
        let trueStart = b.item.startDate ?? b.s
        let trueEnd = b.item.endDate ?? b.e
        
        let bgColor = colorForProgram(b.item)
        let isRecording = b.item.timerId != nil || b.item.seriesTimerId != nil
        
        let content = VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .top) {
                Text(b.item.name ?? "Untitled")
                    .font(.caption).bold()
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .allowsTightening(true)
                
                if isRecording {
                    Spacer(minLength: 2)
                    Image(systemName: "record.circle")
                        .foregroundColor(.red)
                        .font(.system(size: 10))
                }
            }
            Text("\(trueStart.formatted(date: .omitted, time: .shortened)) – \(trueEnd.formatted(date: .omitted, time: .shortened))")
                .font(.caption2)
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
        .padding(6)
        .frame(width: max(0, b.w), height: rowHeight - 8, alignment: .leading)
        .background(bgColor.opacity(0.15))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(bgColor.opacity(0.3), lineWidth: 1))
        .contentShape(Rectangle())

        NavigationLink(destination: ProgramView(program: jf, appState: appState).environmentObject(appState)) {
            content
        }
        .buttonStyle(.plain)
        .offset(x: b.x, y: 4)
        .id(b.id)
    }
    
    private func buildJFProgram(from item: BaseItemDto, channel: LiveTvChannelDto, clampedStart s: Date, clampedEnd e: Date) -> JFProgram {
        let fallbackId = item.id ?? "epg_\(channel.id)_\(Int(s.timeIntervalSince1970))"
        var dict: [String: Any] = [
            "Id": fallbackId,
            "Name": item.name ?? "",
            "StartDate": iso8601InternetDateTime.string(from: s),
            "EndDate": iso8601InternetDateTime.string(from: e),
            "ChannelId": channel.id
        ]
        if let cn = channel.name { dict["ChannelName"] = cn }
        if let ov = item.overview { dict["Overview"] = ov }
        if let et = item.episodeTitle { dict["EpisodeTitle"] = et }
        if let r = item.officialRating { dict["OfficialRating"] = r }
        if let pi = item.parentIndexNumber { dict["ParentIndexNumber"] = pi }
        if let idx = item.indexNumber { dict["IndexNumber"] = idx }
        if let rep = item.isRepeat { dict["IsRepeat"] = rep }
        if let isM = item.isMovie { dict["IsMovie"] = isM }
        if let gs = item.genres { dict["Genres"] = gs }
        if let iid = item.id { dict["ItemId"] = iid }
        if let sid = item.seriesId { dict["SeriesId"] = sid }
        if let isS = item.isSeries { dict["IsSeries"] = isS }
        if let sname = item.seriesName { dict["SeriesName"] = sname }
        if let viaJSON = JFProgram(json: dict) {
            return viaJSON
        }
        let minDict: [String: Any] = ["Id": fallbackId, "Name": item.name ?? ""]
        return JFProgram(json: minDict) ?? JFProgram(json: ["Id": fallbackId, "Name": ""])!
    }
}
