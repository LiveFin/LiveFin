//
//  LiveTVHomeView.swift
//  LiveFin
//
//  Created by KPGamingz on 4/12/25.
//

import SwiftUI
import Foundation

struct LiveTvChannelDto: Codable, Identifiable {
    let id: String
    let name: String?
    let number: String?
    let startDate: Date?
    let endDate: Date?
    let baseURL: String  // Add baseURL manually (this won't be decoded from the API response)
    let currentProgramTitle: String?
    let programId: String?

    var streamUrl: String {
        "/LiveTv/LiveStream?channelId=\(id)"
    }

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case number = "Number"
        case startDate = "StartDate"
        case endDate = "EndDate"
        case currentProgram = "CurrentProgram"
    }

    enum CurrentProgramKeys: String, CodingKey {
        case id = "Id"
        case title = "Title"
    }

    init(id: String, name: String?, number: String?, startDate: Date?, endDate: Date?, baseURL: String, currentProgramTitle: String?, programId: String?) {
        self.id = id
        self.name = name
        self.number = number
        self.startDate = startDate
        self.endDate = endDate
        self.baseURL = baseURL
        self.currentProgramTitle = currentProgramTitle
        self.programId = programId
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.name = try container.decodeIfPresent(String.self, forKey: .name)
        self.number = try container.decodeIfPresent(String.self, forKey: .number)
        self.startDate = try container.decodeIfPresent(Date.self, forKey: .startDate)
        self.endDate = try container.decodeIfPresent(Date.self, forKey: .endDate)
        self.baseURL = "YOUR_SERVER_BASE_URL"  // Replace with actual server URL

        if let currentProgramContainer = try? container.nestedContainer(keyedBy: CurrentProgramKeys.self, forKey: .currentProgram) {
            self.currentProgramTitle = try currentProgramContainer.decodeIfPresent(String.self, forKey: .title)
            self.programId = try currentProgramContainer.decodeIfPresent(String.self, forKey: .id)
        } else {
            self.currentProgramTitle = nil
            self.programId = nil
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(name, forKey: .name)
        try container.encodeIfPresent(number, forKey: .number)
        try container.encodeIfPresent(startDate, forKey: .startDate)
        try container.encodeIfPresent(endDate, forKey: .endDate)
        // baseURL is not encoded as it's not part of the API response
        if currentProgramTitle != nil || programId != nil {
            var currentProgramContainer = container.nestedContainer(keyedBy: CurrentProgramKeys.self, forKey: .currentProgram)
            try currentProgramContainer.encodeIfPresent(programId, forKey: .id)
            try currentProgramContainer.encodeIfPresent(currentProgramTitle, forKey: .title)
        }
    }
}

struct ChannelRowView: View {
    let channel: LiveTvChannelDto
    let baseURL: String
    let apiKey: String
    @Binding var selectedStreamURL: URL?
    @Binding var showPlayer: Bool

    var body: some View {
        HStack {
            ChannelImageView(baseUrl: baseURL, apiKey: apiKey, channelId: channel.id)  // Pass baseURL, apiKey, and channelId to ChannelImageView
                .frame(width: 50, height: 50)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            
            VStack(alignment: .leading) {
                Text(channel.name ?? "Unnamed Channel")
                    .font(.headline)
                if let currentProgram = channel.currentProgramTitle {
                    Text(currentProgram)
                        .font(.subheadline)
                        .foregroundColor(.blue)
                }
                if let number = channel.number {
                    Text("Channel \(number)")
                        .font(.subheadline)
                        .foregroundColor(.gray)
                }
                if let startDate = channel.startDate, let endDate = channel.endDate {
                    Text("\(startDate.formatted(date: .abbreviated, time: .shortened)) - \(endDate.formatted(date: .abbreviated, time: .shortened))")
                        .font(.subheadline)
                        .foregroundColor(.gray)
                }
            }
            Spacer()
            Button(action: {
                let streamPath = "/LiveTv/LiveStream?channelId=\(channel.id)"
                let fullURLString = baseURL + streamPath

                if let encodedString = fullURLString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
                   let url = URL(string: encodedString) {
                    selectedStreamURL = url  // Set the URL for the player
                    showPlayer = true  // Trigger the sheet to show
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
}

struct LiveTVHomeView: View {
    @EnvironmentObject var appState: AppState
    @State private var channels: [LiveTvChannelDto] = []
    @State private var isLoading = false
    @State private var error: String?
    @State private var selectedStreamURL: URL?
    @State private var showPlayer = false

    var body: some View {
        NavigationStack {  // Wrap in NavigationStack to enable navigationDestination
            List {
                if isLoading {
                    ProgressView()
                } else if let error = error {
                    Text("Error: \(error)")
                        .foregroundColor(.red)
                } else if channels.isEmpty {
                    Text("No channels available.")
                } else {
                    ForEach(channels, id: \.id) { channel in
                        NavigationLink(destination: ChannelDetailView(channel: channel)) {
                            ChannelRowView(channel: channel, baseURL: appState.serverURL, apiKey: appState.apiKey, selectedStreamURL: $selectedStreamURL, showPlayer: $showPlayer)
                        }
                    }
                }
            }
            .refreshable {
                await fetchChannels()  // Fetch channels again when pulling to refresh
            }
            .navigationTitle("Live TV")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Logout") {
                        appState.logout()
                    }
                }
            }
            .onAppear {
                loadChannelsFromCache()
                Task {
                    await fetchChannels()
                }
            }
            .sheet(isPresented: $showPlayer) {
                if let url = selectedStreamURL {
                    VideoPlayerView(streamURL: url)
                }
            }
        }
    }

    struct ChannelsResponse: Codable {
        let items: [LiveTvChannelDto]?

        enum CodingKeys: String, CodingKey {
            case items = "Items"
        }
    }

    func fetchChannels() async {
        guard let client = appState.client else {
            error = "Client not initialized"
            return
        }
        guard !appState.accessToken.isEmpty else {
            error = "Access token is missing"
            return
        }

        isLoading = true
        error = nil
        defer { isLoading = false }

        do {
            let url = client.configuration.url.appendingPathComponent("/LiveTv/Channels")
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(appState.accessToken, forHTTPHeaderField: "X-Emby-Token")

            let (data, response) = try await URLSession.shared.data(for: request)

            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
                error = "Failed to fetch channels. Status code: \(httpResponse.statusCode)"
                return
            }

            let decodedResponse = try JSONDecoder().decode(ChannelsResponse.self, from: data)
            var loadedChannels = decodedResponse.items ?? []

            // Parse CurrentProgram details for each channel from raw JSON data
            if let jsonObject = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
               let itemsArray = jsonObject["Items"] as? [[String: Any]] {
                for (index, item) in itemsArray.enumerated() {
                    if let currentProgram = item["CurrentProgram"] as? [String: Any] {
                        let title = currentProgram["Title"] as? String
                        let programId = currentProgram["Id"] as? String
                        if index < loadedChannels.count {
                            let channel = loadedChannels[index]
                            loadedChannels[index] = LiveTvChannelDto(id: channel.id, name: channel.name, number: channel.number, startDate: channel.startDate, endDate: channel.endDate, baseURL: channel.baseURL, currentProgramTitle: title, programId: programId)
                        }
                    }
                }
            }

            self.channels = loadedChannels
            
            await saveChannelsToCache()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func saveChannelsToCache() async {
        do {
            let data = try JSONEncoder().encode(channels)
            let url = try getCacheFileURL()
            try data.write(to: url, options: [.atomic])
        } catch {
            print("Failed to save channels to cache: \(error.localizedDescription)")
        }
    }

    func loadChannelsFromCache() {
        do {
            let url = try getCacheFileURL()
            let data = try Data(contentsOf: url)
            let cachedChannels = try JSONDecoder().decode([LiveTvChannelDto].self, from: data)
            self.channels = cachedChannels
        } catch {
            print("Failed to load channels from cache: \(error.localizedDescription)")
        }
    }

    func getCacheFileURL() throws -> URL {
        let fm = FileManager.default
        let docsURL = try fm.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return docsURL.appendingPathComponent("cachedChannels.json")
    }
}
