//
//  ChannelsView.swift
//  LiveFin
//
//  Created by KPGamingz on 4/12/25.
//

import SwiftUI
import Foundation

// Prefetch helpers to warm channel logo cache
#if canImport(UIKit)
private func buildChannelLogoURL(baseURL: String, apiKey: String, channelId: String) -> URL? {
    let trimmed = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    let path = "/Items/\(channelId)/Images/Primary?maxWidth=200&api_key=\(apiKey)"
    return URL(string: trimmed + path)
}

private func prefetchChannelLogos(_ channels: [LiveTvChannelDto], baseURL: String, apiKey: String) {
    let slice = channels.prefix(60) // limit to first ~60 to avoid burst
    for ch in slice {
        guard let url = buildChannelLogoURL(baseURL: baseURL, apiKey: apiKey, channelId: ch.id) else { continue }
        ImageCacheManager.shared.load(url) { _ in /* warm cache */ }
    }
}
#endif

struct LiveTvChannelDto: Codable, Identifiable {
    let id: String
    let name: String?
    let number: String?
    let startDate: Date?
    let endDate: Date?
    let baseURL: String
    var currentProgram: BaseItemDto?

    var streamUrl: String { "/LiveTv/LiveStream?channelId=\(id)" }

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
        self.currentProgram = nil
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.name = try container.decodeIfPresent(String.self, forKey: .name)
        self.number = try container.decodeIfPresent(String.self, forKey: .number)
        self.startDate = try container.decodeIfPresent(Date.self, forKey: .startDate)
        self.endDate = try container.decodeIfPresent(Date.self, forKey: .endDate)
        self.baseURL = "YOUR_SERVER_BASE_URL"
        self.currentProgram = nil
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(name, forKey: .name)
        try container.encodeIfPresent(number, forKey: .number)
        try container.encodeIfPresent(startDate, forKey: .startDate)
        try container.encodeIfPresent(endDate, forKey: .endDate)
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

struct ChannelsView: View {
    @EnvironmentObject var appState: AppState
    @State private var channels: [LiveTvChannelDto] = []
    @State private var isLoading = false
    @State private var error: String?

    // Natural sort helpers
    private func channelNumericComponents(_ number: String?) -> [Int] {
        guard let number, !number.isEmpty else { return [Int.max] }
        let parts = number.split { !$0.isNumber }
        if parts.isEmpty { return [Int.max] }
        return parts.map { Int($0) ?? Int.max }
    }
    private func channelLessThan(_ a: LiveTvChannelDto, _ b: LiveTvChannelDto) -> Bool {
        let aNum = a.number ?? ""
        let bNum = b.number ?? ""
        let aHas = !aNum.isEmpty
        let bHas = !bNum.isEmpty
        if aHas != bHas { return aHas }
        let ac = channelNumericComponents(aNum)
        let bc = channelNumericComponents(bNum)
        if ac != bc { return ac.lexicographicallyPrecedes(bc) }
        return (a.name ?? "") < (b.name ?? "")
    }

    var body: some View {
        NavigationStack {
            List {
                if isLoading {
                    ProgressView()
                } else if let error = error {
                    Text("Error: \(error)").foregroundColor(.red)
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
            .id("channelsList")
            .refreshable { await fetchChannels(force: true) }
            .navigationTitle("Channels")
            .onAppear {
                if channels.isEmpty {
                    loadChannelsFromCache()
                    #if canImport(UIKit)
                    prefetchChannelLogos(channels, baseURL: appState.serverURL, apiKey: appState.apiKey)
                    #endif
                    Task { await fetchChannels(force: false) }
                }
            }
        }
    }

    struct ChannelsResponse: Codable { let items: [LiveTvChannelDto]?; enum CodingKeys: String, CodingKey { case items = "Items" } }
    struct ProgramsResponse: Codable { let items: [BaseItemDto]?; enum CodingKeys: String, CodingKey { case items = "Items" } }

    func fetchChannels(force: Bool = false) async {
        guard let client = appState.client else { error = "Client not initialized"; return }
        guard !appState.accessToken.isEmpty else { error = "Access token is missing"; return }
        if !force && !channels.isEmpty { return }
        isLoading = true; error = nil; defer { isLoading = false }
        do {
            let url = client.configuration.url.appendingPathComponent("/LiveTv/Channels")
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(appState.accessToken, forHTTPHeaderField: "X-Emby-Token")
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 { error = "Failed to fetch channels. Status code: \(http.statusCode)"; return }
            let decoded = try JSONDecoder().decode(ChannelsResponse.self, from: data)
            let loaded = decoded.items ?? []
            self.channels = loaded.sorted(by: channelLessThan)
            await fetchCurrentPrograms(for: channels)
            await saveChannelsToCache()
            #if canImport(UIKit)
            prefetchChannelLogos(self.channels, baseURL: appState.serverURL, apiKey: appState.apiKey)
            #endif
        } catch { self.error = error.localizedDescription }
    }

    func fetchCurrentPrograms(for channels: [LiveTvChannelDto]) async {
        guard let client = appState.client else { return }
        let now = Date(); let later = Calendar.current.date(byAdding: .hour, value: 1, to: now)!
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
            var updated: [LiveTvChannelDto] = []
            for var channel in channels {
                if let currentProgram = currentPrograms.first(where: { $0.channelId == channel.id }) { channel.currentProgram = currentProgram }
                updated.append(channel)
            }
            self.channels = updated.sorted(by: channelLessThan)
        } catch { print("Error fetching current programs: \(error)") }
    }

    func saveChannelsToCache() async {
        do { let data = try JSONEncoder().encode(channels); let url = try getCacheFileURL(); try data.write(to: url, options: [.atomic]) } catch { print("Failed to save channels to cache: \(error.localizedDescription)") }
    }

    func loadChannelsFromCache() {
        do {
            let url = try getCacheFileURL()
            let data = try Data(contentsOf: url)
            let cached = try JSONDecoder().decode([LiveTvChannelDto].self, from: data)
            self.channels = cached.sorted(by: channelLessThan)
            #if canImport(UIKit)
            prefetchChannelLogos(self.channels, baseURL: appState.serverURL, apiKey: appState.apiKey)
            #endif
            Task { await fetchCurrentPrograms(for: cached) }
        } catch { print("Failed to load channels from cache: \(error.localizedDescription)") }
    }

    func getCacheFileURL() throws -> URL {
        let fm = FileManager.default
        let docsURL = try fm.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return docsURL.appendingPathComponent("cachedChannels.json")
    }
}
