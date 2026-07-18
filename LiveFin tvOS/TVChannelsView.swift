//
//  TVChannelsView.swift
//  LiveFin
//
//  Created by Kervens on 7/17/26.
//


//
//  TVChannelsView.swift
//  LiveFin tvOS
//

import SwiftUI

struct TVChannelsView: View {
    @EnvironmentObject var appState: TVAppState
    
    // tvOS favors horizontal flow or wide grids for focus engines
    let columns = [
        GridItem(.adaptive(minimum: 320), spacing: 50)
    ]
    
    var body: some View {
        NavigationView {
            ScrollView {
                if appState.isLoadingChannels && appState.channels.isEmpty {
                    ProgressView("Loading Channels...")
                        .padding(.top, 100)
                } else if appState.channels.isEmpty {
                    Text("No channels found.")
                        .foregroundColor(.secondary)
                        .padding(.top, 100)
                } else {
                    LazyVGrid(columns: columns, spacing: 50) {
                        ForEach(appState.channels) { channel in
                            NavigationLink(destination: TVPlayerView(channel: channel)) {
                                TVChannelCard(channel: channel)
                            }
                            .buttonStyle(.card) // Native tvOS hover/focus effect
                        }
                    }
                    .padding(60)
                }
            }
            .navigationTitle("Live TV")
        }
        .task {
            await appState.loadChannels()
        }
    }
}

struct TVChannelCard: View {
    let channel: TVChannel
    
    var body: some View {
        VStack {
            // Placeholder for Channel Image
            ZStack {
                Rectangle()
                    .fill(Color.gray.opacity(0.3))
                    .aspectRatio(16/9, contentMode: .fill)
                
                Image(systemName: "tv")
                    .font(.system(size: 60))
                    .foregroundColor(.white.opacity(0.5))
            }
            .cornerRadius(12)
            
            HStack {
                if let num = channel.number {
                    Text(num)
                        .font(.headline)
                        .foregroundColor(.secondary)
                }
                
                Text(channel.name ?? "Unknown Channel")
                    .font(.headline)
                    .lineLimit(1)
                
                Spacer()
            }
            .padding(.top, 8)
            .padding(.horizontal, 4)
        }
        .frame(width: 320)
    }
}