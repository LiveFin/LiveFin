//
//  LoginView.swift
//  LiveFin
//
//  Created by KPGamingz on 4/9/25.
//

import SwiftUI
import JellyfinAPI
import Foundation
import Get

extension Color {
    init(hex: String) {
        let scanner = Scanner(string: hex)
        _ = scanner.scanString("#")
        var rgb: UInt64 = 0
        scanner.scanHexInt64(&rgb)
        let r = Double((rgb >> 16) & 0xFF) / 255
        let g = Double((rgb >> 8) & 0xFF) / 255
        let b = Double(rgb & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}

struct LoginView: View {
    @EnvironmentObject var appState: AppState
    @State private var server = "http://localhost:8096"
    @State private var username = ""
    @State private var password = ""
    @State private var error: String?
    @State private var isLoggingIn = false
    
    var body: some View {
        NavigationStack {
            ZStack {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Login to your Jellyfin server")
                        .font(.title2.bold())
                        .foregroundStyle(
                            LinearGradient(
                                colors: [Color(hex: "#AA5CC3"), Color(hex: "#00A4DC")],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal)
                        .padding(.top)
                    
                    Form {
                        TextField("Server", text: $server)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                        TextField("Username", text: $username)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                        SecureField("Password", text: $password)
                            .onSubmit {
                                performLogin()
                            }
                        
                        if let error = error {
                            Text(error)
                                .foregroundColor(.red)
                        }
                        
                        Button("Login") {
                            performLogin()
                        }
                    }
                    
                    if isLoggingIn {
                        ProgressView("Logging in to your Jellyfin server")
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .center)
                            .tint(.red)
                            .foregroundColor(.red)
                    }
                }
            }
        }
        .onAppear {
            // Generate a new API key every time the app is opened
            let newApiKey = UUID().uuidString
            
            // Save the new API key to Keychain
            KeychainHelper.save(key: "apiKey", value: newApiKey)
            
            appState.restoreLogin()  // Restore login state and API key
        }
        .navigationDestination(isPresented: Binding<Bool>(
            get: { appState.isLoggedIn },
            set: { appState.isLoggedIn = $0 }
        )) {
            if appState.isDemoMode {
                DemoHomeView()
                    .environmentObject(appState)
            } else {
                HomeView()
                    .environmentObject(appState)
            }
        }
    }
    
    // MARK: - Login logic
    private func performLogin() {
        Task {
            isLoggingIn = true
            defer { isLoggingIn = false }
            if let url = URL(string: server) {
                await appState.login(server: url, username: username, password: password)
                if let loginError = appState.loginError {
                    error = loginError
                }
            } else {
                error = "Invalid server URL"
            }
        }
    }
}
