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
                HStack(spacing: 6) {
                    Text(channel.name ?? "Unnamed Channel")
                        .font(.headline)
                    if channel.userData?.isFavorite == true {
                        Image(systemName: "heart.fill")
                            .foregroundColor(.red)
                            .font(.caption)
                    }
                }
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
    @State private var isOffline = false
    @State private var error: String?

    // Natural sort helpers prioritizing favorites
    private func channelNumericComponents(_ number: String?) -> [Int] {
        guard let number, !number.isEmpty else { return [Int.max] }
        let parts = number.split { !$0.isNumber }
        if parts.isEmpty { return [Int.max] }
        return parts.map { Int($0) ?? Int.max }
    }
    
    private func channelLessThan(_ a: LiveTvChannelDto, _ b: LiveTvChannelDto) -> Bool {
        let aFav = a.userData?.isFavorite == true
        let bFav = b.userData?.isFavorite == true
        if aFav != bFav { return aFav }
        
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
            ZStack {
                if isLoading && channels.isEmpty {
                    VStack {
                        Spacer()
                        ProgressView("Loading Channels...")
                            .scaleEffect(1.2)
                        Spacer()
                    }
                } else if isOffline && channels.isEmpty {
                    errorStateView(
                        title: "Cannot connect to your server. Please try again",
                        message: "",
                        icon: "network.slash"
                    )
                } else if channels.isEmpty {
                    errorStateView(
                        title: "Live TV Not Configured",
                        message: "Finish setting up your Jellyfin server with Live TV fully configured on the admin dashboard",
                        icon: "server.rack"
                    )
                } else {
                    List {
                        ForEach(channels, id: \.id) { channel in
                            NavigationLink(destination: ChannelDetailView(channel: channel)) {
                                ChannelRowView(channel: channel, baseURL: appState.serverURL, apiKey: appState.apiKey)
                            }
                        }
                    }
                    .id("channelsList")
                    .refreshable { await fetchChannels(force: true) }
                }
            }
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

    @ViewBuilder
    private func errorStateView(title: String, message: String, icon: String) -> some View {
        ScrollView {
            VStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 48))
                    .foregroundColor(.secondary)
                    .padding(.bottom, 8)
                
                Text(title)
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                
                if !message.isEmpty {
                    Text(message)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
            }
            .padding(.top, 120)
            .frame(maxWidth: .infinity)
        }
        .refreshable {
            await fetchChannels(force: true)
        }
    }

    func fetchChannels(force: Bool = false) async {
        guard let client = appState.client else { error = "Client not initialized"; return }
        guard !appState.accessToken.isEmpty else { error = "Access token is missing"; return }
        if !force && !channels.isEmpty { return }
        
        isLoading = true
        isOffline = false
        error = nil
        defer { isLoading = false }
        
        do {
            var urlComponents = URLComponents(url: client.configuration.url.appendingPathComponent("/LiveTv/Channels"), resolvingAgainstBaseURL: false)
            urlComponents?.queryItems = [
                URLQueryItem(name: "EnableUserData", value: "true"),
                URLQueryItem(name: "userId", value: appState.userID)
            ]
            
            guard let finalUrl = urlComponents?.url else { return }
            var request = URLRequest(url: finalUrl)
            request.httpMethod = "GET"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(appState.accessToken, forHTTPHeaderField: "X-Emby-Token")
            
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                self.isOffline = true
                self.error = "Failed to fetch channels. Status code: \(http.statusCode)"
                return
            }
            
            let decoded = try JSONDecoder().decode(ChannelsResponse.self, from: data)
            let loaded = decoded.items ?? []
            self.channels = loaded.sorted(by: channelLessThan)
            
            await fetchCurrentPrograms(for: channels)
            await saveChannelsToCache()
            
            #if canImport(UIKit)
            prefetchChannelLogos(self.channels, baseURL: appState.serverURL, apiKey: appState.apiKey)
            #endif
        } catch {
            self.error = error.localizedDescription
            self.isOffline = true
        }
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
