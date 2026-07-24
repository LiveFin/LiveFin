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
    
    struct ResolvedStream {
        let url: String?
        let playSessionId: String?
        let serverStatus: String?
    }

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

    // MARK: - Live TV Specific Safeguards
    
    /// iOS absolutely cannot direct-play raw .ts streams from tuners. We must intercept these.
    private static func needsTranscodingForDirectPath(_ path: String?) -> Bool {
        guard let p = path?.lowercased() else { return false }
        if p.hasSuffix(".ts") || p.hasSuffix("/stream.ts") { return true }
        if p.contains("/livetv/") || p.contains("livestreamfiles") { return true }
        return false
    }

    // MARK: - Pre-Open Live Stream (Buffer Warmup)
    
    /// Call /LiveStreams/Open before PlaybackInfo so the server begins capturing the
    /// tuner feed while we wait for PlaybackInfo. This prevents 404s on tuner startup.
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
        
        // Modern Authorization Header for Jellyfin v12+
        let modernAuthHeader = "MediaBrowser Client=\"LiveFin\", Device=\"\(deviceName)\", DeviceId=\"\(deviceId)\", Version=\"\(clientVersion)\", Token=\"\(accessToken)\""
        request.setValue(modernAuthHeader, forHTTPHeaderField: "Authorization")

        let body: [String: Any] = [
            "ItemId": channelId,
            "UserId": userId,
            "PlaySessionId": UUID().uuidString,
            "MaxStreamingBitrate": 60_000_000
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

    // MARK: - URL Helpers
    
    private static func trimTrailingSlash(_ s: String) -> String {
        s.hasSuffix("/") ? String(s.dropLast()) : s
    }

    private static func replaceLocalhostWithServerHostAndPort(in urlString: String, serverBase: String) -> String {
        guard let abs = URL(string: urlString), let base = URL(string: serverBase) else { return urlString }
        guard let host = abs.host?.lowercased(), host == "localhost" || host == "127.0.0.1" else { return urlString }
        var comps = URLComponents(url: abs, resolvingAgainstBaseURL: false)
        let baseComps = URLComponents(url: base, resolvingAgainstBaseURL: false)
        
        comps?.host = baseComps?.host
        
        if comps?.port == nil {
            comps?.port = baseComps?.port
        }
        if comps?.scheme == nil {
            comps?.scheme = baseComps?.scheme
        }
        
        return comps?.url?.absoluteString ?? urlString
    }

    private static func buildAbsoluteURL(base: String, pathOrUrl: String) -> String? {
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
        return value.hasPrefix("/") ? (base + value) : (base + "/" + value)
    }

    private static func sanitizeUrlString(_ s: String) -> String {
        let forbidden: [UInt32] = [0x2028, 0x2029, 0xFEFF]
        return String(s.filter { ch in
            for scalar in ch.unicodeScalars {
                if scalar.value < 0x20 || scalar.value == 0x7F || forbidden.contains(UInt32(scalar.value)) { return false }
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

    // MARK: - Main Resolution Logic
    
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
        
        let resolvedDeviceName: String
        if let name = deviceName {
            resolvedDeviceName = name
        } else {
            resolvedDeviceName = await MainActor.run { UIDevice.current.name }
        }

        do {
            // Concurrently open tuner and fetch PlaybackInfo
            async let liveStreamIdTask = openLiveStream(
                base: base, channelId: channelId, userId: userId, accessToken: accessToken,
                deviceId: deviceId, deviceName: resolvedDeviceName, clientVersion: clientVersion, debug: debug
            )

            async let playbackInfoTask = JFPlaybackInfoService.fetchPlaybackInfoWithTranscodingUrl(
                itemId: channelId, userId: userId, serverURL: base, accessToken: accessToken,
                deviceId: deviceId, deviceName: resolvedDeviceName, clientVersion: clientVersion, debug: debug,
                isLiveTV: true // EXPLICITLY TELL PLAYBACK INFO THIS IS LIVE TV
            )

            let (liveStreamId, playbackResult) = await (liveStreamIdTask, try playbackInfoTask)
            if debug, let sid = liveStreamId { print("[ResolveStream] Pre-opened LiveStreamId: \(sid)") }

            let (playbackInitial, transcodingUrlInitial, mediaSourceIdInitial, _) = playbackResult

            let primary = playbackInitial.mediaSources?.first
            let directPath = primary?.path
            let playSessionId = playbackInitial.playSessionID
            var supportsDirectPlay = primary?.isSupportsDirectPlay ?? false

            // OVERRIDE: If the server thinks it can direct play a raw TS tuner file, reject it.
            // AVPlayer will throw CoreMediaErrorDomain if fed a raw TS URL.
            if supportsDirectPlay {
                if needsTranscodingForDirectPath(directPath) || primary?.container?.lowercased() == "ts" {
                    if debug { print("[ResolveStream] Blocked raw TS direct play to prevent AVPlayer crash.") }
                    supportsDirectPlay = false
                }
            }

            func makeResolved(url: String?, status: String?) -> ResolvedStream {
                ResolvedStream(url: url, playSessionId: playSessionId, serverStatus: status)
            }

            // Direct Play (Safe Formats Only)
            if supportsDirectPlay, let p = directPath {
                let adjusted = replaceLocalhostWithServerHostAndPort(in: p, serverBase: base)
                let authed = ensureApiKeyParam(in: adjusted, token: accessToken)
                return makeResolved(url: authed, status: "DirectPlay")
            }

            // Standard Transcode/Remux from PlaybackInfo
            if let turl = transcodingUrlInitial, let final = buildAbsoluteURL(base: base, pathOrUrl: turl) {
                let authed = ensureApiKeyParam(in: final, token: accessToken)
                return makeResolved(url: authed, status: "Transcoding/Remuxing")
            }

            // Forced Fallback: Ask explicitly for a highly compatible TS/H264 HLS stream
            if debug { print("[ResolveStream] No TranscodingUrl provided; requesting forced Live TV HLS transcode.") }
            if let turl = await requestForcedTranscodingUrl(
                itemId: channelId, userId: userId, serverURL: base,
                accessToken: accessToken, deviceId: deviceId,
                deviceName: resolvedDeviceName, clientVersion: clientVersion,
                mediaSourceId: mediaSourceIdInitial, debug: debug
            ), let final = buildAbsoluteURL(base: base, pathOrUrl: turl) {
                let authed = ensureApiKeyParam(in: final, token: accessToken)
                return makeResolved(url: authed, status: "Forced Transcoding")
            }

            return makeResolved(url: nil, status: "Unknown")
        } catch {
            if debug { print("[ResolveStream] Error: \(error)") }
            return ResolvedStream(url: nil, playSessionId: nil, serverStatus: "Error")
        }
    }

    static func resolveStreamURLWithSession(appState: AppState, channelId: String, debug: Bool = false) async -> ResolvedStream {
        await resolveStreamURLWithSession(
            channelId: channelId, userId: appState.userID, serverURL: appState.serverURL,
            accessToken: appState.accessToken, deviceId: appState.deviceId,
            deviceName: appState.clientDevice, clientVersion: appState.clientVersion, debug: debug
        )
    }

    // MARK: - Forced Fallback for Live TV
    
    private static func requestForcedTranscodingUrl(
        itemId: String, userId: String, serverURL: String, accessToken: String,
        deviceId: String, deviceName: String?, clientVersion: String,
        mediaSourceId: String?, debug: Bool
    ) async -> String? {
        do {
            // For Live TV Fallback: Force standard HLS (ts container) and H.264.
            // This prevents fMP4 initialization atom issues with active tuners.
            let (_, turl, _, _) = try await JFPlaybackInfoService.fetchPlaybackInfoWithTranscodingUrl(
                itemId: itemId, userId: userId, serverURL: serverURL, accessToken: accessToken,
                deviceId: deviceId, deviceName: deviceName, clientVersion: clientVersion,
                maxBitrate: 60_000_000,
                enableDirectPlay: false,
                enableDirectStream: false, // Force it to generate a new playlist
                enableTranscoding: true,
                requireAvc: true,
                audioCodec: "aac,ac3",
                videoCodec: "h264",
                transcodingProtocol: "hls",
                transcodingContainer: "ts", // strictly ts for live tuner stability
                allowVideoStreamCopy: true,
                allowAudioStreamCopy: true,
                mediaSourceId: mediaSourceId,
                debug: debug,
                isLiveTV: true
            )
            return turl
        } catch {
            if debug { print("[ForcedTranscode] error: \(error)") }
            return nil
        }
    }
}
