import SwiftUI
import Foundation
import AVKit
import WebKit

struct MediaSourceDto: Codable {
    let id: String?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
    }
}

struct BaseItemDto: Identifiable, Codable {
    let id: String?
    let name: String?
    let startDate: Date?
    let endDate: Date?
    let overview: String?
    let channelId: String?
    let mediaSources: [MediaSourceDto]?
    let officialRating: String?
    let episodeTitle: String?
    let parentIndexNumber: Int?
    let indexNumber: Int?
    let isRepeat: Bool? // <-- Added isRepeat
    let isMovie: Bool?
    // Optional series name (some server responses use SeriesName)
    let seriesName: String?
    // Genres/Tags
    let genres: [String]?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case startDate = "StartDate"
        case endDate = "EndDate"
        case overview = "Overview"
        case channelId = "ChannelId"
        case mediaSources = "MediaSources"
        case officialRating = "OfficialRating"
        case episodeTitle = "EpisodeTitle"
        case subtitle = "Subtitle" // <-- Accept alternate key
        case seriesName = "SeriesName" // <-- Optional series name
        case genres = "Genres"
        case parentIndexNumber = "ParentIndexNumber"
        case indexNumber = "IndexNumber"
        case isRepeat = "IsRepeat" // <-- Added isRepeat
        case isMovie = "IsMovie"
        case programId = "ProgramId" // <-- New: fallback for EPG items (decode-only)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        // Prefer Id; fallback to ProgramId for EPG items
        if let idValue = try? container.decode(String.self, forKey: .id) {
            id = idValue
        } else {
            id = try? container.decode(String.self, forKey: .programId)
        }
        name = try? container.decode(String.self, forKey: .name)
        startDate = try? container.decode(Date.self, forKey: .startDate)
        endDate = try? container.decode(Date.self, forKey: .endDate)
        overview = try? container.decode(String.self, forKey: .overview)
        channelId = try? container.decode(String.self, forKey: .channelId)
        mediaSources = try? container.decode([MediaSourceDto].self, forKey: .mediaSources)
        officialRating = try? container.decode(String.self, forKey: .officialRating)
        // Try EpisodeTitle first, then fallback to Subtitle (some endpoints use Subtitle)
        if let ep = try? container.decode(String.self, forKey: .episodeTitle), !ep.isEmpty {
            episodeTitle = ep
        } else if let sub = try? container.decode(String.self, forKey: .subtitle), !sub.isEmpty {
            episodeTitle = sub
        } else {
            episodeTitle = nil
        }
        // Series name when available
        seriesName = try? container.decode(String.self, forKey: .seriesName)
        // Genres — may be array of strings or array of any
        if let gs = try? container.decode([String].self, forKey: .genres) {
            genres = gs
        } else if let any = try? container.decode([AnyCodable].self, forKey: .genres) {
            genres = any.compactMap { $0.value as? String }
        } else {
            genres = nil
        }
        parentIndexNumber = try? container.decode(Int.self, forKey: .parentIndexNumber)
        indexNumber = try? container.decode(Int.self, forKey: .indexNumber)
        isRepeat = try? container.decode(Bool.self, forKey: .isRepeat) // <-- Added isRepeat
        isMovie = try? container.decode(Bool.self, forKey: .isMovie)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(id, forKey: .id)
        try container.encodeIfPresent(name, forKey: .name)
        try container.encodeIfPresent(startDate, forKey: .startDate)
        try container.encodeIfPresent(endDate, forKey: .endDate)
        try container.encodeIfPresent(overview, forKey: .overview)
        try container.encodeIfPresent(channelId, forKey: .channelId)
        try container.encodeIfPresent(mediaSources, forKey: .mediaSources)
        try container.encodeIfPresent(officialRating, forKey: .officialRating)
        // Encode EpisodeTitle if present (prefer canonical key)
        try container.encodeIfPresent(episodeTitle, forKey: .episodeTitle)
        try container.encodeIfPresent(seriesName, forKey: .seriesName)
        try container.encodeIfPresent(genres, forKey: .genres)
        try container.encodeIfPresent(parentIndexNumber, forKey: .parentIndexNumber)
        try container.encodeIfPresent(indexNumber, forKey: .indexNumber)
        try container.encodeIfPresent(isRepeat, forKey: .isRepeat)
        try container.encodeIfPresent(isMovie, forKey: .isMovie)
        // Do not encode programId; it is decode-only fallback
    }
}

// Small AnyCodable helper to decode heterogenous arrays without pulling in a whole dependency
struct AnyCodable: Codable {
    let value: Any
    init(_ value: Any) { self.value = value }
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let s = try? container.decode(String.self) { value = s; return }
        if let i = try? container.decode(Int.self) { value = i; return }
        if let d = try? container.decode(Double.self) { value = d; return }
        if let b = try? container.decode(Bool.self) { value = b; return }
        if let arr = try? container.decode([AnyCodable].self) { value = arr.map { $0.value }; return }
        if let dict = try? container.decode([String: AnyCodable].self) { var out: [String: Any] = [:]; for (k,v) in dict { out[k] = v.value }; value = out; return }
        value = ""
    }
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case let s as String: try container.encode(s)
        case let i as Int: try container.encode(i)
        case let d as Double: try container.encode(d)
        case let b as Bool: try container.encode(b)
        case let arr as [Any]: try container.encode(arr.map { AnyCodable($0) })
        case let dict as [String: Any]: try container.encode(dict.mapValues { AnyCodable($0) })
        default: try container.encode(String(describing: value))
        }
    }
}

struct ProgramsResponse: Codable {
    let items: [BaseItemDto]?

    enum CodingKeys: String, CodingKey {
        case items = "Items"
    }
}

struct ChannelDetailView: View {
    let channel: LiveTvChannelDto
    @EnvironmentObject var appState: AppState
    @State private var programs: [BaseItemDto] = []
    @State private var selectedStreamItem: StreamURLItem? = nil
    @State private var selectedProgramTitle: String? = nil
    @State private var selectedProgramSubtitle: String? = nil
    @State private var isLoading: Bool = false
    // Playback error message shown to the user when a channel cannot be played
    @State private var playbackErrorMessage: String? = nil

    var filteredPrograms: [BaseItemDto] {
        let now = Date()
        return programs.filter { program in
            guard let end = program.endDate else { return false }
            return end >= now
        }
    }

    var groupedPrograms: [Date: [BaseItemDto]] {
        Dictionary(grouping: filteredPrograms, by: {
            Calendar.current.startOfDay(for: $0.startDate ?? .distantPast)
        })
    }
    
    var programSections: some View {
        let sortedDates = groupedPrograms.keys.sorted()
        return Group {
            ForEach(sortedDates, id: \.self) { date in
                let programsForDate = groupedPrograms[date] ?? []
                Section(header: Text(date.formatted(date: .abbreviated, time: .omitted))) {
                    ForEach(programsForDate) { item in
                        // Convert EPG item to JFProgram (initializer will synthesize an id if missing)
                        // Build a minimal JSON dictionary compatible with JFProgram(json:) so ProgramView can show tags/genres
                        let jfProgram: JFProgram? = {
                            var dict: [String: Any] = [:]
                            let fallbackId = item.id ?? "epg_\(channel.id)_\(Int((item.startDate ?? Date()).timeIntervalSince1970))"
                            dict["Id"] = fallbackId
                            dict["Name"] = item.name ?? ""
                            let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime]
                            if let s = item.startDate { dict["StartDate"] = iso.string(from: s) }
                            if let e = item.endDate { dict["EndDate"] = iso.string(from: e) }
                            dict["ChannelId"] = channel.id
                            if let cn = channel.name { dict["ChannelName"] = cn }
                            if let ov = item.overview { dict["Overview"] = ov }
                            if let et = item.episodeTitle { dict["EpisodeTitle"] = et }
                            if let r = item.officialRating { dict["OfficialRating"] = r }
                            if let p = item.parentIndexNumber { dict["ParentIndexNumber"] = p }
                            if let idx = item.indexNumber { dict["IndexNumber"] = idx }
                            if let rep = item.isRepeat { dict["IsRepeat"] = rep }
                            if let isM = item.isMovie { dict["IsMovie"] = isM }
                            if let gs = item.genres { dict["Genres"] = gs }
                            if let sname = item.seriesName { dict["SeriesName"] = sname }
                            // Include ItemId to help related/upcoming logic
                            if let iid = item.id { dict["ItemId"] = iid }
                            return JFProgram(json: dict)
                        }()

                        if let converted = jfProgram {
                            let destination = ProgramView(program: converted, appState: appState)
                                .environmentObject(appState)
                            NavigationLink(destination: destination) {
                                ProgramRowView(program: item, programs: programs, channelId: channel.id, appState: appState)
                            }
                            .buttonStyle(.plain)
                        } else {
                            // Fallback: still show row without navigation (should be rare now)
                            ProgramRowView(program: item, programs: programs, channelId: channel.id, appState: appState)
                        }
                    }
                }
            }
        }
    }

    var body: some View {
        mainContentView
            .navigationTitle(channel.name ?? "Channel")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    playButton
                }
            }
            .fullScreenCover(item: $selectedStreamItem) { item in
                DragonetPlayerView(
                     streamURL: item.url,
                     channel: channel,
                     appState: appState,
                    onPlaybackError: { msg in playbackErrorMessage = msg }
                 )
                 .environmentObject(appState)
             }
            // Present an alert when playback cannot start
            .alert("Playback Error", isPresented: Binding(get: { playbackErrorMessage != nil }, set: { if !$0 { playbackErrorMessage = nil } })) {
                Button("OK", role: .cancel) { playbackErrorMessage = nil }
            } message: {
                Text(playbackErrorMessage ?? "An unknown error occurred while trying to play the channel.")
            }
            .task {
                await fetchPrograms()
            }
    }

    var mainContentView: some View {
        Group {
            if filteredPrograms.isEmpty {
                emptyStateView
            } else {
                List {
                    programSections
                }
                .listStyle(.plain)
                .refreshable {
                    await fetchPrograms()
                }
            }
        }
    }

    var emptyStateView: some View {
        Group {
            if isLoading && programs.isEmpty {
                ProgressView("Loading programs...")
                    .frame(maxWidth: .infinity)
            } else if programs.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("No program data available")
                            .font(.headline)
                            .padding(.horizontal)
                        Text("For the best Live TV experience, consider enabling an Electronic Program Guide (EPG) on your server.")
                            .foregroundColor(.secondary)
                            .padding(.horizontal)
                    }
                    .padding(.top, 20)
                }
            } else {
                ScrollView {
                    Text("No programs available.")
                        .foregroundColor(.secondary)
                        .padding()
                }
            }
        }
    }

    var playButton: some View {
        Button(action: playButtonTapped) {
            Image(systemName: "play.fill")
                .resizable()
                .frame(width: 16, height: 16)
                .foregroundColor(.blue)
        }
    }

    func playButtonTapped() {
        let channelId = channel.id

        // Find the currently airing program (if any) from the already-fetched programs list
        let now = Date()
        let currentProgram = programs.first(where: { prog in
            if let start = prog.startDate, let end = prog.endDate {
                return start <= now && now <= end
            }
            return false
        })

        // Prepare title/subtitle to forward into the player as initial values
        let initialTitle = currentProgram?.name
        // Prefer episode title only from EPG item; BaseItemDto does not include seriesName
        let initialSubtitle: String? = {
            if let ep = currentProgram?.episodeTitle, !ep.isEmpty { return ep }
            // Fallback to series subtitle if available, to match HomeView/ProgramView behavior
            if let seriesName = currentProgram?.seriesName, !seriesName.isEmpty, seriesName != currentProgram?.name { return seriesName }
            return nil
        }()

        Task {
            if let streamURLString = await JFOpenLiveStreamService.resolveStreamURL(
                appState: appState,
                channelId: channelId
            ) {
                if let url = URL(string: streamURLString) {
                    // Store initial program info and trigger the player
                    selectedProgramTitle = initialTitle
                    selectedProgramSubtitle = initialSubtitle
                    // Propagate genres/tags into AppState so other components (player/NowPlaying) can observe them
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
                    // Clear any previous error
                    playbackErrorMessage = nil
                } else {
                    // URL couldn't be created
                    playbackErrorMessage = "Unable to play this channel. The stream URL is invalid."
                    print("Invalid stream URL: \(streamURLString)")
                }
            } else {
                // No stream URL available — surface a user-visible error
                let channelName = channel.name ?? "this channel"
                playbackErrorMessage = "Unable to play \(channelName). No stream is available."
                print("No stream URL available.")
            }
        }
    }
    
    func fetchPrograms() async {
        guard let client = appState.client else {
            return
        }

        let accessToken = appState.accessToken
        guard !accessToken.isEmpty else {
            return
        }

        // mark loading state so UI can show spinner only during network fetch
        self.isLoading = true
        defer { self.isLoading = false }
 
         let now = Date()
         let later = Calendar.current.date(byAdding: .day, value: 1, to: now)!

         do {
             let url = client.configuration.url.appendingPathComponent("/LiveTv/Programs")
             var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
             components?.queryItems = [
                 URLQueryItem(name: "channelIds", value: channel.id),
                 URLQueryItem(name: "startDate", value: ISO8601DateFormatter().string(from: now)),
                 URLQueryItem(name: "endDate", value: ISO8601DateFormatter().string(from: later)),
                 URLQueryItem(name: "StartIndex", value: "0"),
                 URLQueryItem(name: "Limit", value: "1000"),
                 // Request richer fields so EPG items include genres/series/image tags when available
                 URLQueryItem(name: "fields", value: "MediaSources,Overview,OfficialRating,Genres,SeriesName,EpisodeTitle,RunTimeTicks,ParentIndexNumber,IndexNumber,IsRepeat,IsMovie,ImageTags,ChannelId,ChannelName"),
                 URLQueryItem(name: "EnableImages", value: "true"),
                 URLQueryItem(name: "EnableUserData", value: "true")
             ]

             guard let userId = appState.user?.id else {
                 print("DEBUG: User ID is missing")
                 return
             }
             components?.queryItems?.append(URLQueryItem(name: "userId", value: userId))

             guard let finalURL = components?.url else {
                 return
             }

             var request = URLRequest(url: finalURL)
             request.httpMethod = "GET"
             request.setValue("application/json", forHTTPHeaderField: "Content-Type")
             request.setValue(accessToken, forHTTPHeaderField: "X-Emby-Token")

             let (data, response) = try await URLSession.shared.data(for: request)

             guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                 return
             }

             let decoder = JSONDecoder()
             decoder.dateDecodingStrategy = .custom { decoder in
                 let container = try decoder.singleValueContainer()
                 let dateStr = try container.decode(String.self)
                 // Build formatters locally to avoid capturing a non-Sendable formatter in a @Sendable closure
                 let fWithFraction = ISO8601DateFormatter()
                 fWithFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                 if let d = fWithFraction.date(from: dateStr) { return d }
                 let fPlain = ISO8601DateFormatter()
                 fPlain.formatOptions = [.withInternetDateTime]
                 if let d2 = fPlain.date(from: dateStr) { return d2 }
                 throw DecodingError.dataCorruptedError(in: container, debugDescription: "Cannot decode date: \(dateStr)")
             }

             let decoded = try decoder.decode(ProgramsResponse.self, from: data)
            // Only overwrite programs if we got a result; keep existing list on transient failures
            self.programs = decoded.items ?? []

         } catch {
            // preserve existing programs on error; optionally log
            print("ChannelDetail: fetchPrograms error: \(error.localizedDescription)")
         }
     }
 }
 
 struct ProgramRowView: View {
    let program: BaseItemDto
    let programs: [BaseItemDto]
    let channelId: String
    @ObservedObject var appState: AppState
    @State private var isExpanded = false
    @State private var selectedStreamURL: URL?
    @State private var showPlayer = false

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
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                // Title, subtitle, and labels
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        if let title = program.name {
                            Text(title)
                                .font(.title3)
                                .bold()
                        }
                        if showNew {
                            Text("New")
                                .font(.caption2)
                                .foregroundColor(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.blue)
                                .cornerRadius(4)
                                .alignmentGuide(.firstTextBaseline) { d in d[.firstTextBaseline] }
                        }
                        // Rating chip removed from title row so it can be shown below the timeslot for all content
                    }
                    // Show subtitle even if only episode title or only season/episode exists
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
                        // Fallback to series name when no episode title is present (match ProgramView behavior)
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
                    }
                    // Move time box here, under title/subtitle
                    if let start = program.startDate, let end = program.endDate {
                        Text("\(start.formatted(date: .omitted, time: .shortened)) - \(end.formatted(date: .omitted, time: .shortened))")
                            .font(.subheadline)
                            .foregroundColor(.primary)
                    }
                    if let rating = program.officialRating {
                        Text(rating)
                            .font(.caption)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color.gray.opacity(0.2))
                            .clipShape(Capsule())
                    }
                }
                // Removed program overview/description; ProgramView handles details
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                if isLive {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 12, height: 12)
                        Text("LIVE")
                            .font(.subheadline)
                            .foregroundColor(.red)
                    }                }
                // Play button removed from here
            }
        }
    }
}

extension JFProgram {
    init?(epg base: BaseItemDto, channelName: String?, channelId: String?) {
        // Some EPG items may not include a stable Item Id; synthesize a fallback so we can always
        // present a ProgramView. Preserve the original id in itemId when present so other logic
        // (related/upcoming lookups) can still use it.
        let originalId = base.id
        let synthesizedId: String = originalId ?? "epg_\(channelId ?? "unknown")_\(Int((base.startDate ?? Date()).timeIntervalSince1970))"
        self.id = synthesizedId
        self.name = base.name ?? ""
        self.overview = base.overview
        self.startDate = base.startDate
        self.endDate = base.endDate
        self.channelId = channelId
        self.channelName = channelName
        // Heuristics
        // Prefer an explicit IsMovie flag from the server when available; otherwise fall back
        // to episode/season heuristics.
        if let explicitIsMovie = base.isMovie {
            self.isMovie = explicitIsMovie
            self.isSeries = !explicitIsMovie
        } else {
            let hasEpisodeMetadata = (base.episodeTitle != nil) || (base.parentIndexNumber != nil)
            self.isSeries = hasEpisodeMetadata
            self.isMovie = !hasEpisodeMetadata
        }
        self.isNews = false
        self.isSports = false
        self.isKids = false
        self.episodeTitle = base.episodeTitle
        // Preserve series name when provided by the EPG item so subtitles can fall back to it
        self.seriesName = base.seriesName
        // Preserve genres/tags coming from EPG
        self.genres = base.genres
        self.runTimeTicks = nil
        self.officialRating = base.officialRating
        // (genres already assigned above)
        self.parentIndexNumber = base.parentIndexNumber
        self.indexNumber = base.indexNumber
        self.isRepeat = base.isRepeat
        // Preserve original item id in itemId (may be nil)
        self.seriesId = nil
        self.itemId = originalId
    }
}
