//
//  TVRootView.swift
//  LiveFin
//
//  Created by KPGamingz on 7/17/26.
//

import SwiftUI
import AVKit
import Combine

/// Manages global playback state across tvOS, enabling Picture-in-Picture / MiniPlayer
/// multitasking mode when the user backs out of full-screen video to navigate the app.
@MainActor
final class GlobalPlayerCoordinator: ObservableObject {
    @Published var activeChannel: JFChannel?
    @Published var player: AVPlayer?
    @Published var isFullScreen: Bool = false
    @Published var isPlaying: Bool = false
    @Published var isBuffering: Bool = false
    @Published var errorMessage: String? = nil
    
    private var timeObserverToken: Any?
    private var hasAutoLaunched: Bool = false

    func startChannelPlayback(_ channel: JFChannel, appState: AppState, fullScreen: Bool = true) {
        UserDefaults.standard.set(channel.id, forKey: "lastWatchedChannelId")
        UserDefaults.standard.set(channel.name, forKey: "lastWatchedChannelName")
        
        if activeChannel?.id == channel.id && player != nil {
            isFullScreen = fullScreen
            player?.play()
            isPlaying = true
            return
        }

        cleanup(appState: appState)
        self.activeChannel = channel
        self.isFullScreen = fullScreen
        self.isBuffering = true
        self.errorMessage = nil

        Task {
            await appState.reportPlaybackStart(itemId: channel.id)
            appState.startEPGPolling(for: channel.id)
            
            let resolved = await JFOpenLiveStreamService.resolveStreamURLWithSession(
                appState: appState,
                channelId: channel.id,
                debug: true
            )
            
            guard let urlString = resolved.url, let url = URL(string: urlString) else {
                await MainActor.run {
                    self.errorMessage = "Unable to resolve stream."
                    self.isBuffering = false
                }
                return
            }
            
            await MainActor.run {
                let newPlayer = AVPlayer(url: url)
                self.player = newPlayer
                newPlayer.play()
                self.isPlaying = true
                self.isBuffering = false
            }
        }
    }

    func autoLaunchLastWatchedIfNeeded(channels: [JFChannel], appState: AppState) {
        guard !hasAutoLaunched, !channels.isEmpty else { return }
        hasAutoLaunched = true
        
        let lastId = UserDefaults.standard.string(forKey: "lastWatchedChannelId")
        let targetChannel: JFChannel
        
        if let lastId = lastId, let matched = channels.first(where: { $0.id == lastId }) {
            targetChannel = matched
        } else if let firstFavorite = channels.first(where: { $0.isFavorite }) {
            targetChannel = firstFavorite
        } else if let first = channels.first {
            targetChannel = first
        } else {
            return
        }
        
        startChannelPlayback(targetChannel, appState: appState, fullScreen: true)
    }

    func returnToFullScreen() {
        withAnimation(.easeInOut(duration: 0.25)) {
            self.isFullScreen = true
        }
    }

    func minimizeToPiP() {
        withAnimation(.easeInOut(duration: 0.25)) {
            self.isFullScreen = false
        }
    }

    func closePlayback(appState: AppState) {
        cleanup(appState: appState)
        withAnimation {
            self.activeChannel = nil
            self.player = nil
            self.isFullScreen = false
        }
    }

    private func cleanup(appState: AppState) {
        if let currentId = activeChannel?.id {
            player?.pause()
            appState.stopEPGPolling()
            Task {
                await appState.reportPlaybackStopped(itemId: currentId, positionTicks: 0)
            }
        }
        player = nil
    }
}

struct TVRootView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var homeVM = HomeViewModel()
    @StateObject private var coordinator = GlobalPlayerCoordinator()

    var body: some View {
        Group {
            if appState.isLoggedIn {
                ZStack(alignment: .topTrailing) {
                    // Main App Navigation Shell
                    TabView {
                        TVHomeView()
                            .tabItem { Label("Home", systemImage: "house") }

                        TVChannelsView()
                            .tabItem { Label("Channels", systemImage: "tv") }

                        TVGuideView()
                            .tabItem { Label("Guide", systemImage: "calendar") }
                            
                        TVLibraryView()
                            .tabItem { Label("Library", systemImage: "books.vertical") }
                            
                        TVSettingsView()
                            .tabItem {
                                if let img = appState.userProfileImage {
                                    Image(uiImage: resizedTabBarImage(img))
                                    Text(appState.username.isEmpty ? "Profile" : appState.username)
                                } else {
                                    Image(systemName: "person.crop.circle")
                                    Text(appState.username.isEmpty ? "Profile" : appState.username)
                                }
                            }
                    }
                    .environmentObject(homeVM)
                    .environmentObject(coordinator)
                    .disabled(coordinator.isFullScreen)

                    // Overlay / PiP Layer
                    if let channel = coordinator.activeChannel, let player = coordinator.player {
                        if coordinator.isFullScreen {
                            TVDragonetPlayerContainer(channel: channel, player: player)
                                .environmentObject(appState)
                                .environmentObject(coordinator)
                                .transition(.opacity)
                                .zIndex(100)
                        } else {
                            TVPiPOverlayView(channel: channel, player: player)
                                .environmentObject(appState)
                                .environmentObject(coordinator)
                                .padding(.trailing, 60)
                                .padding(.top, 40)
                                .transition(.scale(scale: 0.8).combined(with: .opacity))
                                .zIndex(90)
                        }
                    }
                }
                .task {
                    guard homeVM.channels.isEmpty, !appState.serverURL.isEmpty else { return }
                    await homeVM.refresh(appState: appState, force: false)
                    coordinator.autoLaunchLastWatchedIfNeeded(channels: homeVM.channels, appState: appState)
                }
                .onChange(of: homeVM.channels.count) { _, _ in
                    coordinator.autoLaunchLastWatchedIfNeeded(channels: homeVM.channels, appState: appState)
                }
            } else {
                TVLoginView()
            }
        }
    }
    
    private func resizedTabBarImage(_ image: UIImage) -> UIImage {
        let targetSize = CGSize(width: 50, height: 50)
        let renderer = UIGraphicsImageRenderer(size: targetSize)
        
        let resizedImage = renderer.image { _ in
            let rect = CGRect(origin: .zero, size: targetSize)
            UIBezierPath(ovalIn: rect).addClip()
            image.draw(in: rect)
        }
        
        return resizedImage.withRenderingMode(.alwaysOriginal)
    }
}

struct TVPiPOverlayView: View {
    let channel: JFChannel
    let player: AVPlayer
    
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var coordinator: GlobalPlayerCoordinator
    @FocusState private var isFocused: Bool

    var body: some View {
        Button {
            coordinator.returnToFullScreen()
        } label: {
            ZStack(alignment: .topTrailing) {
                DragonetPlayerPlayer(player: player)
                    .frame(width: 440, height: 247.5)
                    .background(Color.black)
                    .cornerRadius(16)
                
                // Dismiss / Close Button
                Button {
                    coordinator.closePlayback(appState: appState)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(Color.black.opacity(0.75)))
                }
                .buttonStyle(.plain)
                .padding(12)
            }
            .frame(width: 440, height: 247.5)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(isFocused ? Color.white : Color.white.opacity(0.2), lineWidth: isFocused ? 4 : 1)
            )
            .scaleEffect(isFocused ? 1.08 : 1.0)
            .shadow(color: .black.opacity(isFocused ? 0.8 : 0.4), radius: isFocused ? 20 : 10, x: 0, y: 6)
            .animation(.easeOut(duration: 0.2), value: isFocused)
        }
        .buttonStyle(.plain)
        .focused($isFocused)
    }
}

struct TVDragonetPlayerContainer: View {
    let channel: JFChannel
    let player: AVPlayer
    
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var coordinator: GlobalPlayerCoordinator
    
    var body: some View {
        TVDragonetPlayerView(channel: channel, customPlayer: player) {
            coordinator.minimizeToPiP()
        }
        .onExitCommand {
            coordinator.minimizeToPiP()
        }
    }
}
