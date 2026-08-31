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
        case name = "Name"
        case episodeTitle = "EpisodeTitle"
        case overview = "Overview"
        case officialRating = "OfficialRating"
        case channelId = "ChannelId"
        case startDate = "StartDate"
        case endDate = "EndDate"
        case isNew = "IsNew"
        case isRepeat = "IsRepeat"
        case timerId = "TimerId"
    }
}

struct WatchTimer: Identifiable, Codable, Hashable {
    let Id: String
    let ProgramId: String?
    let Name: String?
    let StartDate: String?
    let Status: String?
    
    var id: String { Id }
    
    var parsedStartDate: Date? {
        guard let s = StartDate else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: s) { return d }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return iso.date(from: s)
    }
}

// MARK: - Watch App State
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

    var isAuthenticated: Bool { !serverURL.isEmpty && !accessToken.isEmpty }

    private let defaults = UserDefaults.standard
    private let kServer = "watch_serverURL"
    private let kToken = "watch_accessToken"
    private let kApiKey = "watch_apiKey"
    private let kUserId = "watch_userId"

    override init() {
        super.init()
        startConnectivity()
    }

    func restoreCredentials() {
        if let s = defaults.string(forKey: kServer) { serverURL = s }
        if let t = defaults.string(forKey: kToken) { accessToken = t }
        if let a = defaults.string(forKey: kApiKey) { apiKey = a }
        if let u = defaults.string(forKey: kUserId) { userId = u }
    }

    private func persistCredentials() {
        defaults.set(serverURL, forKey: kServer)
        defaults.set(accessToken, forKey: kToken)
        defaults.set(apiKey, forKey: kApiKey)
        defaults.set(userId, forKey: kUserId)
    }
    
    private func cleanedBase(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasSuffix("/") { s = String(s.dropLast()) }
        if !s.lowercased().hasPrefix("http") { s = "http://" + s }
        return s
    }

    private func setAuthHeader(on request: inout URLRequest) {
        let deviceName = WKInterfaceDevice.current().name
        let deviceId = WKInterfaceDevice.current().identifierForVendor?.uuidString ?? "livefin-watch"
        let headerValue = "MediaBrowser Client=\"LiveFin Watch\", Device=\"\(deviceName)\", DeviceId=\"\(deviceId)\", Version=\"1.0\", Token=\"\(accessToken)\""
        request.setValue(headerValue, forHTTPHeaderField: "Authorization")
    }

    // MARK: - Channels API
    func loadChannelsIfNeeded(force: Bool) async {
        if !isAuthenticated { return }
        if !force, let last = lastChannelLoad, Date().timeIntervalSince(last) < 60, !channels.isEmpty { return }
        await fetchChannels()
    }

    private func fetchChannels() async {
        if isLoadingChannels { return }
        guard isAuthenticated, let base = URL(string: cleanedBase(serverURL)) else { return }
        isLoadingChannels = true
        lastError = nil
        defer { isLoadingChannels = false }
        
        var comps = URLComponents(url: base.appendingPathComponent("LiveTv/Channels"), resolvingAgainstBaseURL: false)
        comps?.queryItems = [URLQueryItem(name: "userId", value: userId)]
        guard let url = comps?.url else { return }

        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        setAuthHeader(on: &req)
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let httpResp = resp as? HTTPURLResponse, httpResp.statusCode == 200 else {
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                lastError = "Failed to load (HTTP \(code))"
                return
            }
            
            struct ChannelDTO: Decodable {
                let id: String; let name: String?; let number: String?; let channelNumber: String?
                enum CodingKeys: String, CodingKey { case id = "Id"; case name = "Name"; case number = "Number"; case channelNumber = "ChannelNumber" }
                var resolvedNumber: String? { number ?? channelNumber }
            }
            struct Resp: Decodable { let items: [ChannelDTO]?; enum CodingKeys: String, CodingKey { case items = "Items" } }
            
            let r = try jellyfinDecoder.decode(Resp.self, from: data)
            var mapped: [WatchChannel] = (r.items ?? []).map { WatchChannel(id: $0.id, name: $0.name, number: $0.resolvedNumber) }
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

    func fetchPrograms(for channel: WatchChannel) async -> [WatchProgram] {
        guard isAuthenticated, let base = URL(string: cleanedBase(serverURL)) else { return [] }
        let now = Date()
        let end = now.addingTimeInterval(4 * 3600) // Next 4 hours
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        
        var comps = URLComponents(url: base.appendingPathComponent("LiveTv/Programs"), resolvingAgainstBaseURL: false)
        comps?.queryItems = [
            URLQueryItem(name: "userId", value: userId),
            URLQueryItem(name: "ChannelIds", value: channel.id),
            URLQueryItem(name: "StartDate", value: iso.string(from: now)),
            URLQueryItem(name: "EndDate", value: iso.string(from: end)),
            URLQueryItem(name: "Fields", value: "Name,EpisodeTitle,Overview,OfficialRating,ChannelId,StartDate,EndDate,IsNew,IsRepeat,TimerId")
        ]
        guard let url = comps?.url else { return [] }
        var req = URLRequest(url: url)
        setAuthHeader(on: &req)
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            struct ProgramsResp: Decodable { let items: [WatchProgram]?; enum CodingKeys: String, CodingKey { case items = "Items" } }
            return try jellyfinDecoder.decode(ProgramsResp.self, from: data).items ?? []
        } catch {
            return []
        }
    }

    // MARK: - DVR API
    func fetchDVR() async {
        if isLoadingDVR { return }
        guard isAuthenticated, let base = URL(string: cleanedBase(serverURL)) else { return }
        isLoadingDVR = true
        defer { isLoadingDVR = false }
        
        var timerReq = URLRequest(url: base.appendingPathComponent("LiveTv/Timers"))
        setAuthHeader(on: &timerReq)
        
        do {
            let (timersData, _) = try await URLSession.shared.data(for: timerReq)
            struct TimersResp: Decodable { let Items: [WatchTimer] }
            if let tResp = try? jellyfinDecoder.decode(TimersResp.self, from: timersData) {
                self.scheduledTimers = tResp.Items.sorted { ($0.parsedStartDate ?? .distantFuture) < ($1.parsedStartDate ?? .distantFuture) }
            }
        } catch {
            print("DVR fetch failed: \(error)")
        }
    }
    
    func scheduleRecording(for program: WatchProgram) async -> Bool {
        guard isAuthenticated, let base = URL(string: cleanedBase(serverURL)) else { return false }
        
        var defComps = URLComponents(url: base.appendingPathComponent("LiveTv/Timers/Defaults"), resolvingAgainstBaseURL: false)
        defComps?.queryItems = [URLQueryItem(name: "programId", value: program.id)]
        guard let defUrl = defComps?.url else { return false }
        
        var defReq = URLRequest(url: defUrl)
        setAuthHeader(on: &defReq)
        
        do {
            let (defData, _) = try await URLSession.shared.data(for: defReq)
            guard var payload = try JSONSerialization.jsonObject(with: defData) as? [String: Any] else { return false }
            
            var postReq = URLRequest(url: base.appendingPathComponent("LiveTv/Timers"))
            postReq.httpMethod = "POST"
            setAuthHeader(on: &postReq)
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
        guard isAuthenticated, let base = URL(string: cleanedBase(serverURL)) else { return false }
        var req = URLRequest(url: base.appendingPathComponent("LiveTv/Timers/\(id)"))
        req.httpMethod = "DELETE"
        setAuthHeader(on: &req)
        
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
        if WCSession.isSupported() { WCSession.default.delegate = self; WCSession.default.activate() }
#endif
    }
    
    private func updateFromContext(_ ctx: [String: Any]) {
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
        if changed { persistCredentials(); Task { await loadChannelsIfNeeded(force: true) } }
    }

    private var jellyfinDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let dateString = try container.decode(String.self)
            
            let isoFrac = ISO8601DateFormatter()
            isoFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = isoFrac.date(from: dateString) { return date }
            
            let isoPlain = ISO8601DateFormatter()
            isoPlain.formatOptions = [.withInternetDateTime]
            if let date = isoPlain.date(from: dateString) { return date }
            
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Cannot decode date: \(dateString)")
        }
        return decoder
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

// MARK: - watchOS 10 Root Navigation (Vertical Paging & Crown Navigation)
enum WatchTab: Hashable {
    case channels
    case dvr
}

struct WatchRootView: View {
    @EnvironmentObject var appState: WatchAppState
    @State private var selectedTab: WatchTab = .channels

    var body: some View {
        if !appState.isAuthenticated {
            WatchLoginView()
        } else {
            // watchOS 10 vertical page TabView allows effortless scrolling between sections via Crown or vertical swipe
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
                Text("The watch app will pick up your session automatically.")
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                Button("Retry") {
                    appState.restoreCredentials()
                    Task { await appState.loadChannelsIfNeeded(force: true) }
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
            .frame(maxWidth: .infinity)
        }
    }
}

struct WatchChannelsView: View {
    @EnvironmentObject var appState: WatchAppState
    
    var body: some View {
        List {
            if appState.isLoadingChannels && appState.channels.isEmpty {
                ProgressView("Loading…")
            } else if appState.channels.isEmpty {
                Text("No channels").foregroundColor(.secondary)
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
        HStack(spacing: 8) {
            Text(channel.number ?? "")
                .font(.caption2)
                .foregroundColor(.secondary)
                .frame(width: 26, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(channel.name ?? "Channel")
                    .font(.body)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }
}

struct WatchChannelDetailView: View {
    let channel: WatchChannel
    @EnvironmentObject var appState: WatchAppState
    @State private var programs: [WatchProgram] = []
    @State private var isLoading = false
    @State private var processingId: String? = nil

    var body: some View {
        List {
            if isLoading && programs.isEmpty {
                ProgressView("Loading…")
            } else if programs.isEmpty {
                Text("No upcoming programs").foregroundColor(.secondary)
            } else {
                ForEach(programs) { prog in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(prog.name ?? "Program")
                                .font(.headline)
                                .lineLimit(2)
                            Spacer()
                            if prog.timerId != nil {
                                Image(systemName: "record.circle.fill")
                                    .foregroundColor(.red)
                                    .font(.caption)
                            }
                        }
                        if let ep = prog.episodeTitle { Text(ep).font(.caption).foregroundColor(.secondary) }
                        if let window = dateTimeRangeString(prog) { Text(window).font(.caption2).foregroundColor(.secondary) }
                        
                        if processingId == prog.id {
                            ProgressView().scaleEffect(0.5)
                        }
                    }
                    .padding(.vertical, 4)
                    .swipeActions(edge: .leading) {
                        if let timerId = prog.timerId {
                            Button(role: .destructive) {
                                Task { await cancel(timerId: timerId, for: prog.id) }
                            } label: {
                                Label("Cancel", systemImage: "xmark.circle")
                            }
                        } else {
                            Button {
                                Task { await record(prog: prog) }
                            } label: {
                                Label("Record", systemImage: "record.circle")
                            }
                            .tint(.red)
                        }
                    }
                }
            }
        }
        .navigationTitle(channel.name ?? "Channel")
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
    
    private func record(prog: WatchProgram) async {
        processingId = prog.id
        let success = await appState.scheduleRecording(for: prog)
        if success { await load(force: true) }
        processingId = nil
    }
    
    private func cancel(timerId: String, for progId: String) async {
        processingId = progId
        let success = await appState.cancelTimer(id: timerId)
        if success { await load(force: true) }
        processingId = nil
    }

    private func dateTimeRangeString(_ p: WatchProgram) -> String? {
        guard let s = p.startDate, let e = p.endDate else { return nil }
        let timeStyle: Date.FormatStyle = .init(date: .omitted, time: .shortened)
        return "\(timeStyle.format(s)) - \(timeStyle.format(e))"
    }
}

struct WatchRecordingsView: View {
    @EnvironmentObject var appState: WatchAppState
    
    var body: some View {
        List {
            if appState.isLoadingDVR && appState.scheduledTimers.isEmpty {
                ProgressView()
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
