//
//  TVPlayerView.swift
//  LiveFin
//

import SwiftUI
import AVKit

/// A clean routing wrapper that delegates playback to the correct dedicated player view:
/// - Live TV channels route to `TVLivePlayerView`
/// - VOD items route to `TVLibraryPlayerView`
struct TVPlayerView: View {
    let item: JFItemDto?
    let channel: JFChannel?
    
    @EnvironmentObject var appState: AppState
    
    init(item: JFItemDto? = nil, channel: JFChannel? = nil) {
        self.item = item
        self.channel = channel
    }
    
    var body: some View {
        ZStack {
            if let channel = channel {
                // Route live channels to the dedicated live player view
                TVDragonetPlayerView(channel: channel)
                    .environmentObject(appState)
            } else if let item = item {
                // Route VOD library content to the custom library player playlist
                TVPlanktonPlayerView(playlist: [item], startIndex: 0)
                    .environmentObject(appState)
            } else {
                Color.black.ignoresSafeArea()
            }
        }
    }
}
