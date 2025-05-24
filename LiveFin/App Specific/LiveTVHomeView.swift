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
    var currentProgram: BaseItemDto?  // Add this to store the current program

    var streamUrl: String {
        "/LiveTv/LiveStream?channelId=\(id)"
    }

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case number = "Number"
        case startDate = "StartDate"
        case endDate = "EndDate"
    }

    init(id: String, name: String?, number: String?, startDate: Date?, endDate: Date?, baseURL: String) {
        self.id = id
        self.name = name
        self.number = number
        self.startDate = startDate
        self.endDate = endDate
        self.baseURL = baseURL
        self.currentProgram = nil  // Initialize as nil
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.name = try container.decodeIfPresent(String.self, forKey: .name)
        self.number = try container.decodeIfPresent(String.self, forKey: .number)
        self.startDate = try container.decodeIfPresent(Date.self, forKey: .startDate)
        self.endDate = try container.decodeIfPresent(Date.self, forKey: .endDate)
        self.baseURL = "YOUR_SERVER_BASE_URL"  // Replace with actual server URL
        self.currentProgram = nil
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(name, forKey: .name)
        try container.encodeIfPresent(number, forKey: .number)
        try container.encodeIfPresent(startDate, forKey: .startDate)
        try container.encodeIfPresent(endDate, forKey: .endDate)
        // baseURL is not encoded as it's not part of the API response
    }
}

struct ChannelRowView: View {
    let channel: LiveTvChannelDto
    let baseURL: String
    let apiKey: String

    var body: some View {
        HStack {
            ChannelImageView(baseUrl: baseURL, apiKey: apiKey, channelId: channel.id)
                .frame(width: 50, height: 50)
                .id(channel.id)
            VStack(alignment: .leading) {
                Text(channel.name ?? "Unnamed Channel")
                    .font(.headline)
                if let number = channel.number {
                    HStack(spacing: 4) {
                        Text("Channel \(number)")
                            .font(.subheadline)
                            .foregroundColor(.gray)
                        if let currentProgram = channel.currentProgram {
                            Text("• \(currentProgram.name ?? "No program")")
                                .font(.subheadline)
                                .foregroundColor(.red)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                }
                if let startDate = channel.startDate, let endDate = channel.endDate {
                    Text("\(startDate.formatted(date: .abbreviated, time: .shortened)) - \(endDate.formatted(date: .abbreviated, time: .shortened))")
                        .font(.subheadline)
                        .foregroundColor(.gray)
                }
            }
        }
    }
}

struct LiveTVHomeView: View {
    @EnvironmentObject var appState: AppState
    @State private var channels: [LiveTvChannelDto] = []
    @State private var isLoading = false
    @State private var error: String?
    @State private var showDonateSafari = false

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
                            ChannelRowView(channel: channel, baseURL: appState.serverURL, apiKey: appState.apiKey)
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
                    Menu {
                        // Support Page Button
                        Button(action: {
                            showDonateSafari = true
                        }) {
                            Label("Donate", systemImage: "heart.fill") // Changed label and icon
                        }

                        // Discord Button
                        Button(action: {
                            print("Open Discord")
                            if let url = URL(string: "https://discord.gg/xGdey3dxQN") {
                                UIApplication.shared.open(url)
                            }
                        }) {
                            Label("Discord", systemImage: "link")
                        }

                        // Logout Button
                        Button(role: .destructive, action: { // Use .destructive role for a red logout button
                            print("Logging out...")
                            appState.logout() // This triggers RootView to show LoginView
                        }) {
                            Label("Logout", systemImage: "person.crop.circle.badge.minus")
                        }
                    } label: {
                        Image(systemName: "person.crop.circle") // Account symbol
                            .font(.title2) // Make the icon a bit larger
                    }
                }
            }
            .sheet(isPresented: $showDonateSafari) {
                SafariView(url: URL(string: "https://coff.ee/kpgamingz")!)
            }
            .onAppear {
                loadChannelsFromCache()
                Task {
                    await fetchChannels()
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

    struct ProgramsResponse: Codable {
        let items: [BaseItemDto]?

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
            // Fetch Channels
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
            let loadedChannels = decodedResponse.items ?? []

            self.channels = loadedChannels

            // Fetch current programs for all channels individually
            await fetchCurrentPrograms(for: channels)

            // Save channels to cache after fetching
            await saveChannelsToCache()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func fetchCurrentPrograms(for channels: [LiveTvChannelDto]) async {
        guard let client = appState.client else { return }

        let now = Date()
        let later = Calendar.current.date(byAdding: .hour, value: 1, to: now)!

        let programURL = client.configuration.url.appendingPathComponent("/LiveTv/Programs")
        var components = URLComponents(url: programURL, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "startDate", value: ISO8601DateFormatter().string(from: now)),
            URLQueryItem(name: "endDate", value: ISO8601DateFormatter().string(from: later)),
            URLQueryItem(name: "IsAiring", value: "true")
        ]

        guard let finalURL = components?.url else { return }

        var request = URLRequest(url: finalURL)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(appState.accessToken, forHTTPHeaderField: "X-Emby-Token")

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            let programResponse = try JSONDecoder().decode(ProgramsResponse.self, from: data)
            let currentPrograms = programResponse.items ?? []

            var updatedChannels: [LiveTvChannelDto] = []

            for var channel in channels {
                if let currentProgram = currentPrograms.first(where: { $0.channelId == channel.id }) {
                    channel.currentProgram = currentProgram
                }
                updatedChannels.append(channel)
            }

            self.channels = updatedChannels
        } catch {
            print("Error fetching current programs: \(error)")
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

import SafariServices

struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        return SFSafariViewController(url: url)
    }

    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}
}
