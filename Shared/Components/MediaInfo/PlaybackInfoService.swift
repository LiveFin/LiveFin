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
    static func fetchPlaybackInfo(appState: AppState, itemId: String, debug: Bool = false, isLiveTV: Bool = false) async throws -> PlaybackInfoResponse {
        try await fetchPlaybackInfo(
            itemId: itemId,
            userId: appState.userID,
            serverURL: appState.serverURL,
            accessToken: appState.accessToken,
            deviceId: appState.deviceId,
            deviceName: appState.clientDevice,
            clientVersion: appState.clientVersion,
            debug: debug,
            isLiveTV: isLiveTV
        )
    }

    static func fetchPlaybackInfoWithTranscodingUrl(appState: AppState, itemId: String, debug: Bool = false, isLiveTV: Bool = false) async throws -> (PlaybackInfoResponse, String?, String?, String?) {
        try await fetchPlaybackInfoWithTranscodingUrl(
            itemId: itemId,
            userId: appState.userID,
            serverURL: appState.serverURL,
            accessToken: appState.accessToken,
            deviceId: appState.deviceId,
            deviceName: appState.clientDevice,
            clientVersion: appState.clientVersion,
            debug: debug,
            isLiveTV: isLiveTV
        )
    }

    private static func buildDeviceProfile(maxBitrate: Int?, isLiveTV: Bool) -> [String: Any] {
        var profile: [String: Any] = [:]
        
        profile["Name"] = "LiveFin iOS"
        profile["MaxStreamingBitrate"] = maxBitrate ?? 140_000_000

        profile["DirectPlayProfiles"] = [[
            "Container": "mp4,m4v,mov",
            "Type": "Video",
            "AudioCodec": "aac,ac3,eac3,mp3,alac,flac",
            "VideoCodec": "h264,hevc,h265"
        ], [
            "Container": "m3u8",
            "Type": "Video",
            "AudioCodec": "aac,ac3,eac3,mp3,flac",
            "VideoCodec": "h264,hevc,h265"
        ], [
            "Container": "aac,mp3,alac,flac,m4a,m4b,wav",
            "Type": "Audio"
        ]]

        var transcodingProfiles: [[String: Any]] = []
        
        let mp4TranscodeProfile: [String: Any] = [
            "Container": "mp4",
            "Type": "Video",
            "AudioCodec": "aac,ac3,mp3,alac,flac,eac3",
            "VideoCodec": "hevc,h265,h264",
            "Protocol": "hls",
            "Context": "Streaming",
            "MaxAudioChannels": "6",
            "MinSegments": 1
        ]
        
        let tsTranscodeProfile: [String: Any] = [
            "Container": "ts",
            "Type": "Video",
            "AudioCodec": "aac,ac3,mp3",
            "VideoCodec": "h264",
            "Protocol": "hls",
            "Context": "Streaming",
            "MaxAudioChannels": "6",
            "MinSegments": 1
        ]
        
        if isLiveTV {
            transcodingProfiles.append(tsTranscodeProfile)
            transcodingProfiles.append(mp4TranscodeProfile)
        } else {
            transcodingProfiles.append(mp4TranscodeProfile)
            transcodingProfiles.append(tsTranscodeProfile)
        }
        
        transcodingProfiles.append(contentsOf: [[
            "Container": "mp3", "Type": "Audio", "AudioCodec": "mp3", "Protocol": "http", "Context": "Streaming", "MaxAudioChannels": "2"
        ], [
            "Container": "aac", "Type": "Audio", "AudioCodec": "aac", "Protocol": "http", "Context": "Streaming", "MaxAudioChannels": "2"
        ]])
        
        profile["TranscodingProfiles"] = transcodingProfiles

        // Restored "External" delivery method so Direct Play doesn't force a heavy burn-in transcode
        profile["SubtitleProfiles"] = [[
            "Format": "srt", "Method": "External"
        ], [
            "Format": "subrip", "Method": "External"
        ], [
            "Format": "srt", "Method": "Hls"
        ], [
            "Format": "subrip", "Method": "Hls"
        ], [
            "Format": "vtt", "Method": "External"
        ],[
            "Format": "vtt", "Method": "Hls"
        ], [
            "Format": "ass", "Method": "External"
        ], [
            "Format": "ssa", "Method": "External"
        ]]

        var h264Conditions: [[String: Any]] = [
            [ "Condition": "LessThanEqual", "Property": "VideoLevel", "Value": "52" ]
        ]
        
        var hevcConditions: [[String: Any]] = [
            [ "Condition": "LessThanEqual", "Property": "VideoLevel", "Value": "183" ],
            [ "Condition": "LessThanEqual", "Property": "VideoBitDepth", "Value": "10", "IsRequired": false ],
            [ "Condition": "EqualsAny", "Property": "VideoRangeType", "Value": "SDR,HDR10,HLG,DOVI", "IsRequired": false ],
            [ "Condition": "EqualsAny", "Property": "VideoProfile", "Value": "Main,Main 10,Main10", "IsRequired": false ],
            [ "Condition": "NotEquals", "Property": "VideoCodecTag", "Value": "hev1" ]
        ]

        if isLiveTV {
            let interlacedRule: [String: Any] = [
                "Condition": "Equals",
                "Property": "IsInterlaced",
                "Value": "false"
            ]
            h264Conditions.append(interlacedRule)
            hevcConditions.append(interlacedRule)
        }

        profile["CodecProfiles"] = [[
            "Type": "Video", "Codec": "h264", "Conditions": h264Conditions
        ], [
            "Type": "Video", "Codec": "hevc,h265", "Conditions": hevcConditions
        ], [
            "Type": "Audio", "Codec": "aac", "Conditions": [[
                "Condition": "LessThanEqual", "Property": "AudioChannels", "Value": "6"
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
        subtitleStreamIndex: Int? = nil,
        transcodingProtocol: String? = nil,
        transcodingContainer: String? = nil,
        allowVideoStreamCopy: Bool? = nil,
        allowAudioStreamCopy: Bool? = nil,
        mediaSourceId: String? = nil,
        transcodingUrl: String? = nil,
        debug: Bool = false,
        isLiveTV: Bool = false
    ) async throws -> PlaybackInfoResponse {
        let deviceInfo = await MainActor.run {
            return (name: UIDevice.current.name, model: UIDevice.current.model, system: UIDevice.current.systemName, version: UIDevice.current.systemVersion)
        }
        let resolvedDeviceName = deviceName ?? deviceInfo.name
        let base = serverURL.hasSuffix("/") ? String(serverURL.dropLast()) : serverURL
        let url = URL(string: "\(base)/Items/\(itemId)/PlaybackInfo")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        
        // Modern Authorization Header for Jellyfin v12+
        let modernAuthHeader = "MediaBrowser Client=\"LiveFin\", Device=\"\(resolvedDeviceName)\", DeviceId=\"\(deviceId)\", Version=\"\(clientVersion)\", Token=\"\(accessToken)\""
        request.setValue(modernAuthHeader, forHTTPHeaderField: "Authorization")
        
        let userAgent = "LiveFin/\(clientVersion) (\(deviceInfo.model); \(deviceInfo.system) \(deviceInfo.version))"
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        
        var body: [String: Any] = [
            "UserId": userId,
            "MaxStreamingBitrate": maxBitrate ?? 140_000_000,
            "AutoOpenLiveStream": true,
            "EnableDirectPlay": enableDirectPlay,
            "EnableDirectStream": enableDirectStream,
            "EnableTranscoding": enableTranscoding,
            "EnableAdaptiveBitrateStreaming": false,
            "RequireAvc": requireAvc ?? false
        ]
        
        if let subIndex = subtitleStreamIndex {
            body["SubtitleStreamIndex"] = subIndex
        }
        
        body["AudioCodec"] = audioCodec ?? "aac,ac3,eac3,mp3,alac,flac"
        body["VideoCodec"] = videoCodec ?? "hevc,h265,h264"
        body["TranscodingProtocol"] = transcodingProtocol ?? "hls"
        body["TranscodingContainer"] = transcodingContainer ?? (isLiveTV ? "ts" : "mp4")
        
        body["AllowVideoStreamCopy"] = allowVideoStreamCopy ?? false
        body["AllowAudioStreamCopy"] = allowAudioStreamCopy ?? true
        
        if let ms = mediaSourceId { body["MediaSourceId"] = ms }
        if enableTranscoding {
            body["DeviceProfile"] = buildDeviceProfile(maxBitrate: maxBitrate ?? 140_000_000, isLiveTV: isLiveTV)
        }
        
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
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
        subtitleStreamIndex: Int? = nil,
        transcodingProtocol: String? = nil,
        transcodingContainer: String? = nil,
        allowVideoStreamCopy: Bool? = nil,
        allowAudioStreamCopy: Bool? = nil,
        mediaSourceId: String? = nil,
        transcodingUrl: String? = nil,
        debug: Bool = false,
        isLiveTV: Bool = false
    ) async throws -> (PlaybackInfoResponse, String?, String?, String?) {
        let deviceInfo = await MainActor.run {
            return (name: UIDevice.current.name, model: UIDevice.current.model, system: UIDevice.current.systemName, version: UIDevice.current.systemVersion)
        }
        let resolvedDeviceName = deviceName ?? deviceInfo.name
        let base = serverURL.hasSuffix("/") ? String(serverURL.dropLast()) : serverURL
        let url = URL(string: "\(base)/Items/\(itemId)/PlaybackInfo")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        
        // Modern Authorization Header for Jellyfin v12+
        let modernAuthHeader = "MediaBrowser Client=\"LiveFin\", Device=\"\(resolvedDeviceName)\", DeviceId=\"\(deviceId)\", Version=\"\(clientVersion)\", Token=\"\(accessToken)\""
        request.setValue(modernAuthHeader, forHTTPHeaderField: "Authorization")
        
        let userAgent = "LiveFin/\(clientVersion) (\(deviceInfo.model); \(deviceInfo.system) \(deviceInfo.version))"
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        
        var body: [String: Any] = [
            "UserId": userId,
            "MaxStreamingBitrate": maxBitrate ?? 140_000_000,
            "AutoOpenLiveStream": true,
            "EnableDirectPlay": enableDirectPlay,
            "EnableDirectStream": enableDirectStream,
            "EnableTranscoding": enableTranscoding,
            "EnableAdaptiveBitrateStreaming": false,
            "RequireAvc": requireAvc ?? false
        ]
        
        if let subIndex = subtitleStreamIndex {
            body["SubtitleStreamIndex"] = subIndex
        }
        
        body["AudioCodec"] = audioCodec ?? "aac,ac3,eac3,mp3,alac,flac"
        body["VideoCodec"] = videoCodec ?? "hevc,h265,h264"
        body["TranscodingProtocol"] = transcodingProtocol ?? "hls"
        body["TranscodingContainer"] = transcodingContainer ?? (isLiveTV ? "ts" : "mp4")
        
        body["AllowVideoStreamCopy"] = allowVideoStreamCopy ?? true
        body["AllowAudioStreamCopy"] = allowAudioStreamCopy ?? true
        
        if let ms = mediaSourceId { body["MediaSourceId"] = ms }
        if enableTranscoding {
            body["DeviceProfile"] = buildDeviceProfile(maxBitrate: maxBitrate ?? 140_000_000, isLiveTV: isLiveTV)
        }
        
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        
        let playback = try JSONDecoder().decode(PlaybackInfoResponse.self, from: data)
        var outTranscodingUrl: String? = nil
        var mediaSourceIdOut: String? = nil
        var playSessionId: String? = nil
        
        if let jsonRoot = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let rootTranscodeRaw: String? = (
                (jsonRoot["TranscodingUrl"] as? String) ??
                (jsonRoot["TranscodingURL"] as? String) ??
                (jsonRoot["transcodingUrl"] as? String)
            )?.trimmingCharacters(in: .whitespacesAndNewlines)
            let rootIsHls = rootTranscodeRaw?.lowercased().contains(".m3u8") == true
            
            if let msArr = (jsonRoot["MediaSources"] as? [[String: Any]]) ?? (jsonRoot["mediaSources"] as? [[String: Any]]) {
                var hlsWithTranscode: (url: String, id: String?)? = nil
                var tsWithTranscode: (url: String, id: String?)? = nil
                var firstWithTranscode: (url: String, id: String?)? = nil
                
                for ms in msArr {
                    let turlRaw = ((ms["TranscodingUrl"] as? String) ?? (ms["TranscodingURL"] as? String) ?? (ms["transcodingUrl"] as? String))?.trimmingCharacters(in: .whitespacesAndNewlines)
                    let mid = (ms["Id"] as? String) ?? (ms["id"] as? String)
                    let container = (ms["Container"] as? String) ?? (ms["container"] as? String)
                    
                    guard let turl = turlRaw, !turl.isEmpty else { continue }
                    if firstWithTranscode == nil { firstWithTranscode = (turl, mid) }
                    if turl.lowercased().contains(".m3u8") { hlsWithTranscode = (turl, mid) }
                    if (container?.lowercased() == "ts") { tsWithTranscode = (turl, mid) }
                }
                
                if let chosen = hlsWithTranscode {
                    outTranscodingUrl = chosen.url
                    mediaSourceIdOut = chosen.id
                } else if let chosen = tsWithTranscode {
                    outTranscodingUrl = chosen.url
                    mediaSourceIdOut = chosen.id
                } else if let root = rootTranscodeRaw, !root.isEmpty, rootIsHls {
                    outTranscodingUrl = root
                } else if let chosen = firstWithTranscode {
                    outTranscodingUrl = chosen.url
                    mediaSourceIdOut = chosen.id
                } else if let root = rootTranscodeRaw, !root.isEmpty {
                    outTranscodingUrl = root
                } else {
                    if let first = msArr.first { mediaSourceIdOut = (first["Id"] as? String) ?? (first["id"] as? String) }
                }
            } else {
                if let root = rootTranscodeRaw, !root.isEmpty { outTranscodingUrl = root }
            }
            playSessionId = (jsonRoot["PlaySessionId"] as? String) ?? (jsonRoot["playSessionId"] as? String)
        }
        return (playback, outTranscodingUrl, mediaSourceIdOut, playSessionId)
    }
}
