//
//  TVRootView.swift
//  LiveFin
//
//  Created by Kervens on 7/17/26.
//


//
//  TVRootView.swift
//  LiveFin tvOS
//

import SwiftUI

struct TVRootView: View {
    @StateObject private var appState = TVAppState()
    
    var body: some View {
        if !appState.isAuthenticated {
            TVLoginView()
                .environmentObject(appState)
        } else {
            TabView {
                TVChannelsView()
                    .tabItem {
                        Label("Channels", systemImage: "tv")
                    }
                    .environmentObject(appState)
                
                Text("EPG Guide View Stub")
                    .tabItem {
                        Label("Guide", systemImage: "list.bullet.rectangle")
                    }
                
                TVPlayerView(channel: nil)
                    .tabItem {
                        Label("MultiView", systemImage: "square.split.2x2")
                    }
                
                Text("Library Stub")
                    .tabItem {
                        Label("Library", systemImage: "play.rectangle")
                    }
                
                Text("Settings Stub")
                    .tabItem {
                        Label("Settings", systemImage: "gear")
                    }
            }
        }
    }
}

// Minimal login stub for tvOS
struct TVLoginView: View {
    @EnvironmentObject var appState: TVAppState
    
    var body: some View {
        VStack(spacing: 40) {
            Image(systemName: "tv.circle.fill")
                .font(.system(size: 100))
                .foregroundColor(.accentColor)
            
            Text("Welcome to LiveFin")
                .font(.title)
            
            Text("Please sign in to your Jellyfin Server.")
                .foregroundColor(.secondary)
            
            Button("Sign In (Stub)") {
                // TODO: Implement actual tvOS auth flow (On-screen keyboard or pairing code)
                appState.saveCredentials(server: "http://demo", token: "demo", user: "demo")
            }
            .buttonStyle(.borderedProminent)
        }
    }
}