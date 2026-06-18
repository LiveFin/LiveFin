//
//  WatchAppState.swift
//  LiveFin
//
//  Created by KPGamingz on 4/12/25.
//

import SwiftUI
import Combine
import Foundation
#if canImport(WatchConnectivity)
import WatchConnectivity
#endif

// MARK: - Models
struct WatchChannel: Identifiable, Codable, Hashable {
    let id: String
    var name: String?
    var number: String?
    var currentProgram: WatchProgram? = nil
}

struct WatchProgram: Identifiable, Codable, Hashable {
    let id: String
    var name: String?
    var episodeTitle: String?
    var overview: String?
    var officialRating: String?
    var channelId: String?
    var startDate: Date?
    var endDate: Date?
    var isNew: Bool? // Added
    var isRepeat: Bool? // Added to mirror iOS logic

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case episodeTitle = "EpisodeTitle"
        case overview = "Overview"
        case officialRating = "OfficialRating"
        case channelId = "ChannelId"
        case startDate = "StartDate"
        case endDate = "EndDate"
        case isNew = "IsNew" // Added
        case isRepeat = "IsRepeat" // Added
    }
}

// MARK: - Watch App State
@MainActor
final class WatchAppState: NSObject, ObservableObject { // Added NSObject base class
    // Auth/session
    @Published var serverURL: String = ""
    @Published var accessToken: String = ""
    @Published var apiKey: String = ""
    @Published var userId: String = ""

    // Channel list
    @Published var channels: [WatchChannel] = []
    @Published var isLoadingChannels: Bool = false
    @Published var lastChannelLoad: Date? = nil

    // Misc
    @Published var lastError: String? = nil

    var isAuthenticated: Bool { !serverURL.isEmpty && !accessToken.isEmpty }

    // Persistence keys
    private let defaults = UserDefaults.standard
    private let kServer = "watch_serverURL"
    private let kToken = "watch_accessToken"
    private let kApiKey = "watch_apiKey"
    private let kUserId = "watch_userId"

    // MARK: - Public API used by views
    func restoreCredentials() {
        if let s = defaults.string(forKey: kServer) { serverURL = s }
        if let t = defaults.string(forKey: kToken) { accessToken = t }
        if let a = defaults.string(forKey: kApiKey) { apiKey = a }
        if let u = defaults.string(forKey: kUserId) { userId = u }
    }

    func loadChannelsIfNeeded(force: Bool) async {
        if !isAuthenticated { return }
        if !force, let last = lastChannelLoad, Date().timeIntervalSince(last) < 60, !channels.isEmpty { return }
        await fetchChannels(force: force)
    }

    func fetchPrograms(for channel: WatchChannel) async -> [WatchProgram] {
        guard isAuthenticated, !serverURL.isEmpty else { return [] }
        guard let base = URL(string: cleanedBase(serverURL)) else { return [] }
        // 3 hour window centred on now -> now+3h
        let now = Date()
        let end = now.addingTimeInterval(3 * 3600)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        var comps = URLComponents(url: base.appendingPathComponent("/LiveTv/Programs"), resolvingAgainstBaseURL: false)
        comps?.queryItems = [
            URLQueryItem(name: "ChannelIds", value: channel.id),
            URLQueryItem(name: "StartDate", value: iso.string(from: now)),
            URLQueryItem(name: "EndDate", value: iso.string(from: end)),
            URLQueryItem(name: "Fields", value: "Name,EpisodeTitle,Overview,OfficialRating,ChannelId,StartDate,EndDate,IsNew,IsRepeat")
        ]
        guard let url = comps?.url else { return [] }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue(accessToken, forHTTPHeaderField: "X-Emby-Token")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { return [] }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            struct ProgramsResp: Decodable { let items: [WatchProgram]?; enum CodingKeys: String, CodingKey { case items = "Items" } }
            let pr = try decoder.decode(ProgramsResp.self, from: data)
            return pr.items ?? []
        } catch {
            print("WatchAppState: fetchPrograms error: \(error)")
            return []
        }
    }

    func startConnectivity() {
#if canImport(WatchConnectivity)
        if WCSession.isSupported() { WCSession.default.delegate = self; WCSession.default.activate() }
#endif
    }

    // MARK: - Internal helpers
    private func cleanedBase(_ raw: String) -> String { raw.hasSuffix("/") ? String(raw.dropLast()) : raw }

    private func persistCredentials() {
        defaults.set(serverURL, forKey: kServer)
        defaults.set(accessToken, forKey: kToken)
        defaults.set(apiKey, forKey: kApiKey)
        defaults.set(userId, forKey: kUserId)
    }

    private func updateFromContext(_ ctx: [String: Any]) {
        // Handle explicit logout signal from iOS
        if let loggedOut = ctx["loggedOut"] as? Bool, loggedOut {
            // Only clear if we currently have any credentials
            if !(serverURL.isEmpty && accessToken.isEmpty && apiKey.isEmpty && userId.isEmpty && channels.isEmpty) {
                serverURL = ""
                accessToken = ""
                apiKey = ""
                userId = ""
                channels = []
                lastChannelLoad = nil
                lastError = nil
                persistCredentials() // persist cleared values
            }
            return
        }
        var changed = false
        if let s = ctx["serverURL"] as? String, s != serverURL { serverURL = s; changed = true }
        if let t = ctx["accessToken"] as? String, t != accessToken { accessToken = t; changed = true }
        if let a = ctx["apiKey"] as? String, a != apiKey { apiKey = a; changed = true }
        if let u = ctx["userId"] as? String, u != userId { userId = u; changed = true }
        if changed { persistCredentials(); Task { await loadChannelsIfNeeded(force: true) } }
    }

    // MARK: - Channel Networking
    private func fetchChannels(force: Bool) async {
        if isLoadingChannels { return }
        guard isAuthenticated else { return }
        guard let base = URL(string: cleanedBase(serverURL)) else { return }
        isLoadingChannels = true
        lastError = nil
        defer { isLoadingChannels = false }

        var req = URLRequest(url: base.appendingPathComponent("/LiveTv/Channels"))
        req.httpMethod = "GET"
        req.setValue(accessToken, forHTTPHeaderField: "X-Emby-Token")
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
                lastError = "Channel load failed"
                return
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            struct ChannelDTO: Decodable { let id: String; let name: String?; let number: String?; enum CodingKeys: String, CodingKey { case id = "Id"; case name = "Name"; case number = "Number" } }
            struct Resp: Decodable { let items: [ChannelDTO]?; enum CodingKeys: String, CodingKey { case items = "Items" } }
            let r = try decoder.decode(Resp.self, from: data)
            var mapped: [WatchChannel] = (r.items ?? []).map { WatchChannel(id: $0.id, name: $0.name, number: $0.number) }
            mapped.sort(by: channelSort)
            channels = mapped
            lastChannelLoad = Date()
            // Optionally fetch current program window
            Task { await enrichCurrentPrograms() }
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func channelSort(_ a: WatchChannel, _ b: WatchChannel) -> Bool {
        let na = a.number ?? ""
        let nb = b.number ?? ""
        if na.isEmpty != nb.isEmpty { return !na.isEmpty }
        if na != nb { return na.localizedStandardCompare(nb) == .orderedAscending }
        return (a.name ?? "") < (b.name ?? "")
    }

    private func enrichCurrentPrograms() async {
        guard isAuthenticated, !channels.isEmpty else { return }
        // Fetch currently airing programs within next hour
        guard let base = URL(string: cleanedBase(serverURL)) else { return }
        let now = Date()
        let later = now.addingTimeInterval(3600)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        var comps = URLComponents(url: base.appendingPathComponent("/LiveTv/Programs"), resolvingAgainstBaseURL: false)
        comps?.queryItems = [
            URLQueryItem(name: "StartDate", value: iso.string(from: now)),
            URLQueryItem(name: "EndDate", value: iso.string(from: later)),
            URLQueryItem(name: "IsAiring", value: "true"),
            URLQueryItem(name: "Fields", value: "Name,EpisodeTitle,Overview,OfficialRating,ChannelId,StartDate,EndDate,IsNew")
        ]
        guard let url = comps?.url else { return }
        var req = URLRequest(url: url)
        req.setValue(accessToken, forHTTPHeaderField: "X-Emby-Token")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { return }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            struct ProgResp: Decodable { let items: [WatchProgram]?; enum CodingKeys: String, CodingKey { case items = "Items" } }
            let pr = try decoder.decode(ProgResp.self, from: data)
            let airing = pr.items ?? []
            var updated = channels
            for i in updated.indices {
                if let match = airing.first(where: { $0.channelId == updated[i].id }) {
                    updated[i].currentProgram = match
                }
            }
            channels = updated
        } catch { /* ignore */ }
    }
}

#if canImport(WatchConnectivity)
extension WatchAppState: WCSessionDelegate {
    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) { }
    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String : Any]) {
        Task { @MainActor in self.updateFromContext(applicationContext) }
    }
#if os(watchOS)
    func sessionReachabilityDidChange(_ session: WCSession) { }
#endif
}
#endif
