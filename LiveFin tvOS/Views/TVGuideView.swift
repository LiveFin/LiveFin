//
//  TVGuideView.swift
//  LiveFin
//

import SwiftUI
import Combine

#if canImport(UIKit)
import UIKit
#endif

struct TVGuideView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var vm = GuideViewModel.shared
    
    @State private var selectedDay: Date = guideStartOfDay(Date())
    @State private var nowTick: Date = Date()
    @State private var focusedProgramId: String? = nil
    @State private var streamChannel: LiveTvChannelDto? = nil
    
    // Grid layout constants suitable for TV
    private let tvChannelWidth: CGFloat = 220
    private let tvRowHeight: CGFloat = 80
    private let tvHeaderHeight: CGFloat = 40
    
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
            VStack(spacing: 0) {
                // Top Hero Section for Focused Program
                heroSection
                    .frame(height: 240)
                    .background(Color(white: 0.1))
                
                if vm.isLoading && vm.channels.isEmpty {
                    Spacer()
                    ProgressView("Loading Guide…")
                    Spacer()
                } else if let msg = vm.errorMessage {
                    Spacer()
                    Text(msg).foregroundColor(.secondary)
                    Spacer()
                } else {
                    // EPG Grid
                    epgGrid
                }
            }
            .background(Color.black)
            .preferredColorScheme(.dark)
            .task {
                await vm.start(appState: appState, baseStart: baseStart, visibleWidth: visibleWidth)
                await vm.switchDay(selectedDay, appState: appState, visibleWidth: visibleWidth, baseStart: baseStart)
            }
            .onReceive(Timer.publish(every: 30, on: .main, in: .common).autoconnect()) { now in
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
            .fullScreenCover(item: $streamChannel) { channel in
                // Standard channel start execution matched from TVProgramView
                if let jfChannel = JFChannel(json: ["Id": channel.id, "Name": channel.name ?? ""]) {
                    TVPlayerView(channel: jfChannel)
                        .environmentObject(appState)
                }
            }
        }
    }
    
    // MARK: - Hero Section
    // MARK: - Hero Section
    private var heroSection: some View {
        HStack(alignment: .top, spacing: 24) {
            // Placeholder for program image
            ZStack {
                Rectangle()
                    .fill(Color.gray.opacity(0.3))
                    .frame(width: 320, height: 180)
                    .cornerRadius(12)
                
                if let program = currentlyFocusedItem {
                    let baseUrl = appState.serverURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                    let imgUrl = URL(string: "\(baseUrl)/Items/\(program.id ?? "")/Images/Primary?maxWidth=640&api_key=\(appState.apiKey)")
                    
                    AsyncImage(url: imgUrl) { phase in
                        if let image = phase.image {
                            image.resizable().scaledToFill()
                                .frame(width: 320, height: 180)
                                .cornerRadius(12)
                        } else {
                            Text(program.name ?? "No Image")
                                .foregroundColor(.white.opacity(0.5))
                        }
                    }
                }
            }
            .frame(width: 320, height: 180)
            
            VStack(alignment: .leading, spacing: 8) {
                if let program = currentlyFocusedItem {
                    Text(program.name ?? "Untitled")
                        .font(.system(size: 36, weight: .bold))
                        .lineLimit(1)
                    
                    HStack(spacing: 8) {
                        if let sName = program.seriesName, !sName.isEmpty {
                            Text(sName).foregroundColor(.secondary)
                        }
                        if let eTitle = program.episodeTitle, !eTitle.isEmpty {
                            Text("| \(eTitle)").foregroundColor(.secondary)
                        }
                        
                        Text("| \(timeRangeString(for: program))")
                            .foregroundColor(.secondary)
                    }
                    .font(.title3)
                    
                    Text(program.overview ?? "No description available.")
                        .font(.body)
                        .foregroundColor(.gray)
                        .lineLimit(3)
                        .padding(.top, 4)
                } else {
                    Text("Select a program to view details.")
                        .font(.title2)
                        .foregroundColor(.gray)
                }
            }
            .padding(.top, 12)
            
            Spacer()
        }
        .padding(30)
    }
    
    // MARK: - Grid View
    // MARK: - Grid View
    private var epgGrid: some View {
        ScrollView(.vertical, showsIndicators: false) {
            HStack(alignment: .top, spacing: 0) {
                
                // Fixed Channel List
                VStack(spacing: 0) {
                    // Empty space for time header alignment
                    Color.clear.frame(height: tvHeaderHeight)
                        .overlay(
                            Text(dateFormatter.string(from: selectedDay))
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.leading, 16)
                        )
                    
                    LazyVStack(spacing: 0) {
                        ForEach(vm.sortedChannels, id: \.id) { ch in
                            tvChannelRow(channel: ch)
                                .frame(width: tvChannelWidth, height: tvRowHeight)
                                .background(Color(white: 0.15))
                                .border(Color.black, width: 0.5)
                        }
                    }
                }
                .frame(width: tvChannelWidth)
                .zIndex(1)
                
                // Scrollable Timeline & Programs
                ScrollView(.horizontal, showsIndicators: false) {
                    VStack(spacing: 0) {
                        // Timeline Header
                        tvHourTicksView
                            .frame(height: tvHeaderHeight)
                            .background(Color(white: 0.1))
                        
                        // Program Blocks Grid
                        LazyVStack(spacing: 0) {
                            ForEach(vm.sortedChannels, id: \.id) { ch in
                                let blocks = vm.renderBlocks[selectedDay]?[ch.id] ?? []
                                let hasFocusedProgram = blocks.contains(where: { $0.item.id == focusedProgramId })
                                
                                ZStack(alignment: .topLeading) {
                                    Color.clear.frame(width: max(visibleWidth, UIScreen.main.bounds.width), height: tvRowHeight)
                                    
                                    // Background grid lines
                                    tvHourGridRow
                                    
                                    // Render Programs
                                    HStack(spacing: 0) {
                                        ForEach(Array(blocks.enumerated()), id: \.element.id) { index, b in
                                            let prevEnd = index == 0 ? 0 : (blocks[index - 1].x + blocks[index - 1].w)
                                            let gap = max(0, b.x - prevEnd)
                                            
                                            if gap > 0 {
                                                Color.clear.frame(width: gap, height: tvRowHeight)
                                            }
                                            
                                            tvProgramBlock(b, channel: ch)
                                        }
                                    }
                                    
                                    // Current Time Indicator
                                    if let x = nowX {
                                        Rectangle()
                                            .fill(Color.cyan)
                                            .frame(width: 2, height: tvRowHeight)
                                            .offset(x: x)
                                            .allowsHitTesting(false)
                                            .zIndex(10)
                                    }
                                }
                                .frame(width: max(visibleWidth, UIScreen.main.bounds.width), height: tvRowHeight)
                                .border(Color.black, width: 0.5)
                                .zIndex(hasFocusedProgram ? 10 : 0) // Lift row above others if it contains focused item
                            }
                        }
                    }
                }
            }
        }
    }
    
    // MARK: - Components
    @ViewBuilder
    private func tvChannelRow(channel: LiveTvChannelDto) -> some View {
        let isFocused = focusedProgramId == channel.id
        
        Button(action: {
            streamChannel = channel
        }) {
            HStack(spacing: 12) {
                VStack(spacing: 4) {
                    if channel.userData?.isFavorite == true {
                        Image(systemName: "heart.fill").foregroundColor(.gray).font(.caption2)
                    }
                    Text(channel.number ?? "")
                        .font(.caption)
                        .foregroundColor(.gray)
                }
                .frame(width: 40)
                
                ChannelImageView(baseUrl: appState.serverURL, apiKey: appState.apiKey, channelId: channel.id)
                    .frame(width: 60, height: 40)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                
                Text(channel.name ?? "Channel")
                    .font(.callout)
                    .bold()
                    .lineLimit(2)
                    .foregroundColor(.white)
                
                Spacer()
            }
            .padding(.horizontal, 12)
            .frame(width: tvChannelWidth, height: tvRowHeight)
            .background(isFocused ? Color(white: 0.3) : Color.clear)
        }
        .buttonStyle(.plain)
        .contentShape(RoundedRectangle(cornerRadius: 6))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .scaleEffect(isFocused ? 1.04 : 1.0)
        .zIndex(isFocused ? 100 : 1)
        .onFocusChange { focused in
            if focused {
                self.focusedProgramId = channel.id
            }
        }
    }
    
    private var tvHourTicksView: some View {
        let end = guideEndOfDay(selectedDay)
        let boundaries = hourBoundaries(from: baseStart, to: end)
        
        return ZStack(alignment: .topLeading) {
            ForEach(boundaries, id: \.self) { ts in
                let mins = ts.timeIntervalSince(baseStart) / 60.0
                let x = CGFloat(mins) * guidePxPerMinute
                
                Text(timeFormatterSmall.string(from: ts))
                    .font(.subheadline)
                    .foregroundColor(.gray)
                    .offset(x: x + 8, y: 10)
            }
            
            if let x = nowX {
                Polygon()
                    .fill(Color.cyan)
                    .frame(width: 12, height: 8)
                    .offset(x: x - 6, y: 0)
                Rectangle()
                    .fill(Color.cyan)
                    .frame(width: 2, height: tvHeaderHeight)
                    .offset(x: x, y: 0)
            }
        }
    }
    
    private var tvHourGridRow: some View {
        let end = guideEndOfDay(selectedDay)
        let boundaries = hourBoundaries(from: baseStart, to: end)
        
        return ZStack(alignment: .topLeading) {
            ForEach(boundaries, id: \.self) { ts in
                let mins = ts.timeIntervalSince(baseStart) / 60.0
                let x = CGFloat(mins) * guidePxPerMinute
                
                Rectangle()
                    .fill(Color.white.opacity(0.1))
                    .frame(width: 1, height: tvRowHeight)
                    .offset(x: x)
            }
        }
    }
    
    @ViewBuilder
    private func tvProgramBlock(_ b: RenderBlock, channel: LiveTvChannelDto) -> some View {
        let isFocused = focusedProgramId == b.item.id
        let baseColor = colorForProgram(b.item)
        
        NavigationLink(destination: TVProgramView(program: buildJFProgram(from: b.item, channel: channel), appState: appState)) {
            ZStack(alignment: .leading) {
                // Base background
                Rectangle()
                    .fill(isFocused ? baseColor : baseColor.opacity(0.3))
                
                // Border for block separation
                Rectangle()
                    .strokeBorder(Color.black.opacity(0.5), lineWidth: 1)
                
                Text(b.item.name ?? "Untitled")
                    .font(.callout)
                    .fontWeight(isFocused ? .bold : .regular)
                    .foregroundColor(isFocused ? .white : .gray)
                    .shadow(color: isFocused ? .black.opacity(0.6) : .clear, radius: 1, x: 0, y: 1)
                    .lineLimit(1)
                    .padding(.horizontal, 12)
            }
        }
        .buttonStyle(.plain)
        .frame(width: max(0, b.w), height: tvRowHeight)
        .contentShape(RoundedRectangle(cornerRadius: 6))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .scaleEffect(isFocused ? 1.04 : 1.0) // Pops out item
        .zIndex(isFocused ? 100 : 1) // Elevates program block ZIndex above all others
        .onFocusChange { focused in
            if focused {
                self.focusedProgramId = b.item.id
            }
        }
    }
    
    // MARK: - Helpers
    
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
    
    private func buildJFProgram(from item: BaseItemDto, channel: LiveTvChannelDto) -> JFProgram {
        let fallbackId = item.id ?? "epg_\(channel.id)_\(Int((item.startDate ?? Date()).timeIntervalSince1970))"
        var dict: [String: Any] = [
            "Id": fallbackId,
            "Name": item.name ?? "",
            "ChannelId": channel.id
        ]
        if let s = item.startDate { dict["StartDate"] = ISO8601DateFormatter().string(from: s) }
        if let e = item.endDate { dict["EndDate"] = ISO8601DateFormatter().string(from: e) }
        if let cn = channel.name { dict["ChannelName"] = cn }
        if let ov = item.overview { dict["Overview"] = ov }
        if let et = item.episodeTitle { dict["EpisodeTitle"] = et }
        if let r = item.officialRating { dict["OfficialRating"] = r }
        if let pi = item.parentIndexNumber { dict["ParentIndexNumber"] = pi }
        if let idx = item.indexNumber { dict["IndexNumber"] = idx }
        if let rep = item.isRepeat { dict["IsRepeat"] = rep }
        if let isM = item.isMovie { dict["IsMovie"] = isM }
        if let gs = item.genres { dict["Genres"] = gs }
        if let sid = item.seriesId { dict["SeriesId"] = sid }
        if let isS = item.isSeries { dict["IsSeries"] = isS }
        if let sname = item.seriesName { dict["SeriesName"] = sname }
        return JFProgram(json: dict) ?? JFProgram(json: ["Id": fallbackId, "Name": item.name ?? ""])!
    }
    
    private var currentlyFocusedItem: BaseItemDto? {
        guard let id = focusedProgramId else { return nil }
        for (_, channelsMap) in vm.renderBlocks {
            for (_, blocks) in channelsMap {
                if let match = blocks.first(where: { $0.item.id == id }) {
                    return match.item
                }
            }
        }
        return nil
    }
    
    private func hourBoundaries(from: Date, to: Date) -> [Date] {
        var result: [Date] = []
        var cur = from
        let cal = Calendar.current
        while cur < to {
            result.append(cur)
            cur = cal.date(byAdding: .minute, value: 30, to: cur) ?? to
        }
        return result
    }
    
    private let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mma"
        f.amSymbol = "p"
        f.pmSymbol = "p" // Mimicking "7:18p" from the image
        return f
    }()
    
    private let timeFormatterSmall: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f
    }()
    
    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE. M/d"
        return f
    }()
    
    private func timeRangeString(for item: BaseItemDto) -> String {
        guard let s = item.startDate, let e = item.endDate else { return "" }
        return "\(timeFormatterSmall.string(from: s)) - \(timeFormatterSmall.string(from: e))"
    }
}

// Simple shape for the playhead pointer
struct Polygon: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

// tvOS custom focus extension
extension View {
    func onFocusChange(_ perform: @escaping (Bool) -> Void) -> some View {
        self.modifier(FocusModifier(action: perform))
    }
}

private struct FocusModifier: ViewModifier {
    @FocusState private var isFocused: Bool
    let action: (Bool) -> Void
    
    func body(content: Content) -> some View {
        content
            .focused($isFocused)
            // Updated to fallback safely across SwiftUI versions while passing the focus state
            .onChange(of: isFocused) { _, newValue in
                action(newValue)
            }
    }
}
