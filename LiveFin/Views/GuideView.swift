//
//  GuideView.swift
//  LiveFin
//

import SwiftUI
import Foundation
import Combine
import JellyfinAPI

#if canImport(UIKit)
import UIKit
#endif

// MARK: - Preference Key for Synchronized Horizontal Scrolling
struct ScrollOffsetPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

// MARK: - Main Guide View (iOS)
struct GuideView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var vm = GuideViewModel.shared

    @State private var selectedDay: Date = guideStartOfDay(Date())
    @State private var horizontalScrollOffset: CGFloat = 0

    private var availableDaysSorted: [Date] {
        let cal = Calendar.current
        let today = guideStartOfDay(Date())
        return (0..<7).compactMap { cal.date(byAdding: .day, value: $0, to: today) }
    }

    private func computeBaseStart(for day: Date) -> Date {
        let startD = guideStartOfDay(day)
        guard Calendar.current.isDateInToday(day) else { return startD }
        let now = Date()
        let cal = Calendar.current
        let comps = cal.dateComponents([.year, .month, .day, .hour, .minute], from: now)
        
        var newComps = DateComponents()
        newComps.year = comps.year
        newComps.month = comps.month
        newComps.day = comps.day
        newComps.hour = comps.hour
        newComps.minute = (comps.minute ?? 0) >= 30 ? 30 : 0
        newComps.second = 0
        newComps.nanosecond = 0
        
        let aligned = cal.date(from: newComps) ?? now
        return max(startD, aligned)
    }

    private var baseStart: Date { computeBaseStart(for: selectedDay) }
    private var visibleMinutes: Double { guideEndOfDay(selectedDay).timeIntervalSince(baseStart) / 60.0 }
    private var visibleWidth: CGFloat { CGFloat(visibleMinutes) * guidePxPerMinute }

    var body: some View {
        NavigationStack {
            Group {
                if vm.isLoading && vm.channels.isEmpty {
                    ProgressView("Loading Guide…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let msg = vm.errorMessage, vm.channels.isEmpty {
                    errorStateView(message: msg)
                } else if vm.channels.isEmpty {
                    emptyStateView
                } else {
                    guideContentView
                }
            }
            .navigationTitle("Guide")
            .task(id: appState.accessToken) {
                guard !appState.accessToken.isEmpty else { return }
                await vm.start(appState: appState, baseStart: baseStart, visibleWidth: visibleWidth)
            }
        }
    }

    @ViewBuilder
    private func errorStateView(message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundColor(.orange)
            
            VStack(spacing: 8) {
                Text("Unable to Load Guide")
                    .font(.title3.bold())
                Text(message)
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
    }

    private var emptyStateView: some View {
        VStack(spacing: 12) {
            Text("No channels available").foregroundColor(.secondary)
            Button("Reload") {
                Task { await vm.start(appState: appState, baseStart: baseStart, visibleWidth: visibleWidth) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var guideContentView: some View {
        VStack(spacing: 0) {
            daySelectorHeader
            Divider()
            stickyTimelineHeader // Pinned permanently outside the vertical scrollview
            Divider()
            gridScrollView
        }
    }

    private var daySelectorHeader: some View {
        HStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(availableDaysSorted, id: \.self) { day in
                            let isSel = Calendar.current.isDate(day, inSameDayAs: selectedDay)
                            Button {
                                selectedDay = day
                            } label: {
                                dayCapsuleLabel(day: day, isSelected: isSel)
                            }
                            .buttonStyle(.plain)
                            .id(guideStartOfDay(day))
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                }
                .onChange(of: selectedDay) { _, newDay in
                    withAnimation(.easeInOut) {
                        proxy.scrollTo(guideStartOfDay(newDay), anchor: .center)
                    }
                    Task {
                        let newBaseStart = computeBaseStart(for: newDay)
                        let vWidth = CGFloat(guideEndOfDay(newDay).timeIntervalSince(newBaseStart) / 60.0) * guidePxPerMinute
                        await vm.switchDay(newDay, appState: appState, visibleWidth: vWidth, baseStart: newBaseStart)
                    }
                }
            }
            
            Button {
                Task {
                    let bStart = computeBaseStart(for: selectedDay)
                    let vWidth = CGFloat(guideEndOfDay(selectedDay).timeIntervalSince(bStart) / 60.0) * guidePxPerMinute
                    await vm.manualRefresh(appState: appState, currentDay: selectedDay, baseStart: bStart, visibleWidth: vWidth)
                }
            } label: {
                refreshButtonLabel
            }
            .buttonStyle(.plain)
            .padding(.trailing, 8)
        }
    }

    @ViewBuilder
    private var refreshButtonLabel: some View {
        let icon = Group {
            if vm.isRefreshing {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 16, weight: .medium))
            }
        }
        .frame(width: 36, height: 36)
        .contentShape(Rectangle())

        if #available(iOS 26.0, *) {
            icon
                .clipShape(Circle())
                .glassEffect(.regular.interactive(), in: .circle)
        } else {
            icon
                .background(Color(.secondarySystemBackground))
                .clipShape(Circle())
        }
    }

    @ViewBuilder
    private func dayCapsuleLabel(day: Date, isSelected: Bool) -> some View {
        let label = guideFormatDayLabel(day)
        let bg = isSelected ? Color.accentColor : Color(.secondarySystemBackground)
        let fg = isSelected ? Color.white : Color.primary

        if #available(iOS 26.0, *) {
            Text(label)
                .font(.footnote)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(bg)
                .foregroundColor(fg)
                .clipShape(Capsule())
                .glassEffect()
        } else {
            Text(label)
                .font(.footnote)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(bg)
                .foregroundColor(fg)
                .clipShape(Capsule())
        }
    }

    // Pinned sticky timeline header
    private var stickyTimelineHeader: some View {
        HStack(spacing: 0) {
            timeCornerView
            
            GeometryReader { _ in
                hourTicksView
                    .offset(x: horizontalScrollOffset)
            }
            .frame(height: guideHeaderHeight)
            .clipped()
        }
        .background(Color(.systemBackground))
        .zIndex(10)
    }

    private var timeCornerView: some View {
        VStack(spacing: 0) {
            Text("Channel")
                .font(.caption2.bold())
                .foregroundColor(.secondary)
        }
        .frame(width: guideChannelLabelWidth, height: guideHeaderHeight)
        .background(Color(.systemBackground))
        .overlay(
            Rectangle().fill(Color.secondary.opacity(0.1)).frame(height: 1), alignment: .bottom
        )
    }

    private var gridScrollView: some View {
        ScrollView(.vertical, showsIndicators: true) {
            HStack(alignment: .top, spacing: 0) {
                channelHeadersColumn
                programBlocksScrollView
            }
        }
    }

    private var channelHeadersColumn: some View {
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
        .frame(width: guideChannelLabelWidth)
    }

    private var programBlocksScrollView: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            LazyVStack(spacing: 0) {
                ForEach(vm.sortedChannels, id: \.id) { ch in
                    let blocks = vm.renderBlocks[selectedDay]?[ch.id] ?? []
                    
                    ZStack(alignment: .topLeading) {
                        Color.clear.frame(width: visibleWidth, height: guideRowHeight)
                        
                        hourGridRow
                        
                        ForEach(blocks) { b in
                            ProgramBlockView(b: b, channel: ch, appState: appState)
                        }
                        
                        NowLineOverlay(baseStart: baseStart, selectedDay: selectedDay, rowHeight: guideRowHeight)
                    }
                    .frame(width: visibleWidth, height: guideRowHeight)
                    .background(Color(.secondarySystemBackground))
                    .clipped()
                }
            }
            .background(
                GeometryReader { geo in
                    Color.clear.preference(
                        key: ScrollOffsetPreferenceKey.self,
                        value: geo.frame(in: .named("guideScrollSpace")).minX
                    )
                }
            )
        }
        .coordinateSpace(name: "guideScrollSpace")
        .onPreferenceChange(ScrollOffsetPreferenceKey.self) { val in
            self.horizontalScrollOffset = val
        }
    }

    private var hourTicksView: some View {
        let end = guideEndOfDay(selectedDay)
        let boundaries = calculatedHourBoundaries(from: baseStart, to: end)
        return ZStack(alignment: .topLeading) {
            Color.clear.frame(width: visibleWidth, height: guideHeaderHeight)
            
            ForEach(boundaries, id: \.self) { ts in
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
            NowLineOverlay(baseStart: baseStart, selectedDay: selectedDay, rowHeight: guideHeaderHeight)
        }
        .frame(width: visibleWidth, height: guideHeaderHeight, alignment: .topLeading)
    }

    private var hourGridRow: some View {
        let end = guideEndOfDay(selectedDay)
        let boundaries = calculatedHourBoundaries(from: baseStart, to: end)
        return ZStack(alignment: .topLeading) {
            ForEach(boundaries, id: \.self) { ts in
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

    private func calculatedHourBoundaries(from: Date, to: Date) -> [Date] {
        var result: [Date] = []
        var cur = from
        let cal = Calendar.current
        while cur < to {
            result.append(cur)
            cur = cal.date(byAdding: .minute, value: 30, to: cur) ?? to
        }
        return result
    }
}

// MARK: - Isolated Decoupled Now-Line Component
struct NowLineOverlay: View {
    let baseStart: Date
    let selectedDay: Date
    let rowHeight: CGFloat

    @State private var nowX: CGFloat? = nil

    var body: some View {
        Group {
            if let x = nowX {
                Rectangle()
                    .fill(Color.red)
                    .frame(width: 2, height: rowHeight)
                    .offset(x: x)
                    .allowsHitTesting(false)
            }
        }
        .onReceive(Timer.publish(every: 15, on: .main, in: .common).autoconnect()) { _ in
            updateX()
        }
        .onAppear { updateX() }
    }

    private func updateX() {
        guard Calendar.current.isDateInToday(selectedDay) else {
            nowX = nil
            return
        }
        let now = Date()
        let end = guideEndOfDay(selectedDay)
        if now <= baseStart || now >= end {
            nowX = nil
        } else {
            let mins = now.timeIntervalSince(baseStart) / 60.0
            nowX = CGFloat(mins) * guidePxPerMinute
        }
    }
}

// MARK: - Equatable Lightweight Program Block View
struct ProgramBlockView: View, Equatable {
    let b: RenderBlock
    let channel: LiveTvChannelDto
    let appState: AppState

    static func == (lhs: ProgramBlockView, rhs: ProgramBlockView) -> Bool {
        return lhs.b == rhs.b
    }

    var body: some View {
        let jf = buildJFProgram(from: b.item, channel: channel, clampedStart: b.s, clampedEnd: b.e)

        NavigationLink(destination: ProgramView(program: jf, appState: appState).environmentObject(appState)) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .top) {
                    Text(b.item.name ?? "Untitled")
                        .font(.caption).bold()
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .allowsTightening(true)
                    
                    if b.isRecording {
                        Spacer(minLength: 2)
                        Image(systemName: "record.circle")
                            .foregroundColor(.red)
                            .font(.system(size: 10))
                    }
                }
                Text(b.formattedTimeString)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            .padding(6)
            .frame(width: max(0, b.w), height: guideRowHeight - 8, alignment: .leading)
            .background(b.color.opacity(0.15))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(b.color.opacity(0.3), lineWidth: 1))
            .contentShape(Rectangle())
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
