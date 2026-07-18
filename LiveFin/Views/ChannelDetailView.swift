import SwiftUI
import Foundation
import AVKit
import WebKit

struct ChannelDetailView: View {
    let channel: LiveTvChannelDto
    @EnvironmentObject var appState: AppState
    @State private var programs: [BaseItemDto] = []
    @State private var selectedStreamItem: StreamURLItem? = nil
    @State private var selectedProgramTitle: String? = nil
    @State private var selectedProgramSubtitle: String? = nil
    @State private var isLoading: Bool = false
    @State private var isFavorite: Bool = false
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
                            if let prem = item.isPremiere { dict["IsPremiere"] = prem }
                            if let isN = item.isNew { dict["IsNew"] = isN }
                            if let isM = item.isMovie { dict["IsMovie"] = isM }
                            if let gs = item.genres { dict["Genres"] = gs }
                            if let sname = item.seriesName { dict["SeriesName"] = sname }
                            if let iid = item.id { dict["ItemId"] = iid }
                            if let sid = item.seriesId { dict["SeriesId"] = sid }
                            if let isS = item.isSeries { dict["IsSeries"] = isS }
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
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    favoriteButton
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
            .alert("Playback Error", isPresented: Binding(get: { playbackErrorMessage != nil }, set: { if !$0 { playbackErrorMessage = nil } })) {
                Button("OK", role: .cancel) { playbackErrorMessage = nil }
            } message: {
                Text(playbackErrorMessage ?? "An unknown error occurred while trying to play the channel.")
            }
            .task {
                self.isFavorite = channel.userData?.isFavorite == true
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

    var favoriteButton: some View {
        Button(action: toggleFavorite) {
            Image(systemName: isFavorite ? "heart.fill" : "heart")
                .foregroundColor(isFavorite ? .red : .primary)
        }
    }

    var playButton: some View {
        Button(action: playButtonTapped) {
            Image(systemName: "play.fill")
                .foregroundColor(.blue)
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
        })

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
    
    func fetchPrograms() async {
        guard let client = appState.client else { return }
        let accessToken = appState.accessToken
        guard !accessToken.isEmpty else { return }

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
                 URLQueryItem(name: "fields", value: "MediaSources,Overview,OfficialRating,Genres,SeriesName,EpisodeTitle,RunTimeTicks,ParentIndexNumber,IndexNumber,IsRepeat,IsPremiere,IsNew,IsMovie,ImageTags,ChannelId,ChannelName,TimerId,SeriesTimerId,SeriesId,IsSeries"),
                 URLQueryItem(name: "EnableImages", value: "true"),
                 URLQueryItem(name: "EnableUserData", value: "true")
             ]

             guard let userId = appState.user?.id else { return }
             components?.queryItems?.append(URLQueryItem(name: "userId", value: userId))
             guard let finalURL = components?.url else { return }

             var request = URLRequest(url: finalURL)
             request.httpMethod = "GET"
             request.setValue("application/json", forHTTPHeaderField: "Content-Type")
             request.setValue(accessToken, forHTTPHeaderField: "X-Emby-Token")

             let (data, response) = try await URLSession.shared.data(for: request)
             guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else { return }

             let decoder = JSONDecoder()
             decoder.dateDecodingStrategy = .custom { decoder in
                 let container = try decoder.singleValueContainer()
                 let dateStr = try container.decode(String.self)
                 let fWithFraction = ISO8601DateFormatter()
                 fWithFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                 if let d = fWithFraction.date(from: dateStr) { return d }
                 let fPlain = ISO8601DateFormatter()
                 fPlain.formatOptions = [.withInternetDateTime]
                 if let d2 = fPlain.date(from: dateStr) { return d2 }
                 throw DecodingError.dataCorruptedError(in: container, debugDescription: "Cannot decode date: \(dateStr)")
             }

             let decoded = try decoder.decode(ProgramsResponse.self, from: data)
             self.programs = decoded.items ?? []
         } catch {
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
        let isRecording = program.timerId != nil || program.seriesTimerId != nil

        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        if let title = program.name {
                            Text(title)
                                .font(.title3)
                                .bold()
                        }
                        if isRecording {
                            Image(systemName: "record.circle")
                                .foregroundColor(.red)
                                .font(.caption)
                                .alignmentGuide(.firstTextBaseline) { d in d[.firstTextBaseline] }
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
                    }
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
                    }
                }
            }
        }
    }
}
