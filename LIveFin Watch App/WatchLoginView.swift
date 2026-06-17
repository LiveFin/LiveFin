//
//  WatchLoginView.swift
//  LiveFin watchOS Watch App
//
//  Created by KPGamingz on 9/26/25.
//

import SwiftUI

struct WatchRootView: View { // Renamed from ContentView
    @EnvironmentObject var appState: WatchAppState

    var body: some View {
        Group {
            if !appState.isAuthenticated {
                ScrollView { // Added ScrollView for scrollability on small screens
                    VStack(spacing: 12) {
                        Image(systemName: "lock.circle")
                            .font(.system(size: 42))
                            .foregroundColor(.accentColor)
                        Text("Login on iPhone")
                            .font(.headline)
                        Text("The watch app will pick up your session automatically.")
                            .font(.footnote)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                        Button("Retry") {
                            appState.restoreCredentials()
                            Task { await appState.loadChannelsIfNeeded(force: true) }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .padding()
                    .frame(maxWidth: .infinity)
                }
            } else {
                NavigationStack {
                    List {
                        if appState.isLoadingChannels {
                            ProgressView("Loading…")
                        } else if appState.channels.isEmpty {
                            Text("No channels")
                                .foregroundColor(.secondary)
                        } else {
                            ForEach(appState.channels) { ch in
                                NavigationLink(destination: WatchChannelDetailView(channel: ch).environmentObject(appState)) {
                                    WatchChannelRow(channel: ch, baseURL: appState.serverURL, apiKey: appState.apiKey)
                                }
                            }
                        }
                    }
                    .navigationTitle("Channels")
                    .toolbar { ToolbarItem(placement: .topBarTrailing) { refreshButton } }
                    .task { await appState.loadChannelsIfNeeded(force: false) }
                    .refreshable { await appState.loadChannelsIfNeeded(force: true) }
                }
            }
        }
        .onAppear { appState.restoreCredentials() }
    }

    private var refreshButton: some View {
        Button(action: { Task { await appState.loadChannelsIfNeeded(force: true) } }) { Image(systemName: "arrow.clockwise") }
            .disabled(appState.isLoadingChannels)
    }
}

#Preview {
    WatchRootView()
        .environmentObject(WatchAppState())
}
