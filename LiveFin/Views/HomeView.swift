//
//  HomeView.swift
//  LiveFin
//
//  Created by KPGamingz on 9/12/25.
//

import SwiftUI
import Combine

// MARK: - HomeView

struct HomeView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var vm = HomeViewModel()
    
    let nowTimer = Timer.publish(every: 600, on: .main, in: .common).autoconnect()
    
    @State private var hasAppeared: Bool = false

    var body: some View {
        NavigationStack {
            ZStack {
                let hasChannels = !vm.channels.isEmpty
                let hasPrograms = !(vm.onNow.isEmpty && vm.shows.isEmpty && vm.movies.isEmpty && vm.news.isEmpty && vm.sports.isEmpty && vm.kids.isEmpty)
                let hasLibrary = !(vm.continueWatching.isEmpty && vm.upNext.isEmpty && vm.recentlyAdded.isEmpty)
                let isCompletelyEmpty = !hasChannels && !hasPrograms && !hasLibrary

                if vm.isLoading && isCompletelyEmpty {
                    VStack {
                        Spacer()
                        ProgressView().scaleEffect(1.2)
                        Spacer()
                    }
                } else if vm.isOffline && isCompletelyEmpty {
                    // Offline / Error State
                    ScrollView {
                        VStack(spacing: 12) {
                            Image(systemName: "network.slash")
                                .font(.system(size: 48))
                                .foregroundColor(.secondary)
                                .padding(.bottom, 8)
                            
                            Text("Cannot connect to your server. Please try again")
                                .font(.title2.bold())
                                .foregroundColor(.primary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 32)
                        }
                        .padding(.top, 120)
                    }
                    .refreshable { await performRefresh(force: true) }
                } else if !hasChannels && !hasLibrary {
                    // Jellyfin Not Configured State
                    ScrollView {
                        VStack(spacing: 12) {
                            Image(systemName: "pc")
                                .font(.system(size: 48))
                                .foregroundColor(.secondary)
                                .padding(.bottom, 8)
                            
                            Text("Jellyfin Not Configured")
                                .font(.title2.bold())
                                .foregroundColor(.primary)
                            
                            Text("Finish setting up your Jellyfin server with Live TV fully configured on the Admin Dashboard")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 32)
                        }
                        .padding(.top, 120)
                    }
                    .refreshable { await performRefresh(force: true) }
                } else {
                    // Main Content State
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            Text(customGreeting(for: appState.username))
                                .font(.largeTitle).bold()
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal)
                                .padding(.top, 8)

                            // No Guide Data Warning
                            if hasChannels && !hasPrograms {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("For the best experience, add EPG data on your Admin Dashboard")
                                        .font(.subheadline)
                                        .foregroundColor(.secondary)
                                        .padding(.horizontal)
                                }
                            }

                            // Dynamic Sections
                            if !vm.onNow.isEmpty {
                                SectionHeader("On Now")
                                HorizontalProgramsRow(programs: vm.onNow, style: .landscapeLarge)
                                    .environmentObject(vm)
                                    .padding(.bottom, 12)
                            }

                            if !vm.channels.isEmpty {
                                SectionHeader("Channels")
                                HorizontalChannelsRow(channels: vm.channels)
                                    .environmentObject(appState)
                            }

                            if !vm.continueWatching.isEmpty {
                                SectionHeader("Continue Watching")
                                HorizontalLibraryItemsRow(items: vm.continueWatching, style: .landscape, playDirectly: true)
                                    .environmentObject(appState)
                            }

                            if !vm.upNext.isEmpty {
                                SectionHeader("Up Next")
                                HorizontalLibraryItemsRow(items: vm.upNext, style: .landscape, playDirectly: true)
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
                                    .padding(.bottom, 12)
                            }

                            if !vm.recentlyAdded.isEmpty {
                                SectionHeader("Recently Added")
                                HorizontalLibraryItemsRow(items: vm.recentlyAdded, style: .portrait, playDirectly: false)
                                    .environmentObject(appState)
                                    .padding(.bottom, 12)
                            }
                        }
                        .padding(.bottom, 24)
                    }
                    .refreshable { await performRefresh(force: true) }
                }
            }
            .task {
                guard !appState.serverURL.isEmpty else { return }
                if !hasAppeared {
                    hasAppeared = true
                    await vm.refresh(appState: appState, force: true)
                }
            }
            .onChange(of: appState.serverURL) { old, new in
                if old != new { Task { await vm.refresh(appState: appState, force: true) } }
            }
            .onChange(of: appState.isLoggedIn) { old, new in
                if new {
                    hasAppeared = false
                    Task { await vm.refresh(appState: appState, force: true) }
                }
            }
            .onReceive(nowTimer) { _ in Task { await vm.refresh(appState: appState) } }
            .toolbar { ToolbarView() }
        }
    }

    @MainActor
    private func performRefresh(force: Bool = true) async {
        await vm.refresh(appState: appState, force: force)
    }
}
