//
//  TVHomeView.swift
//  LiveFin
//
//  Created by Kervens on 7/18/26.
//

import SwiftUI
import Combine

struct TVHomeView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var vm: HomeViewModel

    let nowTimer = Timer.publish(every: 600, on: .main, in: .common).autoconnect()
    @State private var hasAppeared = false

    var body: some View {
        NavigationStack {
            ZStack {
                let hasChannels = !vm.channels.isEmpty
                let hasPrograms = !(vm.onNow.isEmpty && vm.shows.isEmpty && vm.movies.isEmpty && vm.news.isEmpty && vm.sports.isEmpty && vm.kids.isEmpty)
                let hasLibrary = !(vm.continueWatching.isEmpty && vm.upNext.isEmpty && vm.recentlyAdded.isEmpty)
                let isCompletelyEmpty = !hasChannels && !hasPrograms && !hasLibrary

                if vm.isLoading && isCompletelyEmpty {
                    ProgressView().scaleEffect(1.4)
                } else if vm.isOffline && isCompletelyEmpty {
                    emptyState(
                        systemImage: "network.slash",
                        title: "Cannot connect to your server",
                        subtitle: "Check that your Jellyfin server is reachable and try again."
                    )
                } else if !hasChannels && !hasLibrary {
                    emptyState(
                        systemImage: "pc",
                        title: "Jellyfin Not Configured",
                        subtitle: "Finish setting up your Jellyfin server with Live TV fully configured on the Admin Dashboard."
                    )
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 48) {
                            topBar

                            if hasChannels && !hasPrograms {
                                Text("For the best experience, add EPG data on your Admin Dashboard")
                                    .font(.title3)
                                    .foregroundColor(.secondary)
                                    .padding(.horizontal, 60)
                            }

                            if !vm.onNow.isEmpty {
                                SectionHeader("On Now")
                                HorizontalProgramsRow(programs: vm.onNow, style: .landscapeLarge)
                                    .environmentObject(vm)
                            }

                            if !vm.channels.isEmpty {
                                SectionHeader("Channels")
                                HorizontalChannelsRow(channels: vm.channels)
                                    .environmentObject(appState)
                            }

                            if !vm.continueWatching.isEmpty {
                                SectionHeader("Continue Watching")
                                TVHorizontalItemsRow(items: vm.continueWatching, isLandscape: true, playDirectly: true)
                                    .environmentObject(appState)
                            }

                            if !vm.upNext.isEmpty {
                                SectionHeader("Up Next")
                                TVHorizontalItemsRow(items: vm.upNext, isLandscape: true, playDirectly: true)
                                    .environmentObject(appState)
                            }

                            if !vm.shows.isEmpty {
                                SectionHeader("Shows")
                                HorizontalProgramsRow(programs: vm.shows, style: .landscape)
                                    .environmentObject(vm)
                            }

                            if !vm.movies.isEmpty {
                                SectionHeader("Movies")
                                HorizontalProgramsRow(programs: vm.movies, style: .portrait)
                                    .environmentObject(vm)
                            }

                            if !vm.news.isEmpty {
                                SectionHeader("News")
                                HorizontalProgramsRow(programs: vm.news, style: .landscape)
                                    .environmentObject(vm)
                            }

                            if !vm.sports.isEmpty {
                                SectionHeader("Sports")
                                HorizontalProgramsRow(programs: vm.sports, style: .landscape)
                                    .environmentObject(vm)
                            }

                            if !vm.kids.isEmpty {
                                SectionHeader("Kids")
                                HorizontalProgramsRow(programs: vm.kids, style: .landscape)
                                    .environmentObject(vm)
                            }

                            if !vm.recentlyAdded.isEmpty {
                                SectionHeader("Recently Added")
                                TVHorizontalItemsRow(items: vm.recentlyAdded, isLandscape: false, playDirectly: false)
                                    .environmentObject(appState)
                            }
                        }
                        .padding(.bottom, 40)
                    }
                }
            }
            .task {
                guard !appState.serverURL.isEmpty else { return }
                if !hasAppeared {
                    hasAppeared = true
                    await performRefresh(force: true)
                }
            }
            .onChange(of: appState.serverURL) { old, new in
                if old != new { Task { await performRefresh(force: true) } }
            }
            .onChange(of: appState.isLoggedIn) { old, new in
                if new {
                    hasAppeared = false
                    Task { await performRefresh(force: true) }
                }
            }
            .onReceive(nowTimer) { _ in Task { await performRefresh(force: false) } }
        }
    }

    private var topBar: some View {
        HStack {
            Text(customGreeting(for: appState.username))
                .font(.system(size: 56, weight: .bold))
            Spacer()
            Button {
                Task { await performRefresh(force: true) }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 28))
            }
        }
        .padding(.horizontal, 60)
        .padding(.top, 20)
    }

    private func emptyState(systemImage: String, title: String, subtitle: String) -> some View {
        VStack(spacing: 20) {
            Image(systemName: systemImage).font(.system(size: 90)).foregroundColor(.secondary)
            Text(title).font(.system(size: 40, weight: .bold))
            Text(subtitle)
                .font(.title3)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 900)
            Button("Try Again") {
                Task { await performRefresh(force: true) }
            }
        }
    }

    @MainActor
    private func performRefresh(force: Bool = true) async {
        await vm.refresh(appState: appState, force: force)
    }
}
