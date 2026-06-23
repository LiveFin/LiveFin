//
//  PlaybackInfoService.swift
//  LiveFin
//
//  Created by KPGamingz on 5/17/25.
//

import Foundation
import JellyfinAPI
import UIKit

struct JFPlaybackInfoService {
    static func fetchPlaybackInfo(appState: AppState, itemId: String, debug: Bool = false) async throws -> PlaybackInfoResponse {
        try await fetchPlaybackInfo(
            itemId: itemId,
            userId: appState.userID,
            serverURL: appState.serverURL,
            accessToken: appState.accessToken,
            deviceId: appState.deviceId,
            deviceName: appState.clientDevice,
            clientVersion: appState.clientVersion,
            debug: debug
        )
    }

    static func fetchPlaybackInfoWithTranscodingUrl(appState: AppState, itemId: String, debug: Bool = false) async throws -> (PlaybackInfoResponse, String?, String?, String?) {
        try await fetchPlaybackInfoWithTranscodingUrl(
            itemId: itemId,
            userId: appState.userID,
            serverURL: appState.serverURL,
            accessToken: appState.accessToken,
            deviceId: appState.deviceId,
            deviceName: appState.clientDevice,
            clientVersion: appState.clientVersion,
            debug: debug
        )
    }

    private static func buildDeviceProfile(maxBitrate: Int?) -> [String: Any] {
        var profile: [String: Any] = [:]
        
        profile["Name"] = "Apple LiveFin iOS"
        
        if let max = maxBitrate { profile["MaxStreamingBitrate"] = max }

        // DirectPlayProfiles: Defines what AVPlayer can play directly without server help.
        profile["DirectPlayProfiles"] = [[
            "Container": "mp4,m4v,mov",
            "Type": "Video",
            "AudioCodec": "aac,ac3,eac3,mp3,alac,flac",
            "VideoCodec": "h264" // 💥 FIX: Removed hevc/h265 here. If we DirectPlay an MP4 with hev1, iOS shows the QuickTime icon! We MUST force HLS for HEVC.
        ], [
            "Container": "m3u8", // Native Apple HLS
            "Type": "Video",
            "AudioCodec": "aac,ac3,eac3,mp3,flac",
            "VideoCodec": "hevc,h265,h264"
        ], [
            "Container": "aac,mp3,alac,flac,m4a,m4b,wav",
            "Type": "Audio"
        ]]

        // TranscodingProfiles: Configures how Jellyfin remuxes/transcodes streams.
        // Re-ordered to ensure fMP4 container tries HEVC first over TS.
        profile["TranscodingProfiles"] = [[
            "Container": "mp4", // Triggers fMP4 (Fragmented MP4) in HLS for HEVC
            "Type": "Video",
            "AudioCodec": "aac,ac3,mp3,alac,flac,eac3",
            "VideoCodec": "hevc,h265,h264",
            "Protocol": "hls",
            "Context": "Streaming",
            "MaxAudioChannels": "6",
            "MinSegments": 2
        ], [
            "Container": "ts",
            "Type": "Video",
            "AudioCodec": "aac,ac3,mp3",
            "VideoCodec": "h264",
            "Protocol": "hls",
            "Context": "Streaming",
            "MaxAudioChannels": "6",
            "MinSegments": 2
        ], [
            "Container": "mp3",
            "Type": "Audio",
            "AudioCodec": "mp3",
            "Protocol": "http",
            "Context": "Streaming",
            "MaxAudioChannels": "2"
        ], [
            "Container": "aac",
            "Type": "Audio",
            "AudioCodec": "aac",
            "Protocol": "http",
            "Context": "Streaming",
            "MaxAudioChannels": "2"
        ], [
            "Container": "mp4",
            "Type": "Audio",
            "AudioCodec": "aac,alac",
            "Protocol": "hls",
            "Context": "Streaming",
            "MaxAudioChannels": "2",
            "MinSegments": 2
        ]]

        // CodecProfiles: Declares exact capabilities of the iOS decoder.
        profile["CodecProfiles"] = [[
            "Type": "Video",
            "Codec": "h264",
            "Conditions": [[
                "Condition": "LessThanEqual",
                "Property": "VideoLevel",
                "Value": "52"
            ]]
        ], [
            "Type": "Video",
            "Codec": "hevc,h265",
            "Conditions": [[
                "Condition": "LessThanEqual",
                "Property": "VideoLevel",
                "Value": "183"
            ], [
                "Condition": "LessThanEqual",
                "Property": "VideoBitDepth",
                "Value": "10" // Explicitly declare 10-bit color support
            ]]
        ], [
            "Type": "Audio",
            "Codec": "aac",
            "Conditions": [[
                "Condition": "LessThanEqual",
                "Property": "AudioChannels",
                "Value": "6"
            ]]
        ]]
        
        return profile
    }

    static func fetchPlaybackInfo(
        itemId: String,
        userId: String,
        serverURL: String,
        accessToken: String,
        deviceId: String,
        deviceName: String? = nil,
        clientVersion: String = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0",
        maxBitrate: Int? = nil,
        enableDirectPlay: Bool = false,
        enableDirectStream: Bool = true,
        enableTranscoding: Bool = true,
        requireAvc: Bool? = nil,
        audioCodec: String? = nil,
        videoCodec: String? = nil,
        transcodingProtocol: String? = nil,
        transcodingContainer: String? = nil,
        allowVideoStreamCopy: Bool? = nil,
        allowAudioStreamCopy: Bool? = nil,
        mediaSourceId: String? = nil,
        transcodingUrl: String? = nil,
        debug: Bool = false
    ) async throws -> PlaybackInfoResponse {
        let deviceInfo = await MainActor.run {
            return (
                name: UIDevice.current.name,
                model: UIDevice.current.model,
                system: UIDevice.current.systemName,
                version: UIDevice.current.systemVersion
            )
        }
        let resolvedDeviceName = deviceName ?? deviceInfo.name
        let base = serverURL.hasSuffix("/") ? String(serverURL.dropLast()) : serverURL
        let url = URL(string: "\(base)/Items/\(itemId)/PlaybackInfo")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(accessToken, forHTTPHeaderField: "X-Emby-Token")
        let authHeader = "MediaBrowser Client=\"LiveFin\", Device=\"\(resolvedDeviceName)\", DeviceId=\"\(deviceId)\", Version=\"\(clientVersion)\""
        request.setValue(authHeader, forHTTPHeaderField: "X-Emby-Authorization")
        request.setValue(userId, forHTTPHeaderField: "X-Emby-User-Id")
        request.setValue("LiveFin", forHTTPHeaderField: "X-Emby-Client")
        request.setValue(resolvedDeviceName, forHTTPHeaderField: "X-Emby-Device-Name")
        request.setValue(deviceId, forHTTPHeaderField: "X-Emby-Device-Id")
        request.setValue(clientVersion, forHTTPHeaderField: "X-Emby-Client-Version")
        
        let userAgent = "LiveFin/\(clientVersion) (\(deviceInfo.model); \(deviceInfo.system) \(deviceInfo.version))"
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        
        var body: [String: Any] = [
            "UserId": userId,
            "MaxStreamingBitrate": maxBitrate ?? 60_000_000,
            "AutoOpenLiveStream": true,
            "EnableDirectPlay": enableDirectPlay,
            "EnableDirectStream": enableDirectStream,
            "EnableTranscoding": enableTranscoding,
            "EnableAdaptiveBitrateStreaming": true,
            "RequireAvc": requireAvc ?? false
        ]
        
        // Ensure codecs are injected even if nil to stop server from defaulting to non-HDR H264 transcodes
        body["AudioCodec"] = audioCodec ?? "aac,ac3,eac3,mp3,alac,flac"
        body["VideoCodec"] = videoCodec ?? "hevc,h265,h264"
        
        body["TranscodingProtocol"] = transcodingProtocol ?? "hls"
        body["TranscodingContainer"] = transcodingContainer ?? "mp4"
        
        if let avs = allowVideoStreamCopy { body["AllowVideoStreamCopy"] = avs }
        if let aas = allowAudioStreamCopy { body["AllowAudioStreamCopy"] = aas }
        if let ms = mediaSourceId { body["MediaSourceId"] = ms }
        if enableTranscoding {
            body["DeviceProfile"] = buildDeviceProfile(maxBitrate: maxBitrate ?? 60_000_000)
        }
        
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        if httpResponse.statusCode != 200 {
            if debug { let bodyText = String(data: data, encoding: .utf8) ?? "<unreadable body>"; print("DEBUG: PlaybackInfo failed (\(httpResponse.statusCode)) body=\(bodyText)") }
            throw URLError(.badServerResponse)
        }
        if debug, let jsonStr = String(data: data, encoding: .utf8) { print("[PlaybackInfo RAW] \(jsonStr)") }
        return try JSONDecoder().decode(PlaybackInfoResponse.self, from: data)
    }

    static func fetchPlaybackInfoWithTranscodingUrl(
        itemId: String,
        userId: String,
        serverURL: String,
        accessToken: String,
        deviceId: String,
        deviceName: String? = nil,
        clientVersion: String = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0",
        maxBitrate: Int? = nil,
        enableDirectPlay: Bool = false,
        enableDirectStream: Bool = true,
        enableTranscoding: Bool = true,
        requireAvc: Bool? = nil,
        audioCodec: String? = nil,
        videoCodec: String? = nil,
        transcodingProtocol: String? = nil,
        transcodingContainer: String? = nil,
        allowVideoStreamCopy: Bool? = nil,
        allowAudioStreamCopy: Bool? = nil,
        mediaSourceId: String? = nil,
        transcodingUrl: String? = nil,
        debug: Bool = false
    ) async throws -> (PlaybackInfoResponse, String?, String?, String?) {
        let deviceInfo = await MainActor.run {
            return (
                name: UIDevice.current.name,
                model: UIDevice.current.model,
                system: UIDevice.current.systemName,
                version: UIDevice.current.systemVersion
            )
        }
        let resolvedDeviceName = deviceName ?? deviceInfo.name
        let base = serverURL.hasSuffix("/") ? String(serverURL.dropLast()) : serverURL
        let url = URL(string: "\(base)/Items/\(itemId)/PlaybackInfo")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(accessToken, forHTTPHeaderField: "X-Emby-Token")
        let authHeader = "MediaBrowser Client=\"LiveFin\", Device=\"\(resolvedDeviceName)\", DeviceId=\"\(deviceId)\", Version=\"\(clientVersion)\""
        request.setValue(authHeader, forHTTPHeaderField: "X-Emby-Authorization")
        request.setValue(userId, forHTTPHeaderField: "X-Emby-User-Id")
        request.setValue("LiveFin", forHTTPHeaderField: "X-Emby-Client")
        request.setValue(resolvedDeviceName, forHTTPHeaderField: "X-Emby-Device-Name")
        request.setValue(deviceId, forHTTPHeaderField: "X-Emby-Device-Id")
        request.setValue(clientVersion, forHTTPHeaderField: "X-Emby-Client-Version")
        
        let userAgent = "LiveFin/\(clientVersion) (\(deviceInfo.model); \(deviceInfo.system) \(deviceInfo.version))"
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        
        var body: [String: Any] = [
            "UserId": userId,
            "MaxStreamingBitrate": maxBitrate ?? 60_000_000,
            "AutoOpenLiveStream": true,
            "EnableDirectPlay": enableDirectPlay,
            "EnableDirectStream": enableDirectStream,
            "EnableTranscoding": enableTranscoding,
            "EnableAdaptiveBitrateStreaming": true,
            "RequireAvc": requireAvc ?? false
        ]
        
        body["AudioCodec"] = audioCodec ?? "aac,ac3,eac3,mp3,alac,flac"
        body["VideoCodec"] = videoCodec ?? "hevc,h265,h264"
        
        body["TranscodingProtocol"] = transcodingProtocol ?? "hls"
        body["TranscodingContainer"] = transcodingContainer ?? "mp4"
        
        if let avs = allowVideoStreamCopy { body["AllowVideoStreamCopy"] = avs }
        if let aas = allowAudioStreamCopy { body["AllowAudioStreamCopy"] = aas }
        if let ms = mediaSourceId { body["MediaSourceId"] = ms }
        if enableTranscoding {
            body["DeviceProfile"] = buildDeviceProfile(maxBitrate: maxBitrate ?? 60_000_000)
        }
        
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            if debug { let bodyText = String(data: data, encoding: .utf8) ?? "<unreadable body>"; print("[PlaybackInfoWithTranscodingUrl] HTTP error: \((response as? HTTPURLResponse)?.statusCode ?? -1) body=\(bodyText)") }
            throw URLError(.badServerResponse)
        }
        if debug, let jsonStr = String(data: data, encoding: .utf8) { print("[PlaybackInfo RAW] \(jsonStr)") }
        let playback = try JSONDecoder().decode(PlaybackInfoResponse.self, from: data)
        var transcodingUrl: String? = nil
        var mediaSourceIdOut: String? = nil
        var playSessionId: String? = nil
        if let jsonRoot = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let rootTranscodeRaw: String? = (
                (jsonRoot["TranscodingUrl"] as? String) ??
                (jsonRoot["TranscodingURL"] as? String) ??
                (jsonRoot["transcodingUrl"] as? String) ??
                (jsonRoot["transcodingURL"] as? String)
            )?.trimmingCharacters(in: .whitespacesAndNewlines)
            let rootIsHls = rootTranscodeRaw?.lowercased().contains(".m3u8") == true
            if let msArr = (jsonRoot["MediaSources"] as? [[String: Any]]) ?? (jsonRoot["mediaSources"] as? [[String: Any]]) {
                if debug {
                    print("[PlaybackInfo] MediaSources summary (count=\(msArr.count)):")
                    for (idx, ms) in msArr.enumerated() {
                        let mid = (ms["Id"] as? String) ?? (ms["id"] as? String) ?? "<nil>"
                        let cont = ((ms["Container"] as? String) ?? (ms["container"] as? String) ?? "").lowercased()
                        let supT = (ms["SupportsTranscoding"] as? Bool) ?? (ms["supportsTranscoding"] as? Bool) ?? false
                        let turl = (
                            (ms["TranscodingUrl"] as? String) ??
                            (ms["TranscodingURL"] as? String) ??
                            (ms["transcodingUrl"] as? String) ??
                            (ms["transcodingURL"] as? String)
                        )
                        let isHls = turl?.lowercased().contains(".m3u8") == true
                        print("  [\(idx)] id=\(mid) container=\(cont) supportsTranscoding=\(supT) hasTranscodingUrl=\(turl != nil) hls=\(isHls)")
                    }
                }
                var hlsWithTranscode: (url: String, id: String?)? = nil
                var tsWithTranscode: (url: String, id: String?)? = nil
                var firstWithTranscode: (url: String, id: String?)? = nil
                for ms in msArr {
                    let turlRaw = (
                        (ms["TranscodingUrl"] as? String) ??
                        (ms["TranscodingURL"] as? String) ??
                        (ms["transcodingUrl"] as? String) ??
                        (ms["transcodingURL"] as? String)
                    )?.trimmingCharacters(in: .whitespacesAndNewlines)
                    let mid = (ms["Id"] as? String) ?? (ms["id"] as? String)
                    let container = (ms["Container"] as? String) ?? (ms["container"] as? String)
                    guard let turl = turlRaw, !turl.isEmpty else { continue }
                    if firstWithTranscode == nil { firstWithTranscode = (turl, mid) }
                    if turl.lowercased().contains(".m3u8") { hlsWithTranscode = (turl, mid) }
                    if (container?.lowercased() == "ts") { tsWithTranscode = (turl, mid) }
                }
                if let chosen = hlsWithTranscode {
                    transcodingUrl = chosen.url
                    mediaSourceIdOut = chosen.id
                } else if let chosen = tsWithTranscode {
                    transcodingUrl = chosen.url
                    mediaSourceIdOut = chosen.id
                } else if let root = rootTranscodeRaw, !root.isEmpty, rootIsHls {
                    transcodingUrl = root
                } else if let chosen = firstWithTranscode {
                    transcodingUrl = chosen.url
                    mediaSourceIdOut = chosen.id
                } else if let root = rootTranscodeRaw, !root.isEmpty {
                    transcodingUrl = root
                } else {
                    if let first = msArr.first {
                        mediaSourceIdOut = (first["Id"] as? String) ?? (first["id"] as? String)
                    }
                }
            } else {
                if let root = rootTranscodeRaw, !root.isEmpty { transcodingUrl = root }
            }
            playSessionId = (jsonRoot["PlaySessionId"] as? String) ?? (jsonRoot["playSessionId"] as? String)
        }
        return (playback, transcodingUrl, mediaSourceIdOut, playSessionId)
    }
}
