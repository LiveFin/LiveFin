
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

    var body: some View {
        if appState.isLoggedIn {
            if appState.isDemoMode {
                VStack(spacing: 0) {
                    TabView {
                        DemoHomeView()
                            .tabItem { Label("Home", systemImage: "house.fill") }

                        DemoChannelsView()
                            .tabItem { Label("Channels", systemImage: "tv.fill") }

                        DemoGuideView()
                            .tabItem { Label("Guide", systemImage: "square.fill.text.grid.1x2") }
                        
                        DemoLibraryView()
                            .tabItem { Label("Library", systemImage: "books.vertical.fill") }
                    }
                }
            } else {
                VStack(spacing: 0) {
                    TabView {
                        HomeView()
                            .tabItem {
                                Label("Home", systemImage: "house.fill")
                            }
                        
                        ChannelsView()
                            .tabItem {
                                Label("Channels", systemImage: "tv.fill")
                            }
                        
                        GuideView()
                            .tabItem {
                                Label("Guide", systemImage: "square.fill.text.grid.1x2")
                            }
                        LibraryView()
                            .tabItem {
                                Label("Library", systemImage: "books.vertical.fill")
                            }
                    }
                }
            }
        } else {
            LoginView()
        }
    }
}
