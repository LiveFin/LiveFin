//
//  OpenLiveStreamService.swift
//  LiveFin
//
//  Created by KPGamingz on 9/14/25.
//

import Foundation
import UIKit
import JellyfinAPI

struct JFOpenLiveStreamService {
    static func resolveStreamURL(
        channelId: String,
        userId: String,
        serverURL: String,
        accessToken: String,
        deviceId: String,
        deviceName: String? = nil,
        clientVersion: String = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0",
        debug: Bool = false
    ) async -> String? {
        let resolved = await resolveStreamURLWithSession(
            channelId: channelId,
            userId: userId,
            serverURL: serverURL,
            accessToken: accessToken,
            deviceId: deviceId,
            deviceName: deviceName,
            clientVersion: clientVersion,
            debug: debug
        )
        return resolved.url
    }

    static func resolveStreamURL(appState: AppState, channelId: String, debug: Bool = false) async -> String? {
        await resolveStreamURL(
            channelId: channelId,
            userId: appState.userID,
            serverURL: appState.serverURL,
            accessToken: appState.accessToken,
            deviceId: appState.deviceId,
            deviceName: appState.clientDevice,
            clientVersion: appState.clientVersion,
            debug: debug
        )
    }

    private static func postOpen(
        base: String,
        path: String,
        channelId: String,
        userId: String,
        accessToken: String,
        deviceId: String,
        deviceName: String,
        clientVersion: String
    ) async throws -> String {
        return try await withCheckedThrowingContinuation { continuation in
            Task {
                let url = URL(string: base + path)!
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue("application/json", forHTTPHeaderField: "Accept")
                request.setValue(accessToken, forHTTPHeaderField: "X-Emby-Token")
                let authHeader = "MediaBrowser Client=\"LiveFin\", Device=\"\(deviceName)\", DeviceId=\"\(deviceId)\", Version=\"\(clientVersion)\""
                request.setValue(authHeader, forHTTPHeaderField: "X-Emby-Authorization")
                request.setValue(userId, forHTTPHeaderField: "X-Emby-User-Id")
                request.setValue("LiveFin", forHTTPHeaderField: "X-Emby-Client")
                request.setValue(deviceName, forHTTPHeaderField: "X-Emby-Device-Name")
                request.setValue(deviceId, forHTTPHeaderField: "X-Emby-Device-Id")
                request.setValue(clientVersion, forHTTPHeaderField: "X-Emby-Client-Version")
                let userAgent = "LiveFin/\(clientVersion) (iOS; \(deviceName))"
                request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
                let body: [String: Any] = [
                    "ChannelId": channelId,
                    "UserId": userId,
                    "AllowAudioStreamCopy": true,
                    "AllowVideoStreamCopy": true,
                    "MaxStreamingBitrate": 60_000_000, // Increased to 60Mbps to prevent unnecessary transcodes
                    "RequireAvc": true,
                    "AudioCodec": "aac",
                    "VideoCodec": "h264"
                ]
                request.httpBody = try? JSONSerialization.data(withJSONObject: body)
                URLSession.shared.dataTask(with: request) { data, response, _ in
                    guard let http = response as? HTTPURLResponse, let data = data, (200...299).contains(http.statusCode) else {
                        continuation.resume(throwing: URLError(.badServerResponse)); return
                    }
                    if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        if let id = obj["Id"] as? String, !id.isEmpty { continuation.resume(returning: id); return }
                        if let id = obj["id"] as? String, !id.isEmpty { continuation.resume(returning: id); return }
                    }
                    struct Resp: Decodable { let Id: String? }
                    if let resp = try? JSONDecoder().decode(Resp.self, from: data), let id = resp.Id, !id.isEmpty {
                        continuation.resume(returning: id); return
                    }
                    continuation.resume(throwing: URLError(.cannotParseResponse))
                }.resume()
            }
        }
    }

    // MARK: - FIX: Pre-open the live stream so the tuner starts buffering immediately
    /// Call /LiveStreams/Open before PlaybackInfo so the server begins capturing the
    /// tuner feed while we wait for PlaybackInfo. Returns the LiveStreamId or nil on failure.
    private static func openLiveStream(
        base: String,
        channelId: String,
        userId: String,
        accessToken: String,
        deviceId: String,
        deviceName: String,
        clientVersion: String,
        debug: Bool
    ) async -> String? {
        guard let url = URL(string: "\(base)/LiveStreams/Open") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(accessToken, forHTTPHeaderField: "X-Emby-Token")
        let authHeader = "MediaBrowser Client=\"LiveFin\", Device=\"\(deviceName)\", DeviceId=\"\(deviceId)\", Version=\"\(clientVersion)\""
        request.setValue(authHeader, forHTTPHeaderField: "X-Emby-Authorization")
        request.setValue(userId, forHTTPHeaderField: "X-Emby-User-Id")

        let body: [String: Any] = [
            "ItemId": channelId,
            "UserId": userId,
            "PlaySessionId": UUID().uuidString,
            "MaxStreamingBitrate": 60_000_000 // Increased to 60Mbps
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                if debug { print("[OpenLiveStream] HTTP error: \((response as? HTTPURLResponse)?.statusCode ?? -1)") }
                return nil
            }
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let liveStreamId = (obj["LiveStreamId"] as? String) ?? (obj["liveStreamId"] as? String)
                if debug { print("[OpenLiveStream] Opened live stream, id=\(liveStreamId ?? "nil")") }
                return liveStreamId
            }
        } catch {
            if debug { print("[OpenLiveStream] Failed: \(error)") }
        }
        return nil
    }

    private static func trimTrailingSlash(_ s: String) -> String {
        s.hasSuffix("/") ? String(s.dropLast()) : s
    }

    private static func replaceLocalhostWithServerHostAndPort(in urlString: String, serverBase: String) -> String {
        guard let abs = URL(string: urlString), let base = URL(string: serverBase) else { return urlString }
        guard let host = abs.host?.lowercased(), host == "localhost" || host == "127.0.0.1" else { return urlString }
        var comps = URLComponents(url: abs, resolvingAgainstBaseURL: false)
        let baseComps = URLComponents(url: base, resolvingAgainstBaseURL: false)
        comps?.host = baseComps?.host
        let pathPort = comps?.port
        let serverPort = baseComps?.port
        comps?.port = pathPort ?? serverPort
        if pathPort != nil {
            if comps?.scheme == nil { comps?.scheme = baseComps?.scheme }
        } else {
            comps?.scheme = baseComps?.scheme
        }
        return comps?.url?.absoluteString ?? urlString
    }

    private static func buildAbsoluteURL(base: String, pathOrUrl: String, altBase: String? = nil) -> String? {
        var value = pathOrUrl
        if value.contains("localhost") || value.contains("127.0.0.1") {
            if let host = URL(string: base)?.host {
                value = value.replacingOccurrences(of: "localhost", with: host)
                value = value.replacingOccurrences(of: "127.0.0.1", with: host)
            }
        }
        if value.hasPrefix("http://") || value.hasPrefix("https://") {
            guard let absURL = URL(string: value), let baseURL = URL(string: base) else { return value }
            var comps = URLComponents(url: absURL, resolvingAgainstBaseURL: false)
            let baseComps = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
            comps?.scheme = baseComps?.scheme
            comps?.host = baseComps?.host
            comps?.port = baseComps?.port
            if let bPath = baseComps?.path, !bPath.isEmpty, bPath != "/" {
                let normalizedBase = bPath.hasSuffix("/") ? String(bPath.dropLast()) : bPath
                let currentPath = comps?.path ?? absURL.path
                if currentPath.hasPrefix(normalizedBase) {
                    comps?.path = currentPath
                } else {
                    let curr = currentPath.hasPrefix("/") ? currentPath : "/" + currentPath
                    comps?.path = normalizedBase + curr
                }
            }
            return comps?.url?.absoluteString ?? value
        }
        let chosenBase = base
        if value.hasPrefix("/") {
            return chosenBase + value
        } else {
            return chosenBase + "/" + value
        }
    }

    private static func needsTranscodingForDirectPath(_ path: String?) -> Bool {
        guard let p = path?.lowercased() else { return false }
        if p.hasSuffix(".ts") || p.hasSuffix("/stream.ts") { return true }
        if p.contains("/livetv/livestreamfiles/") && (p.hasSuffix("/stream.ts") || p.hasSuffix(".ts")) {
            return true
        }
        return false
    }

    private static func sanitizeUrlString(_ s: String) -> String {
        let forbidden: [UInt32] = [0x2028, 0x2029, 0xFEFF]
        return String(s.filter { ch in
            for scalar in ch.unicodeScalars {
                if scalar.value < 0x20 || scalar.value == 0x7F || forbidden.contains(UInt32(scalar.value)) {
                    return false
                }
            }
            return true
        })
    }

    private static func ensureApiKeyParam(in urlString: String, token: String) -> String {
        guard !token.isEmpty else { return sanitizeUrlString(urlString) }
        guard var comps = URLComponents(string: urlString) else { return sanitizeUrlString(urlString) }
        let hasApiKey = (comps.queryItems ?? []).contains { $0.name.lowercased() == "apikey" || $0.name.lowercased() == "api_key" }
        if hasApiKey { return sanitizeUrlString(urlString) }
        var q = comps.queryItems ?? []
        q.append(URLQueryItem(name: "ApiKey", value: token))
        comps.queryItems = q
        return sanitizeUrlString(comps.url?.absoluteString ?? urlString)
    }

    private static func preparePlayableUrl(base: String, pathOrUrl: String, token: String, debug: Bool) async -> String {
        let abs = buildAbsoluteURL(base: base, pathOrUrl: pathOrUrl) ?? pathOrUrl
        let withKey = ensureApiKeyParam(in: abs, token: token)
        let sanitized = sanitizeUrlString(withKey)

        guard debug else { return sanitized }

        if sanitized.lowercased().contains(".m3u8") {
            if let url = URL(string: sanitized) {
                var req = URLRequest(url: url)
                req.httpMethod = "GET"
                if !token.isEmpty { req.setValue(token, forHTTPHeaderField: "X-Emby-Token") }
                do {
                    let (data, resp) = try await URLSession.shared.data(for: req)
                    if let http = resp as? HTTPURLResponse {
                        if debug { print("[Probe] fetched manifest \(sanitized) status=\(http.statusCode) len=\(data.count)") }
                    }
                    let body = String(data: data, encoding: .utf8) ?? "<binary>"
                    let firstSegLine = body.split(separator: "\n").first { line in
                        let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
                        return !t.hasPrefix("#") && !t.isEmpty
                    }
                    if let segLine = firstSegLine {
                        var segUrlStr = String(segLine)
                        if !segUrlStr.hasPrefix("http") {
                            if let baseURL = URL(string: sanitized) {
                                if segUrlStr.hasPrefix("/") {
                                    segUrlStr = baseURL.scheme! + "://" + (baseURL.host ?? "") + segUrlStr
                                } else {
                                    let baseParent = baseURL.deletingLastPathComponent().absoluteString
                                    segUrlStr = baseParent.hasSuffix("/") ? baseParent + segUrlStr : baseParent + "/" + segUrlStr
                                }
                            }
                        }
                        if debug { print("[Probe] probing segment URL: \(segUrlStr)") }
                        if let segUrl = URL(string: segUrlStr) {
                            var headReq = URLRequest(url: segUrl)
                            headReq.httpMethod = "HEAD"
                            if !token.isEmpty { headReq.setValue(token, forHTTPHeaderField: "X-Emby-Token") }
                            do {
                                let (_, headResp) = try await URLSession.shared.data(for: headReq)
                                if let http = headResp as? HTTPURLResponse {
                                    if debug { print("[Probe] segment HEAD status=\(http.statusCode) content-type=\(http.allHeaderFields["Content-Type"] ?? "<nil>")") }
                                }
                            } catch {
                                if debug { print("[Probe] HEAD probe failed for \(segUrlStr): \(error)") }
                            }
                        }
                    } else {
                        if debug { print("[Probe] manifest has no non-comment lines (empty or error) for \(sanitized)") }
                    }
                } catch {
                    if debug { print("[Probe] failed to fetch manifest \(sanitized): \(error)") }
                }
            } else {
                if debug { print("[Probe] cannot parse manifest URL: \(sanitized)") }
            }
        }

        return sanitized
    }

    // MARK: - Session helpers

    struct ResolvedStream {
        let url: String?
        let playSessionId: String?
        /// Server-reported status string. Populated asynchronously after stream starts.
        /// nil on initial return — observe via the background task if needed.
        let serverStatus: String?
    }

    static func resolveStreamURLWithSession(
        channelId: String,
        userId: String,
        serverURL: String,
        accessToken: String,
        deviceId: String,
        deviceName: String? = nil,
        clientVersion: String = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0",
        debug: Bool = false
    ) async -> ResolvedStream {
        let base = trimTrailingSlash(serverURL)
        let resolvedDeviceName = deviceName ?? UIDevice.current.name

        do {
            // FIX: Pre-open the live stream so the tuner starts buffering while
            // we wait for PlaybackInfo to come back. Both calls run concurrently.
            async let liveStreamIdTask = openLiveStream(
                base: base,
                channelId: channelId,
                userId: userId,
                accessToken: accessToken,
                deviceId: deviceId,
                deviceName: resolvedDeviceName,
                clientVersion: clientVersion,
                debug: debug
            )

            async let playbackInfoTask = JFPlaybackInfoService.fetchPlaybackInfoWithTranscodingUrl(
                itemId: channelId,
                userId: userId,
                serverURL: base,
                accessToken: accessToken,
                deviceId: deviceId,
                deviceName: resolvedDeviceName,
                clientVersion: clientVersion,
                debug: debug
            )

            // Await both concurrently — server is warming up the tuner while we
            // process the PlaybackInfo response
            let (liveStreamId, playbackResult) = await (liveStreamIdTask, try playbackInfoTask)
            if debug, let sid = liveStreamId { print("[ResolveStream] LiveStreamId pre-opened: \(sid)") }

            let (playbackInitial, transcodingUrlInitial, mediaSourceIdInitial, _) = playbackResult

            let primary = playbackInitial.mediaSources?.first
            let directPath = primary?.path
            let supportsDirectPlay = primary?.isSupportsDirectPlay
            let playSessionId = playbackInitial.playSessionID

            // FIX: Return the URL immediately without waiting for session status poll.
            // Status polling runs in the background and is purely informational for UI.
            func makeResolved(url: String?, status: String?) -> ResolvedStream {
                ResolvedStream(url: url, playSessionId: playSessionId, serverStatus: status)
            }

            if let supports = supportsDirectPlay {
                if supports {
                    if let p = directPath {
                        let adjusted = replaceLocalhostWithServerHostAndPort(in: p, serverBase: base)
                        let authed = ensureApiKeyParam(in: adjusted, token: accessToken)
                        if debug { print("[ResolveStream] SupportsDirectPlay -> direct path -> \(authed)") }
                        return makeResolved(url: authed, status: "DirectPlay")
                    }
                    if let turl = transcodingUrlInitial, let final = buildAbsoluteURL(base: base, pathOrUrl: turl) {
                        let authed = ensureApiKeyParam(in: final, token: accessToken)
                        if debug { print("[ResolveStream] DirectPlay but no direct path; using TranscodingUrl -> \(authed)") }
                        // FIX: Fire-and-forget background poll — don't block URL return
                        Task.detached {
                            _ = await pollAndDetermineSessionStatus(base: base, playSessionId: playSessionId, accessToken: accessToken, debug: debug)
                        }
                        return makeResolved(url: authed, status: nil)
                    }
                    return makeResolved(url: nil, status: "Unknown")
                } else {
                    if let turl = transcodingUrlInitial, let final = buildAbsoluteURL(base: base, pathOrUrl: turl) {
                        let authed = ensureApiKeyParam(in: final, token: accessToken)
                        if debug { print("[ResolveStream] SupportsDirectPlay == false -> TranscodingUrl -> \(authed)") }
                        Task.detached {
                            _ = await pollAndDetermineSessionStatus(base: base, playSessionId: playSessionId, accessToken: accessToken, debug: debug)
                        }
                        return makeResolved(url: authed, status: nil)
                    }
                    if debug { print("[ResolveStream] No TranscodingUrl; retrying with forced HLS params") }
                    if let turl = await requestForcedTranscodingUrl(
                        itemId: channelId, userId: userId, serverURL: base,
                        accessToken: accessToken, deviceId: deviceId,
                        deviceName: deviceName, clientVersion: clientVersion,
                        mediaSourceId: mediaSourceIdInitial, debug: debug
                    ), let final = buildAbsoluteURL(base: base, pathOrUrl: turl) {
                        let authed = ensureApiKeyParam(in: final, token: accessToken)
                        if debug { print("[ResolveStream] Forced TranscodingUrl -> \(authed)") }
                        Task.detached {
                            _ = await pollAndDetermineSessionStatus(base: base, playSessionId: playSessionId, accessToken: accessToken, debug: debug)
                        }
                        return makeResolved(url: authed, status: nil)
                    }
                    if debug { print("[ResolveStream] No TranscodingUrl available; giving up") }
                    return makeResolved(url: nil, status: "Unknown")
                }
            } else {
                // supportsDirectPlay missing: fall back to TS-based heuristic
                let container = primary?.container?.lowercased()
                let isTS = (container == "ts") || needsTranscodingForDirectPath(directPath)

                if isTS {
                    if let turl = transcodingUrlInitial, let final = buildAbsoluteURL(base: base, pathOrUrl: turl) {
                        let authed = ensureApiKeyParam(in: final, token: accessToken)
                        Task.detached {
                            _ = await pollAndDetermineSessionStatus(base: base, playSessionId: playSessionId, accessToken: accessToken, debug: debug)
                        }
                        return makeResolved(url: authed, status: nil)
                    }
                    if debug { print("[ResolveStream] TS source with no TranscodingUrl; giving up") }
                    return makeResolved(url: nil, status: "Unknown")
                } else {
                    if let p = directPath {
                        let adjusted = replaceLocalhostWithServerHostAndPort(in: p, serverBase: base)
                        let authed = ensureApiKeyParam(in: adjusted, token: accessToken)
                        if debug { print("[ResolveStream] Using direct path (non-TS) -> \(authed)") }
                        return makeResolved(url: authed, status: "DirectPlay")
                    }
                    if let turl = transcodingUrlInitial, let final = buildAbsoluteURL(base: base, pathOrUrl: turl) {
                        let authed = ensureApiKeyParam(in: final, token: accessToken)
                        if debug { print("[ResolveStream] No direct path; falling back to TranscodingUrl (non-TS) -> \(authed)") }
                        Task.detached {
                            _ = await pollAndDetermineSessionStatus(base: base, playSessionId: playSessionId, accessToken: accessToken, debug: debug)
                        }
                        return makeResolved(url: authed, status: nil)
                    }
                    return makeResolved(url: nil, status: "Unknown")
                }
            }
        } catch {
            if debug { print("[ResolveStream] Error: \(error)") }
            return ResolvedStream(url: nil, playSessionId: nil, serverStatus: "Error")
        }
    }

    static func resolveStreamURLWithSession(appState: AppState, channelId: String, debug: Bool = false) async -> ResolvedStream {
        await resolveStreamURLWithSession(
            channelId: channelId,
            userId: appState.userID,
            serverURL: appState.serverURL,
            accessToken: appState.accessToken,
            deviceId: appState.deviceId,
            deviceName: appState.clientDevice,
            clientVersion: appState.clientVersion,
            debug: debug
        )
    }

    // MARK: - Session status polling (background only — never blocks URL return)

    private static func pollAndDetermineSessionStatus(
        base: String,
        playSessionId: String?,
        accessToken: String,
        debug: Bool = false
    ) async -> String? {
        guard let sid = playSessionId, !sid.isEmpty else { return nil }
        let info = await pollSessionStatus(
            base: base, playSessionId: sid,
            accessToken: accessToken,
            attempts: 4, interval: 1.0,
            debug: debug
        )
        guard let t = info else { return nil }
        if let isVideoDirect = t.isVideoDirect {
            if isVideoDirect {
                if debug { print("[SessionStatus] Video is direct -> Remuxing") }
                return "Remuxing"
            } else {
                if debug { print("[SessionStatus] Video is not direct -> Transcoding") }
                return "Transcoding"
            }
        }
        return nil
    }

    private struct _TranscodingInfo: Decodable {
        let isVideoDirect: Bool?
        let isAudioDirect: Bool?
        let transcodeReasons: [String]?

        private enum CodingKeys: String, CodingKey {
            case isVideoDirect = "IsVideoDirect"
            case isAudioDirect = "IsAudioDirect"
            case transcodeReasons = "TranscodeReasons"
        }
    }

    private static func fetchSessionTranscodingInfo(
        base: String,
        playSessionId: String,
        accessToken: String,
        debug: Bool = false
    ) async -> _TranscodingInfo? {
        guard let url = URL(string: base + "/Sessions/" + playSessionId) else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if !accessToken.isEmpty { req.setValue(accessToken, forHTTPHeaderField: "X-Emby-Token") }
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else { return nil }
            if let info = try? JSONDecoder().decode(_TranscodingInfo.self, from: data) { return info }
            struct Wrapper: Decodable { let TranscodingInfo: _TranscodingInfo? }
            if let wrap = try? JSONDecoder().decode(Wrapper.self, from: data) { return wrap.TranscodingInfo }
            return nil
        } catch {
            if debug { print("[FetchSession] error: \(error)") }
            return nil
        }
    }

    private static func pollSessionStatus(
        base: String,
        playSessionId: String,
        accessToken: String,
        attempts: Int = 4,
        interval: TimeInterval = 1.0,
        debug: Bool = false
    ) async -> _TranscodingInfo? {
        var last: _TranscodingInfo? = nil
        for i in 0..<max(1, attempts) {
            if let info = await fetchSessionTranscodingInfo(base: base, playSessionId: playSessionId, accessToken: accessToken, debug: debug) {
                last = info
                if info.isVideoDirect != nil || info.isAudioDirect != nil || (info.transcodeReasons != nil && !(info.transcodeReasons?.isEmpty ?? true)) {
                    return info
                }
            }
            if i < attempts - 1 {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
        return last
    }

    private static func requestForcedTranscodingUrl(
        itemId: String,
        userId: String,
        serverURL: String,
        accessToken: String,
        deviceId: String,
        deviceName: String?,
        clientVersion: String,
        mediaSourceId: String?,
        debug: Bool
    ) async -> String? {
        typealias CopyFlags = (videoCopy: Bool, audioCopy: Bool)
        let attempts: [CopyFlags] = [
            (videoCopy: true, audioCopy: true),
            (videoCopy: false, audioCopy: false)
        ]

        return await withTaskGroup(of: String?.self) { group in
            for flags in attempts {
                group.addTask {
                    do {
                        let (_, turl, _, _) = try await JFPlaybackInfoService.fetchPlaybackInfoWithTranscodingUrl(
                            itemId: itemId,
                            userId: userId,
                            serverURL: serverURL,
                            accessToken: accessToken,
                            deviceId: deviceId,
                            deviceName: deviceName,
                            clientVersion: clientVersion,
                            maxBitrate: 60_000_000, // Increased to 60Mbps
                            enableDirectPlay: false,
                            enableDirectStream: false,
                            enableTranscoding: true,
                            requireAvc: true,
                            audioCodec: "aac",
                            videoCodec: "h264",
                            transcodingProtocol: "hls",
                            transcodingContainer: "ts",
                            allowVideoStreamCopy: flags.videoCopy,
                            allowAudioStreamCopy: flags.audioCopy,
                            mediaSourceId: mediaSourceId,
                            debug: debug
                        )
                        return turl
                    } catch {
                        if debug { print("[ForcedTranscode] error (videoCopy=\(flags.videoCopy) audioCopy=\(flags.audioCopy)): \(error)") }
                        return nil
                    }
                }
            }

            var result: String? = nil
            for await maybe in group {
                if let url = maybe {
                    result = url
                    group.cancelAll()
                    break
                }
            }
            return result
        }
    }
}
