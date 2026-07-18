//
//  MultiViewChannelPickerView.swift
//  LiveFin
//
//  Created by KPGamingz on 7/14/26.
//

import SwiftUI

struct MultiViewChannelPickerView: View {
    let appState: AppState
    let activeChannelIds: [String]
    let onSelect: (URL, LiveTvChannelDto?, JFProgram?) -> Void
    
    @Environment(\.dismiss) private var dismiss
    
    @State private var channels: [LiveTvChannelDto] = []
    @State private var isLoading = true
    @State private var loadingChannelId: String? = nil

    var body: some View {
        NavigationView {
            Group {
                if isLoading {
                    ProgressView("Loading channels...")
                } else if channels.isEmpty {
                    Text("No channels found.")
                        .foregroundColor(.secondary)
                } else {
                    List(channels) { channel in
                        Button {
                            selectChannel(channel)
                        } label: {
                            HStack(spacing: 12) {
                                ChannelImageView(
                                    baseUrl: appState.serverURL,
                                    apiKey: appState.accessToken,
                                    channelId: channel.id
                                )
                                .frame(width: 44, height: 44)
                                
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(channel.name ?? "Unknown Channel")
                                        .font(.headline)
                                        .foregroundColor(.primary)
                                    
                                    if let progName = channel.currentProgram?.name {
                                        Text(progName)
                                            .font(.subheadline)
                                            .foregroundColor(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                                
                                Spacer()
                                
                                if loadingChannelId == channel.id {
                                    ProgressView()
                                }
                            }
                        }
                        .disabled(loadingChannelId != nil)
                    }
                }
            }
            .navigationTitle("Add to MultiView")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .foregroundColor(.primary)
                            .fontWeight(.semibold)
                    }
                }
            }
            .onAppear {
                fetchChannels()
            }
        }
    }
    
    private func fetchChannels() {
        let serverStr = appState.serverURL.hasSuffix("/") ? String(appState.serverURL.dropLast()) : appState.serverURL
        guard let url = URL(string: "\(serverStr)/LiveTv/Channels?userId=\(appState.userID)") else {
            isLoading = false
            return
        }
        
        var req = URLRequest(url: url)
        req.setValue(appState.accessToken, forHTTPHeaderField: "X-Emby-Token")
        
        Task {
            do {
                // Fetch basic channels
                let (data, _) = try await URLSession.shared.data(for: req)
                let response = try JSONDecoder().decode(ChannelsResponse.self, from: data)
                
                // Fetch active programs concurrently to populate the 'currentProgram'
                var currentPrograms: [String: BaseItemDto] = [:]
                if let progUrl = URL(string: "\(serverStr)/LiveTv/Programs?userId=\(appState.userID)&IsAiring=true&limit=1000") {
                    var progReq = URLRequest(url: progUrl)
                    progReq.setValue(appState.accessToken, forHTTPHeaderField: "X-Emby-Token")
                    
                    if let (progData, _) = try? await URLSession.shared.data(for: progReq),
                       let progResp = try? JSONDecoder().decode(ProgramsResponse.self, from: progData),
                       let items = progResp.items {
                        for prog in items {
                            if let cid = prog.channelId {
                                currentPrograms[cid] = prog
                            }
                        }
                    }
                }
                
                await MainActor.run {
                    var updatedChannels = (response.items ?? []).filter { !activeChannelIds.contains($0.id) }
                    // Map active programs to channels
                    for i in 0..<updatedChannels.count {
                        if let prog = currentPrograms[updatedChannels[i].id] {
                            updatedChannels[i].currentProgram = prog
                        }
                    }
                    self.channels = updatedChannels
                    self.isLoading = false
                }
            } catch {
                print("MultiView Channel Fetch Error: \(error)")
                await MainActor.run { self.isLoading = false }
            }
        }
    }
    
    private func selectChannel(_ channel: LiveTvChannelDto) {
        loadingChannelId = channel.id
        Task {
            let resolved = await JFOpenLiveStreamService.resolveStreamURLWithSession(
                appState: appState,
                channelId: channel.id,
                debug: false
            )
            
            await MainActor.run {
                loadingChannelId = nil
                if let urlStr = resolved.url, let streamUrl = URL(string: urlStr) {
                    onSelect(streamUrl, channel, nil)
                    dismiss()
                } else {
                    print("Failed to resolve MultiView stream URL for channel \(channel.id)")
                }
            }
        }
    }
}
