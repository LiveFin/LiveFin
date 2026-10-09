//
//  LiveFin_watchOS.swift
//  LiveFin
//
//  Created by KPGamingz on 7/18/26.
//

import SwiftUI
import Combine
import Foundation
import WatchKit
#if canImport(WatchConnectivity)
import WatchConnectivity
#endif

// MARK: - App Entry Point
@main
struct LiveFin_watchOS_Watch_AppApp: App {
    @StateObject private var appState = WatchAppState()

    var body: some Scene {
        WindowGroup {
            WatchRootView()
                .environmentObject(appState)
                .onAppear {
                    appState.restoreCredentials()
                }
        }
    }
}

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
    var isNew: Bool?
    var isRepeat: Bool?
    var timerId: String?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case altId = "id"
        case name = "Name"
        case altName = "name"
        case episodeTitle = "EpisodeTitle"
        case altEpisodeTitle = "episodeTitle"
        case overview = "Overview"
        case altOverview = "overview"
        case officialRating = "OfficialRating"
        case altOfficialRating = "officialRating"
        case channelId = "ChannelId"
        case altChannelId = "channelId"
        case startDate = "StartDate"
        case altStartDate = "startDate"
        case endDate = "EndDate"
        case altEndDate = "endDate"
        case isNew = "IsNew"
        case altIsNew = "isNew"
        case isRepeat = "IsRepeat"
        case altIsRepeat = "isRepeat"
        case timerId = "TimerId"
        case altTimerId = "timerId"
    }

    init(id: String, name: String? = nil, episodeTitle: String? = nil, overview: String? = nil, officialRating: String? = nil, channelId: String? = nil, startDate: Date? = nil, endDate: Date? = nil, isNew: Bool? = nil, isRepeat: Bool? = nil, timerId: String? = nil) {
        self.id = id
        self.name = name
        self.episodeTitle = episodeTitle
        self.overview = overview
        self.officialRating = officialRating
        self.channelId = channelId
        self.startDate = startDate
        self.endDate = endDate
        self.isNew = isNew
        self.isRepeat = isRepeat
        self.timerId = timerId
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let val = try? container.decode(String.self, forKey: .id) {
            id = val
        } else if let val = try? container.decode(String.self, forKey: .altId) {
            id = val
        } else {
            id = UUID().uuidString
        }

        name = (try? container.decodeIfPresent(String.self, forKey: .name)) ?? (try? container.decodeIfPresent(String.self, forKey: .altName))
        episodeTitle = (try? container.decodeIfPresent(String.self, forKey: .episodeTitle)) ?? (try? container.decodeIfPresent(String.self, forKey: .altEpisodeTitle))
        overview = (try? container.decodeIfPresent(String.self, forKey: .overview)) ?? (try? container.decodeIfPresent(String.self, forKey: .altOverview))
        officialRating = (try? container.decodeIfPresent(String.self, forKey: .officialRating)) ?? (try? container.decodeIfPresent(String.self, forKey: .altOfficialRating))
        channelId = (try? container.decodeIfPresent(String.self, forKey: .channelId)) ?? (try? container.decodeIfPresent(String.self, forKey: .altChannelId))
        isNew = (try? container.decodeIfPresent(Bool.self, forKey: .isNew)) ?? (try? container.decodeIfPresent(Bool.self, forKey: .altIsNew))
        isRepeat = (try? container.decodeIfPresent(Bool.self, forKey: .isRepeat)) ?? (try? container.decodeIfPresent(Bool.self, forKey: .altIsRepeat))
        timerId = (try? container.decodeIfPresent(String.self, forKey: .timerId)) ?? (try? container.decodeIfPresent(String.self, forKey: .altTimerId))

        let startRaw = (try? container.decodeIfPresent(String.self, forKey: .startDate)) ?? (try? container.decodeIfPresent(String.self, forKey: .altStartDate))
        if let s = startRaw {
            startDate = WatchAppState.parseFlexibleDate(s)
        } else {
            startDate = (try? container.decodeIfPresent(Date.self, forKey: .startDate)) ?? (try? container.decodeIfPresent(Date.self, forKey: .altStartDate))
        }

        let endRaw = (try? container.decodeIfPresent(String.self, forKey: .endDate)) ?? (try? container.decodeIfPresent(String.self, forKey: .altEndDate))
        if let e = endRaw {
            endDate = WatchAppState.parseFlexibleDate(e)
        } else {
            endDate = (try? container.decodeIfPresent(Date.self, forKey: .endDate)) ?? (try? container.decodeIfPresent(Date.self, forKey: .altEndDate))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(name, forKey: .name)
        try container.encodeIfPresent(episodeTitle, forKey: .episodeTitle)
        try container.encodeIfPresent(overview, forKey: .overview)
        try container.encodeIfPresent(officialRating, forKey: .officialRating)
        try container.encodeIfPresent(channelId, forKey: .channelId)
        try container.encodeIfPresent(startDate, forKey: .startDate)
        try container.encodeIfPresent(endDate, forKey: .endDate)
        try container.encodeIfPresent(isNew, forKey: .isNew)
        try container.encodeIfPresent(isRepeat, forKey: .isRepeat)
        try container.encodeIfPresent(timerId, forKey: .timerId)
    }
}

struct WatchTimer: Identifiable, Codable, Hashable {
    let id: String
    let programId: String?
    let name: String?
    let startDate: String?
    let status: String?

    var Id: String { id }
    var Name: String? { name }
    var ProgramId: String? { programId }
    var StartDate: String? { startDate }
    var Status: String? { status }

    var parsedStartDate: Date? {
        guard let s = startDate else { return nil }
        return WatchAppState.parseFlexibleDate(s)
    }

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case altId = "id"
        case programId = "ProgramId"
        case altProgramId = "programId"
        case name = "Name"
        case altName = "name"
        case startDate = "StartDate"
        case altStartDate = "startDate"
        case status = "Status"
        case altStatus = "status"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let val = try? c.decode(String.self, forKey: .id) {
            id = val
        } else if let val = try? c.decode(String.self, forKey: .altId) {
            id = val
        } else {
            id = UUID().uuidString
        }
        programId = (try? c.decodeIfPresent(String.self, forKey: .programId)) ?? (try? c.decodeIfPresent(String.self, forKey: .altProgramId))
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? (try? c.decodeIfPresent(String.self, forKey: .altName))
        startDate = (try? c.decodeIfPresent(String.self, forKey: .startDate)) ?? (try? c.decodeIfPresent(String.self, forKey: .altStartDate))
        status = (try? c.decodeIfPresent(String.self, forKey: .status)) ?? (try? c.decodeIfPresent(String.self, forKey: .altStatus))
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(programId, forKey: .programId)
        try c.encodeIfPresent(name, forKey: .name)
        try c.encodeIfPresent(startDate, forKey: .startDate)
        try c.encodeIfPresent(status, forKey: .status)
    }
}

enum WatchTab {
    case channels
    case dvr
}

// MARK: - State & Networking
@MainActor
final class WatchAppState: NSObject, ObservableObject {
    // Auth/session
    @Published var serverURL: String = ""
    @Published var accessToken: String = ""
    @Published var apiKey: String = ""
    @Published var userId: String = ""

    // Content
    @Published var channels: [WatchChannel] = []
    @Published var scheduledTimers: [WatchTimer] = []

    @Published var isLoadingChannels: Bool = false
    @Published var isLoadingDVR: Bool = false
    @Published var lastChannelLoad: Date? = nil
    @Published var lastError: String? = nil

    var isAuthenticated: Bool { !serverURL.isEmpty && (!accessToken.isEmpty || !apiKey.isEmpty) }
    var effectiveToken: String { !accessToken.isEmpty ? accessToken : apiKey }

    private let defaults = UserDefaults.standard
    private let kServer = "watch_serverURL"
    private let kToken = "watch_accessToken"
    private let kApiKey = "watch_apiKey"
    private let kUserId = "watch_userId"

    override init() {
        super.init()
        restoreCredentials()
        startConnectivity()
        if isAuthenticated {
            Task {
                await loadChannelsIfNeeded(force: false)
                await fetchDVR()
            }
        }
    }

    func restoreCredentials() {
        if let s = defaults.string(forKey: kServer), !s.isEmpty { serverURL = s }
        if let t = defaults.string(forKey: kToken), !t.isEmpty { accessToken = t }
        if let a = defaults.string(forKey: kApiKey), !a.isEmpty { apiKey = a }
        if let u = defaults.string(forKey: kUserId), !u.isEmpty { userId = u }

#if canImport(WatchConnectivity)
        if WCSession.isSupported() {
            let session = WCSession.default
            let ctx = session.receivedApplicationContext
            if !ctx.isEmpty {
                updateFromContext(ctx)
            }
        }
#endif
        if isAuthenticated && channels.isEmpty {
            Task {
                await loadChannelsIfNeeded(force: false)
                await fetchDVR()
            }
        }
    }

    private func persistCredentials() {
        defaults.set(serverURL, forKey: kServer)
        defaults.set(accessToken, forKey: kToken)
        defaults.set(apiKey, forKey: kApiKey)
        defaults.set(userId, forKey: kUserId)
    }

    private func cleanedBase(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s = String(s.dropLast()) }
        if !s.lowercased().hasPrefix("http://") && !s.lowercased().hasPrefix("https://") {
            s = "http://" + s
        }
        return s
    }

    private func buildURL(path: String, queryItems: [URLQueryItem]? = nil) -> URL? {
        let base = cleanedBase(serverURL)
        guard !base.isEmpty else { return nil }
        let normalizedPath = path.hasPrefix("/") ? path : "/\(path)"
        guard var comps = URLComponents(string: base + normalizedPath) else { return nil }
        if let queryItems = queryItems, !queryItems.isEmpty {
            comps.queryItems = queryItems
        }
        return comps.url
    }

    private func setAuthHeaders(on request: inout URLRequest) {
        let deviceName = WKInterfaceDevice.current().name
        let deviceId = WKInterfaceDevice.current().identifierForVendor?.uuidString ?? "livefin-watch"
        let token = effectiveToken

        var parts: [String] = []
        if !token.isEmpty {
            parts.append("Token=\"\(token)\"")
        }
        parts.append("Client=\"LiveFin\"")
        parts.append("Device=\"\(deviceName)\"")
        parts.append("DeviceId=\"\(deviceId)\"")
        parts.append("Version=\"1.0\"")

        let headerValue = "MediaBrowser \(parts.joined(separator: ", "))"
        request.setValue(headerValue, forHTTPHeaderField: "Authorization")
        if !token.isEmpty {
            request.setValue(token, forHTTPHeaderField: "X-Emby-Token")
            request.setValue(headerValue, forHTTPHeaderField: "X-Emby-Authorization")
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
    }

    // MARK: - Date Parser (Jellyfin v12 7-digit fractional seconds support)
    static func parseFlexibleDate(_ string: String) -> Date? {
        let fWithFraction = ISO8601DateFormatter()
        fWithFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = fWithFraction.date(from: string) { return d }

        let fPlain = ISO8601DateFormatter()
        fPlain.formatOptions = [.withInternetDateTime]
        if let d = fPlain.date(from: string) { return d }

        if let dotIndex = string.firstIndex(of: ".") {
            let base = String(string[..<dotIndex])
            let rest = String(string[dotIndex...])
            let digits = rest.dropFirst().prefix(while: { $0.isNumber })
            let tz = rest.dropFirst(digits.count + 1)
            let normalizedDigits = digits.prefix(3).padding(toLength: 3, withPad: "0", startingAt: 0)
            let normalized = "\(base).\(normalizedDigits)\(tz)"
            if let d = fWithFraction.date(from: normalized) { return d }
        }

        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(secondsFromGMT: 0)
        for fmt in ["yyyy-MM-dd'T'HH:mm:ssZZZZZ", "yyyy-MM-dd'T'HH:mm:ss.SSSZZZZZ", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ssZ"] {
            df.dateFormat = fmt
            if let d = df.date(from: string) { return d }
        }
        return nil
    }

    var jellyfinDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let dateString = try container.decode(String.self)
            if let date = WatchAppState.parseFlexibleDate(dateString) {
                return date
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Cannot decode date: \(dateString)")
        }
        return decoder
    }

    // MARK: - Channels API
    func loadChannelsIfNeeded(force: Bool) async {
        if !isAuthenticated { return }
        if !force, let last = lastChannelLoad, Date().timeIntervalSince(last) < 60, !channels.isEmpty { return }
        await fetchChannels()
    }

    func fetchChannels() async {
        if isLoadingChannels { return }
        guard isAuthenticated else { return }

        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "EnableUserData", value: "true"),
            URLQueryItem(name: "addCurrentProgram", value: "true"),
            URLQueryItem(name: "EnableImages", value: "false")
        ]
        if !userId.isEmpty {
            queryItems.append(URLQueryItem(name: "userId", value: userId))
        }

        guard let url = buildURL(path: "/LiveTv/Channels", queryItems: queryItems) else {
            lastError = "Invalid server URL"
            return
        }

        isLoadingChannels = true
        lastError = nil
        defer { isLoadingChannels = false }

        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        setAuthHeaders(on: &req)

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let httpResp = resp as? HTTPURLResponse, (200...299).contains(httpResp.statusCode) else {
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                lastError = "Failed to load (HTTP \(code))"
                return
            }

            struct ChannelDTO: Decodable {
                let id: String
                let name: String?
                let number: String?
                let channelNumber: String?
                let currentProgram: WatchProgram?

                enum CodingKeys: String, CodingKey {
                    case id = "Id"
                    case altId = "id"
                    case name = "Name"
                    case altName = "name"
                    case number = "Number"
                    case altNumber = "number"
                    case channelNumber = "ChannelNumber"
                    case altChannelNumber = "channelNumber"
                    case currentProgram = "CurrentProgram"
                    case altCurrentProgram = "currentProgram"
                }

                init(from decoder: Decoder) throws {
                    let container = try decoder.container(keyedBy: CodingKeys.self)
                    if let val = try? container.decode(String.self, forKey: .id) {
                        id = val
                    } else if let val = try? container.decode(String.self, forKey: .altId) {
                        id = val
                    } else {
                        id = UUID().uuidString
                    }

                    name = (try? container.decodeIfPresent(String.self, forKey: .name)) ?? (try? container.decodeIfPresent(String.self, forKey: .altName))
                    number = (try? container.decodeIfPresent(String.self, forKey: .number)) ?? (try? container.decodeIfPresent(String.self, forKey: .altNumber))
                    channelNumber = (try? container.decodeIfPresent(String.self, forKey: .channelNumber)) ?? (try? container.decodeIfPresent(String.self, forKey: .altChannelNumber))
                    currentProgram = (try? container.decodeIfPresent(WatchProgram.self, forKey: .currentProgram)) ?? (try? container.decodeIfPresent(WatchProgram.self, forKey: .altCurrentProgram))
                }

                init(id: String, name: String? = nil, number: String? = nil, channelNumber: String? = nil, currentProgram: WatchProgram? = nil) {
                    self.id = id
                    self.name = name
                    self.number = number
                    self.channelNumber = channelNumber
                    self.currentProgram = currentProgram
                }

                var resolvedNumber: String? { number ?? channelNumber }
            }

            struct Resp: Decodable {
                let items: [ChannelDTO]?
                enum CodingKeys: String, CodingKey { case items = "Items" }
            }

            let loadedDTOs: [ChannelDTO]
            if let r = try? jellyfinDecoder.decode(Resp.self, from: data), let items = r.items {
                loadedDTOs = items
            } else if let arr = try? jellyfinDecoder.decode([ChannelDTO].self, from: data) {
                loadedDTOs = arr
            } else if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let rawItems = obj["Items"] as? [[String: Any]] {
                loadedDTOs = rawItems.compactMap { (d: [String: Any]) -> ChannelDTO? in
                    if let rawData = try? JSONSerialization.data(withJSONObject: d),
                       let parsed = try? self.jellyfinDecoder.decode(ChannelDTO.self, from: rawData) {
                        return parsed
                    }
                    guard let id = (d["Id"] as? String) ?? (d["id"] as? String) else { return nil }
                    let name = (d["Name"] as? String) ?? (d["name"] as? String)
                    let num = (d["Number"] as? String) ?? (d["number"] as? String)
                    let chNum = (d["ChannelNumber"] as? String) ?? (d["channelNumber"] as? String)
                    return ChannelDTO(id: id, name: name, number: num, channelNumber: chNum, currentProgram: nil)
                }
            } else {
                lastError = "Unable to parse channel list"
                return
            }

            var mapped: [WatchChannel] = loadedDTOs.map {
                WatchChannel(id: $0.id, name: $0.name, number: $0.resolvedNumber, currentProgram: $0.currentProgram)
            }
            mapped.sort { a, b in
                let na = a.number ?? ""; let nb = b.number ?? ""
                if na.isEmpty != nb.isEmpty { return !na.isEmpty }
                if na != nb { return na.localizedStandardCompare(nb) == .orderedAscending }
                return (a.name ?? "") < (b.name ?? "")
            }
            channels = mapped
            lastChannelLoad = Date()
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Programs API
    func fetchPrograms(for channel: WatchChannel) async -> [WatchProgram] {
        guard isAuthenticated else { return [] }
        let now = Date()
        let end = now.addingTimeInterval(6 * 3600) // Next 6 hours
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let nowStr = iso.string(from: now)
        let endStr = iso.string(from: end)

        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "channelIds", value: channel.id),
            URLQueryItem(name: "channelId", value: channel.id),
            URLQueryItem(name: "minEndDate", value: nowStr),
            URLQueryItem(name: "maxStartDate", value: endStr),
            URLQueryItem(name: "startDate", value: nowStr),
            URLQueryItem(name: "endDate", value: endStr),
            URLQueryItem(name: "sortBy", value: "StartDate"),
            URLQueryItem(name: "sortOrder", value: "Ascending"),
            URLQueryItem(name: "EnableImages", value: "false"),
            URLQueryItem(name: "fields", value: "Name,EpisodeTitle,Overview,OfficialRating,ChannelId,StartDate,EndDate,IsNew,IsRepeat,TimerId")
        ]
        if !userId.isEmpty {
            queryItems.append(URLQueryItem(name: "userId", value: userId))
        }

        guard let url = buildURL(path: "/LiveTv/Programs", queryItems: queryItems) else { return [] }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        setAuthHeaders(on: &req)

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let httpResp = resp as? HTTPURLResponse, (200...299).contains(httpResp.statusCode) else { return [] }

            struct ProgramsResp: Decodable {
                let items: [WatchProgram]?
                enum CodingKeys: String, CodingKey { case items = "Items" }
            }
            if let r = try? jellyfinDecoder.decode(ProgramsResp.self, from: data), let items = r.items {
                return items
            } else if let arr = try? jellyfinDecoder.decode([WatchProgram].self, from: data) {
                return arr
            }
            return []
        } catch {
            return []
        }
    }

    // MARK: - DVR API
    func fetchDVR() async {
        if isLoadingDVR { return }
        guard isAuthenticated, let url = buildURL(path: "/LiveTv/Timers") else { return }
        isLoadingDVR = true
        defer { isLoadingDVR = false }

        var timerReq = URLRequest(url: url)
        timerReq.httpMethod = "GET"
        setAuthHeaders(on: &timerReq)

        do {
            let (timersData, resp) = try await URLSession.shared.data(for: timerReq)
            guard let httpResp = resp as? HTTPURLResponse, (200...299).contains(httpResp.statusCode) else { return }

            struct TimersResp: Decodable {
                let items: [WatchTimer]?
                enum CodingKeys: String, CodingKey { case items = "Items" }
            }

            let timers: [WatchTimer]
            if let tResp = try? jellyfinDecoder.decode(TimersResp.self, from: timersData), let items = tResp.items {
                timers = items
            } else if let arr = try? jellyfinDecoder.decode([WatchTimer].self, from: timersData) {
                timers = arr
            } else {
                timers = []
            }
            self.scheduledTimers = timers.sorted { ($0.parsedStartDate ?? .distantFuture) < ($1.parsedStartDate ?? .distantFuture) }
        } catch {
            print("DVR fetch failed: \(error)")
        }
    }

    func scheduleRecording(for program: WatchProgram) async -> Bool {
        guard isAuthenticated else { return false }

        guard let defUrl = buildURL(path: "/LiveTv/Timers/Defaults", queryItems: [URLQueryItem(name: "programId", value: program.id)]) else { return false }

        var defReq = URLRequest(url: defUrl)
        defReq.httpMethod = "GET"
        setAuthHeaders(on: &defReq)

        do {
            let (defData, defResp) = try await URLSession.shared.data(for: defReq)
            guard let httpDef = defResp as? HTTPURLResponse, (200...299).contains(httpDef.statusCode),
                  var payload = try JSONSerialization.jsonObject(with: defData) as? [String: Any] else { return false }

            guard let postUrl = buildURL(path: "/LiveTv/Timers") else { return false }
            var postReq = URLRequest(url: postUrl)
            postReq.httpMethod = "POST"
            setAuthHeaders(on: &postReq)
            postReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
            postReq.httpBody = try JSONSerialization.data(withJSONObject: payload)

            let (_, postResp) = try await URLSession.shared.data(for: postReq)
            let success = (postResp as? HTTPURLResponse)?.statusCode ?? 500 < 300
            if success { await fetchDVR() }
            return success
        } catch {
            return false
        }
    }

    func cancelTimer(id: String) async -> Bool {
        guard isAuthenticated, let url = buildURL(path: "/LiveTv/Timers/\(id)") else { return false }
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        setAuthHeaders(on: &req)

        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            let success = (resp as? HTTPURLResponse)?.statusCode ?? 500 < 300
            if success {
                self.scheduledTimers.removeAll { $0.Id == id }
            }
            return success
        } catch {
            return false
        }
    }

    // MARK: - Connectivity Sync
    func startConnectivity() {
#if canImport(WatchConnectivity)
        if WCSession.isSupported() {
            let session = WCSession.default
            session.delegate = self
            session.activate()
        }
#endif
    }

    func requestCredentialsFromPhone() {
#if canImport(WatchConnectivity)
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        if session.activationState == .activated && session.isReachable {
            session.sendMessage(["request": "credentials"]) { [weak self] reply in
                Task { @MainActor in
                    self?.updateFromContext(reply)
                }
            } errorHandler: { error in
                print("WatchAppState: requestCredentialsFromPhone error: \(error)")
            }
        }
#endif
    }

    func updateFromContext(_ ctx: [String: Any]) {
        if let loggedOut = ctx["loggedOut"] as? Bool, loggedOut {
            serverURL = ""; accessToken = ""; apiKey = ""; userId = ""; channels = []; scheduledTimers = []
            persistCredentials()
            return
        }
        var changed = false
        if let s = ctx["serverURL"] as? String, s != serverURL { serverURL = s; changed = true }
        if let t = ctx["accessToken"] as? String, t != accessToken { accessToken = t; changed = true }
        if let a = ctx["apiKey"] as? String, a != apiKey { apiKey = a; changed = true }
        if let u = ctx["userId"] as? String, u != userId { userId = u; changed = true }
        if changed || channels.isEmpty {
            persistCredentials()
            Task {
                await loadChannelsIfNeeded(force: true)
                await fetchDVR()
            }
        }
    }
}

// MARK: - WCSessionDelegate
#if canImport(WatchConnectivity)
extension WatchAppState: WCSessionDelegate {
    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        if activationState == .activated {
            let ctx = session.receivedApplicationContext
            if !ctx.isEmpty {
                Task { @MainActor in
                    self.updateFromContext(ctx)
                }
            }
            self.requestCredentialsFromPhone()
        }
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String : Any]) {
        Task { @MainActor in self.updateFromContext(applicationContext) }
    }

    func session(_ session: WCSession, didReceiveMessage message: [String : Any]) {
        Task { @MainActor in self.updateFromContext(message) }
    }

#if os(watchOS)
    func sessionReachabilityDidChange(_ session: WCSession) {
        if session.isReachable {
            requestCredentialsFromPhone()
        }
    }
#endif
}
#endif

// MARK: - Views
struct WatchRootView: View {
    @EnvironmentObject var appState: WatchAppState
    @State private var selectedTab: WatchTab = .channels

    var body: some View {
        if !appState.isAuthenticated {
            WatchLoginView()
        } else {
            TabView(selection: $selectedTab) {
                NavigationStack {
                    WatchChannelsView()
                }
                .tag(WatchTab.channels)

                NavigationStack {
                    WatchRecordingsView()
                }
                .tag(WatchTab.dvr)
            }
            .tabViewStyle(.verticalPage)
            .task {
                await appState.loadChannelsIfNeeded(force: false)
                await appState.fetchDVR()
            }
        }
    }
}

struct WatchLoginView: View {
    @EnvironmentObject var appState: WatchAppState

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                Image(systemName: "lock.circle")
                    .font(.system(size: 42))
                    .foregroundColor(.accentColor)
                Text("Login on iPhone")
                    .font(.headline)
                Text("Open LiveFin on your iPhone to connect automatically.")
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                Button("Retry") {
                    appState.restoreCredentials()
                    appState.requestCredentialsFromPhone()
                    Task { await appState.loadChannelsIfNeeded(force: true) }
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
            .frame(maxWidth: .infinity)
        }
        .onAppear {
            appState.restoreCredentials()
            appState.requestCredentialsFromPhone()
        }
    }
}

struct WatchChannelsView: View {
    @EnvironmentObject var appState: WatchAppState

    var body: some View {
        List {
            if appState.isLoadingChannels && appState.channels.isEmpty {
                HStack {
                    Spacer()
                    ProgressView("Loading channels…")
                    Spacer()
                }
                .padding()
            } else if appState.channels.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "tv.slash")
                        .font(.title3)
                        .foregroundColor(.secondary)
                    Text(appState.lastError ?? "No channels found")
                        .font(.caption2)
                        .multilineTextAlignment(.center)
                        .foregroundColor(.secondary)
                    Button("Retry") {
                        Task { await appState.loadChannelsIfNeeded(force: true) }
                    }
                    .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            } else {
                ForEach(appState.channels) { ch in
                    NavigationLink(value: ch) {
                        WatchChannelRow(channel: ch)
                    }
                }
            }
        }
        .navigationTitle("Channels")
        .navigationDestination(for: WatchChannel.self) { ch in
            WatchChannelDetailView(channel: ch)
        }
        .refreshable { await appState.loadChannelsIfNeeded(force: true) }
    }
}

struct WatchChannelRow: View {
    let channel: WatchChannel

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                if let num = channel.number, !num.isEmpty {
                    Text(num)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundColor(.accentColor)
                }
                Text(channel.name ?? "Channel")
                    .font(.body)
                    .lineLimit(1)
            }
            if let prog = channel.currentProgram {
                Text(prog.name ?? "")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }
}

struct WatchChannelDetailView: View {
    let channel: WatchChannel
    @EnvironmentObject var appState: WatchAppState
    @State private var programs: [WatchProgram] = []
    @State private var isLoading = false
    @State private var recordingProgramId: String? = nil

    var body: some View {
        List {
            Section(header: Text(channel.name ?? "Channel")) {
                if isLoading && programs.isEmpty {
                    ProgressView("Loading guide…")
                } else if programs.isEmpty {
                    Text("No upcoming programs.")
                        .foregroundColor(.secondary)
                        .font(.caption)
                } else {
                    ForEach(programs) { prog in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(prog.name ?? "Unknown")
                                .font(.headline)
                            if let ep = prog.episodeTitle, !ep.isEmpty {
                                Text(ep).font(.caption2).foregroundColor(.secondary)
                            }
                            if let s = prog.startDate, let e = prog.endDate {
                                Text("\(s, style: .time) - \(e, style: .time)")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            HStack {
                                if prog.isNew == true {
                                    Text("NEW")
                                        .font(.system(size: 9, weight: .bold))
                                        .padding(.horizontal, 4)
                                        .padding(.vertical, 1)
                                        .background(Color.blue)
                                        .foregroundColor(.white)
                                        .cornerRadius(3)
                                }
                                if prog.isRepeat == true {
                                    Text("RPT")
                                        .font(.system(size: 9, weight: .bold))
                                        .padding(.horizontal, 4)
                                        .padding(.vertical, 1)
                                        .background(Color.secondary.opacity(0.3))
                                        .cornerRadius(3)
                                }
                                Spacer()
                                Button {
                                    Task {
                                        recordingProgramId = prog.id
                                        _ = await appState.scheduleRecording(for: prog)
                                        recordingProgramId = nil
                                    }
                                } label: {
                                    if recordingProgramId == prog.id {
                                        ProgressView().scaleEffect(0.6)
                                    } else {
                                        Image(systemName: "record.circle")
                                            .foregroundColor(.red)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
        .navigationTitle(channel.number ?? channel.name ?? "Guide")
        .task { await load() }
        .refreshable { await load(force: true) }
    }

    private func load(force: Bool = false) async {
        if isLoading { return }
        isLoading = true
        defer { isLoading = false }

        let fetched = await appState.fetchPrograms(for: channel)
        let nowRef = Date()
        let filtered = fetched.filter { prog in
            if let end = prog.endDate { return end >= nowRef }
            return true
        }
        let sorted = filtered.sorted { a, b in
            return (a.startDate ?? .distantFuture) < (b.startDate ?? .distantFuture)
        }
        programs = sorted
    }
}

struct WatchRecordingsView: View {
    @EnvironmentObject var appState: WatchAppState

    var body: some View {
        List {
            if appState.isLoadingDVR && appState.scheduledTimers.isEmpty {
                ProgressView("Loading DVR…")
            } else if appState.scheduledTimers.isEmpty {
                Text("No upcoming recordings.")
                    .foregroundColor(.secondary)
                    .font(.caption)
            } else {
                Section(header: Text("Upcoming").foregroundColor(.red)) {
                    ForEach(appState.scheduledTimers) { timer in
                        VStack(alignment: .leading) {
                            Text(timer.Name ?? "Unknown")
                                .font(.headline)
                            if let start = timer.parsedStartDate {
                                Text(start, style: .date)
                                    .font(.caption2).foregroundColor(.secondary)
                                Text(start, style: .time)
                                    .font(.caption2).foregroundColor(.secondary)
                            }
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                Task { await appState.cancelTimer(id: timer.Id) }
                            } label: {
                                Label("Cancel", systemImage: "trash")
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("DVR")
        .refreshable { await appState.fetchDVR() }
    }
}
