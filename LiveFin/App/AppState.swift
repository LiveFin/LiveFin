import SwiftUI
import Foundation
import UIKit
#if canImport(WatchConnectivity)
import WatchConnectivity
#endif
@preconcurrency import JellyfinAPI

// MARK: - Jellyfin v12 SDK Interceptor
/// Silently catches third-party SDK requests and upgrades them to modern v12 Auth headers
class JellyfinV12Interceptor: URLProtocol {
    static var authHeader: String?
    
    override class func canInit(with request: URLRequest) -> Bool {
        if request.value(forHTTPHeaderField: "X-JF-Intercepted") == "true" { return false }
        
        // Intercept if legacy headers are present from the SDK
        if request.value(forHTTPHeaderField: "X-Emby-Token") != nil { return true }
        
        // Intercept if auth is missing entirely on API routes
        if request.value(forHTTPHeaderField: "Authorization") == nil && authHeader != nil {
            guard let urlStr = request.url?.absoluteString else { return false }
            if urlStr.contains("/Items") || urlStr.contains("/Users") || urlStr.contains("/LiveTv") || urlStr.contains("/System") || urlStr.contains("/Sessions") {
                return true
            }
        }
        return false
    }
    
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { return request }
    
    override func startLoading() {
        guard let mutableRequest = (request as NSURLRequest).mutableCopy() as? NSMutableURLRequest else { return }
        
        mutableRequest.setValue("true", forHTTPHeaderField: "X-JF-Intercepted") // Prevent infinite loops
        
        // Strip out the legacy headers the SDK is trying to send
        mutableRequest.setValue(nil, forHTTPHeaderField: "X-Emby-Token")
        mutableRequest.setValue(nil, forHTTPHeaderField: "X-Emby-Authorization")
        mutableRequest.setValue(nil, forHTTPHeaderField: "X-Emby-User-Id")
        mutableRequest.setValue(nil, forHTTPHeaderField: "X-Emby-Device-Id")
        mutableRequest.setValue(nil, forHTTPHeaderField: "X-Emby-Device-Name")
        mutableRequest.setValue(nil, forHTTPHeaderField: "X-Emby-Client")
        mutableRequest.setValue(nil, forHTTPHeaderField: "X-Emby-Client-Version")
        
        // Inject the modern v12 Authorization header
        if let header = JellyfinV12Interceptor.authHeader {
            mutableRequest.setValue(header, forHTTPHeaderField: "Authorization")
        }
        
        let task = URLSession.shared.dataTask(with: mutableRequest as URLRequest) { data, response, error in
            if let error = error {
                self.client?.urlProtocol(self, didFailWithError: error)
                return
            }
            if let response = response {
                self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .allowed)
            }
            if let data = data {
                self.client?.urlProtocol(self, didLoad: data)
            }
            self.client?.urlProtocolDidFinishLoading(self)
        }
        task.resume()
    }
    
    override func stopLoading() {}
}

final class AppState: ObservableObject {
    @Published var client: JellyfinClient?
    @Published var isLoggedIn = false
    @Published var user: UserDto?
    @Published var serverURL: String = ""
    @Published var accessToken: String = ""
    @Published var userID: String = ""
    @Published var username: String = ""
    
    @Published var deviceId: String = {
        let vendorId = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
        return vendorId
    }()
    
    @Published var apiKey: String = ""
    @Published var userPrimaryImageTag: String? = nil
    @Published var userProfileImage: UIImage? = nil

    @Published var currentPlaybackItemId: String? = nil
    @Published var isPlaying: Bool = false
    @Published var currentChannelImageUrl: String? = nil
    @Published var currentProgramTitle: String? = nil
    @Published var currentProgramSubtitle: String? = nil
    @Published var currentProgramId: String? = nil
    @Published var currentProgramPrimaryImageTag: String? = nil
    @Published var currentProgramImageType: String? = nil
    @Published var currentProgramThumbImageTag: String? = nil
    @Published var currentProgramGenres: [String]? = nil
    @Published var currentProgramIsMovie: Bool = false
    @Published var currentProgramStartDate: Date? = nil
    @Published var currentProgramEndDate: Date? = nil
    @Published var channelNames: [String: String] = [:]

    private var epgTimer: Timer?

    @Published var clientVersion: String = {
        if let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
            return v
        }
        return "1.0"
    }()
    @Published var clientDevice: String = UIDevice.current.name
    @Published var selectedURL: URL?
    @Published var serverName: String = ""
    @Published var serverVersion: String = ""
    @Published var isDemoMode: Bool = false
    @Published var loginError: String? = nil
    
    init() {
        // Register the interceptor instantly on boot to protect the SDK
        URLProtocol.registerClass(JellyfinV12Interceptor.self)
        
        // Prime the Watch connectivity instantly on boot
#if canImport(WatchConnectivity)
        _ = WatchSyncManager.shared
#endif
    }
    
    // MARK: - Modern Jellyfin Authorization Header
    func getAuthorizationHeader(includeToken: Bool = true) -> String {
        var parts = [
            "Client=\"LiveFin\"",
            "Device=\"\(clientDevice)\"",
            "DeviceId=\"\(deviceId)\"",
            "Version=\"\(clientVersion)\""
        ]
        if includeToken && !accessToken.isEmpty {
            parts.insert("Token=\"\(accessToken)\"", at: 0)
        }
        let finalHeader = "MediaBrowser \(parts.joined(separator: ", "))"
        
        // Sync the auth token to the interceptor so SDK calls can be rewritten
        if !accessToken.isEmpty {
            JellyfinV12Interceptor.authHeader = "MediaBrowser Client=\"LiveFin\", Device=\"\(clientDevice)\", DeviceId=\"\(deviceId)\", Version=\"\(clientVersion)\", Token=\"\(accessToken)\""
        }
        
        return finalHeader
    }

    private func buildURL(_ path: String) -> URL? {
        guard !serverURL.isEmpty else { return nil }
        let base = serverURL.hasSuffix("/") ? String(serverURL.dropLast()) : serverURL
        let normalizedPath = path.hasPrefix("/") ? path : "/\(path)"
        return URL(string: base + normalizedPath)
    }

    private func startOfDay(_ date: Date) -> Date { Calendar.current.startOfDay(for: date) }
    private func endOfDay(_ date: Date) -> Date { Calendar.current.date(byAdding: .day, value: 1, to: startOfDay(date)) ?? date.addingTimeInterval(24*3600) }

    @MainActor
    private func activateDemoMode() {
        self.isDemoMode = true
        self.isLoggedIn = true
        self.user = UserDto(id: "demo", name: "App Store Reviewer")
        self.userID = "demo"
        self.username = "appledemo"
        self.accessToken = ""
        self.client = nil
        self.serverURL = ""
        self.apiKey = ""
        self.loginError = nil
    }

    @MainActor
    private func activateNormalUser(userId: String, userName: String, accessToken: String, client: JellyfinClient, serverURL: String) {
        self.isDemoMode = false
        self.isLoggedIn = true
        self.user = UserDto(id: userId, name: userName)
        self.userID = userId
        self.username = userName
        self.accessToken = accessToken
        self.client = client
        self.serverURL = serverURL
        
        // FIXED: Set apiKey to the accessToken so images actually load in v12
        self.apiKey = accessToken
        self.loginError = nil
        
        let prefix = self.deviceId
        
        KeychainHelper.save(key: "\(prefix)_apiKey", value: accessToken)
        KeychainHelper.save(key: "\(prefix)_userId", value: userId)
        KeychainHelper.save(key: "\(prefix)_server", value: serverURL)
        KeychainHelper.save(key: "\(prefix)_username", value: userName)
        KeychainHelper.save(key: "\(prefix)_token", value: accessToken)
        
        KeychainHelper.delete(key: "apiKey")
        KeychainHelper.delete(key: "userId")
        KeychainHelper.delete(key: "serverURL")
        KeychainHelper.delete(key: "username")
        KeychainHelper.delete(key: "accessToken")
        KeychainHelper.delete(key: "deviceUUID")
        
        // Prime the interceptor instantly
        _ = getAuthorizationHeader(includeToken: true)
        
#if canImport(WatchConnectivity)
        WatchSyncManager.shared.sendLogin(serverURL: serverURL, accessToken: accessToken, apiKey: self.apiKey, userId: userId)
#endif
        Task { await self.refreshUserProfileInfoAndImage() }
        self.reportFullClientCapabilities()
    }

    @MainActor
    private func resetState() {
        self.isDemoMode = false
        self.isLoggedIn = false
        self.user = nil
        self.userID = ""
        self.username = ""
        self.accessToken = ""
        self.client = nil
        self.serverURL = ""
        self.apiKey = ""
        self.loginError = nil
        self.userPrimaryImageTag = nil
        self.userProfileImage = nil
        JellyfinV12Interceptor.authHeader = nil // Clear interceptor
#if canImport(WatchConnectivity)
        WatchSyncManager.shared.sendLogout()
#endif
    }

    @MainActor
    func login(server: URL, username: String, password: String) async {
        await MainActor.run { self.resetState() }
        if username == "appledemo" && password == "review" {
            activateDemoMode()
            return
        }
        do {
            let config = JellyfinClient.Configuration(
                url: server,
                client: "LiveFin",
                deviceName: clientDevice,
                deviceID: deviceId,
                version: clientVersion
            )
            let requestBody: [String: Any] = [
                "Username": username,
                "Pw": password
            ]
            let requestData = try JSONSerialization.data(withJSONObject: requestBody)
            let cleanBaseURL = server.absoluteString.hasSuffix("/") ? String(server.absoluteString.dropLast()) : server.absoluteString
            let url = URL(string: cleanBaseURL + "/Users/AuthenticateByName")!
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.httpBody = requestData
            
            request.setValue(getAuthorizationHeader(includeToken: false), forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            
            let (data, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse {
                if httpResponse.statusCode != 200 {
                    if let responseString = String(data: data, encoding: .utf8), !responseString.isEmpty {
                        self.loginError = responseString
                    } else {
                        self.loginError = "Login failed: Server returned status code \(httpResponse.statusCode)"
                    }
                    await MainActor.run { self.resetState() }
                    return
                }
            }
            struct LoginResponse: Decodable {
                let AccessToken: String
                let User: UserInfo
                struct UserInfo: Decodable {
                    let Id: String
                    let Name: String
                }
            }
            let authResponse = try JSONDecoder().decode(LoginResponse.self, from: data)
            let clientWithToken = JellyfinClient(configuration: config, accessToken: authResponse.AccessToken)
            activateNormalUser(userId: authResponse.User.Id, userName: authResponse.User.Name, accessToken: authResponse.AccessToken, client: clientWithToken, serverURL: server.absoluteString)
            await fetchServerName()
        } catch {
            self.loginError = "Invalid username or password."
            await MainActor.run { self.resetState() }
        }
    }

    @MainActor
    func completeLogin(server: URL, userId: String, userName: String, accessToken: String) async {
        let config = JellyfinClient.Configuration(
            url: server,
            client: "LiveFin",
            deviceName: clientDevice,
            deviceID: deviceId,
            version: clientVersion
        )
        let clientWithToken = JellyfinClient(configuration: config, accessToken: accessToken)
        activateNormalUser(userId: userId, userName: userName, accessToken: accessToken, client: clientWithToken, serverURL: server.absoluteString)
        await fetchServerName()
    }

    @MainActor
    func restoreLogin() {
        let prefix = self.deviceId
        
        let server = KeychainHelper.load(key: "\(prefix)_server") ?? ""
        let username = KeychainHelper.load(key: "\(prefix)_username") ?? ""
        let token = KeychainHelper.load(key: "\(prefix)_token") ?? ""
        
        guard !server.isEmpty, !token.isEmpty, !username.isEmpty else { return }
        
        let config = JellyfinClient.Configuration(
            url: URL(string: server)!,
            client: "LiveFin",
            deviceName: clientDevice,
            deviceID: deviceId,
            version: clientVersion
        )
        self.client = JellyfinClient(configuration: config, accessToken: token)
        self.serverURL = server
        self.accessToken = token
        self.username = username
        self.apiKey = token // FIXED: Map directly to the access token!
        self.isLoggedIn = true
        self.isDemoMode = false
        
        // Prime the interceptor for restored sessions
        _ = getAuthorizationHeader(includeToken: true)
        
        Task { await fetchServerName() }
        
        let isolatedUserId = KeychainHelper.load(key: "\(prefix)_userId") ?? ""
        self.userID = isolatedUserId
        
        if !isolatedUserId.isEmpty {
            self.user = UserDto(id: isolatedUserId, name: username)
        }
        
#if canImport(WatchConnectivity)
        if !server.isEmpty && !token.isEmpty {
            WatchSyncManager.shared.sendLogin(serverURL: server, accessToken: token, apiKey: self.apiKey, userId: self.userID)
        }
#endif
        Task { await self.refreshUserProfileInfoAndImage() }
        self.reportFullClientCapabilities()
    }

    @MainActor
    func fetchServerName() async {
        guard let url = buildURL("/System/Info/Public") else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
             if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                 if let name = json["ServerName"] as? String {
                     await MainActor.run { self.serverName = name }
                 }
                 if let version = json["Version"] as? String {
                     await MainActor.run { self.serverVersion = version }
                 }
             }
         } catch {
             print("Failed to fetch server name/version: \(error)")
         }
     }

    @MainActor
    func logout() {
        resetState()
        if !isDemoMode {
            let prefix = self.deviceId
            KeychainHelper.delete(key: "\(prefix)_server")
            KeychainHelper.delete(key: "\(prefix)_username")
            KeychainHelper.delete(key: "\(prefix)_token")
            KeychainHelper.delete(key: "\(prefix)_userId")
            KeychainHelper.delete(key: "\(prefix)_apiKey")
        }
    }

    @MainActor
    func reportPlaybackStart(itemId: String, canSeek: Bool = true, playMethod: String = "DirectPlay", repeatMode: String = "RepeatNone") {
        guard let url = buildURL("/Sessions/Playing"), !accessToken.isEmpty else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(getAuthorizationHeader(), forHTTPHeaderField: "Authorization")

        let body: [String: Any] = [
            "ItemId": itemId,
            "CanSeek": canSeek,
            "PlayMethod": playMethod,
            "RepeatMode": repeatMode
        ]

        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            if let error = error {
                print("Jellyfin: Error reporting playback start: \(error)")
            } else {
                DispatchQueue.main.async {
                    self?.currentPlaybackItemId = itemId
                    self?.isPlaying = true
                }
            }
        }.resume()
    }

    @MainActor
    func reportPlaybackProgress(itemId: String, positionTicks: Int64, canSeek: Bool = true, isPaused: Bool = false, playMethod: String = "DirectPlay", repeatMode: String = "RepeatNone") {
        guard let url = buildURL("/Sessions/Playing/Progress"), !accessToken.isEmpty else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(getAuthorizationHeader(), forHTTPHeaderField: "Authorization")

        let body: [String: Any] = [
            "ItemId": itemId,
            "PositionTicks": positionTicks,
            "CanSeek": canSeek,
            "IsPaused": isPaused,
            "PlayMethod": playMethod,
            "RepeatMode": repeatMode
        ]

        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: request) { _, _, error in }.resume()
    }

    @MainActor
    func reportPlaybackStopped(itemId: String, positionTicks: Int64, playSessionId: String? = nil, playMethod: String = "DirectPlay") {
        guard let url = buildURL("/Sessions/Playing/Stopped"), !accessToken.isEmpty else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(getAuthorizationHeader(), forHTTPHeaderField: "Authorization")

        var body: [String: Any] = [
            "ItemId": itemId,
            "PositionTicks": positionTicks,
            "PlayMethod": playMethod
        ]

        if let sessionId = playSessionId, !sessionId.isEmpty {
            body["PlaySessionId"] = sessionId
        }

        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: request) { [weak self] _, response, error in
            if error == nil {
                DispatchQueue.main.async {
                    if self?.currentPlaybackItemId == itemId {
                        self?.currentPlaybackItemId = nil
                        self?.isPlaying = false
                    }
                }
            }
        }.resume()
    }

    @MainActor
    func closeLiveStream(liveStreamId: String) {
        guard let url = buildURL("/LiveStreams/Close?liveStreamId=\(liveStreamId)"), !accessToken.isEmpty else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(getAuthorizationHeader(), forHTTPHeaderField: "Authorization")
        URLSession.shared.dataTask(with: request) { _, _, _ in }.resume()
    }

    @MainActor
    func startEPGPolling(for channelId: String, intervalSeconds: TimeInterval = 30) {
        stopEPGPolling()
        Task { await fetchCurrentProgram(channelId: channelId) }
        epgTimer = Timer.scheduledTimer(withTimeInterval: intervalSeconds, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            Task { await self.fetchCurrentProgram(channelId: channelId) }
        }
    }

    @MainActor
    func stopEPGPolling() {
        epgTimer?.invalidate()
        epgTimer = nil
    }

    @MainActor
    func fetchCurrentProgram(channelId: String) async {
        guard let base = buildURL("/LiveTv/Programs") else { return }
        let now = Date()
        let end = now.addingTimeInterval(3600)
        let iso = ISO8601DateFormatter()
        iso.timeZone = TimeZone(secondsFromGMT: 0)
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let startStr = iso.string(from: now)
        let endStr = iso.string(from: end)

        var comps = URLComponents(url: base, resolvingAgainstBaseURL: false)
        comps?.queryItems = [
            URLQueryItem(name: "channelIds", value: channelId),
            URLQueryItem(name: "startDate", value: startStr),
            URLQueryItem(name: "endDate", value: endStr),
            URLQueryItem(name: "EnableImages", value: "true"),
            URLQueryItem(name: "EnableUserData", value: "false"),
            URLQueryItem(name: "fields", value: "SeriesName,Overview,ImageTags,ChannelId,ProgramId,Type,IsMovie")
        ]
        if let uid = user?.id, !uid.isEmpty { comps?.queryItems?.append(URLQueryItem(name: "userId", value: uid)) }
        guard let url = comps?.url else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        if !accessToken.isEmpty {
            request.setValue(getAuthorizationHeader(), forHTTPHeaderField: "Authorization")
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return
            }
            var list: [[String: Any]] = []
            if let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let items = root["Items"] as? [[String: Any]] { list = items }
                else if let items = root["items"] as? [[String: Any]] { list = items }
            } else if let arr = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                list = arr
            }

            guard !list.isEmpty else { return }

            let parser = ISO8601DateFormatter()
            parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            var selected: [String: Any]? = nil
            var latestBeforeNow: (prog: [String: Any], start: Date)? = nil
            var earliestAfterNow: (prog: [String: Any], start: Date)? = nil
            for prog in list {
                let startS = (prog["StartDate"] as? String) ?? (prog["StartDateUtc"] as? String)
                let endS = (prog["EndDate"] as? String) ?? (prog["EndDateUtc"] as? String)
                func parse(_ s: String?) -> Date? {
                    guard let s = s else { return nil }
                    if let d = parser.date(from: s) { return d }
                    let fallback = ISO8601DateFormatter()
                    fallback.formatOptions = [.withInternetDateTime]
                    return fallback.date(from: s)
                }
                guard let startD = parse(startS), let endD = parse(endS) else { continue }
                if startD <= now && now <= endD { selected = prog; break }
                if startD <= now {
                    if let latest = latestBeforeNow {
                        if startD > latest.start { latestBeforeNow = (prog, startD) }
                    } else {
                        latestBeforeNow = (prog, startD)
                    }
                }
                if startD > now {
                    if let earliest = earliestAfterNow {
                        if startD < earliest.start { earliestAfterNow = (prog, startD) }
                    } else {
                        earliestAfterNow = (prog, startD)
                    }
                }
            }
            let program = selected ?? earliestAfterNow?.prog ?? latestBeforeNow?.prog ?? list.first!
            let startTimeString = program["StartDate"] as? String ?? program["StartDateUtc"] as? String
            let endTimeString = program["EndDate"] as? String ?? program["EndDateUtc"] as? String
            let programStartDate = (parser.date(from: startTimeString ?? "")) ?? {
                let fb = ISO8601DateFormatter(); fb.formatOptions = [.withInternetDateTime]; return fb.date(from: startTimeString ?? "")
            }()
            let programEndDate = (parser.date(from: endTimeString ?? "")) ?? {
                let fb = ISO8601DateFormatter(); fb.formatOptions = [.withInternetDateTime]; return fb.date(from: endTimeString ?? "")
            }()

            let title = program["Name"] as? String ?? program["SeriesName"] as? String
            let programId = (program["Id"] as? String)
            var primaryTag: String? = nil
            var imageType: String? = nil
            var thumbTag: String? = nil
            if let imageTags = program["ImageTags"] as? [String: Any] {
                if let t = imageTags["Primary"] as? String {
                    primaryTag = t
                    imageType = "Primary"
                }
                if let th = imageTags["Thumb"] as? String {
                    thumbTag = th
                    if primaryTag == nil {
                        primaryTag = th
                        imageType = "Thumb"
                    }
                }
            }
            let typeStr = (program["Type"] as? String) ?? (program["ProgramType"] as? String)
            let isMovie = (typeStr?.caseInsensitiveCompare("Movie") == .orderedSame) || (program["IsMovie"] as? Bool == true)

            await MainActor.run {
                self.currentProgramTitle = title
                if let series = program["SeriesName"] as? String, series != title {
                    self.currentProgramSubtitle = series
                } else {
                    let episodeTitle = (program["EpisodeTitle"] as? String) ?? (program["EpisodeName"] as? String) ?? (program["PartTitle"] as? String)
                    if let ep = episodeTitle, !ep.isEmpty {
                        self.currentProgramSubtitle = ep
                    } else {
                        self.currentProgramSubtitle = nil
                    }
                }
                var resolvedGenres: [String]? = nil
                if let gs = program["Genres"] as? [String] {
                    resolvedGenres = gs
                } else if let gsArr = program["Genres"] as? [[String: Any]] {
                    resolvedGenres = gsArr.compactMap { $0["Name"] as? String }
                } else if let tags = program["Tags"] as? [String] {
                    resolvedGenres = tags
                }
                self.currentProgramGenres = resolvedGenres
                 self.currentProgramId = programId
                 self.currentProgramPrimaryImageTag = primaryTag
                 self.currentProgramImageType = imageType
                 self.currentProgramThumbImageTag = thumbTag
                 self.currentProgramIsMovie = isMovie
                 self.currentProgramStartDate = programStartDate
                 self.currentProgramEndDate = programEndDate
             }
         } catch {
             print("EPG fetch error: \(error.localizedDescription)")
         }
     }

    func reportFullClientCapabilities() {
        guard !accessToken.isEmpty else { return }
        let normalizedIconUrl: String
        if let image = UIImage(named: "Logo"),
           let imageData = image.pngData() {
            let base64String = imageData.base64EncodedString()
            normalizedIconUrl = "data:image/png;base64,\(base64String)"
        } else {
            normalizedIconUrl = ""
        }
        self.postCapabilitiesManually(iconUrl: normalizedIconUrl)
    }

    private func postCapabilitiesManually(iconUrl: String) {
        guard let url = buildURL("/Sessions/Capabilities/Full"), !accessToken.isEmpty else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(getAuthorizationHeader(), forHTTPHeaderField: "Authorization")

        let supported: [String] = [
            JellyfinAPI.GeneralCommandType.play.rawValue,
            JellyfinAPI.GeneralCommandType.mute.rawValue,
            JellyfinAPI.GeneralCommandType.unmute.rawValue,
            JellyfinAPI.GeneralCommandType.setVolume.rawValue,
            JellyfinAPI.GeneralCommandType.setAudioStreamIndex.rawValue,
            JellyfinAPI.GeneralCommandType.setSubtitleStreamIndex.rawValue,
            JellyfinAPI.GeneralCommandType.setRepeatMode.rawValue,
            JellyfinAPI.GeneralCommandType.setMaxStreamingBitrate.rawValue,
            JellyfinAPI.GeneralCommandType.setPlaybackOrder.rawValue
        ]
        let body: [String: Any] = [
            "PlayableMediaTypes": ["Video"],
            "SupportedCommands": supported,
            "SupportsMediaControl": true,
            "SupportsPersistentIdentifier": true,
            "IconUrl": iconUrl
        ]

        var finalBodyStr: String? = nil
        if let raw = try? JSONSerialization.data(withJSONObject: body, options: []) , let rawStr = String(data: raw, encoding: .utf8) {
            finalBodyStr = rawStr.replacingOccurrences(of: "\\/", with: "/")
            request.httpBody = finalBodyStr!.data(using: .utf8)
        } else if let dbg = try? JSONSerialization.data(withJSONObject: body, options: .prettyPrinted), let dbgStr = String(data: dbg, encoding: .utf8) {
            finalBodyStr = dbgStr
            request.httpBody = dbgStr.data(using: .utf8)
        } else {
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }

        URLSession.shared.dataTask(with: request) { data, response, error in }.resume()
    }

    @MainActor
    func refreshUserProfileInfoAndImage() async {
        guard !serverURL.isEmpty, !accessToken.isEmpty, !userID.isEmpty else { return }
        await fetchUserPrimaryImageTag()
        await fetchUserPrimaryImage()
    }

    @MainActor
    private func fetchUserPrimaryImageTag() async {
        guard !serverURL.isEmpty, !accessToken.isEmpty, !userID.isEmpty else { return }
        let base = serverURL.hasSuffix("/") ? String(serverURL.dropLast()) : serverURL
        guard let url = URL(string: base + "/Users/\(userID)") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue(getAuthorizationHeader(), forHTTPHeaderField: "Authorization")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else { return }
            struct UserDetail: Decodable { let PrimaryImageTag: String? }
            if let detail = try? JSONDecoder().decode(UserDetail.self, from: data) {
                if self.userPrimaryImageTag != detail.PrimaryImageTag {
                    self.userPrimaryImageTag = detail.PrimaryImageTag
                }
            }
        } catch { print("[ProfileImage] Tag fetch failed: \(error)") }
    }

    @MainActor
    private func fetchUserPrimaryImage() async {
        guard !serverURL.isEmpty, !accessToken.isEmpty, !userID.isEmpty else { return }
        let base = serverURL.hasSuffix("/") ? String(serverURL.dropLast()) : serverURL
        var urlString = base + "/Users/\(userID)/Images/Primary"
        if let tag = userPrimaryImageTag, !tag.isEmpty { urlString += "?tag=\(tag)&quality=80" } else { urlString += "?quality=80" }
        guard let url = URL(string: urlString) else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue(getAuthorizationHeader(), forHTTPHeaderField: "Authorization")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else { return }
            if let image = UIImage(data: data) { self.userProfileImage = image }
        } catch { print("[ProfileImage] Image fetch failed: \(error)") }
    }

    @MainActor
    func performBackgroundEPGRefresh() async {
        guard !serverURL.isEmpty else { return }
        guard !accessToken.isEmpty else { return }

        let cal = Calendar.current
        let today = startOfDay(Date())
        let offsets = [-1, 0, 1]

        for off in offsets {
            let day = cal.date(byAdding: .day, value: off, to: today) ?? today
            await fetchAndCacheEPG(for: day)
        }
        pruneOldGuideEPGCacheFiles()
    }

    private func fetchAndCacheEPG(for day: Date) async {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let start = startOfDay(day)
        let end = Calendar.current.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(24*3600)

        guard let base = buildURL("/LiveTv/Programs") else { return }
        var comps = URLComponents(url: base, resolvingAgainstBaseURL: false)
        comps?.queryItems = [
            URLQueryItem(name: "startDate", value: iso.string(from: start)),
            URLQueryItem(name: "endDate", value: iso.string(from: end)),
            URLQueryItem(name: "EnableImages", value: "false"),
            URLQueryItem(name: "EnableUserData", value: "false"),
            URLQueryItem(name: "fields", value: "Overview,OfficialRating,EpisodeTitle,ParentIndexNumber,IndexNumber,IsRepeat,IsMovie")
        ]
        if let uid = user?.id, !uid.isEmpty { comps?.queryItems?.append(URLQueryItem(name: "userId", value: uid)) }
        guard let url = comps?.url else { return }

        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !accessToken.isEmpty {
            req.setValue(getAuthorizationHeader(), forHTTPHeaderField: "Authorization")
        }

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            if let http = resp as? HTTPURLResponse, http.statusCode != 200 { return }

            let dec = JSONDecoder()
            dec.dateDecodingStrategy = .custom { d in
                let c = try d.singleValueContainer(); let s = try c.decode(String.self)
                let f1 = ISO8601DateFormatter(); f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                if let dt = f1.date(from: s) { return dt }
                let f2 = ISO8601DateFormatter(); if let dt2 = f2.date(from: s) { return dt2 }
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "Cannot parse date: \(s)")
            }

            struct EPGProgramsResponseLocal: Decodable { let Items: [BaseItemDto]? }
            let decoded = try dec.decode(EPGProgramsResponseLocal.self, from: data)
            let items = decoded.Items ?? []

            try saveGuideEPGCache(for: day, items: items)

        } catch {
            print("Background EPG fetch failed for \(day): \(error)")
        }
    }

    private var guideCacheFolderName: String { "GuideCache" }
    private var epgFilePrefix: String { "epg_day_" }
    private var epgFileExt: String { ".json" }

    private func guideCacheDirectoryURL() throws -> URL {
        let fm = FileManager.default
        let base = try fm.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let dir = base.appendingPathComponent(guideCacheFolderName, isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    private func epgCacheFileURL(for day: Date) throws -> URL {
        let key = dayFileKey(day)
        return try guideCacheDirectoryURL().appendingPathComponent(epgFilePrefix + key + epgFileExt)
    }

    private func dayFileKey(_ date: Date) -> String {
        let df = DateFormatter()
        df.calendar = Calendar(identifier: .gregorian)
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = .current
        df.dateFormat = "yyyy-MM-dd"
        return df.string(from: startOfDay(date))
    }

    private func saveGuideEPGCache(for day: Date, items: [BaseItemDto]) throws {
        struct EPGCacheFileLocal: Codable { let dayKey: String; let timestamp: Date; let items: [BaseItemDto] }
        let payload = EPGCacheFileLocal(dayKey: dayFileKey(day), timestamp: Date(), items: items)
        let data = try JSONEncoder().encode(payload)
        let url = try epgCacheFileURL(for: day)
        try data.write(to: url, options: [.atomic])
    }

    private func pruneOldGuideEPGCacheFiles() {
        do {
            let dir = try guideCacheDirectoryURL()
            let fm = FileManager.default
            let files = try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            let horizon = Calendar.current.date(byAdding: .day, value: -14, to: startOfDay(Date())) ?? Date.distantPast
            for url in files where url.lastPathComponent.hasPrefix(epgFilePrefix) && url.pathExtension == "json" {
                let name = url.deletingPathExtension().lastPathComponent
                let key = String(name.dropFirst(epgFilePrefix.count))
                let df = DateFormatter()
                df.calendar = Calendar(identifier: .gregorian)
                df.locale = Locale(identifier: "en_US_POSIX")
                df.timeZone = .current
                df.dateFormat = "yyyy-MM-dd"
                if let d = df.date(from: key), startOfDay(d) < horizon {
                    try? fm.removeItem(at: url)
                }
            }
        } catch {}
    }
}

extension AppState: @unchecked Sendable {}

#if canImport(WatchConnectivity)
final class WatchSyncManager: NSObject, WCSessionDelegate {
    static let shared = WatchSyncManager()
    
    // Store context if we try to send before activation is complete
    private var pendingContext: [String: Any]?

    private override init() {
        super.init()
        activate()
    }

    private func activate() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    func sendLogin(serverURL: String, accessToken: String, apiKey: String, userId: String) {
        guard WCSession.isSupported() else { return }
        let ctx: [String: Any] = [
            "serverURL": serverURL,
            "accessToken": accessToken,
            "apiKey": apiKey,
            "userId": userId,
            "loggedOut": false
        ]
        updateContextOrQueue(ctx)
    }

    func sendLogout() {
        guard WCSession.isSupported() else { return }
        updateContextOrQueue(["loggedOut": true])
    }

    private func updateContextOrQueue(_ ctx: [String: Any]) {
        let session = WCSession.default
        if session.activationState == .activated {
            do {
                try session.updateApplicationContext(ctx)
            } catch {
                print("WatchSyncManager: updateApplicationContext error: \(error)")
            }
        } else {
            // Queue it up to be sent once activation completes
            pendingContext = ctx
            if session.activationState == .notActivated {
                session.activate()
            }
        }
    }

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        // Send the queued context now that we are fully activated
        if activationState == .activated, let ctx = pendingContext {
            do {
                try session.updateApplicationContext(ctx)
                self.pendingContext = nil
            } catch {
                print("WatchSyncManager: pending updateApplicationContext error: \(error)")
            }
        }
    }

#if os(iOS)
    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) { WCSession.default.activate() }
#endif
}
#endif
