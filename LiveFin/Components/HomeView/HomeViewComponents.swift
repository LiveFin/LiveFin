//
//  HomeViewComponents.swift
//  LiveFin
//
//  Created by KPGamingz on 9/12/25.
//

import SwiftUI

// MARK: - Section Header

struct SectionHeader: View {
    let title: String
    init(_ title: String) { self.title = title }
    var body: some View {
        Text(title)
            .font(.title2).bold()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)
    }
}

// MARK: - Row Style

enum RowStyle { case landscape, portrait }

// MARK: - Horizontal Programs Row

struct HorizontalProgramsRow: View {
    let programs: [JFProgram]
    let style: RowStyle
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var vm: HomeViewModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 8) {
                ForEach(programs) { program in
                    NavigationLink(destination: ProgramView(program: program, appState: appState)
                        .environmentObject(appState)
                        .environmentObject(vm)) {
                        ProgramCard(program: program, style: style)
                            .environmentObject(appState)
                            .environmentObject(vm)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 12) // Adds breathing room inside the ScrollView so text isn't clipped
        }
    }
}

// MARK: - Horizontal Channels Row

struct HorizontalChannelsRow: View {
    let channels: [JFChannel]
    @EnvironmentObject private var appState: AppState

    private func rainbowColor(for index: Int) -> Color {
        let hue = Double(index) / Double(max(channels.count, 1))
        return Color(hue: hue, saturation: 0.8, brightness: 1.0)
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .center, spacing: 10) {
                ForEach(Array(channels.enumerated()), id: \.element.id) { index, channel in
                    NavigationLink(destination: ChannelDetailView(channel: channel.asLiveDto(baseURL: appState.serverURL))) {
                        ZStack {
                            if #available(iOS 26.0, *) {
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .glassEffect(.regular.tint(rainbowColor(for: index).opacity(0.45)).interactive(), in: .rect(cornerRadius: 16.0))
                            } else {
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .fill(.ultraThinMaterial)
                            }
                            ChannelImageView(baseUrl: appState.serverURL, apiKey: appState.apiKey, channelId: channel.id)
                                .frame(width: 67, height: 67)
                        }
                        .frame(width: 84, height: 84)
                        .accessibilityLabel(Text(channel.name))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)
            .frame(minHeight: 90)
        }
    }
}

// MARK: - Program Card

struct ProgramCard: View {
    let program: JFProgram
    let style: RowStyle
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var vm: HomeViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack(alignment: .bottomLeading) {
                ProgramImage(program: program)
                    .frame(width: imageWidth, height: imageHeight)
                    .background(Color(UIColor.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                if let progress = progressRatio, progress > 0, progress < 1 {
                    ZStack(alignment: .leading) {
                        Rectangle().fill(Color.black.opacity(0.35)).frame(height: 4)
                        Rectangle().fill(Color.white).frame(width: imageWidth * progress, height: 4)
                    }
                    .clipShape(Capsule())
                    .padding(6)
                }
            }
            Text(program.name)
                .font(.headline)
                .lineLimit(1)
                .frame(maxWidth: imageWidth, alignment: .leading)
            if let subtitle = programSubtitle {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: imageWidth, alignment: .leading)
            }
            if let timeLine = timeLine {
                Text(timeLine)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: imageWidth, alignment: .leading)
            }
            Text(channelLine)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .frame(maxWidth: imageWidth, alignment: .leading)
        }
        .fixedSize(horizontal: false, vertical: true) // Prevents SwiftUI from squishing the vertical height of the text
        .padding(.bottom, 12) // Forces physical breathing room at the bottom of the card
    }

    private var imageWidth: CGFloat  { style == .portrait ? 120 : 220 }
    private var imageHeight: CGFloat { style == .portrait ? 180 : 124 }

    private var programSubtitle: String? {
        let seasonEpisode: String? = {
            guard let s = program.parentIndexNumber, let e = program.indexNumber else { return nil }
            return String(format: "S%02dE%02d", s, e)
        }()
        if let ep = program.episodeTitle, !ep.isEmpty {
            return seasonEpisode.map { "\($0) • \(ep)" } ?? ep
        }
        return seasonEpisode
    }

    private var timeLine: String? {
        guard let start = program.startDate else { return nil }
        let end: Date? = {
            if let e = program.endDate { return e }
            if let t = program.runTimeTicks { return start.addingTimeInterval(TimeInterval(Double(t) / 10_000_000.0)) }
            return nil
        }()
        guard let end else { return nil }
        return "\(start.formatted(date: .omitted, time: .shortened)) – \(end.formatted(date: .omitted, time: .shortened))"
    }

    private var channelLine: String {
        (program.channelName ?? vm.channelName(for: program.channelId)) ?? "Unknown channel"
    }

    private var progressRatio: Double? {
        guard let start = program.startDate else { return nil }
        let end: Date? = {
            if let e = program.endDate { return e }
            if let t = program.runTimeTicks { return start.addingTimeInterval(TimeInterval(Double(t) / 10_000_000.0)) }
            return nil
        }()
        guard let end else { return nil }
        let now = Date()
        guard start <= now, now <= end else { return nil }
        let total = end.timeIntervalSince(start)
        guard total > 1 else { return nil }
        return min(max(now.timeIntervalSince(start) / total, 0), 1)
    }
}

// MARK: - Empty Section Placeholder

struct EmptySectionPlaceholder: View {
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack { Text("No items right now").foregroundColor(.secondary) }
                .frame(height: 20)
                .padding(.horizontal)
        }
    }
}

// MARK: - Array Helper

extension Array where Element == JFProgram {
    func prefixed(_ n: Int) -> [JFProgram] { Array(self.prefix(n)) }
}
