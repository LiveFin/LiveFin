//
//  RootView.swift
//  LiveFin
//
//  Created by KPGamingz on 4/9/25.
//


import SwiftUI

struct RootView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        if appState.isLoggedIn {
            LiveTVHomeView()
        } else {
            LoginView()
        }
    }
}
