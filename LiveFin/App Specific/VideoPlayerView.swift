//
//  VideoPlayerView.swift
//  LiveFin
//
//  Created by Kervens on 5/6/25.
//

import SwiftUI
import AVKit
import UIKit

struct VideoPlayerView: View {
    let streamURL: URL
    @State private var player: AVPlayer?
    private let observer = PlayerObserver()

    init(streamURL: URL) {
        self.streamURL = streamURL

        var headers: [String: String] = [
            "User-Agent": "LiveFin iOS",
        ]

        if let token = UserDefaults.standard.string(forKey: "accessToken") {
            headers["X-Emby-Token"] = token
        }

        _ = AVURLAsset(url: streamURL)
        _ = Array(headers.keys)
        let headerOptions = ["AVURLAssetHTTPHeaderFieldsKey": headers]
        let customAsset = AVURLAsset(url: streamURL, options: headerOptions)
        let item = AVPlayerItem(asset: customAsset)

        let playerInstance = AVPlayer(playerItem: item)
        _player = State(initialValue: playerInstance)

        print("Debug: Player initialized")
        print("Debug: Stream URL: \(streamURL)")
    }

    var body: some View {
        VStack {
            if let player = player {
                VideoPlayer(player: player)
                    .onAppear {
                        print("Debug: VideoPlayer appeared")
                        observer.observe(player: player)
                        player.play()
                        print("Debug: Player started playing")

                        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
                            let geometryPreferences = UIWindowScene.GeometryPreferences.iOS(interfaceOrientations: .landscapeRight)
                            windowScene.requestGeometryUpdate(geometryPreferences)
                        }
                        AppDelegate.orientationLock = .landscapeRight
                    }
                    .onDisappear {
                        player.pause()
                        print("Debug: Player paused")

                        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
                            let geometryPreferences = UIWindowScene.GeometryPreferences.iOS(interfaceOrientations: .portrait)
                            windowScene.requestGeometryUpdate(geometryPreferences)
                        }
                        AppDelegate.orientationLock = .portrait
                    }
                    .edgesIgnoringSafeArea(.all)
            } else {
                Text("Unable to load the video.")
                    .foregroundColor(.red)
                    .padding()
                    .onAppear {
                        print("Debug: Player failed to load")
                    }
            }

        }
    }
}

final class PlayerObserver: NSObject {
    private var player: AVPlayer?
    private var playerItemContext = 0

    func observe(player: AVPlayer) {
        self.player = player
        player.currentItem?.addObserver(self, forKeyPath: "status", options: [.new, .initial], context: &playerItemContext)
    }

    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
        guard context == &playerItemContext else {
            super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
            return
        }

        if keyPath == "status" {
            if let item = object as? AVPlayerItem {
                switch item.status {
                case .readyToPlay:
                    print("DEBUG: AVPlayer is ready to play")
                case .failed:
                    print("ERROR: AVPlayer failed with error: \(item.error?.localizedDescription ?? "Unknown error")")
                case .unknown:
                    print("DEBUG: AVPlayer status is unknown")
                @unknown default:
                    print("DEBUG: AVPlayer status is unexpected")
                }
            }
        }
    }

    deinit {
        player?.currentItem?.removeObserver(self, forKeyPath: "status")
    }
}
