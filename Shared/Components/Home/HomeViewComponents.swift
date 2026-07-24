//
//  HomeViewComponents.swift
//  LiveFin
//

import SwiftUI

// MARK: - Dynamic Greeting Helper

/// Calculates the Gregorian Easter Sunday for any given year.
private func easterDate(for year: Int) -> (month: Int, day: Int)? {
    let a = year % 19
    let b = year / 100
    let c = year % 100
    let d = b / 4
    let e = b % 4
    let f = (b + 8) / 25
    let g = (b - f + 1) / 3
    let h = (19 * a + b - d - g + 15) % 30
    let i = c / 4
    let k = c % 4
    let l = (32 + 2 * e + 2 * i - h - k) % 7
    let m = (a + 11 * h + 22 * l) / 451
    let month = (h + l - 7 * m + 114) / 31
    let day = ((h + l - 7 * m + 114) % 31) + 1
    return (month, day)
}

/// Generates a personalized greeting based on time of day or major holidays.
/// Shared across iOS and tvOS targets via HomeViewComponents.
func customGreeting(for username: String, date: Date = Date()) -> String {
    let calendar = Calendar.current
    let month = calendar.component(.month, from: date)
    let day = calendar.component(.day, from: date)
    let year = calendar.component(.year, from: date)
    let weekday = calendar.component(.weekday, from: date) // 1 = Sun, 2 = Mon, ..., 5 = Thu
    let hour = calendar.component(.hour, from: date)

    // Easter & Good Friday
    if let easter = easterDate(for: year) {
        if month == easter.month && day == easter.day {
            return "Happy Easter, \(username)!"
        }
        if let easterDateComponents = DateComponents(calendar: calendar, year: year, month: easter.month, day: easter.day).date,
           let goodFridayDate = calendar.date(byAdding: .day, value: -2, to: easterDateComponents) {
            let gfMonth = calendar.component(.month, from: goodFridayDate)
            let gfDay = calendar.component(.day, from: goodFridayDate)
            if month == gfMonth && day == gfDay {
                return "Have a blessed Good Friday, \(username)!"
            }
        }
    }

    // Holiday Greetings
    switch (month, day) {
    case (1, 1):
        return "Happy New Year, \(username)!"
    case (1, 15...21) where weekday == 2:
        return "Happy MLK Jr. Day, \(username)!"
    case (2, 2):
        return "Happy Groundhog Day, \(username)!"
    case (2, 14):
        return "Happy Valentine's Day, \(username)!"
    case (2, 15...21) where weekday == 2:
        return "Happy Presidents' Day, \(username)!"
    case (3, 17):
        return "Happy St. Patrick's Day, \(username)!"
    case (4, 1):
        return "Happy April Fools' Day, \(username)!"
    case (4, 22):
        return "Happy Earth Day, \(username)!"
    case (5, 5):
        return "Happy Cinco de Mayo, \(username)!"
    case (5, 8...14) where weekday == 1:
        return "Happy Mother's Day, \(username)!"
    case (5, 25...31) where weekday == 2:
        return "Happy Memorial Day, \(username)!"
    case (6, 15...21) where weekday == 1:
        return "Happy Father's Day, \(username)!"
    case (6, 19):
        return "Happy Juneteenth, \(username)!"
    case (7, 4):
        return "Happy 4th of July, \(username)!"
    case (9, 1...7) where weekday == 2:
        return "Happy Labor Day, \(username)!"
    case (10, 8...14) where weekday == 2:
        return "Happy Indigenous Peoples' Day, \(username)!"
    case (10, 31):
        return "Happy Halloween, \(username)!"
    case (11, 11):
        return "Happy Veterans Day, \(username)!"
    case (11, 22...28) where weekday == 5:
        return "Happy Thanksgiving, \(username)!"
    case (12, 24):
        return "Merry Christmas Eve, \(username)!"
    case (12, 25):
        return "Merry Christmas, \(username)!"
    case (12, 26):
        return "Happy Kwanzaa, \(username)!"
    case (12, 31):
        return "Happy New Year's Eve, \(username)!"
    default:
        break
    }

    // Time of Day Greetings
    switch hour {
    case 5..<12:
        return "Good Morning, \(username)!"
    case 12..<17:
        return "Good Afternoon, \(username)!"
    case 17..<22:
        return "Good Evening, \(username)!"
    default:
        return "Good Night, \(username)!"
    }
}

// MARK: - TV Plain Card Button Style
#if os(tvOS)
/// Removes the grey background of the default tvOS `.card` style while preserving the standard focus scaling animation.
struct TVPlainCardButtonStyle: ButtonStyle {
    @Environment(\.isFocused) private var isFocused
    
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(isFocused ? 1.05 : 1.0)
            .animation(.easeOut(duration: 0.2), value: isFocused)
    }
}
#endif

// MARK: - Cross-Platform Helpers

extension Color {
    /// Provides a safe fallback for tvOS since `UIColor.secondarySystemBackground` is iOS-only.
    static var homeSecondaryBackground: Color {
        #if os(tvOS)
        return Color.gray.opacity(0.2)
        #else
        return Color(UIColor.secondarySystemBackground)
        #endif
    }
}

/// A localized stream context to prevent ambiguous type collisions with other media views.
struct HomeStreamContext: Identifiable {
    let id = UUID()
    let playlist: [JFItemDto]
    let startIndex: Int
}

// MARK: - Section Header

struct SectionHeader: View {
    let title: String
    init(_ title: String) { self.title = title }
    var body: some View {
        Text(title)
            #if os(tvOS)
            .font(.system(size: 40, weight: .bold))
            #else
            .font(.title2).bold()
            #endif
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)
            .padding(.bottom, 12)
    }
}

// MARK: - Row Style

enum RowStyle {
    case landscape
    case landscapeLarge // Added for larger "On Now" content
    case portrait
}

// MARK: - Array Helper

extension Array where Element == JFProgram {
    func prefixed(_ n: Int) -> [JFProgram] { Array(self.prefix(n)) }
}

// MARK: - Horizontal Programs Row

struct HorizontalProgramsRow: View {
    let programs: [JFProgram]
    let style: RowStyle
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var vm: HomeViewModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: rowSpacing) {
                ForEach(Array(programs.enumerated()), id: \.offset) { index, program in
                    #if os(tvOS)
                    NavigationLink(destination: TVProgramView(program: program, appState: appState)
                        .environmentObject(appState)
                        .environmentObject(vm)) {
                        ProgramCard(program: program, style: style)
                            .environmentObject(appState)
                            .environmentObject(vm)
                    }
                    .buttonStyle(TVPlainCardButtonStyle())
                    #else
                    NavigationLink(destination: ProgramView(program: program, appState: appState)
                        .environmentObject(appState)
                        .environmentObject(vm)) {
                        ProgramCard(program: program, style: style)
                            .environmentObject(appState)
                            .environmentObject(vm)
                    }
                    .buttonStyle(.plain)
                    #endif
                }
            }
            .padding(.horizontal)
            .padding(.vertical, rowVerticalPadding)
        }
        .padding(.vertical, -rowVerticalPadding)
    }

    private var rowSpacing: CGFloat {
        #if os(tvOS)
        40
        #else
        8
        #endif
    }
    
    private var rowVerticalPadding: CGFloat {
        #if os(tvOS)
        40
        #else
        12
        #endif
    }
}

// MARK: - Horizontal Channels Row

struct HorizontalChannelsRow: View {
    let channels: [JFChannel]
    @EnvironmentObject private var appState: AppState

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .center, spacing: channelSpacing) {
                ForEach(Array(channels.enumerated()), id: \.offset) { index, channel in
                    #if os(tvOS)
                    NavigationLink(destination: TVPlayerView(channel: channel).environmentObject(appState)) {
                        channelCardContent(for: channel, index: index)
                    }
                    .buttonStyle(TVPlainCardButtonStyle())
                    #else
                    NavigationLink(destination: ChannelDetailView(channel: channel.asLiveDto(baseURL: appState.serverURL))) {
                        channelCardContent(for: channel, index: index)
                    }
                    .buttonStyle(.plain)
                    #endif
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 16)
            .frame(minHeight: rowMinHeight)
        }
    }

    private var channelSpacing: CGFloat {
        #if os(tvOS)
        28
        #else
        10
        #endif
    }
    private var rowMinHeight: CGFloat {
        #if os(tvOS)
        260
        #else
        110
        #endif
    }
    
    @ViewBuilder
    private func channelCardContent(for channel: JFChannel, index: Int) -> some View {
        ZStack(alignment: .topTrailing) {
            ZStack {
                ChannelImageView(baseUrl: appState.serverURL, apiKey: appState.apiKey, channelId: channel.id)
                    .frame(width: iconOuterSize, height: iconOuterSize)
                    .blur(radius: 32)
                    .opacity(0.85)

                if #available(iOS 26.0, tvOS 26.0, *) {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .glassEffect(.regular, in: .rect(cornerRadius: 16.0))
                } else {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(.ultraThinMaterial)
                }

                ChannelImageView(baseUrl: appState.serverURL, apiKey: appState.apiKey, channelId: channel.id)
                    .frame(width: iconInnerSize, height: iconInnerSize)
            }
            .frame(width: iconOuterSize, height: iconOuterSize)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            
            if channel.isFavorite {
                Image(systemName: "heart.fill")
                    .foregroundColor(.red)
                    .font(favoriteBadgeFont)
                    .padding(favoriteBadgePadding)
                    .background(Color.black.opacity(0.5))
                    .clipShape(Circle())
                    .padding(4)
            }
        }
        .accessibilityLabel(Text(channel.name))
    }

    private var iconOuterSize: CGFloat {
        #if os(tvOS)
        220
        #else
        84
        #endif
    }
    private var iconInnerSize: CGFloat {
        #if os(tvOS)
        176
        #else
        67
        #endif
    }
    private var favoriteBadgeFont: Font {
        #if os(tvOS)
        .title2
        #else
        .caption
        #endif
    }
    private var favoriteBadgePadding: CGFloat {
        #if os(tvOS)
        14
        #else
        6
        #endif
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
                Color.homeSecondaryBackground
                    .frame(width: imageWidth, height: imageHeight)
                
                if let url = URL(string: "\(base)/Items/\(program.id)/Images/Primary?maxWidth=400&ApiKey=\(appState.apiKey)") {
                    CachedAsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let image):
                            ZStack {
                                ZStack {
                                    image
                                        .resizable()
                                        .aspectRatio(contentMode: .fill)
                                        .frame(width: imageWidth, height: imageHeight)
                                        .blur(radius: 32)
                                    
                                    Rectangle()
                                        .fill(.ultraThinMaterial)
                                }
                                .clipped()
                                
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
                
                if isRecording {
                    ZStack(alignment: .leading) {
                        Rectangle()
                            .fill(Color.black.opacity(0.35))
                            .frame(width: max(0, imageWidth - 12), height: 4)
                        Rectangle()
                            .fill(Color.red)
                            .frame(width: max(0, (imageWidth - 12) * (progressRatio ?? 1.0)), height: 4)
                    }
                    .clipShape(Capsule())
                    .padding(6)
                } else if let progress = progressRatio, progress > 0, progress < 1 {
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
            
            VStack(alignment: .leading, spacing: textSpacing) {
                Text(program.name)
                    .font(titleFont)
                    .foregroundColor(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: imageWidth, alignment: .leading)
                
                if let subtitle = programSubtitle {
                    Text(subtitle)
                        .font(subtitleFont)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .frame(maxWidth: imageWidth, alignment: .leading)
                }
                if let timeLine = timeLine {
                    Text(timeLine)
                        .font(captionFont)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .frame(maxWidth: imageWidth, alignment: .leading)
                }
                Text(channelLine)
                    .font(subtitleFont)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: imageWidth, alignment: .leading)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.bottom, 12)
    }

    private var textSpacing: CGFloat {
        #if os(tvOS)
        6
        #else
        2
        #endif
    }
    private var titleFont: Font {
        #if os(tvOS)
        .system(size: 30, weight: .semibold)
        #else
        .headline
        #endif
    }
    private var subtitleFont: Font {
        #if os(tvOS)
        .system(size: 22)
        #else
        .subheadline
        #endif
    }
    private var captionFont: Font {
        #if os(tvOS)
        .system(size: 20)
        #else
        .caption
        #endif
    }

    private var imageWidth: CGFloat {
        #if os(tvOS)
        switch style {
        case .portrait: return 220
        case .landscapeLarge: return 560
        case .landscape: return 380
        }
        #else
        switch style {
        case .portrait: return 120
        case .landscapeLarge: return 350
        case .landscape: return 220
        }
        #endif
    }
    private var imageHeight: CGFloat {
        #if os(tvOS)
        switch style {
        case .portrait: return 330
        case .landscapeLarge: return 315
        case .landscape: return 214
        }
        #else
        switch style {
        case .portrait: return 180
        case .landscapeLarge: return 197
        case .landscape: return 124
        }
        #endif
    }

    @ViewBuilder
    private var fallbackImage: some View {
        VStack(spacing: 8) {
            Image(systemName: "tv")
                .font(.system(size: fallbackIconSize))
                .foregroundColor(.secondary)
            Text(program.name)
                .font(.system(size: fallbackTextSize, weight: .medium))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .padding(.horizontal, 6)
        }
        .frame(width: imageWidth, height: imageHeight)
        .background(Color.homeSecondaryBackground)
    }

    private var fallbackIconSize: CGFloat {
        #if os(tvOS)
        style == .portrait ? 48 : 40
        #else
        style == .portrait ? 28 : 24
        #endif
    }
    private var fallbackTextSize: CGFloat {
        #if os(tvOS)
        18
        #else
        10
        #endif
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

    private var isRecording: Bool {
        return program.timerId != nil || program.seriesTimerId != nil
    }
}

// MARK: - Horizontal Library Items Row

struct HorizontalLibraryItemsRow: View {
    let items: [JFItemDto]
    let style: RowStyle
    var playDirectly: Bool = false
    
    @EnvironmentObject private var appState: AppState
    @State private var streamContext: HomeStreamContext? = nil

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: libraryRowSpacing) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    if playDirectly {
                        Button {
                            streamContext = HomeStreamContext(playlist: [item], startIndex: 0)
                        } label: {
                            LibraryItemCard(item: item, style: style)
                                .environmentObject(appState)
                        }
                        #if os(tvOS)
                        .buttonStyle(TVPlainCardButtonStyle())
                        #else
                        .buttonStyle(.plain)
                        #endif
                    } else {
                        #if os(tvOS)
                        NavigationLink(destination: TVMediaItemDetailView(item: item).environmentObject(appState)) {
                            LibraryItemCard(item: item, style: style)
                                .environmentObject(appState)
                        }
                        .buttonStyle(TVPlainCardButtonStyle())
                        #else
                        NavigationLink(destination: MediaItemDetailView(item: item).environmentObject(appState)) {
                            LibraryItemCard(item: item, style: style)
                                .environmentObject(appState)
                        }
                        .buttonStyle(.plain)
                        #endif
                    }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, rowVerticalPadding)
        }
        .padding(.vertical, -rowVerticalPadding)
        .fullScreenCover(item: $streamContext) { context in
            #if os(tvOS)
            TVPlanktonPlayerView(playlist: context.playlist, startIndex: context.startIndex)
                .environmentObject(appState)
            #else
            PlanktonPlayerView(
                playlist: context.playlist,
                startIndex: context.startIndex,
                seriesName: nil,
                appState: appState
            )
            .environmentObject(appState)
            #endif
        }
    }

    private var libraryRowSpacing: CGFloat {
        #if os(tvOS)
        70
        #else
        8
        #endif
    }
    
    private var rowVerticalPadding: CGFloat {
        #if os(tvOS)
        40
        #else
        12
        #endif
    }
}

// MARK: - Library Item Card

struct LibraryItemCard: View {
    let item: JFItemDto
    let style: RowStyle
    @EnvironmentObject private var appState: AppState

    @ViewBuilder
    private func renderImage(image: Image) -> some View {
        ZStack {
            ZStack {
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: imageWidth, height: imageHeight)
                    .blur(radius: 32)
                
                Rectangle()
                    .fill(.ultraThinMaterial)
            }
            .clipped()
            
            image
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: imageWidth, height: imageHeight)
        }
    }

    var body: some View {
        let base = appState.serverURL.hasSuffix("/") ? String(appState.serverURL.dropLast()) : appState.serverURL
        
        VStack(alignment: .leading, spacing: outerSpacing) {
            ZStack(alignment: .bottomLeading) {
                Color.homeSecondaryBackground
                    .frame(width: imageWidth, height: imageHeight)
                
                Group {
                    if style == .landscape || style == .landscapeLarge {
                        if let backdropTag = item.backdropImageTag,
                           let url = URL(string: "\(base)/Items/\(item.Id)/Images/Backdrop/0?tag=\(backdropTag)&maxWidth=\(fetchMaxWidth)&ApiKey=\(appState.apiKey)") {
                            CachedAsyncImage(url: url) { phase in
                                switch phase {
                                case .success(let image): renderImage(image: image)
                                case .failure, .empty: fallbackImage
                                @unknown default: fallbackImage
                                }
                            }
                        } else if let primaryTag = item.primaryImageTag,
                                  let url = URL(string: "\(base)/Items/\(item.Id)/Images/Primary?tag=\(primaryTag)&maxWidth=\(fetchMaxWidth)&ApiKey=\(appState.apiKey)") {
                            CachedAsyncImage(url: url) { phase in
                                switch phase {
                                case .success(let image): renderImage(image: image)
                                case .failure, .empty: fallbackImage
                                @unknown default: fallbackImage
                                }
                            }
                        } else {
                            fallbackImage
                        }
                    } else {
                        if let primaryTag = item.primaryImageTag,
                           let url = URL(string: "\(base)/Items/\(item.Id)/Images/Primary?tag=\(primaryTag)&maxWidth=\(fetchMaxWidth)&ApiKey=\(appState.apiKey)") {
                            CachedAsyncImage(url: url) { phase in
                                switch phase {
                                case .success(let image): renderImage(image: image)
                                case .failure, .empty: fallbackImage
                                @unknown default: fallbackImage
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
            
            VStack(alignment: .leading, spacing: textSpacing) {
                Text(displayTitle)
                    .font(titleFont)
                    .foregroundColor(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: imageWidth, alignment: .leading)
                
                if let subtitle = itemSubtitle {
                    Text(subtitle)
                        .font(subtitleFont)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .frame(maxWidth: imageWidth, alignment: .leading)
                }
                
                if let secondaryInfo = secondaryInfoLine {
                    Text(secondaryInfo)
                        .font(captionFont)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .frame(maxWidth: imageWidth, alignment: .leading)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.bottom, cardBottomPadding)
    }

    private var cardBottomPadding: CGFloat {
        #if os(tvOS)
        24
        #else
        12
        #endif
    }

    private var fetchMaxWidth: Int {
        #if os(tvOS)
        switch style {
        case .portrait: return 500
        case .landscapeLarge: return 700
        case .landscape: return 700
        }
        #else
        style == .portrait ? 300 : 400
        #endif
    }

    private var imageWidth: CGFloat {
        #if os(tvOS)
        switch style {
        case .portrait: return 220
        case .landscapeLarge: return 480
        case .landscape: return 460
        }
        #else
        switch style {
        case .portrait: return 120
        case .landscapeLarge: return 300
        case .landscape: return 220
        }
        #endif
    }
    
    private var imageHeight: CGFloat {
        #if os(tvOS)
        switch style {
        case .portrait: return 330
        case .landscapeLarge: return 270
        case .landscape: return 259
        }
        #else
        switch style {
        case .portrait: return 180
        case .landscapeLarge: return 169
        case .landscape: return 124
        }
        #endif
    }

    private var outerSpacing: CGFloat {
        #if os(tvOS)
        14
        #else
        6
        #endif
    }

    private var textSpacing: CGFloat {
        #if os(tvOS)
        6
        #else
        2
        #endif
    }
    private var titleFont: Font {
        #if os(tvOS)
        .system(size: 30, weight: .semibold)
        #else
        .headline
        #endif
    }
    private var subtitleFont: Font {
        #if os(tvOS)
        .system(size: 22)
        #else
        .subheadline
        #endif
    }
    private var captionFont: Font {
        #if os(tvOS)
        .system(size: 20)
        #else
        .caption
        #endif
    }

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
                .font(.system(size: fallbackIconSize))
                .foregroundColor(.secondary)
            Text(item.Name)
                .font(.system(size: fallbackTextSize, weight: .medium))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .padding(.horizontal, 6)
        }
        .frame(width: imageWidth, height: imageHeight)
        .background(Color.homeSecondaryBackground)
    }

    private var fallbackIconSize: CGFloat {
        #if os(tvOS)
        style == .portrait ? 48 : 40
        #else
        style == .portrait ? 28 : 24
        #endif
    }
    private var fallbackTextSize: CGFloat {
        #if os(tvOS)
        18
        #else
        10
        #endif
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
