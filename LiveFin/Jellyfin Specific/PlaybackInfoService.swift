//
//  PlaybackInfoService.swift
//  LiveFin
//
//  Created by KPGamingz on 5/17/25.
//


import Foundation
import JellyfinAPI

/// A service for fetching playback info from Jellyfin's /Items/{itemId}/PlaybackInfo API.
struct PlaybackInfoService {
    static func fetchPlaybackInfo(
        itemId: String,
        userId: String,
        serverURL: String,
        accessToken: String,
        maxBitrate: Int? = nil
    ) async throws -> PlaybackInfoResponse {
        let url = URL(string: "\(serverURL)/Items/\(itemId)/PlaybackInfo")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(accessToken, forHTTPHeaderField: "X-Emby-Token")

        let body: [String: Any] = [
            "UserId": userId,
            "MaxStreamingBitrate": maxBitrate ?? 8000000
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        if httpResponse.statusCode != 200 {
            let bodyText = String(data: data, encoding: .utf8) ?? "<unreadable body>"
            print("DEBUG: PlaybackInfo request failed with status: \(httpResponse.statusCode)")
            print("DEBUG: Response body: \(bodyText)")
            throw URLError(.badServerResponse)
        }

        let decoder = JSONDecoder()
        return try decoder.decode(PlaybackInfoResponse.self, from: data)
    }
}
