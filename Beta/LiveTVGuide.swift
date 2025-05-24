//
//  GuideView.swift
//  LiveFin
//
//  Created by Kervens on 5/13/25.
//

import SwiftUI

struct GuideView: View {
    @EnvironmentObject var appState: AppState
    @State private var channels: [LiveTvChannelDto] = []
    @State private var programs: [BaseItemDto] = []
    @State private var error: String?
    @State private var isLoading = true
    @State private var cacheURL: URL = {
        let urls = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
        return urls[0].appendingPathComponent("cached_programs.json")
    }()

    var body: some View {
        NavigationStack {
            VStack {
                if isLoading {
                    ProgressView("Loading guide...")
                } else if let error = error {
                    Text("Error: \(error)")
                        .foregroundColor(.red)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 16) {
                            ForEach(channels, id: \.id) { channel in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(channel.name ?? "Unnamed Channel")
                                        .font(.headline)
                                    ScrollView(.horizontal, showsIndicators: false) {
                                        HStack(spacing: 8) {
                                            ForEach(programs.filter { $0.channelId == channel.id }, id: \.id) { program in
                                                VStack(alignment: .leading) {
                                                    Text(program.name ?? "Untitled")
                                                        .font(.subheadline)
                                                    if let start = program.startDate, let end = program.endDate {
                                                        Text("\(start.formatted(date: .omitted, time: .shortened)) - \(end.formatted(date: .omitted, time: .shortened))")
                                                            .font(.caption)
                                                            .foregroundColor(.gray)
                                                    }
                                                }
                                                .padding(8)
                                                .background(Color.gray.opacity(0.1))
                                                .cornerRadius(6)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                        .padding()
                    }
                }
            }
            .navigationTitle("TV Guide")
            .task {
                await loadGuideData()
            }
        }
    }

    func loadCachedPrograms() {
        do {
            let data = try Data(contentsOf: cacheURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let response = try decoder.decode(ProgramsResponse.self, from: data)
            self.programs = response.items ?? []
            print("Loaded programs from cache")
        } catch {
            print("No cached programs found or failed to decode: \(error)")
        }
    }

    func saveProgramsToCache(_ programs: [BaseItemDto]) {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let response = ProgramsResponse(items: programs)
            let data = try encoder.encode(response)
            try data.write(to: cacheURL)
            print("Programs cached to disk")
        } catch {
            print("Failed to cache programs: \(error)")
        }
    }

    func loadGuideData() async {
        loadCachedPrograms()
        isLoading = true
        error = nil

        guard let client = appState.client else {
            error = "Client not initialized"
            isLoading = false
            return
        }

        let now = Date()
        let later = Calendar.current.date(byAdding: .hour, value: 4, to: now)!

        do {
            // Fetch channels
            let channelURL = client.configuration.url.appendingPathComponent("/LiveTv/Channels")
            var channelRequest = URLRequest(url: channelURL)
            channelRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            channelRequest.setValue(appState.accessToken, forHTTPHeaderField: "X-Emby-Token")
            let (channelData, _) = try await URLSession.shared.data(for: channelRequest)
            let channelResponse = try JSONDecoder().decode(ChannelsResponse.self, from: channelData)
            self.channels = channelResponse.items ?? []

            // Fetch programs
            let programURL = client.configuration.url.appendingPathComponent("/LiveTv/Programs")
            var components = URLComponents(url: programURL, resolvingAgainstBaseURL: false)
            components?.queryItems = [
                URLQueryItem(name: "startDate", value: ISO8601DateFormatter().string(from: now)),
                URLQueryItem(name: "endDate", value: ISO8601DateFormatter().string(from: later)),
                URLQueryItem(name: "EnableImages", value: "false"),
                URLQueryItem(name: "EnableUserData", value: "false")
            ]

            guard let finalURL = components?.url else {
                error = "Invalid programs URL"
                isLoading = false
                return
            }

            var programRequest = URLRequest(url: finalURL)
            programRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            programRequest.setValue(appState.accessToken, forHTTPHeaderField: "X-Emby-Token")
            let (programData, _) = try await URLSession.shared.data(for: programRequest)

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

            let programResponse = try decoder.decode(ProgramsResponse.self, from: programData)
            self.programs = programResponse.items ?? []
            saveProgramsToCache(self.programs)
        } catch {
            self.error = error.localizedDescription
        }

        isLoading = false
    }
}

// Response model for Channels
struct ChannelsResponse: Codable {
    let items: [LiveTvChannelDto]?

    enum CodingKeys: String, CodingKey {
        case items = "Items"
    }
}
