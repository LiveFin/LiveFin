import SwiftUI
import Foundation
import UIKit
#if canImport(WatchConnectivity)
import WatchConnectivity
#endif
@preconcurrency import JellyfinAPI


final class AppState: ObservableObject {
    @Published var client: JellyfinClient?
    @Published var isLoggedIn = false
    @Published var user: UserDto?
    @Published var serverURL: String = ""
    @Published var accessToken: String = ""
    @Published var userID: String = ""
    @Published var username: String = "" // Added property for username
    @Published var deviceId: String = KeychainHelper.load(key: "deviceUUID") ?? {
        let newUUID = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
        KeychainHelper.save(key: "deviceUUID", value: newUUID)
        return newUUID
    }()
    @Published var apiKey: String = "" // Add this to AppState
    // User profile image cache
    @Published var userPrimaryImageTag: String? = nil
    @Published var userProfileImage: UIImage? = nil

    // New playback-related published properties
    @Published var currentPlaybackItemId: String? = nil
    @Published var isPlaying: Bool = false
    @Published var currentChannelImageUrl: String? = nil
    @Published var currentProgramTitle: String? = nil
    @Published var currentProgramSubtitle: String? = nil
    // New: program identity + image tag for Now Playing artwork
    @Published var currentProgramId: String? = nil
    @Published var currentProgramPrimaryImageTag: String? = nil
    @Published var currentProgramImageType: String? = nil // "Primary" or "Thumb"
    @Published var currentProgramThumbImageTag: String? = nil // New: capture Thumb tag when available
    // New: genres/tags for the current program (used by UI / related queries)
    @Published var currentProgramGenres: [String]? = nil
    // New: whether the current program is a movie (used to suppress subtitles in player)
    @Published var currentProgramIsMovie: Bool = false
    @Published var currentProgramStartDate: Date? = nil // New: track start time
    @Published var currentProgramEndDate: Date? = nil   // New: track end time
    // Global channel name cache (Id -> Name) populated by HomeViewModel and others
    @Published var channelNames: [String: String] = [:]

    // EPG polling timer
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

    // Helper: build absolute URL safely from serverURL and a path (handles leading slash)
    private func buildURL(_ path: String) -> URL? {
        guard !serverURL.isEmpty else { return nil }
        let base = serverURL.hasSuffix("/") ? String(serverURL.dropLast()) : serverURL
        let normalizedPath = path.hasPrefix("/") ? path : "/\(path)"
        return URL(string: base + normalizedPath)
    }

    // Small date helpers used across AppState
    private func startOfDay(_ date: Date) -> Date { Calendar.current.startOfDay(for: date) }
    private func endOfDay(_ date: Date) -> Date { Calendar.current.date(byAdding: .day, value: 1, to: startOfDay(date)) ?? date.addingTimeInterval(24*3600) }

    // MARK: - Demo Mode Activation
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

    // MARK: - Normal User Activation
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
        let newApiKey = UUID().uuidString
        self.apiKey = newApiKey
        self.loginError = nil
        KeychainHelper.save(key: "apiKey", value: newApiKey)
        KeychainHelper.save(key: "userId", value: userId)
        KeychainHelper.saveCredentials(server: serverURL, username: userName, accessToken: accessToken)
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
            let authHeader = "MediaBrowser Client=\"LiveFin\", Device=\"\(clientDevice)\", DeviceId=\"\(deviceId)\", Version=\"\(clientVersion)\""
            request.setValue(authHeader, forHTTPHeaderField: "X-Emby-Authorization")
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
    func restoreLogin() {
        let creds = KeychainHelper.retrieveCredentials()
        guard let server = creds.serverURL,
              let username = creds.username,
              let token = creds.accessToken else { return }
        
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
        self.isLoggedIn = true
        self.isDemoMode = false
        Task { await fetchServerName() }
        if let storedApiKey = KeychainHelper.load(key: "apiKey") { self.apiKey = storedApiKey }
        if let storedUserId = KeychainHelper.load(key: "userId") { self.userID = storedUserId }
        if let id = KeychainHelper.load(key: "userId"), let name = creds.username { self.user = UserDto(id: id, name: name) }
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
            KeychainHelper.deleteCredentials()
        }
    }

    @MainActor
    func reportPlaybackStart(itemId: String, canSeek: Bool = true, playMethod: String = "DirectPlay", repeatMode: String = "RepeatNone") {
        guard let url = buildURL("/Sessions/Playing"), !accessToken.isEmpty else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(accessToken, forHTTPHeaderField: "X-Emby-Token")

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
                print("Jellyfin: Reported playback start for \(itemId)")
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
        request.setValue(accessToken, forHTTPHeaderField: "X-Emby-Token")

        let body: [String: Any] = [
            "ItemId": itemId,
            "PositionTicks": positionTicks,
            "CanSeek": canSeek,
            "IsPaused": isPaused,
            "PlayMethod": playMethod,
            "RepeatMode": repeatMode
        ]

        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: request) { _, _, error in
            if let error = error {
                print("Jellyfin: Error reporting playback progress: \(error)")
            } else {
                print("Jellyfin: Reported playback progress for \(itemId) at \(positionTicks) ticks")
            }
        }.resume()
    }

    @MainActor
    func reportPlaybackStopped(itemId: String, positionTicks: Int64, playSessionId: String? = nil, playMethod: String = "DirectPlay") {
        guard let url = buildURL("/Sessions/Playing/Stopped"), !accessToken.isEmpty else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(accessToken, forHTTPHeaderField: "X-Emby-Token")

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
            if let error = error {
                print("Jellyfin: Error reporting playback stopped: \(error)")
            } else {
                if let httpResponse = response as? HTTPURLResponse {
                    print("Jellyfin: Reported playback stopped for \(itemId) (Status: \(httpResponse.statusCode))")
                }
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
        // Fix for the 400 error: LiveStreams/Close requires the liveStreamId in the URL query string!
        guard let url = buildURL("/LiveStreams/Close?liveStreamId=\(liveStreamId)"), !accessToken.isEmpty else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(accessToken, forHTTPHeaderField: "X-Emby-Token")
        
        URLSession.shared.dataTask(with: request) { _, response, error in
            if let error = error {
                print("Jellyfin: Error closing live stream tuner connection: \(error)")
            } else if let http = response as? HTTPURLResponse {
                print("Jellyfin: Closed active live stream tuner \(liveStreamId) (Status: \(http.statusCode))")
            }
        }.resume()
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
        // Build start and end times (now -> +1 hour) in UTC to avoid server TZ ambiguity
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
            request.setValue(accessToken, forHTTPHeaderField: "X-Emby-Token")
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return
            }
            // Decode response (prefer { Items: [...] }, fallback to array)
            var list: [[String: Any]] = []
            if let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let items = root["Items"] as? [[String: Any]] { list = items }
                else if let items = root["items"] as? [[String: Any]] { list = items }
            } else if let arr = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                list = arr
            }

            guard !list.isEmpty else {
                // FIX: Don't clear metadata on empty EPG response - the program is still playing!
                // Empty responses can happen due to temporary network delays or API issues.
                // The metadata we set will remain valid until the actual program changes.
                return
            }

            // Find program that contains 'now'; else choose nearest upcoming; else latest before
            let parser = ISO8601DateFormatter()
            parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            var selected: [String: Any]? = nil
            var latestBeforeNow: (prog: [String: Any], start: Date)? = nil
            var earliestAfterNow: (prog: [String: Any], start: Date)? = nil
            for prog in list {
                let startS = (prog["StartDate"] as? String) ?? (prog["StartDateUtc"] as? String)
                let endS = (prog["EndDate"] as? String) ?? (prog["EndDateUtc"] as? String)
                // Try with fractional seconds, then without as a fallback to be robust
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
            // Extract times again for chosen program
            let startTimeString = program["StartDate"] as? String ?? program["StartDateUtc"] as? String
            let endTimeString = program["EndDate"] as? String ?? program["EndDateUtc"] as? String
            let programStartDate = (parser.date(from: startTimeString ?? "")) ?? {
                let fb = ISO8601DateFormatter(); fb.formatOptions = [.withInternetDateTime]; return fb.date(from: startTimeString ?? "")
            }()
            let programEndDate = (parser.date(from: endTimeString ?? "")) ?? {
                let fb = ISO8601DateFormatter(); fb.formatOptions = [.withInternetDateTime]; return fb.date(from: endTimeString ?? "")
            }()

            let title = program["Name"] as? String ?? program["SeriesName"] as? String
            let overview = program["Overview"] as? String
            // Use Id for images; ProgramId may not be a valid item endpoint
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
            // Detect if program is a movie via common fields
            let typeStr = (program["Type"] as? String) ?? (program["ProgramType"] as? String)
            let isMovie = (typeStr?.caseInsensitiveCompare("Movie") == .orderedSame) || (program["IsMovie"] as? Bool == true)

            await MainActor.run {
                self.currentProgramTitle = title
                // Prefer series name or explicit episode title for subtitle. Do NOT use the program Overview (description)
                if let series = program["SeriesName"] as? String, series != title {
                    self.currentProgramSubtitle = series
                } else {
                    // Try common episode title keys (EPG sources vary)
                    let episodeTitle = (program["EpisodeTitle"] as? String) ?? (program["EpisodeName"] as? String) ?? (program["PartTitle"] as? String)
                    if let ep = episodeTitle, !ep.isEmpty {
                        self.currentProgramSubtitle = ep
                    } else {
                        self.currentProgramSubtitle = nil
                    }
                }
                // Extract genres/tags from several possible shapes the server may return
                var resolvedGenres: [String]? = nil
                if let gs = program["Genres"] as? [String] {
                    resolvedGenres = gs
                } else if let gsArr = program["Genres"] as? [[String: Any]] {
                    // Some servers return array of objects { Name: "..." }
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

    // MARK: - Report full client capabilities (adds ImageUrl for server devices/playstate)
    func reportFullClientCapabilities() {
        guard !accessToken.isEmpty else { return }
        
        let normalizedIconUrl: String
        // Convert local asset directly to Base64 to bypass Jellyfin CSP image loading restrictions.
        // **IMPORTANT:** Ensure you add an image asset named "Logo" to your Xcode Assets.xcassets
        if let image = UIImage(named: "Logo"),
           let imageData = image.pngData() {
            let base64String = imageData.base64EncodedString()
            normalizedIconUrl = "data:image/png;base64,\(base64String)"
        } else {
            print("[Capabilities] Warning: Asset 'Logo' not found. Using blank IconUrl.")
            normalizedIconUrl = ""
        }
        
        // Debug: show a snippet of the IconUrl string we'll send so it doesn't flood the console
        print("[Capabilities] IconUrl to send: \(normalizedIconUrl.prefix(50))...")

        // Call the manual JSON capabilities endpoint.
        // By bypassing the SDK here, we avoid accidentally passing DeviceId as the SessionId,
        // which causes Jellyfin to return a 404 Not Found.
        self.postCapabilitiesManually(iconUrl: normalizedIconUrl)
    }

    // Manual JSON-body capabilities POST to /Sessions/Capabilities/Full
    private func postCapabilitiesManually(iconUrl: String) {
        guard let url = buildURL("/Sessions/Capabilities/Full"), !accessToken.isEmpty else { return }

        // IMPORTANT: We do NOT append ?id=deviceId to the URL.
        // The 'id' parameter in this Jellyfin endpoint expects a SessionId, not a DeviceId.
        // Passing the DeviceId as the 'id' causes Jellyfin to return a 404 Not Found because
        // it cannot find a session with that ID. Omitting it applies the capabilities to the current authenticated session.

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(accessToken, forHTTPHeaderField: "X-Emby-Token")
        let authHeader = "MediaBrowser Client=\"LiveFin\", Device=\"\(clientDevice)\", DeviceId=\"\(deviceId)\", Version=\"\(clientVersion)\", Token=\"\(accessToken)\""
        request.setValue(authHeader, forHTTPHeaderField: "X-Emby-Authorization")

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

        // Build the actual HTTP body string we'll send, preferring to unescape forward slashes
        var finalBodyStr: String? = nil
        if let raw = try? JSONSerialization.data(withJSONObject: body, options: []) , let rawStr = String(data: raw, encoding: .utf8) {
            // Replace escaped forward slashes with plain forward slashes so the server sees normal URLs
            finalBodyStr = rawStr.replacingOccurrences(of: "\\/", with: "/")
            request.httpBody = finalBodyStr!.data(using: .utf8)
        } else if let dbg = try? JSONSerialization.data(withJSONObject: body, options: .prettyPrinted), let dbgStr = String(data: dbg, encoding: .utf8) {
            // Fallback - send the pretty-printed serialization if we couldn't do the compact one
            finalBodyStr = dbgStr
            request.httpBody = dbgStr.data(using: .utf8)
        } else {
            // Last-resort: let the system serialize directly into Data
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
            if let data = request.httpBody { finalBodyStr = String(data: data, encoding: .utf8) }
        }

        // Print the exact body we're sending so it's unambiguous in logs (no escaped slashes)
        if let final = finalBodyStr {
            print("[Capabilities] Posting body (sent, prefix truncated): \n\(final.prefix(300))...")
        } else {
            print("[Capabilities] Posting body: <unable to render body as string>")
        }

        // Debug: print the outgoing request URL, headers and the exact UTF-8 body string we'll send
        if let requestURL = request.url { print("[Capabilities] POST (JSON) URL: \(requestURL.absoluteString)") }
        if let headers = request.allHTTPHeaderFields { print("[Capabilities] POST (JSON) headers: \(headers)") }

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                print("[Capabilities] Failed to report: \(error)")
                return
            }
            if let http = response as? HTTPURLResponse {
                print("[Capabilities] Server response: \(http.statusCode)")
                if http.statusCode != 204 && http.statusCode != 200 {
                    if let data = data, let s = String(data: data, encoding: .utf8) { print("[Capabilities] Body: \(s)") }
                }
            }
            // After posting capabilities, fetch Sessions and print parsed IconUrl/ImageUrl
            // so we can verify what the server stored (this prints the parsed value, not raw JSON escape sequences).
            Task {
                await MainActor.run {
                    self.debugLogCurrentSessionIcon()
                }
            }
        }.resume()
    }

    // Debug: inspect sessions and print any IconUrl/ImageUrl stored for this device
    private func debugLogCurrentSessionIcon() {
        guard let url = buildURL("/Sessions"), !accessToken.isEmpty else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue(accessToken, forHTTPHeaderField: "X-Emby-Token")
        let deviceIdLocal = self.deviceId
        let deviceNameLocal = self.clientDevice
        URLSession.shared.dataTask(with: req) { data, resp, err in
            if let err = err { print("[Sessions] fetch error: \(err)"); return }
            guard let data = data, let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }
            if let session = arr.first(where: { ($0["DeviceId"] as? String) == deviceIdLocal }) ?? arr.first(where: { ($0["DeviceName"] as? String) == deviceNameLocal }) {
                if let caps = session["ClientCapabilities"] as? [String: Any] {
                    if let icon = caps["IconUrl"] as? String { print("[Sessions] ClientCapabilities.IconUrl (prefix) = \(icon.prefix(50))...") }
                    if let image = caps["ImageUrl"] as? String { print("[Sessions] ClientCapabilities.ImageUrl (prefix) = \(image.prefix(50))...") }
                }
                if let icon = session["IconUrl"] as? String { print("[Sessions] Session.IconUrl (prefix) = \(icon.prefix(50))...") }
                if let image = session["ImageUrl"] as? String { print("[Sessions] Session.ImageUrl (prefix) = \(image.prefix(50))...") }
                if let any = AppState.findIconUrlRecursively(in: session) { print("[Sessions] Found Icon/Image URL (recursive prefix) = \(any.prefix(50))...") }
            } else {
                print("[Sessions] No session matched deviceId=\(deviceIdLocal)")
            }
        }.resume()
    }

    private static func findIconUrlRecursively(in dict: [String: Any]) -> String? {
        for (k, v) in dict {
            if (k == "IconUrl" || k == "ImageUrl"), let s = v as? String { return s }
            if let sub = v as? [String: Any], let s = findIconUrlRecursively(in: sub) { return s }
            if let arr = v as? [[String: Any]] {
                for el in arr { if let s = findIconUrlRecursively(in: el) { return s } }
            }
        }
        return nil
    }

    // MARK: - User Profile Image Handling
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
        req.setValue(accessToken, forHTTPHeaderField: "X-Emby-Token")
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
        req.setValue(accessToken, forHTTPHeaderField: "X-Emby-Token")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else { return }
            if let image = UIImage(data: data) { self.userProfileImage = image }
        } catch { print("[ProfileImage] Image fetch failed: \(error)") }
    }

    // MARK: - Background EPG refresh
    // This will be invoked from BGAppRefresh handler to warm local EPG cache files
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

        // Prune old files (same horizon as GuideView)
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
        if !accessToken.isEmpty { req.setValue(accessToken, forHTTPHeaderField: "X-Emby-Token") }

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

            // Save to cache in GuideCache format
            try saveGuideEPGCache(for: day, items: items)

        } catch {
            print("Background EPG fetch failed for \(day): \(error)")
        }
    }

    // Guide cache helpers (mirrors GuideView cache naming/format)
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
        } catch {
            // ignore
        }
    }
}

// Allow AppState to be captured in @Sendable closures; it's main-actor confined so this is safe.
extension AppState: @unchecked Sendable {}

#if canImport(WatchConnectivity)
final class WatchSyncManager: NSObject, WCSessionDelegate {
    static let shared = WatchSyncManager()
    private override init() { super.init(); activate() }

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
        do { try WCSession.default.updateApplicationContext(ctx) } catch { print("WatchSyncManager: updateApplicationContext error: \(error)") }
    }

    func sendLogout() {
        guard WCSession.isSupported() else { return }
        do { try WCSession.default.updateApplicationContext(["loggedOut": true]) } catch { }
    }

    // WCSessionDelegate minimal stubs
    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {}
#if os(iOS)
    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) { WCSession.default.activate() }
#endif
}
#endif
