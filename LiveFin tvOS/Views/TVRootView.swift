//
//  TVRootView.swift
//  LiveFin
//
//  Created by Kervens on 7/17/26.
//

import SwiftUI

struct TVRootView: View {
    @EnvironmentObject var appState: AppState
    // Shared across Home + Channels tabs so both read the same channel list
    // (same favorites/order, and only one /LiveTv/Channels fetch).
    @StateObject private var homeVM = HomeViewModel()

    var body: some View {
        Group {
            if appState.isLoggedIn {
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
                                // Use the resized image helper to prevent tab bar layout explosion
                                Image(uiImage: resizedTabBarImage(img))
                                Text(appState.username.isEmpty ? "Profile" : appState.username)
                            } else {
                                Image(systemName: "person.crop.circle")
                                Text(appState.username.isEmpty ? "Profile" : appState.username)
                            }
                        }
                }
                .environmentObject(homeVM)
            } else {
                TVLoginView()
            }
        }
    }
    
    private func resizedTabBarImage(_ image: UIImage) -> UIImage {
        // Tab bar icons in tvOS are ideally around 50x50
        let targetSize = CGSize(width: 50, height: 50)
        let renderer = UIGraphicsImageRenderer(size: targetSize)
        
        let resizedImage = renderer.image { _ in
            let rect = CGRect(origin: .zero, size: targetSize)
            // Clip the image to a circle so it looks native
            UIBezierPath(ovalIn: rect).addClip()
            image.draw(in: rect)
        }
        
        // .alwaysOriginal prevents tvOS from tinting the colorful profile pic into a solid grey silhouette
        return resizedImage.withRenderingMode(.alwaysOriginal)
    }
}
