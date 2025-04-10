import SwiftUI
import JellyfinAPI

struct StreamManager {
    static func fetchStreamURL(
        programId: String,
        userId: String,
        deviceId: String,
        serverURL: String,
        accessToken: String,
        mediaSourceId: String?,
        programs: [BaseItemDto]
    ) async -> URL? {
        print("fetchStreamURL called with:")
        print("programId: \(programId)")
        print("userId: \(userId)")
        print("deviceId: \(deviceId)")
        print("serverURL: \(serverURL)")
        print("accessToken: \(accessToken)")
        
        let playbackInfoURLString = "\(serverURL)/Items/\(programId)/PlaybackInfo?UserId=\(userId)&DeviceId=\(deviceId)&access_token=\(accessToken)"
        print("Constructed playbackInfoURLString: \(playbackInfoURLString)")
        
        guard let playbackInfoURL = URL(string: playbackInfoURLString) else {
            print("Invalid playback info URL")
            return nil
        }

        var request = URLRequest(url: playbackInfoURL)
        request.httpMethod = "GET"
        request.setValue(accessToken, forHTTPHeaderField: "X-Emby-Token")
        let authorizationValue = "MediaBrowser Client=\"LiveFin\", Device=\"iOS\", DeviceId=\"\(deviceId)\", Token=\"\(accessToken)\""
        print("Authorization header: \(authorizationValue)")
        request.setValue(authorizationValue, forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse {
                print("Received response with status code: \(httpResponse.statusCode)")
                guard httpResponse.statusCode == 200 else {
                    print("Failed to fetch playback info, status code: \(httpResponse.statusCode)")
                    return nil
                }
            } else {
                print("Response was not an HTTPURLResponse")
                return nil
            }

            print("Server response contains data: \(data.count > 0)")
            struct PlaybackInfoResponse: Decodable {
                struct MediaSource: Decodable {
                    let id: String
                    let path: String?
                }
                let MediaSources: [MediaSource]
            }

            let decoder = JSONDecoder()
            do {
                let playbackInfo = try decoder.decode(PlaybackInfoResponse.self, from: data)
                print("Decoded JSON object: \(playbackInfo)")
                guard let mediaSource = playbackInfo.MediaSources.first else {
                    print("No media sources found in playback info")
                    return nil
                }

                let streamURLString = "\(serverURL)/Videos/\(programId)/stream?static=true&MediaSourceId=\(mediaSource.id)&access_token=\(accessToken)"
                print("Constructed streamURLString: \(streamURLString)")
                guard let streamURL = URL(string: streamURLString) else {
                    print("Invalid stream URL")
                    return nil
                }

                print("Final stream URL: \(streamURL)")
                return streamURL
            } catch {
                if let responseString = String(data: data, encoding: .utf8) {
                    print("Failed to decode JSON. Raw server response: \(responseString)")
                }
                print("Error decoding playback info: \(error)")
                return nil
            }

        } catch {
            print("Error fetching playback info: \(error)")
            return nil
        }
    }
}

struct PlayerView: View {
    let url: URL
    var body: some View {
        Text("Player for URL: \(url.absoluteString)")
    }
}
