//
//  RootView.swift
//  LiveFin
//
//  Created by KPGamingz on 4/9/25.
//

import SwiftUI

struct RootView: View {
    @EnvironmentObject var appState: AppState
    @State private var searchQuery: String = ""
    @State private var selectedTab: String = "home"

    var body: some View {
        if appState.isLoggedIn {
            if appState.isDemoMode {
                VStack(spacing: 0) {
                    TabView(selection: $selectedTab) {
                        DemoHomeView()
                            .tabItem { Label("Home", systemImage: "house.fill") }
                            .tag("home")

                        DemoChannelsView()
                            .tabItem { Label("Channels", systemImage: "tv.fill") }
                            .tag("channels")

                        DemoGuideView()
                            .tabItem { Label("Guide", systemImage: "square.fill.text.grid.1x2") }
                            .tag("guide")
                        
                        DemoLibraryView()
                            .tabItem { Label("Library", systemImage: "books.vertical.fill") }
                            .tag("library")
                    }
                }
            } else {
                VStack(spacing: 0) {
                    TabView(selection: $selectedTab) {
                        HomeView()
                            .tabItem {
                                Label("Home", systemImage: "house.fill")
                            }
                            .tag("home")
                        
                        ChannelsView()
                            .tabItem {
                                Label("Channels", systemImage: "tv.fill")
                            }
                            .tag("channels")
                        
                        GuideView()
                            .tabItem {
                                Label("Guide", systemImage: "square.fill.text.grid.1x2")
                            }
                            .tag("guide")
                        RecordingsView(appState: appState)
                            .tabItem {
                                if selectedTab == "dvr" {
                                    Image(uiImage: UIImage(systemName: "record.circle.fill")!
                                        .withTintColor(.systemRed, renderingMode: .alwaysOriginal))
                                    Text("DVR")
                                } else {
                                    Image(systemName: "circle")
                                    Text("DVR")
                                }
                            }
                            .tag("dvr")
                        LibraryView()
                            .tabItem {
                                Label("Library", systemImage: "books.vertical.fill")
                            }
                            .tag("library")
                    }
                }
            }
        } else {
            LoginView()
        }
    }
}
