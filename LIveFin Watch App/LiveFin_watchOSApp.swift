//
//  LiveFin_watchOSApp.swift
//  LiveFin watchOS Watch App
//
//  Created by Kervens on 9/26/25.
//

import SwiftUI

@main
struct LiveFin_watchOS_Watch_AppApp: App {
    @StateObject private var appState = WatchAppState()

    var body: some Scene {
        WindowGroup {
            WatchRootView() // renamed from ContentView
                .environmentObject(appState)
                .onAppear {
                    appState.restoreCredentials()
                    appState.startConnectivity()
                }
        }
    }
}
