//
//  VideoPlayerView.swift
//  LiveFin
//
//  Created by KPGamingz on 5/6/25.
//

import SwiftUI
import AVKit
import AVFoundation
import UIKit
import MediaPlayer
import Combine

extension Notification.Name {
    static let VideoPlayerStartPlayback = Notification.Name("VideoPlayerStartPlayback")
}

struct VideoPlayerView: View {
    let streamURL: URL
    let channel: LiveTvChannelDto?
    let onPlaybackError: ((String) -> Void)?

    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .topLeading) {
            PlayerViewControllerRepresentable(
                streamURL: streamURL,
                channel: channel,
                appState: appState,
                onClose: { dismiss() },
                onPlaybackError: onPlaybackError
            )
            .ignoresSafeArea()
        }
        .onAppear {
            // notify player to start (the representable should observe this and call play())
            NotificationCenter.default.post(name: .VideoPlayerStartPlayback, object: streamURL)

            if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
                let geometryPreferences = UIWindowScene.GeometryPreferences.iOS(interfaceOrientations: .landscapeRight)
                windowScene.requestGeometryUpdate(geometryPreferences)
            }
            AppDelegate.orientationLock = .landscapeRight
        }
        .onDisappear {
            // notify player to stop if needed (object=nil indicates stop)
            NotificationCenter.default.post(name: .VideoPlayerStartPlayback, object: nil)

            if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
                let geometryPreferences = UIWindowScene.GeometryPreferences.iOS(interfaceOrientations: .portrait)
                windowScene.requestGeometryUpdate(geometryPreferences)
            }
            AppDelegate.orientationLock = .portrait
        }
    }

}
