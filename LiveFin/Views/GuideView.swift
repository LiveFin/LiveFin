//
//  GuideView.swift
//  LiveFin
//

import SwiftUI
import Foundation

#if canImport(UIKit)
import UIKit
#endif

// MARK: - Main Guide View
struct GuideView: View {
@EnvironmentObject var appState: AppState
@StateObject private var vm = GuideViewModel.shared

@State private var selectedDay: Date = guideStartOfDay(Date())
@State private var nowTick: Date = Date()
@State private var cachedHourBoundaries: [Date] = []
@State private var cachedHourBoundariesKey: Date = .distantPast

private var availableDaysSorted: [Date] {
    let cal = Calendar.current
    let today = guideStartOfDay(Date())
    return (0..<7).compactMap { cal.date(byAdding: .day, value: $0, to: today) }
}

private func computeBaseStart(for time: Date, day: Date) -> Date {
    let startD = guideStartOfDay(day)
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
private var visibleMinutes: Double { guideEndOfDay(selectedDay).timeIntervalSince(baseStart) / 60.0 }
private var visibleWidth: CGFloat { CGFloat(visibleMinutes) * guidePxPerMinute }

private var nowX: CGFloat? {
    guard Calendar.current.isDateInToday(selectedDay) else { return nil }
    let now = nowTick
    if now <= baseStart || now >= guideEndOfDay(selectedDay) { return nil }
    let mins = now.timeIntervalSince(baseStart) / 60.0
    return CGFloat(mins) * guidePxPerMinute
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
                                                Text(guideFormatDayLabel(day))
                                                    .font(.footnote)
                                                    .padding(.horizontal, 12).padding(.vertical, 6)
                                                    .background(isSel ? Color.accentColor : Color(.secondarySystemBackground))
                                                    .foregroundColor(isSel ? .white : .primary)
                                                    .clipShape(Capsule())
                                                    .glassEffect()
                                            } else {
                                                Text(guideFormatDayLabel(day))
                                                    .font(.footnote)
                                                    .padding(.horizontal, 12).padding(.vertical, 6)
                                                    .background(isSel ? Color.accentColor : Color(.secondarySystemBackground))
                                                    .foregroundColor(isSel ? .white : .primary)
                                                    .clipShape(Capsule())
                                            }
                                        }
                                        .buttonStyle(.plain)
                                        .id(guideStartOfDay(day))
                                    }
                                }
                                .padding(.horizontal)
                                .padding(.vertical, 8)
                            }
                            .onChange(of: selectedDay) { _, new in
                                withAnimation(.easeInOut) {
                                    proxy.scrollTo(guideStartOfDay(new), anchor: .center)
                                }
                                Task {
                                    let newBaseStart = computeBaseStart(for: nowTick, day: new)
                                    let vWidth = CGFloat(guideEndOfDay(new).timeIntervalSince(newBaseStart) / 60.0) * guidePxPerMinute
                                    await vm.switchDay(new, appState: appState, visibleWidth: vWidth, baseStart: newBaseStart)
                                }
                            }
                        }
                        HStack(spacing: 4) {
                            Button {
                                Task {
                                    let bStart = computeBaseStart(for: nowTick, day: selectedDay)
                                    let vWidth = CGFloat(guideEndOfDay(selectedDay).timeIntervalSince(bStart) / 60.0) * guidePxPerMinute
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
                                Color.clear.frame(height: guideHeaderHeight)
                                LazyVStack(spacing: 0) {
                                    ForEach(vm.sortedChannels, id: \.id) { ch in
                                        NavigationLink(
                                            destination: ChannelDetailView(channel: ch)
                                                .environmentObject(appState)
                                        ) {
                                            GuideChannelHeader(channel: ch)
                                                .environmentObject(appState)
                                                .frame(width: guideChannelLabelWidth, height: guideRowHeight, alignment: .leading)
                                        }
                                        .buttonStyle(.plain)
                                        .background(Color(.systemBackground))
                                        .overlay(Rectangle().fill(Color.secondary.opacity(0.1)).frame(height: 1), alignment: .bottom)
                                    }
                                }
                            }
                            .frame(width: guideChannelLabelWidth)

                            ScrollView(.horizontal, showsIndicators: true) {
                                VStack(spacing: 0) {
                                    hourTicksView
                                        .background(Color(.systemBackground))
                                    Divider()
                                    LazyVStack(spacing: 0) {
                                        ForEach(vm.sortedChannels, id: \.id) { ch in
                                            let blocks = vm.renderBlocks[selectedDay]?[ch.id] ?? []
                                            
                                            ZStack(alignment: .topLeading) {
                                                Color.clear.frame(width: visibleWidth, height: guideRowHeight)
                                                
                                                hourGridRow
                                                
                                                ForEach(blocks) { b in
                                                    self.renderProgramBlock(b, channel: ch)
                                                }
                                                
                                                if let x = nowX {
                                                    Rectangle()
                                                        .fill(Color.red)
                                                        .frame(width: 2, height: guideRowHeight)
                                                        .offset(x: x)
                                                        .allowsHitTesting(false)
                                                }
                                            }
                                            .frame(width: visibleWidth, height: guideRowHeight)
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
                    let newVisibleWidth = CGFloat(guideEndOfDay(self.selectedDay).timeIntervalSince(newBaseStart) / 60.0) * guidePxPerMinute
                    Task {
                        await vm.scheduleCollapsePrograms(for: self.selectedDay, baseStart: newBaseStart, visibleWidth: newVisibleWidth)
                    }
                }
            }
        }
        #if os(iOS)
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            Task { await vm.scheduleCollapsePrograms(for: self.selectedDay, baseStart: self.baseStart, visibleWidth: self.visibleWidth) }
        }
        #endif
    }
}

private var hourTicksView: some View {
    let end = guideEndOfDay(selectedDay)
    return ZStack(alignment: .topLeading) {
        Color.clear.frame(width: visibleWidth, height: guideHeaderHeight)
        
        ForEach(hourBoundaries(from: baseStart, to: end), id: \.self) { ts in
            let mins = ts.timeIntervalSince(baseStart) / 60.0
            let x = CGFloat(mins) * guidePxPerMinute
            
            Rectangle()
                .fill(Color.secondary.opacity(0.4))
                .frame(width: 1, height: guideHeaderHeight)
                .offset(x: x)
            
            Text(guideHourTickFormatter.string(from: ts))
                .font(.caption2)
                .foregroundColor(.secondary)
                .offset(x: x + 6, y: 6)
        }
        if let x = nowX {
            Rectangle()
                .fill(Color.red)
                .frame(width: 2, height: guideHeaderHeight)
                .offset(x: x)
                .allowsHitTesting(false)
        }
    }
    .frame(width: visibleWidth, height: guideHeaderHeight)
}

private var hourGridRow: some View {
    let end = guideEndOfDay(selectedDay)
    return ZStack(alignment: .topLeading) {
        ForEach(hourBoundaries(from: baseStart, to: end), id: \.self) { ts in
            let mins = ts.timeIntervalSince(baseStart) / 60.0
            let x = CGFloat(mins) * guidePxPerMinute
            let w = 30 * guidePxPerMinute
            
            Rectangle()
                .fill(Color.secondary.opacity(0.08))
                .frame(width: w, height: guideRowHeight)
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
    .frame(width: max(0, b.w), height: guideRowHeight - 8, alignment: .leading)
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
        "StartDate": guideIso8601InternetDateTime.string(from: s),
        "EndDate": guideIso8601InternetDateTime.string(from: e),
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
