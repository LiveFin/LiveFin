//
//  GuideView.swift
//  LiveFin
//
//
//

import SwiftUI
import Foundation

#if canImport(UIKit)
import UIKit
#endif

// Timeline layout constants
private let pxPerMinute: CGFloat = 8 // 30min intervals => ~240px per hour
private let channelLabelWidth: CGFloat = 120
private let rowHeight: CGFloat = 72
private let headerHeight: CGFloat = 28
// Caching TTLs (in seconds)
private let channelsCacheTTL: TimeInterval = 3600 // Reduced from 24h to 1h
private let epgCacheTTL: TimeInterval = 30 * 60
// Cache pruning horizon (in days)
private let epgKeepDays: Int = 14

// MARK: - Helpers
private func startOfDay(_ date: Date) -> Date { Calendar.current.startOfDay(for: date) }
private func endOfDay(_ date: Date) -> Date { Calendar.current.date(byAdding: .day, value: 1, to: startOfDay(date)) ?? date.addingTimeInterval(24*3600) }

// MARK: - Local response wrappers (unique names to avoid collisions)
private struct LiveTvChannelsResponse: Codable { let items: [LiveTvChannelDto]?; enum CodingKeys: String, CodingKey { case items = "Items" } }
private struct EPGProgramsResponse: Codable { let items: [BaseItemDto]?; enum CodingKeys: String, CodingKey { case items = "Items" } }

// NOTE: Compact channel header and program row views were moved to:
//   LiveFin/Components/Guide View/GuideViewComponents.swift
// See that file for `GuideChannelHeader`, `GuideProgramRow`, and `RenderBlock`.

// Cache folder and filename constants used by the Guide caching helpers
private let guideCacheFolder = "GuideCache"
private let epgFilePrefix = "epg_day_"
private let epgFileExt = ".json"
private let channelsCacheFile = "channels.json"

// Prefetch helpers to warm channel logo cache for Guide (UIKit only)
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

// Shared ISO8601 formatters — reused across all EPG fetches and program block builds
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

// Cached formatter for hour tick labels
private let hourTickFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm"
    return f
}()

// Cached formatter for day chip labels
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

// MARK: - Pure EPG layout helpers (free functions; safe to call from any thread)

private func epgClampedRange(
    for item: BaseItemDto,
    baseStart: Date,
    dayEnd: Date,
    grouped: [String: [BaseItemDto]]
) -> (Date, Date) {
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
    
    if inferredEnd <= baseStart {
        return (baseStart, baseStart)
    }
    if s0 >= dayEnd {
        return (dayEnd, dayEnd)
    }
    
    let s = max(s0, baseStart)
    let e = min(inferredEnd, dayEnd)
    return (s, max(s, e))
}

private func epgStabilizeItems(
    _ items: [BaseItemDto],
    baseStart: Date,
    dayEnd: Date,
    grouped: [String: [BaseItemDto]]
) -> [BaseItemDto] {
    struct Candidate {
        let item: BaseItemDto
        let s: Date
        let e: Date
        let duration: TimeInterval
    }
    
    let candidates: [Candidate] = items.compactMap { item in
        let (s, e) = epgClampedRange(for: item, baseStart: baseStart, dayEnd: dayEnd, grouped: grouped)
        if e.timeIntervalSince(s) < 60 { return nil }
        return Candidate(item: item, s: s, e: e, duration: e.timeIntervalSince(s))
    }
    
    let sorted = candidates.sorted {
        if abs($0.s.timeIntervalSince($1.s)) < 120 {
            return $0.duration > $1.duration
        }
        return $0.s < $1.s
    }
    
    var out: [Candidate] = []
    for cur in sorted {
        var isDuplicateStart = false
        if let last = out.last {
            if abs(cur.s.timeIntervalSince(last.s)) < 120 {
                isDuplicateStart = true
            }
        }
        if !isDuplicateStart {
            out.append(cur)
        }
    }
    return out.map { $0.item }
}

private func epgComputeRenderBlocks(
    _ items: [BaseItemDto],
    channelId: String,
    baseStart: Date,
    dayEnd: Date,
    visibleWidth: CGFloat,
    grouped: [String: [BaseItemDto]]
) -> [RenderBlock] {
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
            if nextX > cur.x {
                finalW = min(finalW, nextX - cur.x)
            }
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
    let aNum = a.number ?? ""; let bNum = b.number ?? ""
    let aHas = !aNum.isEmpty; let bHas = !bNum.isEmpty
    if aHas != bHas { return aHas }
    let ac = channelNumericComponents(aNum); let bc = channelNumericComponents(bNum)
    if ac != bc { return ac.lexicographicallyPrecedes(bc) }
    return (a.name ?? "") < (b.name ?? "")
}

// MARK: - Main Guide View
struct GuideView: View {
    @EnvironmentObject var appState: AppState

    @State private var channels: [LiveTvChannelDto] = []
    @State private var sortedChannels: [LiveTvChannelDto] = []
    @State private var programs: [BaseItemDto] = []
    @State private var groupedProgramsCache: [String: [BaseItemDto]] = [:]

    @State private var selectedDay: Date = Date()
    @State private var isLoading: Bool = false
    @State private var isRefreshing: Bool = false
    @State private var errorMessage: String?
    @State private var nowTick: Date = Date()
    @State private var fetchingDays: Set<Date> = []

    @State private var collapsedProgramsByChannel: [String: [BaseItemDto]] = [:]
    @State private var cachedRenderBlocksByChannel: [String: [RenderBlock]] = [:]
    @State private var collapseTask: Task<Void, Never>? = nil
    @State private var selectionDebounceTask: Task<Void, Never>? = nil

    @State private var cachedHourBoundaries: [Date] = []
    @State private var cachedHourBoundariesKey: Date = .distantPast

    private var availableDaysSorted: [Date] {
        let cal = Calendar.current
        let today = startOfDay(Date())
        return (0..<7).compactMap { cal.date(byAdding: .day, value: $0, to: today) }
    }

    private var groupedByChannel: [String: [BaseItemDto]] { groupedProgramsCache }
    private func normDay(_ d: Date) -> Date { startOfDay(d) }
    private var isToday: Bool { Calendar.current.isDateInToday(selectedDay) }
    
    private func computeBaseStart(for time: Date) -> Date {
        let day = startOfDay(selectedDay)
        guard isToday else { return day }
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
        return max(day, aligned)
    }
    
    private var baseStart: Date { computeBaseStart(for: nowTick) }
    private var visibleMinutes: Double { endOfDay(selectedDay).timeIntervalSince(baseStart) / 60.0 }
    private var visibleWidth: CGFloat { CGFloat(visibleMinutes) * pxPerMinute }
    
    private var nowX: CGFloat? {
        guard isToday else { return nil }
        let now = nowTick
        if now <= baseStart || now >= endOfDay(selectedDay) { return nil }
        let mins = now.timeIntervalSince(baseStart) / 60.0
        return CGFloat(mins) * pxPerMinute
    }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading && channels.isEmpty {
                    ProgressView("Loading Guide…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let msg = errorMessage {
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
                            Task { await reloadAll() }
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
                } else if channels.isEmpty {
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
                                            .id(normDay(day))
                                        }
                                    }
                                    .padding(.horizontal)
                                    .padding(.vertical, 8)
                                }
                                .onChange(of: selectedDay) { _, new in
                                    withAnimation(.easeInOut) {
                                        proxy.scrollTo(normDay(new), anchor: .center)
                                    }
                                }
                            }
                            HStack(spacing: 4) {
                                if #available(iOS 26.0, *) {
                                    Button { Task { await handleManualRefresh() } } label: {
                                        if isRefreshing {
                                            ProgressView().controlSize(.small).frame(width: 36, height: 36)
                                        } else {
                                            Image(systemName: "arrow.clockwise")
                                                .font(.system(size: 16, weight: .medium))
                                                .frame(width: 36, height: 36)
                                                .contentShape(Rectangle())
                                        }
                                    }
                                    .buttonStyle(.plain)
                                    .glassEffect(.regular.interactive())
                                } else {
                                    Button { Task { await handleManualRefresh() } } label: {
                                        if isRefreshing {
                                            ProgressView().controlSize(.small).frame(width: 44, height: 44)
                                        } else {
                                            Image(systemName: "arrow.clockwise")
                                                .font(.system(size: 16, weight: .medium))
                                                .frame(width: 44, height: 44)
                                                .contentShape(Rectangle())
                                        }
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.trailing, 8)
                        }
                        Divider()

                        ScrollView(.vertical, showsIndicators: true) {
                            HStack(alignment: .top, spacing: 0) {
                                VStack(spacing: 0) {
                                    Color.clear.frame(height: headerHeight)
                                    LazyVStack(spacing: 0) {
                                        ForEach(sortedChannels, id: \.id) { ch in
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
                                            ForEach(sortedChannels, id: \.id) { ch in
                                                let items = groupedByChannel[ch.id] ?? []
                                                
                                                let stabilized: [BaseItemDto] = collapsedProgramsByChannel[ch.id] ?? epgStabilizeItems(
                                                    items, baseStart: self.baseStart, dayEnd: endOfDay(self.selectedDay), grouped: groupedByChannel
                                                )

                                                let blocks: [RenderBlock] = cachedRenderBlocksByChannel[ch.id] ?? epgComputeRenderBlocks(
                                                    stabilized, channelId: ch.id, baseStart: self.baseStart, dayEnd: endOfDay(self.selectedDay),
                                                    visibleWidth: visibleWidth, grouped: groupedByChannel
                                                )
                                                
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
                                        .animation(nil, value: programs.count)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Guide")
            .task {
                await reloadAll()
            }
            .onChange(of: selectedDay) {
                let targetDay = selectedDay
                selectionDebounceTask?.cancel()

                cachedRenderBlocksByChannel = [:]
                collapsedProgramsByChannel = [:]
                groupedProgramsCache = [:]

                selectionDebounceTask = Task {
                    let loaded = await loadProgramsFromCache(for: targetDay)
                    if Task.isCancelled { return }
                    
                    if !loaded || !epgCacheIsFresh(for: targetDay) {
                        await fetchEPG(for: targetDay, updateUI: true)
                    } else {
                        await backgroundProcessAndGroup(programs: self.programs, for: targetDay)
                    }
                    if Task.isCancelled { return }
                    
                    await prefetchAdjacentDays(around: targetDay)
                }
            }
            .onReceive(Timer.publish(every: 10, on: .main, in: .common).autoconnect()) { now in
                let oldBaseStart = self.baseStart
                self.nowTick = now
                let newBaseStart = self.computeBaseStart(for: now)
                
                if newBaseStart != oldBaseStart {
                    self.cachedRenderBlocksByChannel = [:]
                    Task { scheduleCollapsePrograms(for: self.selectedDay) }
                }
            }
            #if canImport(UIKit)
            .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
                self.cachedRenderBlocksByChannel = [:]
                Task { scheduleCollapsePrograms(for: self.selectedDay) }
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
                
                Text(timeLabel(ts))
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
        if from == cachedHourBoundariesKey { return cachedHourBoundaries }
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
    
    private func timeLabel(_ d: Date) -> String { hourTickFormatter.string(from: d) }

    @ViewBuilder
    private func renderProgramBlock(_ b: RenderBlock, channel: LiveTvChannelDto) -> some View {
        let jf: JFProgram = buildJFProgram(from: b.item, channel: channel, clampedStart: b.s, clampedEnd: b.e)
        let trueStart = b.item.startDate ?? b.s
        let trueEnd = b.item.endDate ?? b.e
        
        let content = VStack(alignment: .leading, spacing: 2) {
            Text(b.item.name ?? "Untitled")
                .font(.caption).bold()
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .allowsTightening(true)
            Text("\(trueStart.formatted(date: .omitted, time: .shortened)) – \(trueEnd.formatted(date: .omitted, time: .shortened))")
                .font(.caption2)
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
        .padding(6)
        .frame(width: max(0, b.w), height: rowHeight - 8, alignment: .leading)
        .background(Color.blue.opacity(0.15))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.blue.opacity(0.3), lineWidth: 1))
        .contentShape(Rectangle())

        NavigationLink(destination: ProgramView(program: jf, appState: appState).environmentObject(appState)) {
            content
        }
        .buttonStyle(.plain)
        .offset(x: b.x, y: 4)
        .id(b.id)
    }
}

// MARK: - Safe cache network extensions
private extension GuideView {
    
    func handleManualRefresh() async {
        await MainActor.run { isRefreshing = true }
        
        // 1. Fully wipe the file caches
        try? FileManager.default.removeItem(at: channelsCacheURL())
        if let epgUrl = try? epgCacheFileURL(for: selectedDay) {
            try? FileManager.default.removeItem(at: epgUrl)
        }
        
        // 2. Clear memory state forcing a re-render
        await MainActor.run {
            self.cachedRenderBlocksByChannel = [:]
            self.collapsedProgramsByChannel = [:]
            self.groupedProgramsCache = [:]
        }
        
        // 3. Parallel fetch without utilizing local files
        async let cTask: () = loadChannels()
        async let pTask: () = fetchEPG(for: selectedDay, updateUI: true)
        
        _ = await (cTask, pTask)
        
        await MainActor.run { isRefreshing = false }
    }

    func reloadAll() async {
        await MainActor.run {
            isLoading = true
            errorMessage = nil
        }
        
        let targetDay = selectedDay
        
        // Parallel cache fetch
        async let fetchChannelsFromCache = loadChannelsFromCache()
        async let fetchProgramsFromCache = loadProgramsFromCache(for: targetDay)
        
        let (channelsLoaded, programsLoaded) = await (fetchChannelsFromCache, fetchProgramsFromCache)
        
        if !channelsLoaded {
            await loadChannels()
        } else {
            // Background refresh channels so lineup additions/removals are caught seamlessly
            Task { await loadChannels() }
        }
        
        if !programsLoaded || !epgCacheIsFresh(for: targetDay) {
            await fetchEPG(for: targetDay, updateUI: true)
        } else {
            await backgroundProcessAndGroup(programs: self.programs, for: targetDay)
        }
        
        await MainActor.run { isLoading = false }
        
        Task {
            await prefetchAdjacentDays(around: targetDay)
            pruneOldEPGCacheFiles()
        }
    }

    func loadChannelsFromCache() async -> Bool {
        do {
            let url = try channelsCacheURL()
            let list = try await Task.detached(priority: .utility) {
                let data = try Data(contentsOf: url)
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let decoded = try decoder.decode(ChannelCacheFile.self, from: data)
                return decoded.items.sorted(by: channelLessThan)
            }.value
            
            if Task.isCancelled { return false }
            
            await MainActor.run {
                self.channels = list
                self.sortedChannels = list
            }
            #if canImport(UIKit)
            guidePrefetchChannelLogos(list, baseURL: appState.serverURL, apiKey: appState.apiKey)
            #endif
            return true
        } catch {
            return false
        }
    }

    func loadProgramsFromCache(for day: Date) async -> Bool {
        do {
            let key = dayKey(from: day)
            let url = try epgCacheURL(forDayKey: key)
            let decoded = try await Task.detached(priority: .userInitiated) {
                let data = try Data(contentsOf: url)
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                return try decoder.decode(EPGCacheFile.self, from: data)
            }.value

            if Task.isCancelled { return false }

            await MainActor.run {
                if Calendar.current.isDate(self.selectedDay, inSameDayAs: day) {
                    self.programs = decoded.items
                }
            }
            return true
        } catch {
            return false
        }
    }

    func loadChannels() async {
        guard let client = appState.client else { return }
        guard !appState.accessToken.isEmpty else { return }
        do {
            var req = URLRequest(url: client.configuration.url.appendingPathComponent("/LiveTv/Channels"))
            req.httpMethod = "GET"
            req.cachePolicy = .reloadIgnoringLocalCacheData
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue(appState.accessToken, forHTTPHeaderField: "X-Emby-Token")
            
            let (data, resp) = try await URLSession.shared.data(for: req)
            if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
                throw NSError(domain: "LiveFin", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "Server returned error code \(http.statusCode)"])
            }
            
            if Task.isCancelled { return }
            
            let decoded = try JSONDecoder().decode(LiveTvChannelsResponse.self, from: data)
            let rawList = decoded.items ?? []
            
            // Offload sorting from Main thread
            let list = await Task.detached(priority: .userInitiated) {
                rawList.sorted(by: channelLessThan)
            }.value
            
            await MainActor.run {
                self.channels = list
                self.sortedChannels = list
                self.scheduleCollapsePrograms(for: self.selectedDay)
            }
            try saveChannelsToCache(list)
            
            #if canImport(UIKit)
            guidePrefetchChannelLogos(list, baseURL: appState.serverURL, apiKey: appState.apiKey)
            #endif
        } catch {
            await MainActor.run { self.errorMessage = error.localizedDescription }
        }
    }

    func epgCacheIsFresh(for day: Date) -> Bool {
        guard let url = try? epgCacheFileURL(for: day),
              let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modified = attrs[.modificationDate] as? Date else { return false }
        return Date().timeIntervalSince(modified) < epgCacheTTL
    }

    func prefetchAdjacentDays(around day: Date) async {
        let cal = Calendar.current
        let offsets = [-2, -1, 1, 2]
        await withTaskGroup(of: Void.self) { group in
            for off in offsets {
                let d = cal.date(byAdding: .day, value: off, to: day) ?? day
                if !epgCacheIsFresh(for: d) {
                    group.addTask { await self.prefetchDay(d) }
                }
            }
        }
    }

    func prefetchDay(_ day: Date) async {
        if fetchingDays.contains(startOfDay(day)) { return }
        await MainActor.run { fetchingDays.insert(startOfDay(day)) }
        defer { Task { await MainActor.run { fetchingDays.remove(startOfDay(day)) } } }
        await fetchEPG(for: day, updateUI: false)
    }

    // Completely offloaded dictionary grouping & sorting to fix massive main-thread lag
    func backgroundProcessAndGroup(programs: [BaseItemDto], for day: Date) async {
        let start = startOfDay(day)
        let end = endOfDay(day)
        
        let builtCache = await Task.detached(priority: .userInitiated) {
            let filtered = programs.filter { p in
                let s0 = p.startDate ?? start
                let defaultEnd = Calendar.current.date(byAdding: .minute, value: 30, to: s0) ?? s0.addingTimeInterval(30 * 60)
                let s = max(s0, start)
                let e = min(p.endDate ?? defaultEnd, end)
                return e > start && s < end
            }
            
            var grouped = Dictionary(grouping: filtered, by: { $0.channelId ?? "" })
            for (k, v) in grouped {
                grouped[k] = v.sorted { (a, b) in
                    let aStart = a.startDate ?? start
                    let bStart = b.startDate ?? start
                    return aStart < bStart
                }
            }
            return grouped
        }.value
        
        if Task.isCancelled { return }
        
        await MainActor.run {
            if Calendar.current.isDate(self.selectedDay, inSameDayAs: day) {
                self.groupedProgramsCache = builtCache
                self.scheduleCollapsePrograms(for: day)
            }
        }
    }

    func scheduleCollapsePrograms(for targetDay: Date? = nil) {
        collapseTask?.cancel()
        Task { @MainActor in
            if let tDay = targetDay, !Calendar.current.isDate(self.selectedDay, inSameDayAs: tDay) { return }
            
            let channelsSnapshot = self.channels
            let selectedDaySnapshot = self.selectedDay
            let baseStartSnapshot = self.baseStart
            let groupedSnapshot = self.groupedProgramsCache

            collapseTask = Task.detached(priority: .userInitiated) {
                let dayEnd = endOfDay(selectedDaySnapshot)
                let visibleMinutes = dayEnd.timeIntervalSince(baseStartSnapshot) / 60.0
                let visibleWidthSnapshot = CGFloat(visibleMinutes) * pxPerMinute

                let priorityCount = min(20, channelsSnapshot.count)
                let channelsPriority = Array(channelsSnapshot.prefix(priorityCount))
                let channelsRemainder = Array(channelsSnapshot.dropFirst(priorityCount))

                func processChannels(_ list: [LiveTvChannelDto]) -> ([String: [BaseItemDto]], [String: [RenderBlock]]) {
                    var localCollapsed: [String: [BaseItemDto]] = [:]
                    var localBlocks: [String: [RenderBlock]] = [:]
                    for ch in list {
                        let items = groupedSnapshot[ch.id] ?? []
                        if items.isEmpty { continue }
                        let collapsed = epgStabilizeItems(items, baseStart: baseStartSnapshot, dayEnd: dayEnd, grouped: groupedSnapshot)
                        localCollapsed[ch.id] = collapsed
                        localBlocks[ch.id] = epgComputeRenderBlocks(
                            collapsed, channelId: ch.id,
                            baseStart: baseStartSnapshot, dayEnd: dayEnd,
                            visibleWidth: visibleWidthSnapshot, grouped: groupedSnapshot)
                    }
                    return (localCollapsed, localBlocks)
                }

                if !channelsPriority.isEmpty {
                    let (pCollapsed, pBlocks) = processChannels(channelsPriority)
                    if Task.isCancelled { return }
                    
                    // BATCH MainActor updates to avoid severe SwiftUI UI thrashing
                    await MainActor.run {
                        if Calendar.current.isDate(self.selectedDay, inSameDayAs: selectedDaySnapshot) {
                            var newCollapsed = self.collapsedProgramsByChannel
                            var newBlocks = self.cachedRenderBlocksByChannel
                            for (k, v) in pCollapsed { newCollapsed[k] = v }
                            for (k, v) in pBlocks { newBlocks[k] = v }
                            self.collapsedProgramsByChannel = newCollapsed
                            self.cachedRenderBlocksByChannel = newBlocks
                        }
                    }
                }

                let batchSize = 50
                var idx = 0
                while idx < channelsRemainder.count {
                    if Task.isCancelled { break }
                    let end = min(idx + batchSize, channelsRemainder.count)
                    let (rCollapsed, rBlocks) = processChannels(Array(channelsRemainder[idx..<end]))
                    
                    await MainActor.run {
                        if Calendar.current.isDate(self.selectedDay, inSameDayAs: selectedDaySnapshot) {
                            var newCollapsed = self.collapsedProgramsByChannel
                            var newBlocks = self.cachedRenderBlocksByChannel
                            for (k, v) in rCollapsed { newCollapsed[k] = v }
                            for (k, v) in rBlocks { newBlocks[k] = v }
                            self.collapsedProgramsByChannel = newCollapsed
                            self.cachedRenderBlocksByChannel = newBlocks
                        }
                    }
                    idx += batchSize
                }
            }
        }
    }

    private func saveChannelsToCache(_ items: [LiveTvChannelDto]) throws {
        let payload = ChannelCacheFile(timestamp: Date(), items: items)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(payload)
        let url = try channelsCacheURL()
        try data.write(to: url, options: [.atomic])
    }

    private func saveEPGToCache(for day: Date, items: [BaseItemDto]) throws {
        let payload = EPGCacheFile(dayKey: dayKey(from: day), timestamp: Date(), items: items)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(payload)
        let url = try epgCacheURL(forDayKey: payload.dayKey)
        Task.detached(priority: .utility) {
            try? data.write(to: url, options: [.atomic])
        }
    }
}

private extension GuideView {
    func fetchEPG(for day: Date, updateUI: Bool) async {
        guard let client = appState.client else { return }
        guard !appState.accessToken.isEmpty else { return }
        
        if updateUI {
            await MainActor.run {
                if programs.isEmpty { isLoading = true }
                errorMessage = nil
            }
        }
        
        defer {
            if updateUI { Task { await MainActor.run { isLoading = false } } }
        }
        
        do {
            let start = startOfDay(day); let end = endOfDay(day)
            let programBase = client.configuration.url.appendingPathComponent("/LiveTv/Programs")
            var comps = URLComponents(url: programBase, resolvingAgainstBaseURL: false)
            comps?.queryItems = [
                URLQueryItem(name: "startDate", value: iso8601Basic.string(from: start)),
                URLQueryItem(name: "endDate", value: iso8601Basic.string(from: end)),
                URLQueryItem(name: "EnableImages", value: "false"),
                URLQueryItem(name: "EnableUserData", value: "false"),
                URLQueryItem(name: "fields", value: "Overview,OfficialRating,Genres,SeriesName,EpisodeTitle,ParentIndexNumber,IndexNumber,IsRepeat,IsMovie,ImageTags,ChannelId,ProgramId")
            ]
            if let uid = appState.user?.id, !uid.isEmpty { comps?.queryItems?.append(URLQueryItem(name: "userId", value: uid)) }
            guard let final = comps?.url else { return }
            
            var req = URLRequest(url: final)
            req.httpMethod = "GET"
            req.cachePolicy = .reloadIgnoringLocalCacheData
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue(appState.accessToken, forHTTPHeaderField: "X-Emby-Token")

            let dec = JSONDecoder()
            dec.dateDecodingStrategy = .custom { d in
                let c = try d.singleValueContainer(); let s = try c.decode(String.self)
                if let dt = iso8601WithFractional.date(from: s) { return dt }
                if let dt2 = iso8601Basic.date(from: s) { return dt2 }
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "Cannot parse date: \(s)")
            }

            let (data, resp) = try await URLSession.shared.data(for: req)
            if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
                throw NSError(domain: "LiveFin", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "Server returned error code \(http.statusCode)"])
            }
            
            if Task.isCancelled { return }

            let decoded = try await Task.detached(priority: .userInitiated) {
                return try dec.decode(EPGProgramsResponse.self, from: data)
            }.value

            let items = decoded.items ?? []
            try? saveEPGToCache(for: day, items: items)

            if Task.isCancelled { return }

            if updateUI {
                await MainActor.run {
                    if Calendar.current.isDate(self.selectedDay, inSameDayAs: day) {
                        self.programs = items
                    }
                }
                await backgroundProcessAndGroup(programs: items, for: day)
            }
        } catch {
            if updateUI {
                await MainActor.run {
                    if Calendar.current.isDate(self.selectedDay, inSameDayAs: day) {
                        self.errorMessage = error.localizedDescription
                    }
                }
            }
        }
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
        if let viaJSON = JFProgram(json: dict) {
            return viaJSON
        }
        let minDict: [String: Any] = [
            "Id": fallbackId,
            "Name": item.name ?? ""
        ]
        return JFProgram(json: minDict) ?? JFProgram(json: ["Id": fallbackId, "Name": ""])!
    }
}

// MARK: - Cache helpers
extension GuideView {
    func channelsCacheFileURL() throws -> URL { try guideCacheDirectory().appendingPathComponent(channelsCacheFile) }
    func epgCacheFileURL(for day: Date) throws -> URL {
        let key = dayKey(from: day)
        return try guideCacheDirectory().appendingPathComponent(epgFilePrefix + key + epgFileExt)
    }

    func isEPGCacheFresh(for day: Date) -> Bool { epgCacheIsFresh(for: day) }

    func channelsCacheIsFresh() async -> Bool {
        guard let url = try? channelsCacheURL(),
              let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modified = attrs[.modificationDate] as? Date else { return false }
        return Date().timeIntervalSince(modified) < channelsCacheTTL
    }

    func pruneOldEPGCacheFiles() {
        URLCache.shared.removeAllCachedResponses()
        
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
        } catch { /* ignore */ }
    }
}

