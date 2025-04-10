import SwiftUI
import Foundation
import AVKit
import WebKit

struct MediaSourceDto: Codable {
    let id: String?
    let path: String?
    let protocolType: String?
    let container: String?
    let type: String?
    let mediaStreams: [MediaStreamDto]?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case path = "Path"
        case protocolType = "Protocol"
        case container = "Container"
        case type = "Type"
        case mediaStreams = "MediaStreams"
    }
}

struct MediaStreamDto: Codable {
    let codec: String?
    let language: String?
    let type: String?

    enum CodingKeys: String, CodingKey {
        case codec = "Codec"
        case language = "Language"
        case type = "Type"
    }
}
// MARK: - Playback Info DTOs
struct PlaybackInfoResponse: Codable {
    let mediaSources: [MediaSourceDto]?
    let playSessionId: String?

    enum CodingKeys: String, CodingKey {
        case mediaSources = "MediaSources"
        case playSessionId = "PlaySessionId"
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

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case startDate = "StartDate"
        case endDate = "EndDate"
        case overview = "Overview"
        case channelId = "ChannelId"
        case mediaSources = "MediaSources"
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
    @State private var error: String?
    @State private var selectedStreamURL: URL?
    @State private var showPlayer = false

    var filteredPrograms: [BaseItemDto] {
        let now = Date()
        return programs.filter { program in
            guard let start = program.startDate else { return false }
            return start >= Calendar.current.startOfDay(for: now)
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
            Section(header: Text(date.formatted(date: .abbreviated, time: .omitted))
                .fontWeight(Calendar.current.isDateInToday(date) ? .bold : .regular)
                .foregroundColor(Calendar.current.isDateInToday(date) ? .blue : .primary)
            ) {
                ForEach(programsForDate) { program in
                    ProgramRowView(program: program, programs: programs, channelId: channel.id, appState: appState, selectedStreamURL: $selectedStreamURL, showPlayer: $showPlayer, error: $error)
                }
            }
        }
    }

    var body: some View {
        Group {
            if filteredPrograms.isEmpty && error == nil {
                ProgressView("Loading programs...")
                    .frame(maxWidth: .infinity)
            } else if filteredPrograms.isEmpty {
                ScrollView {
                    Text("No programs available.")
                        .foregroundColor(.secondary)
                        .padding()
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
        .alert("Error", isPresented: .constant(error != nil), actions: {
            Button("OK", role: .cancel) {
                error = nil
            }
        }, message: {
            Text(error ?? "Unknown error")
        })
        .navigationTitle(channel.name ?? "Channel")
        .task {
            await fetchPrograms()
        }
        .sheet(isPresented: $showPlayer) {
            if let url = selectedStreamURL {
                WebPlayerView(streamURL: url)
            } else {
                Text("Invalid stream URL")
            }
        }
    }
    
    func fetchPrograms() async {
        guard let client = appState.client else {
            error = "Client not initialized"
            return
        }

        let accessToken = appState.accessToken
        guard !accessToken.isEmpty else {
            error = "Access token is missing"
            return
        }

        error = nil

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
                URLQueryItem(name: "fields", value: "MediaSources"),
                URLQueryItem(name: "EnableImages", value: "true"),
                URLQueryItem(name: "EnableUserData", value: "true")
            ]

            guard let userId = appState.user?.id else {
                error = "User ID is missing"
                print("DEBUG: User ID is missing")
                return
            }
            components?.queryItems?.append(URLQueryItem(name: "userId", value: userId))

            guard let finalURL = components?.url else {
                error = "Failed to construct URL"
                return
            }

            var request = URLRequest(url: finalURL)
            request.httpMethod = "GET"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(accessToken, forHTTPHeaderField: "X-Emby-Token")

            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                error = "Invalid response"
                return
            }

            if httpResponse.statusCode != 200 {
                // Attempt to decode error JSON response
                do {
                    if let jsonObject = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        print("DEBUG: Error response JSON: \(jsonObject)")
                        if let message = jsonObject["Message"] as? String {
                            print("DEBUG: Error message: \(message)")
                            error = message
                            return
                        }
                    } else {
                        let rawString = String(data: data, encoding: .utf8) ?? "Unable to decode response"
                        print("DEBUG: Error response raw string: \(rawString)")
                    }
                } catch {
                    let rawString = String(data: data, encoding: .utf8) ?? "Unable to decode response"
                    print("DEBUG: Failed to decode error response JSON. Raw response: \(rawString)")
                }
                error = "Failed to fetch programs."
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
            self.error = error.localizedDescription
        }
    }
}

struct ProgramRowView: View {
    let program: BaseItemDto
    let programs: [BaseItemDto]
    let channelId: String
    @ObservedObject var appState: AppState
    @Binding var selectedStreamURL: URL?
    @Binding var showPlayer: Bool
    @Binding var error: String?

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
                    Text(program.name ?? "Untitled")
                        .font(.headline)

                    if isLive {
                        Text("LIVE")
                            .font(.subheadline)
                            .foregroundColor(.white)
                            .padding(5)
                            .background(Circle().fill(Color.red))
                    }

                    if let start = program.startDate, let end = program.endDate {
                        Spacer()
                        Text("\(start.formatted(date: .omitted, time: .shortened)) - \(end.formatted(date: .omitted, time: .shortened))")
                            .font(.subheadline)
                            .foregroundColor(.blue)
                    }
                }

                if let overview = program.overview {
                    Text(overview)
                        .font(.body)
                        .foregroundColor(.secondary)
                }
            }

            if isLive {
                Spacer()
                Button(action: {
                    if let programId = program.id {
                        Task {
                            if let url = await StreamManager.fetchStreamURL(
                                programId: programId,
                                userId: appState.user?.id ?? "",
                                deviceId: appState.deviceId,
                                serverURL: appState.serverURL,
                                accessToken: appState.accessToken,
                                mediaSourceId: nil,
                                programs: programs
                            ) {
                                selectedStreamURL = url
                                showPlayer = true
                            } else {
                                error = "Invalid stream URL"
                            }
                        }
                    } else {
                        error = "Program ID is missing"
                        print("DEBUG: Program ID is missing")
                    }
                }) {
                    Image(systemName: "play.circle.fill")
                        .resizable()
                        .frame(width: 24, height: 24)
                        .foregroundColor(.blue)
                        .padding(.leading, 8)
                }
            }
        }
        .padding(.vertical, 8)
    }
}

struct WebPlayerView: View {
    let streamURL: URL
    
    var body: some View {
        WebView(url: streamURL)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct WebView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        return WKWebView()
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        let request = URLRequest(url: url)
        uiView.load(request)
    }
}

extension String {
    var isValidURL: Bool {
        guard let url = URL(string: self) else { return false }
        return UIApplication.shared.canOpenURL(url)
    }
}

// StreamManager is now provided in StreamManager.swift
