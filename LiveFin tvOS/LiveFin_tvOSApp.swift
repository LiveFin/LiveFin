//
//  LiveFin_tvOSApp.swift
//  LiveFin tvOS
//
//  Created by KPGamingz on 12/13/25.
//

import SwiftUI

@main
struct LiveFin_tvOSApp: App {
    // 1. Initialize your shared, unified AppState
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            // 2. Launch your custom TVRootView instead of the CoreData ContentView
            TVRootView()
                .environmentObject(appState)
        }
    }
}
