//
//  GetLiveStream.swift
//  LiveFin
//
//  Created by KPGamingz on 5/6/25.
//

import Foundation

struct LiveTVStreamService {
    static func fetchStreamURL(
        streamID: String,
        container: String,
        serverURL: String,
        accessToken: String
    ) async -> URL? {
        let playbackInfoURLString = "\(serverURL)/LiveTv/LiveStreamFiles/\(streamID)/stream.\(container)"

        guard let playbackInfoURL = URL(string: playbackInfoURLString) else {
            print("Invalid playback info URL")
            return nil
        }

        var request = URLRequest(url: playbackInfoURL)
        request.httpMethod = "GET"
        request.setValue(accessToken, forHTTPHeaderField: "X-Emby-Token")

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                print("Invalid response")
                return nil
            }

            guard httpResponse.statusCode == 200 else {
                print("Unexpected HTTP status code: \(httpResponse.statusCode)")
                return nil
            }

            return playbackInfoURL
        } catch {
            print("Error fetching stream URL: \(error)")
            return nil
        }
    }
}
