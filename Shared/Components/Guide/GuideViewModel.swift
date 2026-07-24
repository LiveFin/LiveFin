//
//  GuideViewModel.swift
//  LiveFin
//
//  Created by Kervens on 7/18/26.
//

import SwiftUI
import Combine
import JellyfinAPI

#if os(iOS)
import UIKit
#endif

// MARK: - Global Shared Constants
let guidePxPerMinute: CGFloat = 6
let guideChannelLabelWidth: CGFloat = 86
let guideRowHeight: CGFloat = 72
let guideHeaderHeight: CGFloat = 28

let guideIso8601InternetDateTime: ISO8601DateFormatter = {
let f = ISO8601DateFormatter()
f.formatOptions = [.withInternetDateTime]
return f
}()

let guideHourTickFormatter: DateFormatter = {
let f = DateFormatter()
f.dateFormat = "HH:mm"
return f
}()

// MARK: - Global Helpers
func guideStartOfDay(_ date: Date) -> Date { Calendar.current.startOfDay(for: date) }
func guideEndOfDay(_ date: Date) -> Date { Calendar.current.date(byAdding: .day, value: 1, to: guideStartOfDay(date)) ?? date.addingTimeInterval(24*3600) }

private let dayLabelFormatter: DateFormatter = {
let f = DateFormatter()
f.dateStyle = .medium
f.timeStyle = .none
return f
}()

func guideFormatDayLabel(_ d: Date) -> String {
let cal = Calendar.current
if cal.isDateInToday(d) { return "Today" }
if cal.isDateInTomorrow(d) { return "Tomorrow" }
return dayLabelFormatter.string(from: d)
}

// MARK: - Caching Configuration
private let channelsCacheTTL: TimeInterval = 3600 // 1h
private let epgCacheTTL: TimeInterval = 30 * 60
private let epgKeepDays: Int = 14

private struct LiveTvChannelsResponse: Codable { let items: [LiveTvChannelDto]?; enum CodingKeys: String, CodingKey { case items = "Items" } }
private struct EPGProgramsResponse: Codable { let items: [BaseItemDto]?; enum CodingKeys: String, CodingKey { case items = "Items" } }

private let guideCacheFolder = "GuideCache"
private let epgFilePrefix = "epg_day_"
private let epgFileExt = ".json"
private let channelsCacheFile = "channels.json"

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

private func dayKey(from date: Date) -> String { dayFileFormatter.string(from: guideStartOfDay(date)) }
private func dateFromDayKey(_ key: String) -> Date? { dayFileFormatter.date(from: key) }

private let iso8601WithFractional: ISO8601DateFormatter = {
let f = ISO8601DateFormatter()
f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
return f
}()
private let iso8601Basic = ISO8601DateFormatter()

private struct ChannelCacheFile: Codable { let timestamp: Date; let items: [LiveTvChannelDto] }
private struct EPGCacheFile: Codable { let dayKey: String; let timestamp: Date; let items: [BaseItemDto] }

// MARK: - EPG Types and Algorithms
struct RenderBlock: Identifiable {
let id: String
let item: BaseItemDto
let s: Date
let e: Date
let x: CGFloat
let w: CGFloat
}

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
    let x = CGFloat(s.timeIntervalSince(baseStart) / 60) * guidePxPerMinute
    let w = CGFloat(e.timeIntervalSince(s) / 60) * guidePxPerMinute
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

#if os(iOS)
private func guideBuildChannelLogoURL(baseURL: String, apiKey: String, channelId: String) -> URL? {
let trimmed = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
let path = "/Items/\(channelId)/Images/Primary?maxWidth=200&api_key=\(apiKey)"
return URL(string: trimmed + path)
}

private func guidePrefetchChannelLogos(_ channels: [LiveTvChannelDto], baseURL: String, apiKey: String) {
let slice = channels.prefix(80)
for ch in slice {
guard let url = guideBuildChannelLogoURL(baseURL: baseURL, apiKey: apiKey, channelId: ch.id) else { continue }
// Assumes ImageCacheManager exists in your project.
ImageCacheManager.shared.load(url) { _ in /* warm cache */ }
}
}
#endif

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
    if !hasLoadedChannels {
        hasLoadedChannels = await loadChannelsFromCache()
    }
    
    let today = guideStartOfDay(Date())
    if groupedPrograms[today] == nil {
        _ = await loadProgramsFromCache(for: today)
    }
    
    await scheduleCollapsePrograms(for: today, baseStart: baseStart, visibleWidth: visibleWidth)
    
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
    let dayEnd = guideEndOfDay(day)
    
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
        let start = guideStartOfDay(day)
        let end = guideEndOfDay(day)
        
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
        
        req.setValue("MediaBrowser Token=\"\(appState.accessToken)\"", forHTTPHeaderField: "Authorization")
        
        let (data, _) = try await URLSession.shared.data(for: req)
        let decoded = try JSONDecoder().decode(LiveTvChannelsResponse.self, from: data)
        let rawList = decoded.items ?? []
        let list = await Task.detached(priority: .userInitiated) { rawList.sorted(by: channelLessThan) }.value
        
        self.channels = list
        self.sortedChannels = list
        try? saveChannelsToCache(list)
        #if os(iOS)
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
    let start = guideStartOfDay(day); let end = guideEndOfDay(day)
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
            let sd = guideStartOfDay(d)
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
                    self.fetchingDays.remove(guideStartOfDay(d))
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
        let horizon = guideStartOfDay(Date())
        for url in files where url.lastPathComponent.hasPrefix(epgFilePrefix) && url.pathExtension == "json" {
            let name = url.deletingPathExtension().lastPathComponent
            let key = String(name.dropFirst(epgFilePrefix.count))
            if let d = dateFromDayKey(key), guideStartOfDay(d) < horizon {
                try? fm.removeItem(at: url)
            }
        }
    } catch { }
}

nonisolated func epgCacheFileURL(for day: Date) throws -> URL {
    return try epgCacheURL(forDayKey: dayKey(from: day))
}


}
