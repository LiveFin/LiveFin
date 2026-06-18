//
//  DemoChannelDetailView.swift
//  LiveFin
//
//  Created by KPGamingz on 9/10/25.
//

import SwiftUI

struct DemoChannelDetailView: View {
    let channel: DemoChannel
    @State private var showPlayer = false
    @State private var streamURL: URL? = nil
    // Playback error presented when demo player reports a failure
    @State private var playbackErrorMessage: String? = nil
    @EnvironmentObject var appState: AppState
    
    // Demo stream URLs for each channel (replace with real demo streams if available)
    private var demoStreamURL: URL? {
        switch channel.id {
        case "1": // Demo News
            return URL(string: "https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8")
        case "2": // Demo Sports
            return URL(string: "https://bitdash-a.akamaihd.net/content/sintel/hls/playlist.m3u8")
        case "3": // Demo Kids
            return URL(string: "https://mojenovosti.com/stream/test.m3u8")
        case "4": // Demo Movies
            return URL(string: "https://cph-p2p-msl.akamaized.net/hls/live/2000341/test/master.m3u8")
        case "5": // Demo Music
            return URL(string: "https://test-streams.mux.dev/pts_shift/master.m3u8")
        default:
            return URL(string: "https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8")
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                Image(systemName: channel.imageName)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 120, height: 120)
                    .padding()
                    .foregroundColor(.accentColor)
                Text(channel.name)
                    .font(.largeTitle)
                    .bold()
                Text("Channel \(channel.number)")
                    .font(.title2)
                    .foregroundColor(.secondary)
                Text(channel.description)
                    .font(.body)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                Button(action: {
                    streamURL = demoStreamURL
                    showPlayer = true
                }) {
                    HStack {
                        Image(systemName: "play.fill")
                            .resizable()
                            .frame(width: 16, height: 16)
                        Text("Play Demo Stream")
                            .font(.headline)
                    }
                    .padding()
                    .foregroundColor(.white)
                    .background(Color.accentColor)
                    .cornerRadius(12)
                }
                Spacer()
            }
            .padding()
        }
        .navigationTitle(channel.name)
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(isPresented: $showPlayer) {
            if let url = streamURL {
                // We don't have a remote logo URL for demo channels; pass nil.
                // Title and subtitle derived from DemoChannel.
                VideoPlayerView(
                    streamURL: url,
                    channel: nil,
                    onPlaybackError: { msg in
                        // Dismiss the player and show the alert
                        showPlayer = false
                        playbackErrorMessage = msg
                    }
                )
                .environmentObject(appState)
            }
        }
        .alert("Playback Error", isPresented: Binding(get: { playbackErrorMessage != nil }, set: { if !$0 { playbackErrorMessage = nil } })) {
            Button("OK", role: .cancel) { playbackErrorMessage = nil }
        } message: {
            Text(playbackErrorMessage ?? "An unknown error occurred while trying to play the demo stream.")
        }
    }
}

struct DemoChannelDetailView_Previews: PreviewProvider {
    static var previews: some View {
        DemoChannelDetailView(channel: DemoChannelsData.channels[0])
    }
}
