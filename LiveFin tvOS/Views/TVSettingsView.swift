//
//  TVSettingsView.swift
//  LiveFin
//
//  Created by Kervens on 7/21/26.
//

import SwiftUI
import JellyfinAPI

struct TVSettingsView: View {
    @EnvironmentObject var appState: AppState
    
    // Strips http:// or https:// from the server URL
    var serverURLStripped: String {
        appState.serverURL.replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: "")
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 80) {
                
                // --- Profile Header ---
                HStack(spacing: 50) {
                    profileImage
                        .frame(width: 220, height: 220)
                        .clipShape(Circle())
                        .overlay(Circle().stroke(Color.secondary.opacity(0.3), lineWidth: 2))
                        .shadow(radius: 15)
                    
                    VStack(alignment: .leading, spacing: 24) {
                        Text(appState.username.isEmpty ? (appState.user?.name ?? "Unknown") : appState.username)
                            .font(.system(size: 64, weight: .bold))
                        
                        FocusableLogoutButton(action: { appState.logout() })
                    }
                    Spacer()
                }
                .padding(.horizontal, 60)
                .padding(.top, 80)
                
                // --- Connection Info Grid ---
                VStack(alignment: .leading, spacing: 30) {
                    Text("CONNECTION INFO")
                        .font(.headline)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 60)
                    
                    VStack(spacing: 40) {
                        HStack(spacing: 40) {
                            InfoCard(title: "Device", value: appState.clientDevice)
                            InfoCard(title: "Server Name", value: appState.serverName.isEmpty ? "-" : appState.serverName)
                        }
                        
                        HStack(spacing: 40) {
                            InfoCard(title: "Server Version", value: appState.serverVersion.isEmpty ? "-" : appState.serverVersion)
                            InfoCard(title: "Server URL", value: serverURLStripped)
                        }
                    }
                    .padding(.horizontal, 60)
                }
                
                // --- About Section ---
                VStack(spacing: 24) {
                    Image("Logo")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 200, height: 200)
                        .cornerRadius(40)
                        .shadow(radius: 10)
                        
                    Text("LiveFin")
                        .font(.system(size: 48, weight: .bold))
                        
                    Text("Version \(appState.clientVersion)")
                        .font(.title3)
                        .foregroundColor(.secondary)
                        
                    Text("LiveFin is a Live TV client app for Jellyfin.")
                        .font(.body)
                        .padding(.top, 16)
                        
                    Text("Developed by KPGamingz.")
                        .font(.body)
                        
                    Text("LiveFin is not affiliated or a part of the Jellyfin project.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 60)
                .padding(.top, 60)
                .padding(.bottom, 120) // Deep bottom padding for tvOS scrolling comfort
            }
        }
        .edgesIgnoringSafeArea(.horizontal)
        .onAppear {
            ensureProfileLoadedIfNeeded()
        }
    }
    
    @ViewBuilder
    private var profileImage: some View {
        if let img = appState.userProfileImage {
            Image(uiImage: img)
                .resizable()
                .scaledToFill()
        } else {
            Image(systemName: "person.crop.circle")
                .resizable()
                .scaledToFit()
                .foregroundColor(.primary)
                .opacity(0.85)
        }
    }
    
    private func ensureProfileLoadedIfNeeded() {
        if appState.isLoggedIn && appState.userProfileImage == nil {
            Task { await appState.refreshUserProfileInfoAndImage() }
        }
    }
}

// A custom card view that responds to the tvOS focus engine
struct InfoCard: View {
    let title: String
    let value: String
    @Environment(\.isFocused) var isFocused
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
                .foregroundColor(isFocused ? .black.opacity(0.6) : .secondary)
            
            Text(value)
                .font(.title2)
                .fontWeight(.medium)
                .foregroundColor(isFocused ? .black : .primary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(32)
        // Adjusts background colors specifically to look good when focused (white) vs unfocused
        .background(isFocused ? Color.white : Color.secondary.opacity(0.15))
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .scaleEffect(isFocused ? 1.05 : 1.0)
        .shadow(radius: isFocused ? 20 : 0, y: isFocused ? 10 : 0)
        .animation(.easeOut(duration: 0.2), value: isFocused)
        .focusable(true) // Extremely important: This allows the Siri Remote to snap to this card!
    }
}

// A native button view that perfectly handles tvOS focus state automatically
struct FocusableLogoutButton: View {
    let action: () -> Void
    
    var body: some View {
        Button(role: .destructive, action: action) {
            Text("Logout")
                .font(.title3)
                .fontWeight(.bold)
                .padding(.horizontal, 24)
                .padding(.vertical, 8)
        }
        // By using the native tvOS .bordered style and completely removing .plain,
        // Apple TV automatically handles focus state, making it selectable via the Siri Remote,
        // scaling it up, and turning the button solid red when highlighted.
        .buttonStyle(.bordered)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
