//
//  GuideViewModel.swift
//  LiveFin
//

import SwiftUI
import Combine
import Foundation
import JellyfinAPI

#if os(iOS)
import UIKit
#endif

let guidePxPerMinute: CGFloat = 6
let guideChannelLabelWidth: CGFloat = 86
let guideRowHeight: CGFloat = 72
let guideHeaderHeight: CGFloat = 28
let guideChannelChunkSize: Int = 20

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

private let timeRangeShortFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateStyle = .none
    f.timeStyle = .short
    return f
}()

private let dayLabelFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateStyle = .medium
    f.timeStyle = .none
    return f
}()

func guideStartOfDay(_ date: Date) -> Date {
    Calendar.current.startOfDay(for: date)
}

func guideEndOfDay(_ date: Date) -> Date {
    Calendar.current.date(byAdding: .day, value: 1, to: guideStartOfDay(date)) ?? date.addingTimeInterval(24 * 3600)
}

func guideFormatDayLabel(_ d: Date) -> String {
    let cal = Calendar.current
    if cal.isDateInToday(d) { return "Today" }
    if cal.isDateInTomorrow(d) { return "Tomorrow" }
    return dayLabelFormatter.string(from: d)
}

private let channelsCacheTTL: TimeInterval = 3600 // 1 hour
private let epgCacheTTL: TimeInterval = 30 * 60 // 30 minutes

private struct LiveTvChannelsResponse: Codable {
    let items: [LiveTvChannelDto]?
    enum CodingKeys: String, CodingKey { case items = "Items" }
}

private struct EPGProgramsResponse: Codable {
    let items: [BaseItemDto]?
    enum CodingKeys: String, CodingKey { case items = "Items" }
}

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

private func channelsCacheURL() throws -> URL {
    try guideCacheDirectory().appendingPathComponent(channelsCacheFile)
}

private func epgCacheURL(forDayKey key: String) throws -> URL {
    try guideCacheDirectory().appendingPathComponent(epgFilePrefix + key + epgFileExt)
}

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

private struct ChannelCacheFile: Codable {
    let timestamp: Date
    let items: [LiveTvChannelDto]
}

private struct EPGCacheFile: Codable {
    let dayKey: String
    let timestamp: Date
    let items: [BaseItemDto]
}

struct RenderBlock: Identifiable, Equatable {
    let id: String
    let item: BaseItemDto
    let s: Date
    let e: Date
    let x: CGFloat
    let w: CGFloat
    let formattedTimeString: String
    let color: Color
    let isRecording: Bool

    static func == (lhs: RenderBlock, rhs: RenderBlock) -> Bool {
        return lhs.id == rhs.id &&
               lhs.x == rhs.x &&
               lhs.w == rhs.w &&
               lhs.isRecording == rhs.isRecording &&
               lhs.formattedTimeString == rhs.formattedTimeString
    }
}

func backgroundProgramColor(_ program: BaseItemDto) -> Color {
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
    struct Pre {
        let key: String
        let item: BaseItemDto
        let s: Date
        let e: Date
        let x: CGFloat
        let w: CGFloat
        let formattedTime: String
        let color: Color
        let isRecording: Bool
    }

    let pres: [Pre] = items.compactMap { it in
        let (s, e) = epgClampedRange(for: it, baseStart: baseStart, dayEnd: dayEnd, grouped: grouped)
        if e.timeIntervalSince(s) < 60 { return nil }
        let x = CGFloat(s.timeIntervalSince(baseStart) / 60) * guidePxPerMinute
        let w = CGFloat(e.timeIntervalSince(s) / 60) * guidePxPerMinute
        let key = (it.id ?? "") + "|\(Int(s.timeIntervalSince1970))|\(Int(e.timeIntervalSince1970))"
        
        let trueStart = it.startDate ?? s
        let trueEnd = it.endDate ?? e
        let formattedTime = "\(timeRangeShortFormatter.string(from: trueStart)) – \(timeRangeShortFormatter.string(from: trueEnd))"
        let color = backgroundProgramColor(it)
        let isRec = it.timerId != nil || it.seriesTimerId != nil

        return Pre(key: key, item: it, s: s, e: e, x: x, w: w, formattedTime: formattedTime, color: color, isRecording: isRec)
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
            out.append(RenderBlock(
                id: cur.key,
                item: cur.item,
                s: cur.s,
                e: cur.e,
                x: cur.x,
                w: finalW,
                formattedTimeString: cur.formattedTime,
                color: cur.color,
                isRecording: cur.isRecording
            ))
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
        ImageCacheManager.shared.load(url) { _ in }
    }
}
#endif

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

    // Chunk tracking per day key
    private var loadedChunksPerDay: [String: Set<Int>] = [:]
    private var inFlightChunkTasks: Set<String> = []
    private var hasLoadedChannels = false
    private var collapseTasks: [Date: Task<[String: [RenderBlock]], Never>] = [:]
    private var activePrefetchTask: Task<Void, Never>?

    private init() {}

    func start(appState: AppState, baseStart: Date, visibleWidth: CGFloat) async {
        if channels.isEmpty {
            isLoading = true
        }
        
        if !hasLoadedChannels {
            hasLoadedChannels = await loadChannelsFromCache()
        }
        
        let today = guideStartOfDay(Date())
        let hasCachedProgs = await loadProgramsFromCache(for: today)
        
        if hasCachedProgs {
            await scheduleCollapsePrograms(for: today, baseStart: baseStart, visibleWidth: visibleWidth)
            isLoading = false
        }

        if !hasLoadedChannels {
            await loadChannels(appState: appState)
        }

        // Fetch chunk 0 for today if cache is empty or stale
        if !hasCachedProgs || !epgCacheIsFresh(for: today) {
            await fetchEPGSingleChunk(chunkIndex: 0, for: today, appState: appState, baseStart: baseStart, visibleWidth: visibleWidth)
        }
        
        isLoading = false

        activePrefetchTask?.cancel()
        activePrefetchTask = Task { [weak self] in
            guard let self = self else { return }
            if !self.channelsCacheIsFresh() {
                await self.loadChannels(appState: appState)
            }
            guard !Task.isCancelled else { return }
            self.pruneOldEPGCacheFiles()
        }
    }

    func switchDay(_ day: Date, appState: AppState, visibleWidth: CGFloat, baseStart: Date) async {
        let dayK = dayKey(from: day)
        
        if groupedPrograms[day] == nil {
            _ = await loadProgramsFromCache(for: day)
        }
        
        if renderBlocks[day] == nil {
            await scheduleCollapsePrograms(for: day, baseStart: baseStart, visibleWidth: visibleWidth)
        }
        
        // If not loaded yet, fetch initial chunk 0 for this day
        if (loadedChunksPerDay[dayK] ?? []).isEmpty && !epgCacheIsFresh(for: day) {
            await fetchEPGSingleChunk(chunkIndex: 0, for: day, appState: appState, baseStart: baseStart, visibleWidth: visibleWidth)
        }
    }

    func manualRefresh(appState: AppState, currentDay: Date, baseStart: Date, visibleWidth: CGFloat) async {
        isRefreshing = true
        let dayK = dayKey(from: currentDay)
        loadedChunksPerDay[dayK] = []

        try? FileManager.default.removeItem(at: channelsCacheURL())
        if let url = try? epgCacheFileURL(for: currentDay) {
            try? FileManager.default.removeItem(at: url)
        }
        
        groupedPrograms[currentDay] = nil
        renderBlocks[currentDay] = nil
        
        await loadChannels(appState: appState)
        await fetchEPGSingleChunk(chunkIndex: 0, for: currentDay, appState: appState, baseStart: baseStart, visibleWidth: visibleWidth)
        
        isRefreshing = false
    }

    /// Triggers loading the next chunk if the user's visible position is close to the end of the current chunk
    func loadNextChunkIfNeeded(channelIndex: Int, day: Date, appState: AppState, baseStart: Date, visibleWidth: CGFloat) {
        guard !sortedChannels.isEmpty else { return }
        let currentChunk = channelIndex / guideChannelChunkSize
        let nextChunk = currentChunk + 1
        
        let chunkEndIndex = (currentChunk + 1) * guideChannelChunkSize
        // Trigger when the user is within 6 channels of the current chunk's end
        let isNearEnd = channelIndex >= (chunkEndIndex - 6)
        guard isNearEnd else { return }
        
        let nextChunkStart = nextChunk * guideChannelChunkSize
        guard nextChunkStart < sortedChannels.count else { return }
        
        let dayK = dayKey(from: day)
        let loadedSet = loadedChunksPerDay[dayK] ?? []
        let taskKey = "\(dayK)_\(nextChunk)"
        
        guard !loadedSet.contains(nextChunk), !inFlightChunkTasks.contains(taskKey) else { return }
        
        Task {
            await fetchEPGSingleChunk(chunkIndex: nextChunk, for: day, appState: appState, baseStart: baseStart, visibleWidth: visibleWidth)
        }
    }

    func fetchEPGSingleChunk(chunkIndex: Int, for day: Date, appState: AppState, baseStart: Date, visibleWidth: CGFloat) async {
        guard let client = appState.client, !appState.accessToken.isEmpty else { return }
        let total = sortedChannels.count
        let startIdx = chunkIndex * guideChannelChunkSize
        guard startIdx < total else { return }
        let endIdx = min(startIdx + guideChannelChunkSize, total)
        let batch = Array(sortedChannels[startIdx..<endIdx])
        guard !batch.isEmpty else { return }

        let dayK = dayKey(from: day)
        let taskKey = "\(dayK)_\(chunkIndex)"
        guard !inFlightChunkTasks.contains(taskKey) else { return }
        inFlightChunkTasks.insert(taskKey)
        defer { inFlightChunkTasks.remove(taskKey) }

        let start = guideStartOfDay(day)
        let end = guideEndOfDay(day)
        let dayEnd = end

        do {
            let channelIds = batch.map(\.id).joined(separator: ",")
            let programBase = client.configuration.url.appendingPathComponent("/LiveTv/Programs")
            var comps = URLComponents(url: programBase, resolvingAgainstBaseURL: false)
            comps?.queryItems = [
                URLQueryItem(name: "channelIds", value: channelIds),
                URLQueryItem(name: "startDate", value: iso8601Basic.string(from: start)),
                URLQueryItem(name: "endDate", value: iso8601Basic.string(from: end)),
                URLQueryItem(name: "EnableImages", value: "false"),
                URLQueryItem(name: "EnableUserData", value: "true"),
                URLQueryItem(name: "fields", value: "Overview,OfficialRating,Genres,SeriesName,EpisodeTitle,ParentIndexNumber,IndexNumber,IsRepeat,IsMovie,ImageTags,ChannelId,ProgramId,TimerId,SeriesTimerId,SeriesId,IsSeries")
            ]
            if !appState.userID.isEmpty {
                comps?.queryItems?.append(URLQueryItem(name: "userId", value: appState.userID))
            }
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
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else { return }

            let decoded = try await Task.detached(priority: .userInitiated) {
                return try dec.decode(EPGProgramsResponse.self, from: data)
            }.value

            let items = decoded.items ?? []
            let batchGrouped = await self.backgroundProcessAndGroup(programs: items, for: day)
            
            var currentGrouped = self.groupedPrograms[day] ?? [:]
            for (cid, progs) in batchGrouped {
                currentGrouped[cid] = progs
            }
            self.groupedPrograms[day] = currentGrouped

            let batchBlocks = await Task.detached(priority: .userInitiated) {
                var blocks: [String: [RenderBlock]] = [:]
                for ch in batch {
                    let chItems = currentGrouped[ch.id] ?? []
                    if chItems.isEmpty { continue }
                    let collapsed = epgStabilizeItems(chItems, baseStart: baseStart, dayEnd: dayEnd, grouped: currentGrouped)
                    blocks[ch.id] = epgComputeRenderBlocks(
                        collapsed, channelId: ch.id, baseStart: baseStart, dayEnd: dayEnd,
                        visibleWidth: visibleWidth, grouped: currentGrouped)
                }
                return blocks
            }.value

            var currentBlocks = self.renderBlocks[day] ?? [:]
            for (cid, blks) in batchBlocks {
                currentBlocks[cid] = blks
            }
            self.renderBlocks[day] = currentBlocks

            var loaded = self.loadedChunksPerDay[dayK] ?? []
            loaded.insert(chunkIndex)
            self.loadedChunksPerDay[dayK] = loaded

            if !items.isEmpty {
                await self.saveEPGToCache(for: day, items: items)
            }
        } catch {
            // Fail gracefully
        }
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
            await saveChannelsToCache(list)
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
        let start = guideStartOfDay(day)
        let end = guideEndOfDay(day)
        return await Task.detached(priority: .userInitiated) {
            let filtered = programs.filter { p in
                let s0 = p.startDate ?? start
                let defaultEnd = Calendar.current.date(byAdding: .minute, value: 30, to: s0) ?? s0.addingTimeInterval(30 * 60)
                let s = max(s0, start)
                let e = min(p.endDate ?? defaultEnd, end)
                return e > start && s < end
            }
            var grouped = Dictionary(grouping: filtered, by: { $0.channelId ?? "" })
            for (k, v) in grouped {
                grouped[k] = v.sorted { ($0.startDate ?? start) < ($1.startDate ?? start) }
            }
            return grouped
        }.value
    }

    private func saveChannelsToCache(_ items: [LiveTvChannelDto]) async {
        await Task.detached(priority: .utility) {
            do {
                let payload = ChannelCacheFile(timestamp: Date(), items: items)
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                let data = try encoder.encode(payload)
                try data.write(to: try channelsCacheURL(), options: [.atomic])
            } catch {}
        }.value
    }

    private func saveEPGToCache(for day: Date, items: [BaseItemDto]) async {
        let key = dayKey(from: day)
        await Task.detached(priority: .utility) {
            do {
                var existingItems: [BaseItemDto] = []
                let url = try epgCacheURL(forDayKey: key)
                if let existingData = try? Data(contentsOf: url) {
                    let decoder = JSONDecoder()
                    decoder.dateDecodingStrategy = .iso8601
                    if let cached = try? decoder.decode(EPGCacheFile.self, from: existingData) {
                        existingItems = cached.items
                    }
                }
                var combined = existingItems
                let newIds = Set(items.compactMap { $0.id })
                combined.removeAll { it in
                    guard let id = it.id else { return false }
                    return newIds.contains(id)
                }
                combined.append(contentsOf: items)

                let payload = EPGCacheFile(dayKey: key, timestamp: Date(), items: combined)
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                let data = try encoder.encode(payload)
                try data.write(to: url, options: [.atomic])
            } catch {}
        }.value
    }

    nonisolated private func channelsCacheIsFresh() -> Bool {
        guard let url = try? channelsCacheURL(),
              let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modified = attrs[.modificationDate] as? Date else { return false }
        return Date().timeIntervalSince(modified) < channelsCacheTTL
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
