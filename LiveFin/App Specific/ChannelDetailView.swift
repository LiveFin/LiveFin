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
        case parentIndexNumber = "ParentIndexNumber"
        case indexNumber = "IndexNumber"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        id = try? container.decode(String.self, forKey: .id)
        name = try? container.decode(String.self, forKey: .name)
        startDate = try? container.decode(Date.self, forKey: .startDate)
        endDate = try? container.decode(Date.self, forKey: .endDate)
        overview = try? container.decode(String.self, forKey: .overview)
        channelId = try? container.decode(String.self, forKey: .channelId)
        mediaSources = try? container.decode([MediaSourceDto].self, forKey: .mediaSources)
        officialRating = try? container.decode(String.self, forKey: .officialRating)
        episodeTitle = try? container.decode(String.self, forKey: .episodeTitle)
        parentIndexNumber = try? container.decode(Int.self, forKey: .parentIndexNumber)
        indexNumber = try? container.decode(Int.self, forKey: .indexNumber)
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
        return ForEach(sortedDates, id: \.self) { date in
            let programsForDate = groupedPrograms[date] ?? []
            Section(header: Text(date.formatted(date: .abbreviated, time: .omitted))) {
                ForEach(programsForDate) { program in
                    ProgramRowView(program: program, programs: programs, channelId: channel.id, appState: appState)
                }
            }
        }
    }

    var body: some View {
        Group {
            if filteredPrograms.isEmpty {
                if programs.isEmpty {
                    ProgressView("Loading programs...")
                        .frame(maxWidth: .infinity)
                } else {
                    ScrollView {
                        Text("No programs available.")
                            .foregroundColor(.secondary)
                            .padding()
                    }
                }
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
        .navigationTitle(channel.name ?? "Channel")
        .task {
            await fetchPrograms()
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
                URLQueryItem(name: "fields", value: "MediaSources,Overview,OfficialRating,EpisodeTitle,ParentIndexNumber,IndexNumber"),
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
            let isoFormatter = ISO8601DateFormatter()
            isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            decoder.dateDecodingStrategy = .custom { decoder in
                let container = try decoder.singleValueContainer()
                let dateStr = try container.decode(String.self)
                guard let date = isoFormatter.date(from: dateStr) else {
                    throw DecodingError.dataCorruptedError(in: container, debugDescription: "Cannot decode date: \(dateStr)")
                }
                return date
            }

            let decoded = try decoder.decode(ProgramsResponse.self, from: data)
            self.programs = decoded.items ?? []

        } catch {
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

        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            if let title = program.name {
                                Text(title)
                                    .font(.title3)
                                    .bold()
                            }
                            if program.episodeTitle == nil, let rating = program.officialRating {
                                Text(rating)
                                    .font(.caption)
                                    .padding(4)
                                    .background(Color.gray.opacity(0.2))
                                    .cornerRadius(4)
                            }
                        }
                        if let season = program.parentIndexNumber, let episodeNum = program.indexNumber {
                            let seasonEpisode = String(format: "S%02dE%02d", season, episodeNum)
                            let subtitle = program.episodeTitle != nil ? "\(seasonEpisode) • \(program.episodeTitle!)" : seasonEpisode
                            Text(subtitle)
                                .font(.subheadline)
                                .foregroundColor(.secondary)

                            if let rating = program.officialRating {
                                Text(rating)
                                    .font(.caption)
                                    .padding(4)
                                    .background(Color.gray.opacity(0.2))
                                    .cornerRadius(4)
                            }
                        }
                    }
                    if isLive {
                        Text("LIVE")
                            .font(.subheadline)
                            .foregroundColor(.white)
                            .padding(5)
                            .background(Circle().fill(Color.red))
                    }

                    if let start = program.startDate, let end = program.endDate {
                        Spacer()
                        VStack(alignment: .trailing, spacing: 4) {
                            Text("\(start.formatted(date: .omitted, time: .shortened)) - \(end.formatted(date: .omitted, time: .shortened))")
                                .font(.subheadline)
                                .foregroundColor(.blue)

                            if isLive {
                                Button(action: {
                                    if let programId = program.id {
                                        Task {
                                            do {
                                                let playbackInfo = try await PlaybackInfoService.fetchPlaybackInfo(
                                                    programId: programId,
                                                    userId: appState.user?.id ?? "",
                                                    deviceId: appState.deviceId,
                                                    serverURL: appState.serverURL,
                                                    apiKey: appState.apiKey,
                                                    mediaSourceId: program.mediaSources?.first?.id
                                                )

                                                if let hlsUrlString = playbackInfo.hlsUri, let url = URL(string: hlsUrlString) {
                                                    selectedStreamURL = url
                                                    showPlayer = true
                                                }
                                            } catch {
                                                print("Error fetching playback URL: \(error)")
                                            }
                                        }
                                    }
                                }) {
                                    Image(systemName: "play.circle.fill")
                                        .resizable()
                                        .frame(width: 24, height: 24)
                                        .foregroundColor(.blue)
                                }
                            }
                        }
                    }
                }

                let overviewText: String = {
                    if let raw = program.overview?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
                        return raw
                    } else {
                        return "No description available."
                    }
                }()

                VStack(alignment: .leading, spacing: 4) {
                    if isExpanded {
                        Text(overviewText)
                            .font(.body)
                            .foregroundColor(.secondary)
                    }
                    Button(isExpanded ? "Less" : "More") {
                        isExpanded.toggle()
                    }
                    .font(.caption)
                    .foregroundColor(.blue)
                }
            }
        }
        .padding(.vertical, 8)
        .sheet(isPresented: $showPlayer) {
            if let url = selectedStreamURL {
                SafariView(url: url)
            }
        }
    }
}

import SafariServices

struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }

    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}
}
