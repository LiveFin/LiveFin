import SwiftUI
import Foundation
import AVKit
import WebKit
import UIKit

// Pre-parsed item wrapper to avoid performance bottlenecks during scroll renders
struct ProgramDetailItem: Identifiable {
    let item: BaseItemDto
    let jfProgram: JFProgram?
    var id: String { item.id ?? UUID().uuidString }
}

// Track when action buttons scroll past the navigation bar threshold
struct ActionButtonsStickyPreferenceKey: PreferenceKey {
    static var defaultValue: Bool = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = value || nextValue()
    }
}

private struct EPGCacheFileLocal: Codable {
    let dayKey: String
    let timestamp: Date
    let items: [BaseItemDto]
}

// Helper to extract the prominent color palette from a logo image
extension UIImage {
    var dominantColor: UIColor? {
        guard let cgImage = self.cgImage else { return nil }

        let width = 36
        let height = 36
        var rawData = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: &rawData,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        
        var totalR: CGFloat = 0
        var totalG: CGFloat = 0
        var totalB: CGFloat = 0
        var count: CGFloat = 0
        
        var maxSaturation: CGFloat = -1
        var bestColor: (CGFloat, CGFloat, CGFloat)? = nil
        
        for i in stride(from: 0, to: rawData.count, by: 4) {
            let r = CGFloat(rawData[i]) / 255.0
            let g = CGFloat(rawData[i + 1]) / 255.0
            let b = CGFloat(rawData[i + 2]) / 255.0
            let a = CGFloat(rawData[i + 3]) / 255.0
            
            // Discard transparent/low-alpha pixels
            if a < 0.3 { continue }
            
            let maxVal = max(r, g, b)
            let minVal = min(r, g, b)
            let delta = maxVal - minVal
            let saturation = maxVal == 0 ? 0 : delta / maxVal
            
            // Prefer vibrant brand colors over near-white or near-black
            if maxVal > 0.15 && minVal < 0.95 {
                totalR += r
                totalG += g
                totalB += b
                count += 1
                
                if saturation > maxSaturation {
                    maxSaturation = saturation
                    bestColor = (r, g, b)
                }
            }
        }
        
        if let best = bestColor, maxSaturation > 0.25 {
            return UIColor(red: best.0, green: best.1, blue: best.2, alpha: 1.0)
        } else if count > 0 {
            return UIColor(red: totalR / count, green: totalG / count, blue: totalB / count, alpha: 1.0)
        }
        
        return nil
    }
}

struct ChannelDetailView: View {
    let channel: LiveTvChannelDto
    @EnvironmentObject var appState: AppState
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.colorScheme) private var colorScheme

    @State private var programs: [BaseItemDto] = []
    @State private var programDetailItems: [ProgramDetailItem] = []
    @State private var selectedStreamItem: StreamURLItem? = nil
    @State private var selectedProgramTitle: String? = nil
    @State private var selectedProgramSubtitle: String? = nil
    @State private var isLoading: Bool = false
    @State private var isFavorite: Bool = false
    @State private var playbackErrorMessage: String? = nil

    // Header & Color States
    @State private var hasLogo: Bool = false
    @State private var hasBackdrop: Bool = false
    @State private var rawBackdropColor: Color? = nil
    @State private var rawLogoColor: Color? = nil

    // Sticky header toggle (only mutates state when boundary is crossed)
    @State private var showStickyHeader: Bool = false

    var baseServerURL: String {
        appState.serverURL.hasSuffix("/") ? String(appState.serverURL.dropLast()) : appState.serverURL
    }

    private var channelBackdropURL: URL? {
        URL(string: "\(baseServerURL)/Items/\(channel.id)/Images/Backdrop?maxWidth=1200&api_key=\(appState.apiKey)")
    }

    private var channelLogoURL: URL? {
        URL(string: "\(baseServerURL)/Items/\(channel.id)/Images/Primary?maxWidth=400&api_key=\(appState.apiKey)")
    }

    var filteredProgramItems: [ProgramDetailItem] {
        let now = Date()
        return programDetailItems.filter { detail in
            let end = detail.item.endDate ?? detail.item.startDate?.addingTimeInterval(1800)
            guard let end = end else { return true }
            return end >= now
        }
    }

    var groupedProgramItems: [(Date, [ProgramDetailItem])] {
        let now = Date()
        let dict = Dictionary(grouping: filteredProgramItems, by: {
            Calendar.current.startOfDay(for: $0.item.startDate ?? now)
        })
        return dict.keys.sorted().map { date in
            (date, dict[date] ?? [])
        }
    }

    // Blends with backdrop color or falls back to logo color palette
    var effectivePaletteColor: Color {
        rawBackdropColor ?? rawLogoColor ?? (colorScheme == .dark ? Color.black : Color(UIColor.systemBackground))
    }

    var blendedBackgroundColor: Color {
        let baseColor = effectivePaletteColor
        if colorScheme == .dark {
            return baseColor.blended(with: Color(red: 0.08, green: 0.08, blue: 0.09), ratio: 0.75)
        } else {
            return baseColor.blended(with: Color(red: 0.96, green: 0.96, blue: 0.98), ratio: 0.85)
        }
    }

    private func formattedDateHeader(for date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) {
            return "Today • " + date.formatted(Date.FormatStyle().month(.abbreviated).day())
        } else if cal.isDateInTomorrow(date) {
            return "Tomorrow • " + date.formatted(Date.FormatStyle().month(.abbreviated).day())
        } else {
            return date.formatted(Date.FormatStyle().weekday(.wide).month(.abbreviated).day())
        }
    }

    // Program list styled with refined inset grouped cards
    var programSections: some View {
        let grouped = groupedProgramItems
        return LazyVStack(alignment: .leading, spacing: 24) {
            ForEach(grouped, id: \.0) { date, itemsForDate in
                VStack(alignment: .leading, spacing: 10) {
                    Text(formattedDateHeader(for: date).uppercased())
                        .font(.caption.weight(.bold))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 20)
                    
                    VStack(spacing: 0) {
                        ForEach(itemsForDate.indices, id: \.self) { index in
                            let detail = itemsForDate[index]

                            Group {
                                if let converted = detail.jfProgram {
                                    NavigationLink(destination: ProgramView(program: converted, appState: appState).environmentObject(appState)) {
                                        ProgramRowView(program: detail.item, programs: programs, channelId: channel.id, appState: appState)
                                    }
                                    .buttonStyle(.plain)
                                } else {
                                    ProgramRowView(program: detail.item, programs: programs, channelId: channel.id, appState: appState)
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            
                            if index < itemsForDate.count - 1 {
                                Divider()
                                    .padding(.leading, 16)
                            }
                        }
                    }
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(
                                colorScheme == .dark
                                    ? Color(UIColor.secondarySystemGroupedBackground).opacity(0.85)
                                    : Color(UIColor.secondarySystemGroupedBackground)
                            )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(
                                colorScheme == .dark
                                    ? Color.white.opacity(0.12)
                                    : Color.black.opacity(0.06),
                                lineWidth: 1
                            )
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .padding(.horizontal, 16)
                }
            }
        }
    }

    @ViewBuilder private var channelTitleAndLogo: some View {
        VStack {
            if hasLogo {
                ChannelImageView(baseUrl: appState.serverURL, apiKey: appState.apiKey, channelId: channel.id, hasImage: $hasLogo)
                    .frame(maxWidth: horizontalSizeClass == .compact ? 240 : 400, maxHeight: 100)
                    .padding(.bottom, 0)
            } else {
                Text(channel.name ?? "Channel")
                    .font(.system(size: horizontalSizeClass == .compact ? 28 : 34, weight: .bold))
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .minimumScaleFactor(0.6)
                    .padding(.bottom, 0)
                    .padding(.horizontal)
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder private var headerSection: some View {
        let backdropHeight: CGFloat = horizontalSizeClass == .compact ? 300 : 420
        
        if hasBackdrop, let url = channelBackdropURL {
            ZStack(alignment: .bottom) {
                GeometryReader { geo in
                    DynamicBackdropImageView(
                        url: url,
                        rawColor: $rawBackdropColor,
                        height: backdropHeight
                    )
                    .frame(width: geo.size.width, height: backdropHeight)
                    .clipped()
                }
                .frame(height: backdropHeight)
                
                LinearGradient(
                    gradient: Gradient(colors: [.clear, blendedBackgroundColor]),
                    startPoint: .center,
                    endPoint: .bottom
                )
                .frame(height: backdropHeight)
                
                channelTitleAndLogo
                    .offset(y: 12)
            }
            .frame(maxWidth: .infinity)
        } else {
            channelTitleAndLogo
                .padding(.top, 16)
        }
    }

    @ViewBuilder private var actionButtons: some View {
        HStack(spacing: 16) {
            Button(action: playButtonTapped) {
                Label("Play", systemImage: "play.fill")
                    .font(.headline.bold())
                    .foregroundColor(colorScheme == .dark ? .white : .black)
                    .frame(width: 150, height: 44)
                    .background(Color.clear)
                    .glassEffect(in: .rect(cornerRadius: 22.0))
            }
            
            Button(action: toggleFavorite) {
                Image(systemName: isFavorite ? "heart.fill" : "heart")
                    .font(.headline.bold())
                    .foregroundColor(isFavorite ? .red : (colorScheme == .dark ? .white : .black))
                    .frame(width: 44, height: 44)
                    .background(Color.clear)
                    .glassEffect(in: .rect(cornerRadius: 22.0))
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .background(
            GeometryReader { proxy in
                let maxY = proxy.frame(in: .named("scroll")).maxY
                Color.clear.preference(
                    key: ActionButtonsStickyPreferenceKey.self,
                    value: maxY <= 60
                )
            }
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                headerSection
                
                VStack(alignment: .leading, spacing: 24) {
                    actionButtons
                        .padding(.top, 16)
                        .padding(.horizontal)
                    
                    if filteredProgramItems.isEmpty {
                        emptyStateView
                    } else {
                        programSections
                            .padding(.bottom, 48)
                    }
                }
                
                Spacer(minLength: 40)
            }
        }
        .background(blendedBackgroundColor.ignoresSafeArea())
        .ignoresSafeArea(.container, edges: hasBackdrop ? .top : [])
        .toolbarBackground(showStickyHeader ? .visible : .hidden, for: .navigationBar)
        .coordinateSpace(name: "scroll")
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if showStickyHeader {
                ToolbarItem(placement: .principal) {
                    Group {
                        if hasLogo {
                            ChannelImageView(baseUrl: appState.serverURL, apiKey: appState.apiKey, channelId: channel.id, hasImage: .constant(true))
                                .frame(maxWidth: 160, maxHeight: 38)
                        } else {
                            Text(channel.name ?? "Channel")
                                .font(.headline)
                                .bold()
                                .lineLimit(1)
                        }
                    }
                    .transition(.opacity)
                }
                
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: playButtonTapped) {
                        Image(systemName: "play.fill")
                    }
                    .accessibilityLabel("Play Channel")
                }
            }
        }
        .animation(.easeInOut(duration: 0.25), value: showStickyHeader)
        .fullScreenCover(item: $selectedStreamItem) { item in
            DragonetPlayerView(
                 streamURL: item.url,
                 channel: channel,
                 appState: appState,
                onPlaybackError: { msg in playbackErrorMessage = msg }
             )
             .environmentObject(appState)
         }
        .alert("Playback Error", isPresented: Binding(get: { playbackErrorMessage != nil }, set: { if !$0 { playbackErrorMessage = nil } })) {
            Button("OK", role: .cancel) { playbackErrorMessage = nil }
        } message: {
            Text(playbackErrorMessage ?? "An unknown error occurred while trying to play the channel.")
        }
        .task {
            self.isFavorite = channel.userData?.isFavorite == true
            await loadCachedPrograms()
            async let paletteTask: Void = checkPaletteAndBackdrop()
            async let fetchTask: Void = fetchPrograms()
            _ = await (paletteTask, fetchTask)
        }
        .onPreferenceChange(ActionButtonsStickyPreferenceKey.self) { isSticky in
            if self.showStickyHeader != isSticky {
                self.showStickyHeader = isSticky
            }
        }
        .refreshable {
            await checkPaletteAndBackdrop()
            await fetchPrograms()
        }
    }

    var emptyStateView: some View {
        Group {
            if isLoading && filteredProgramItems.isEmpty {
                ProgressView("Loading programs...")
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 40)
            } else if filteredProgramItems.isEmpty {
                VStack(alignment: .center, spacing: 12) {
                    Text("No program data available")
                        .font(.headline)
                        .padding(.horizontal)
                    Text("For the best Live TV experience, consider enabling an Electronic Program Guide (EPG) on your server.")
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 40)
            } else {
                Text("No programs available.")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 40)
            }
        }
    }

    func checkPaletteAndBackdrop() async {
        // 1. Verify and extract color from logo
        if let logoURL = channelLogoURL {
            if let (data, response) = try? await URLSession.shared.data(from: logoURL),
               let http = response as? HTTPURLResponse, http.statusCode == 200,
               let img = UIImage(data: data) {
                await MainActor.run {
                    self.hasLogo = true
                    if let dominant = img.dominantColor {
                        self.rawLogoColor = Color(dominant)
                    }
                }
            }
        }
        
        // 2. Check if a backdrop image actually exists
        if let bURL = channelBackdropURL {
            var req = URLRequest(url: bURL)
            req.httpMethod = "HEAD"
            if !appState.accessToken.isEmpty {
                req.setValue(appState.accessToken, forHTTPHeaderField: "X-Emby-Token")
            }
            if let (_, response) = try? await URLSession.shared.data(for: req),
               let http = response as? HTTPURLResponse, http.statusCode == 200 {
                await MainActor.run {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        self.hasBackdrop = true
                    }
                }
            } else {
                await MainActor.run {
                    self.hasBackdrop = false
                }
            }
        }
    }

    func toggleFavorite() {
        guard let client = appState.client else { return }
        let userId = appState.userID
        guard !userId.isEmpty else { return }
        
        let isNowFavorite = !isFavorite
        isFavorite = isNowFavorite
        
        Task {
            do {
                let endpoint = "/Users/\(userId)/FavoriteItems/\(channel.id)"
                let url = client.configuration.url.appendingPathComponent(endpoint)
                var request = URLRequest(url: url)
                request.httpMethod = isNowFavorite ? "POST" : "DELETE"
                request.setValue(appState.accessToken, forHTTPHeaderField: "X-Emby-Token")
                
                let (_, response) = try await URLSession.shared.data(for: request)
                if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
                    await MainActor.run { isFavorite = !isNowFavorite }
                }
            } catch {
                await MainActor.run { isFavorite = !isNowFavorite }
            }
        }
    }

    func playButtonTapped() {
        let channelId = channel.id

        let now = Date()
        let currentProgram = programs.first(where: { prog in
            if let start = prog.startDate, let end = prog.endDate {
                return start <= now && now <= end
            }
            return false
        }) ?? channel.currentProgram

        let initialTitle = currentProgram?.name
        let initialSubtitle: String? = {
            if let ep = currentProgram?.episodeTitle, !ep.isEmpty { return ep }
            if let seriesName = currentProgram?.seriesName, !seriesName.isEmpty, seriesName != currentProgram?.name { return seriesName }
            return nil
        }()

        Task {
            if let streamURLString = await JFOpenLiveStreamService.resolveStreamURL(
                appState: appState,
                channelId: channelId
            ) {
                if let url = URL(string: streamURLString) {
                    selectedProgramTitle = initialTitle
                    selectedProgramSubtitle = initialSubtitle
                    await MainActor.run {
                        appState.currentProgramTitle = initialTitle
                        appState.currentProgramSubtitle = initialSubtitle
                        appState.currentProgramId = currentProgram?.id
                        appState.currentProgramGenres = currentProgram?.genres
                        appState.currentProgramIsMovie = currentProgram?.isMovie ?? false
                        appState.currentProgramStartDate = currentProgram?.startDate
                        appState.currentProgramEndDate = currentProgram?.endDate
                    }
                    selectedStreamItem = StreamURLItem(url)
                    playbackErrorMessage = nil
                } else {
                    playbackErrorMessage = "Unable to play this channel. The stream URL is invalid."
                }
            } else {
                let channelName = channel.name ?? "this channel"
                playbackErrorMessage = "Unable to play \(channelName). No stream is available."
            }
        }
    }

    static func parseFlexibleDate(_ string: String) -> Date? {
        let fWithFraction = ISO8601DateFormatter()
        fWithFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = fWithFraction.date(from: string) { return d }

        let fPlain = ISO8601DateFormatter()
        fPlain.formatOptions = [.withInternetDateTime]
        if let d = fPlain.date(from: string) { return d }

        // Normalize fractional seconds (e.g. 7 digits -> 3 digits)
        if let dotIndex = string.firstIndex(of: ".") {
            let base = String(string[..<dotIndex])
            let rest = String(string[dotIndex...])
            let digits = rest.dropFirst().prefix(while: { $0.isNumber })
            let tz = rest.dropFirst(digits.count + 1)
            let normalizedDigits = digits.prefix(3).padding(toLength: 3, withPad: "0", startingAt: 0)
            let normalized = "\(base).\(normalizedDigits)\(tz)"
            if let d = fWithFraction.date(from: normalized) { return d }
        }

        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(secondsFromGMT: 0)
        for fmt in ["yyyy-MM-dd'T'HH:mm:ssZZZZZ", "yyyy-MM-dd'T'HH:mm:ss.SSSZZZZZ", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ssZ"] {
            df.dateFormat = fmt
            if let d = df.date(from: string) { return d }
        }
        return nil
    }

    private func buildProgramDetailItems(from rawItems: [BaseItemDto]) -> [ProgramDetailItem] {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let channelId = channel.id
        let channelName = channel.name ?? ""

        return rawItems.map { item in
            var dict: [String: Any] = [:]
            let fallbackId = item.id ?? "epg_\(channelId)_\(Int((item.startDate ?? Date()).timeIntervalSince1970))"
            dict["Id"] = fallbackId
            dict["Name"] = item.name ?? ""
            if let s = item.startDate { dict["StartDate"] = iso.string(from: s) }
            if let e = item.endDate { dict["EndDate"] = iso.string(from: e) }
            dict["ChannelId"] = channelId
            if !channelName.isEmpty { dict["ChannelName"] = channelName }
            if let ov = item.overview { dict["Overview"] = ov }
            if let et = item.episodeTitle { dict["EpisodeTitle"] = et }
            if let r = item.officialRating { dict["OfficialRating"] = r }
            if let p = item.parentIndexNumber { dict["ParentIndexNumber"] = p }
            if let idx = item.indexNumber { dict["IndexNumber"] = idx }
            if let rep = item.isRepeat { dict["IsRepeat"] = rep }
            if let prem = item.isPremiere { dict["IsPremiere"] = prem }
            if let isN = item.isNew { dict["IsNew"] = isN }
            if let isM = item.isMovie { dict["IsMovie"] = isM }
            if let gs = item.genres { dict["Genres"] = gs }
            if let sname = item.seriesName { dict["SeriesName"] = sname }
            if let iid = item.id { dict["ItemId"] = iid }
            if let sid = item.seriesId { dict["SeriesId"] = sid }
            if let isS = item.isSeries { dict["IsSeries"] = isS }
            if let tid = item.timerId { dict["TimerId"] = tid }
            if let stid = item.seriesTimerId { dict["SeriesTimerId"] = stid }
            let jfProg = JFProgram(json: dict)
            return ProgramDetailItem(item: item, jfProgram: jfProg)
        }
    }

    private func loadCachedPrograms() async {
        guard programs.isEmpty else { return }
        let cal = Calendar.current
        let today = Date()
        let tomorrow = cal.date(byAdding: .day, value: 1, to: today) ?? today.addingTimeInterval(86400)

        let df = DateFormatter()
        df.calendar = Calendar(identifier: .gregorian)
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = .current
        df.dateFormat = "yyyy-MM-dd"

        var cachedItems: [BaseItemDto] = []
        if let baseDir = try? FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: false) {
            let guideDir = baseDir.appendingPathComponent("GuideCache", isDirectory: true)
            for day in [today, tomorrow] {
                let fileURL = guideDir.appendingPathComponent("epg_day_\(df.string(from: cal.startOfDay(for: day))).json")
                if let data = try? Data(contentsOf: fileURL) {
                    let decoder = JSONDecoder()
                    decoder.dateDecodingStrategy = .iso8601
                    if let file = try? decoder.decode(EPGCacheFileLocal.self, from: data) {
                        let matching = file.items.filter { $0.channelId == channel.id }
                        cachedItems.append(contentsOf: matching)
                    }
                }
            }
        }

        if !cachedItems.isEmpty {
            let sorted = cachedItems.sorted { ($0.startDate ?? .distantPast) < ($1.startDate ?? .distantPast) }
            self.programs = sorted
            self.programDetailItems = buildProgramDetailItems(from: sorted)
        } else if let cur = channel.currentProgram {
            self.programs = [cur]
            self.programDetailItems = buildProgramDetailItems(from: [cur])
        }
    }

    func fetchPrograms() async {
        guard appState.client != nil else { return }
        let accessToken = appState.accessToken
        guard !accessToken.isEmpty else { return }

        self.isLoading = true
        defer { self.isLoading = false }

        let now = Date()
        let later = Calendar.current.date(byAdding: .day, value: 1, to: now)!
        let isoBasic = ISO8601DateFormatter()
        isoBasic.formatOptions = [.withInternetDateTime]
        let nowStr = isoBasic.string(from: now)
        let laterStr = isoBasic.string(from: later)

        do {
            let base = appState.serverURL.hasSuffix("/") ? String(appState.serverURL.dropLast()) : appState.serverURL
            guard let url = URL(string: base + "/LiveTv/Programs") else { return }
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)

            var queryItems: [URLQueryItem] = [
                URLQueryItem(name: "channelIds", value: channel.id),
                URLQueryItem(name: "channelId", value: channel.id),
                URLQueryItem(name: "minEndDate", value: nowStr),
                URLQueryItem(name: "maxStartDate", value: laterStr),
                URLQueryItem(name: "startDate", value: nowStr),
                URLQueryItem(name: "endDate", value: laterStr),
                URLQueryItem(name: "sortBy", value: "StartDate"),
                URLQueryItem(name: "sortOrder", value: "Ascending"),
                URLQueryItem(name: "hasAired", value: "false"),
                URLQueryItem(name: "StartIndex", value: "0"),
                URLQueryItem(name: "Limit", value: "1000"),
                URLQueryItem(name: "fields", value: "MediaSources,Overview,OfficialRating,Genres,SeriesName,EpisodeTitle,RunTimeTicks,ParentIndexNumber,IndexNumber,IsRepeat,IsPremiere,IsNew,IsMovie,ImageTags,ChannelId,ChannelName,TimerId,SeriesTimerId,SeriesId,IsSeries"),
                URLQueryItem(name: "EnableImages", value: "true"),
                URLQueryItem(name: "EnableUserData", value: "true")
            ]

            let userId = !appState.userID.isEmpty ? appState.userID : (appState.user?.id ?? "")
            if !userId.isEmpty {
                queryItems.append(URLQueryItem(name: "userId", value: userId))
            }
            components?.queryItems = queryItems
            guard let finalURL = components?.url else { return }

            var request = URLRequest(url: finalURL)
            request.httpMethod = "GET"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(accessToken, forHTTPHeaderField: "X-Emby-Token")
            let authHeader = appState.getAuthorizationHeader()
            if !authHeader.isEmpty {
                request.setValue(authHeader, forHTTPHeaderField: "Authorization")
            }

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                if self.programs.isEmpty { await loadCachedPrograms() }
                return
            }

            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .custom { decoder in
                let container = try decoder.singleValueContainer()
                let dateStr = try container.decode(String.self)
                if let d = Self.parseFlexibleDate(dateStr) { return d }
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Cannot decode date: \(dateStr)")
            }

            let decoded = try decoder.decode(ProgramsResponse.self, from: data)
            let rawItems = decoded.items ?? []

            // Filter to this channel if channelId is tagged on items
            let matchingItems = rawItems.filter { item in
                guard let cid = item.channelId, !cid.isEmpty else { return true }
                return cid == channel.id
            }
            let finalItems = !matchingItems.isEmpty ? matchingItems : rawItems

            if !finalItems.isEmpty {
                self.programs = finalItems
                self.programDetailItems = buildProgramDetailItems(from: finalItems)
            } else if self.programs.isEmpty {
                await loadCachedPrograms()
            }
            await appState.fetchSeriesTimers()
        } catch {
            print("ChannelDetail: fetchPrograms error: \(error.localizedDescription)")
            if self.programs.isEmpty {
                await loadCachedPrograms()
            }
        }
    }
}

struct ProgramRowView: View {
    let program: BaseItemDto
    let programs: [BaseItemDto]
    let channelId: String
    @ObservedObject var appState: AppState

    var body: some View {
        let isLive: Bool = {
            if let start = program.startDate, let end = program.endDate {
                return start <= Date() && end >= Date()
            }
            return false
        }()
        let showNew: Bool = {
            let notRepeat = (program.isRepeat == false) || (program.isRepeat == nil)
            let hasEpisodeOrSeries = (program.episodeTitle?.isEmpty == false) || (program.seriesName?.isEmpty == false) || (program.parentIndexNumber != nil)
            return notRepeat && hasEpisodeOrSeries
        }()
        let isRecording = program.timerId != nil || program.seriesTimerId != nil
        let isSeriesNewOnly: Bool = {
            guard let sid = program.seriesTimerId else { return false }
            return appState.seriesTimerRecordNewOnly[sid] ?? false
        }()
        let isNewEpisode: Bool = {
            if program.isNew == true { return true }
            if program.isPremiere == true { return true }
            if program.isNew == false || program.isRepeat == true { return false }
            return showNew
        }()
        let isSkippedBySeriesRule = program.timerId == nil && isSeriesNewOnly && !isNewEpisode

        HStack(alignment: .center, spacing: 12) {
            // Program details
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if let title = program.name {
                        Text(title)
                            .font(.headline)
                            .foregroundColor(.primary)
                            .lineLimit(1)
                    }
                    if isRecording {
                        Image(systemName: "record.circle")
                            .foregroundColor(isSkippedBySeriesRule ? .secondary : .red)
                            .font(.caption)
                    }
                    if showNew {
                        Text("NEW")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.blue)
                            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    }
                }

                let subtitleText: String? = {
                    let seasonEpisode: String? = {
                        if let season = program.parentIndexNumber, let episodeNum = program.indexNumber {
                            return String(format: "S%02dE%02d", season, episodeNum)
                        }
                        return nil
                    }()
                    if let epTitle = program.episodeTitle, !epTitle.isEmpty {
                        if let seasonEpisode = seasonEpisode {
                            return "\(seasonEpisode) • \(epTitle)"
                        } else {
                            return epTitle
                        }
                    }
                    if let series = program.seriesName, !series.isEmpty {
                        if let seasonEpisode = seasonEpisode { return "\(seasonEpisode) • \(series)" }
                        return series
                    }
                    return seasonEpisode
                }()

                if let subtitleText = subtitleText {
                    Text(subtitleText)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                HStack(spacing: 6) {
                    if let start = program.startDate, let end = program.endDate {
                        Text("\(start.formatted(date: .omitted, time: .shortened)) - \(end.formatted(date: .omitted, time: .shortened))")
                            .font(.caption)
                            .foregroundColor(isLive ? .red : .secondary)
                            .fontWeight(isLive ? .semibold : .regular)
                    }
                    if let rating = program.officialRating, !rating.isEmpty {
                        Text(rating)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(Color.secondary.opacity(0.2))
                            .clipShape(Capsule())
                    }
                }
            }

            Spacer(minLength: 12)

            // Right side indicator: LIVE badge and navigation chevron
            HStack(spacing: 8) {
                if isLive {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 7, height: 7)
                        Text("LIVE")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.red)
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.red.opacity(0.12))
                    .clipShape(Capsule())
                }
                
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Color(UIColor.tertiaryLabel))
            }
        }
        .contentShape(Rectangle())
    }
}
