//
//  AboutView.swift
//
//  LiveFin
//

import SwiftUI

struct AboutView: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var appState: AppState
    
    // State to control the presentation of the AlternateIconView sheet
    @State private var showingIconPicker = false
    
    var serverURLStripped: String {
        appState.serverURL.replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: "")
    }
    
    var body: some View {
        NavigationStack {
            ScrollView { // Wrapped in a ScrollView to prevent cramping on smaller screens
                VStack(spacing: 24) {
                    Image("Logo")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 120, height: 120)
                        .foregroundColor(.accentColor)
                    
                    Text("LiveFin")
                        .font(.largeTitle)
                        .fontWeight(.bold)
                    
                    Text("Version \(appState.clientVersion)")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    
                    Text("LiveFin is a Live TV client app for Jellyfin.")
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                    
                    Text("Developed by KPGamingz.")
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                    
                    Text("LiveFin is not affiliated or a part of the Jellyfin project.")
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                    
                    // Button to open the alternate icon picker
                    Button(action: {
                        showingIconPicker = true
                    }) {
                        if #available(iOS 26.0, *) {
                            Label("Change App Icon", systemImage: "app.dashed")
                                .font(.headline)
                                .foregroundColor(.white)
                                .frame(width: 250, height: 60)
                                .background(Color.red)
                                .glassEffect(in: .rect(cornerRadius: 30))
                        } else {
                            Label("Change App Icon", systemImage: "app.dashed")
                                .font(.headline)
                                .foregroundColor(.white)
                                .frame(width: 250, height: 60)
                                .background(Color.red)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.top, 8)
                    
                    // --- AppState Info Section ---
                    VStack(alignment: .leading, spacing: 12) {
                        Divider()
                        Text("User: \(appState.username.isEmpty ? (appState.user?.name ?? "-") : appState.username)")
                            .font(.body)
                        Text("Device: \(appState.clientDevice)")
                            .font(.body)
                        Text("Server Name: \(appState.serverName.isEmpty ? "-" : appState.serverName)")
                            .font(.body)
                        Text("Server Version: \(appState.serverVersion.isEmpty ? "-" : appState.serverVersion)")
                            .font(.body)
                        Text("Server URL: \(serverURLStripped)")
                            .font(.body)
                    }
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 8)
                }
                .padding()
            }
            .navigationTitle("About")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(action: { dismiss() }) {
                        Image(systemName: "xmark")
                    }
                }
            }
            .sheet(isPresented: $showingIconPicker) {
                AlternateIconView()
                    .presentationDetents([.medium, .large])
            }
        }
    }
}

#Preview {
    NavigationStack {
        AboutView()
            .environmentObject(AppState())
    }
}

