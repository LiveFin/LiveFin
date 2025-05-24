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
                        
                        if let error = error {
                            Text(error)
                                .foregroundColor(.red)
                        }
                        
                        Button("Login") {
                            Task {
                                isLoggingIn = true
                                guard let url = URL(string: "\(server)/Users/AuthenticateByName") else {
                                    error = "Invalid server URL"
                                    isLoggingIn = false
                                    return
                                }

                                var request = URLRequest(url: url, timeoutInterval: 60)
                                request.httpMethod = "POST"
                                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                                request.setValue("MediaBrowser Client=\"LiveFin\", Device=\"\(appState.clientDevice)\", DeviceId=\"unique-device-id\", Version=\"\(appState.clientVersion)\"" , forHTTPHeaderField: "X-Emby-Authorization")

                                let body: [String: Any] = [
                                    "Username": username,
                                    "Pw": password
                                ]

                                request.httpBody = try? JSONSerialization.data(withJSONObject: body)

                                let startTime = Date() // Log time before request
                                print("Step 1: Sending login request to \(url)")
                                do {
                                    let (data, response) = try await URLSession.shared.data(for: request)

                                    let endTime = Date()
                                    let elapsedTime = endTime.timeIntervalSince(startTime)
                                    print("Request completed in \(elapsedTime) seconds")

                                    guard let httpResponse = response as? HTTPURLResponse else {
                                        error = "No response from server"
                                        isLoggingIn = false
                                        return
                                    }

                                    if httpResponse.statusCode != 200 {
                                        error = "Login failed with status code \(httpResponse.statusCode)"
                                        isLoggingIn = false
                                        return
                                    }

                                    print("Step 2: Received response, decoding JSON")
                                    struct LoginResponse: Decodable {
                                        let AccessToken: String
                                        let User: UserInfo

                                        struct UserInfo: Decodable {
                                            let Id: String
                                            let Name: String
                                        }
                                    }

                                    let decodedResponse = try JSONDecoder().decode(LoginResponse.self, from: data)
                                    appState.userID = decodedResponse.User.Id
                                    KeychainHelper.save(key: "userId", value: decodedResponse.User.Id)
                                    print("DEBUG: UserID assigned: \(appState.userID)")  // For debugging purposes
                                    print("Step 3: Saving token, initializing client")
                                    // Generate a new API key each time
                                    let newApiKey = UUID().uuidString

                                    // Save the new API key to Keychain
                                    KeychainHelper.save(key: "apiKey", value: newApiKey)

                                    // Save the new API key and access token
                                    KeychainHelper.save(key: "accessToken", value: decodedResponse.AccessToken)
                                    KeychainHelper.saveCredentials(
                                        server: server,
                                        username: username,
                                        accessToken: decodedResponse.AccessToken
                                    )

                                    let config = JellyfinClient.Configuration(
                                        url: URL(string: server)!,
                                        client: "LiveFin",
                                        deviceName: appState.clientDevice,
                                        deviceID: UUID().uuidString,
                                        version: appState.clientVersion
                                    )
                                    let client = JellyfinClient(configuration: config)
                                    appState.client = client

                                    appState.serverURL = server
                                    appState.accessToken = decodedResponse.AccessToken
                                    appState.apiKey = decodedResponse.AccessToken  // Ensure apiKey is assigned here
                                    appState.user?.id ?? ""
                                    appState.isLoggedIn = true
                                    isLoggingIn = false
                                } catch {
                                    print("Request failed with error: \(error.localizedDescription)")
                                    self.error = error.localizedDescription
                                    isLoggingIn = false
                                }
                            }
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
        .navigationDestination(isPresented: Binding(
            get: { appState.isLoggedIn },
            set: { _ in }
        )) {
            LiveTVHomeView()
                .environmentObject(appState)
        }
    }
}
