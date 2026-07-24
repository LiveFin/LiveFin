//
//  TVChannelsView.swift
//  LiveFin
//
//  Created by Kervens on 7/17/26.
//

import SwiftUI

struct TVChannelsView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var homeVM: HomeViewModel

    private let columns = [GridItem(.adaptive(minimum: 220, maximum: 260), spacing: 40)]

    var body: some View {
        /* STREAMING_CHUNK:Rendering the main channels grid... */
        NavigationStack {
            Group {
                if homeVM.channels.isEmpty && homeVM.isLoading {
                    ProgressView().scaleEffect(1.4)
                } else if homeVM.channels.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "tv.slash").font(.system(size: 56)).foregroundColor(.secondary)
                        Text("No channels found").font(.title2).bold()
                    }
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 40) {
                            ForEach(homeVM.channels) { channel in
                                // Route directly to the TVPlayerView for immediate playback on tvOS
                                NavigationLink(destination: TVPlayerView(channel: channel)
                                    .environmentObject(appState)) {
                                    channelTile(channel)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(60)
                    }
                }
            }
            .navigationTitle("Channels")
            .task {
                guard homeVM.channels.isEmpty, !appState.serverURL.isEmpty else { return }
                await homeVM.refresh(appState: appState, force: true)
            }
        }
    }

    private func channelTile(_ channel: JFChannel) -> some View {
        VStack(spacing: 10) {
            ZStack(alignment: .topTrailing) {
                ChannelImageView(baseUrl: appState.serverURL, apiKey: appState.apiKey, channelId: channel.id)
                    .frame(width: 220, height: 130)
                    .background(Color.secondary.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                if channel.isFavorite {
                    Image(systemName: "heart.fill")
                        .foregroundColor(.red)
                        .font(.caption)
                        .padding(6)
                        .background(Color.black.opacity(0.5))
                        .clipShape(Circle())
                        .padding(6)
                }
            }

            Text(channel.name)
                .font(.callout)
                .lineLimit(1)
        }
    }
}
