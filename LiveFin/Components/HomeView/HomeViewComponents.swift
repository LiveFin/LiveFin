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
                ForEach(Array(programs.enumerated()), id: \.offset) { index, program in
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
            .padding(.bottom, 12)
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
                ForEach(Array(channels.enumerated()), id: \.offset) { index, channel in
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
        let base = appState.serverURL.hasSuffix("/") ? String(appState.serverURL.dropLast()) : appState.serverURL

        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomLeading) {
                Color(UIColor.secondarySystemBackground)
                    .frame(width: imageWidth, height: imageHeight)
                
                if let url = URL(string: "\(base)/Items/\(program.id)/Images/Primary?maxWidth=400&ApiKey=\(appState.apiKey)") {
                    CachedAsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let image):
                            ZStack {
                                // 1. Blurred background filling the box (prevents ugly empty spaces for portrait images)
                                image
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                                    .frame(width: imageWidth, height: imageHeight)
                                    .blur(radius: 15)
                                    .opacity(0.6)
                                    .clipped()
                                
                                // 2. The actual image fitted cleanly inside the box
                                image
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(width: imageWidth, height: imageHeight)
                            }
                        case .failure, .empty:
                            fallbackImage
                        @unknown default:
                            fallbackImage
                        }
                    }
                    .frame(width: imageWidth, height: imageHeight)
                } else {
                    fallbackImage
                }
                
                if let progress = progressRatio, progress > 0, progress < 1 {
                    ZStack(alignment: .leading) {
                        Rectangle()
                            .fill(Color.black.opacity(0.35))
                            .frame(width: max(0, imageWidth - 12), height: 4)
                        Rectangle()
                            .fill(Color.white)
                            .frame(width: max(0, (imageWidth - 12) * progress), height: 4)
                    }
                    .clipShape(Capsule())
                    .padding(6)
                }
            }
            .frame(width: imageWidth, height: imageHeight)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .shadow(color: Color.black.opacity(0.12), radius: 4, x: 0, y: 2)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(program.name)
                    .font(.headline)
                    .foregroundColor(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
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
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.bottom, 12)
    }

    private var imageWidth: CGFloat  { style == .portrait ? 120 : 220 }
    private var imageHeight: CGFloat { style == .portrait ? 180 : 124 }

    @ViewBuilder
    private var fallbackImage: some View {
        VStack(spacing: 8) {
            Image(systemName: "tv")
                .font(.system(size: style == .portrait ? 28 : 24))
                .foregroundColor(.secondary)
            Text(program.name)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .padding(.horizontal, 6)
        }
        .frame(width: imageWidth, height: imageHeight)
        .background(Color(UIColor.secondarySystemBackground))
    }

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

// MARK: - Array Helper

extension Array where Element == JFProgram {
    func prefixed(_ n: Int) -> [JFProgram] { Array(self.prefix(n)) }
}

// MARK: - Horizontal Library Items Row

struct HorizontalLibraryItemsRow: View {
    let items: [JFItemDto]
    let style: RowStyle
    var playDirectly: Bool = false
    
    @EnvironmentObject private var appState: AppState
    @State private var streamContext: StreamContext? = nil

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 8) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    if playDirectly {
                        Button {
                            streamContext = StreamContext(playlist: [item], startIndex: 0)
                        } label: {
                            LibraryItemCard(item: item, style: style)
                                .environmentObject(appState)
                        }
                        .buttonStyle(.plain)
                    } else {
                        NavigationLink(destination: MediaItemDetailView(item: item).environmentObject(appState)) {
                            LibraryItemCard(item: item, style: style)
                                .environmentObject(appState)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 12)
        }
        .fullScreenCover(item: $streamContext) { context in
            PlanktonPlayerView(
                playlist: context.playlist,
                startIndex: context.startIndex,
                seriesName: nil,
                appState: appState
            )
            .environmentObject(appState)
        }
    }
}

// MARK: - Library Item Card

struct LibraryItemCard: View {
    let item: JFItemDto
    let style: RowStyle
    @EnvironmentObject private var appState: AppState

    var body: some View {
        let base = appState.serverURL.hasSuffix("/") ? String(appState.serverURL.dropLast()) : appState.serverURL
        
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomLeading) {
                Color(UIColor.secondarySystemBackground)
                    .frame(width: imageWidth, height: imageHeight)
                
                Group {
                    if style == .landscape {
                        // FIXED: Appended ApiKey parameter securely to all image URLs
                        if let backdropTag = item.backdropImageTag,
                           let url = URL(string: "\(base)/Items/\(item.Id)/Images/Backdrop/0?tag=\(backdropTag)&maxWidth=400&ApiKey=\(appState.apiKey)") {
                            CachedAsyncImage(url: url) { phase in
                                switch phase {
                                case .success(let image):
                                    image
                                        .resizable()
                                        .aspectRatio(contentMode: .fill)
                                case .failure, .empty:
                                    fallbackImage
                                @unknown default:
                                    fallbackImage
                                }
                            }
                        } else if let primaryTag = item.primaryImageTag,
                                  let url = URL(string: "\(base)/Items/\(item.Id)/Images/Primary?tag=\(primaryTag)&maxWidth=400&ApiKey=\(appState.apiKey)") {
                            CachedAsyncImage(url: url) { phase in
                                switch phase {
                                case .success(let image):
                                    image
                                        .resizable()
                                        .aspectRatio(contentMode: .fill)
                                case .failure, .empty:
                                    fallbackImage
                                @unknown default:
                                    fallbackImage
                                }
                            }
                        } else {
                            fallbackImage
                        }
                    } else {
                        // FIXED: Appended ApiKey parameter securely to all image URLs
                        if let primaryTag = item.primaryImageTag,
                           let url = URL(string: "\(base)/Items/\(item.Id)/Images/Primary?tag=\(primaryTag)&maxWidth=300&ApiKey=\(appState.apiKey)") {
                            CachedAsyncImage(url: url) { phase in
                                switch phase {
                                case .success(let image):
                                    image
                                        .resizable()
                                        .aspectRatio(contentMode: .fill)
                                case .failure, .empty:
                                    fallbackImage
                                @unknown default:
                                    fallbackImage
                                }
                            }
                        } else {
                            fallbackImage
                        }
                    }
                }
                .frame(width: imageWidth, height: imageHeight)
                
                if let progress = progressRatio, progress > 0, progress < 1 {
                    ZStack(alignment: .leading) {
                        Rectangle()
                            .fill(Color.black.opacity(0.35))
                            .frame(width: max(0, imageWidth - 12), height: 4)
                        Rectangle()
                            .fill(Color.blue)
                            .frame(width: max(0, (imageWidth - 12) * progress), height: 4)
                    }
                    .clipShape(Capsule())
                    .padding(6)
                }
            }
            .frame(width: imageWidth, height: imageHeight)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .shadow(color: Color.black.opacity(0.12), radius: 4, x: 0, y: 2)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(displayTitle)
                    .font(.headline)
                    .foregroundColor(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: imageWidth, alignment: .leading)
                
                if let subtitle = itemSubtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .frame(maxWidth: imageWidth, alignment: .leading)
                }
                
                if let secondaryInfo = secondaryInfoLine {
                    Text(secondaryInfo)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .frame(maxWidth: imageWidth, alignment: .leading)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.bottom, 12)
    }

    private var imageWidth: CGFloat  { style == .portrait ? 120 : 220 }
    private var imageHeight: CGFloat { style == .portrait ? 180 : 124 }

    private var displayTitle: String {
        if item.Type.lowercased() == "episode", let seriesName = item.SeriesName, !seriesName.isEmpty {
            return seriesName
        }
        return item.Name
    }

    private var itemSubtitle: String? {
        if item.Type.lowercased() == "episode" {
            let s = item.ParentIndexNumber.map { String(format: "S%02d", $0) } ?? ""
            let e = item.IndexNumber.map { String(format: "E%02d", $0) } ?? ""
            let se = [s, e].filter { !$0.isEmpty }.joined()
            
            if !se.isEmpty {
                return "\(se) • \(item.Name)"
            } else {
                return item.Name
            }
        }
        return item.Genres?.first
    }

    @ViewBuilder
    private var fallbackImage: some View {
        VStack(spacing: 8) {
            Image(systemName: item.Type == "Series" ? "tv" : "film")
                .font(.system(size: style == .portrait ? 28 : 24))
                .foregroundColor(.secondary)
            Text(item.Name)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .padding(.horizontal, 6)
        }
        .frame(width: imageWidth, height: imageHeight)
        .background(Color(UIColor.secondarySystemBackground))
    }

    private var secondaryInfoLine: String? {
        if let year = item.ProductionYear {
            return String(year)
        }
        return nil
    }

    private var progressRatio: Double? {
        guard let ticks = item.UserData?.PlaybackPositionTicks, ticks > 0,
              let total = item.RunTimeTicks, total > 0 else { return nil }
        return min(max(Double(ticks) / Double(total), 0.0), 1.0)
    }
}
