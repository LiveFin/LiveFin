//
//  TVLoginStep.swift
//  LiveFin
//
//  Created by Kervens on 7/18/26.
//

import SwiftUI

private enum TVLoginStep {
    case server
    case quickConnect
    case manual
}

struct TVLoginView: View {
    @EnvironmentObject var appState: AppState

    @AppStorage("lastUsedServer") private var lastUsedServer: String = ""

    @State private var server = ""
    @State private var username = ""
    @State private var password = ""

    @State private var quickConnectCode = ""
    @State private var quickConnectSecret = ""
    @State private var quickConnectTimer: Timer?

    @State private var error: String?
    @State private var isConnecting = false
    @State private var isLoggingIn = false

    @State private var step: TVLoginStep = .server
    @FocusState private var serverFieldFocused: Bool

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(hex: "#1a1a2e"), Color.black],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 40) {
                Text("LiveFin")
                    .font(.system(size: 56, weight: .bold))
                    .foregroundStyle(
                        LinearGradient(colors: [Color(hex: "#AA5CC3"), Color(hex: "#00A4DC")],
                                       startPoint: .leading, endPoint: .trailing)
                    )

                Group {
                    switch step {
                    case .server: serverEntryView
                    case .quickConnect: quickConnectView
                    case .manual: manualLoginView
                    }
                }
                .frame(maxWidth: 900)
            }
            .padding(60)
        }
        .onAppear {
            appState.restoreLogin()
            if !appState.isLoggedIn && !lastUsedServer.isEmpty {
                server = lastUsedServer
                connectToServer()
            }
        }
        .onDisappear { stopQuickConnectPolling() }
    }

    // MARK: - Step 1: Server Entry

    private var serverEntryView: some View {
        VStack(spacing: 24) {
            Text("Enter your Jellyfin server address")
                .font(.title3)
                .foregroundColor(.secondary)

            TextField("e.g. 192.168.1.100:8096", text: $server)
                .textFieldStyle(.plain)
                .focused($serverFieldFocused)
                .onSubmit { connectToServer() }

            if let error {
                Text(error).foregroundColor(.red).font(.callout)
            }

            Button {
                connectToServer()
            } label: {
                if isConnecting {
                    ProgressView()
                } else {
                    Text("Connect").frame(maxWidth: .infinity)
                }
            }
            .disabled(server.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isConnecting)
        }
        .onAppear { serverFieldFocused = true }
    }

    // MARK: - Step 2: Quick Connect (primary tvOS flow)

    private var quickConnectView: some View {
        VStack(spacing: 20) {
            Text("On your phone or computer, sign in to this server and go to your account's Quick Connect settings. Enter the code below.")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            if quickConnectCode.isEmpty {
                ProgressView("Generating code…")
            } else {
                Text(quickConnectCode)
                    .font(.system(size: 64, weight: .bold, design: .monospaced))
                    .tracking(12)
                    .padding(24)
                    .background(Color.white.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 16))

                HStack(spacing: 8) {
                    ProgressView()
                    Text("Waiting for approval…").font(.callout).foregroundColor(.secondary)
                }
            }

            if let error {
                Text(error).foregroundColor(.red).font(.callout).multilineTextAlignment(.center)
            }

            HStack(spacing: 24) {
                Button("Use Username & Password Instead") {
                    stopQuickConnectPolling()
                    error = nil
                    step = .manual
                }
                Button("Change Server") {
                    stopQuickConnectPolling()
                    step = .server
                    error = nil
                }
            }
        }
    }

    // MARK: - Step 3: Manual Login (fallback)

    private var manualLoginView: some View {
        VStack(spacing: 20) {
            TextField("Username", text: $username)
                .textFieldStyle(.plain)

            SecureField("Password", text: $password)
                .textFieldStyle(.plain)
                .onSubmit { performLogin() }

            if let error {
                Text(error).foregroundColor(.red).font(.callout)
            }

            Button {
                performLogin()
            } label: {
                if isLoggingIn {
                    ProgressView()
                } else {
                    Text("Sign In").frame(maxWidth: .infinity)
                }
            }
            .disabled(isLoggingIn || username.isEmpty)

            HStack(spacing: 24) {
                Button("Use Quick Connect Instead") {
                    error = nil
                    step = .quickConnect
                    startQuickConnect()
                }
                Button("Change Server") {
                    step = .server
                    error = nil
                }
            }
        }
    }

    // MARK: - Server Connection

    private func connectToServer() {
        let rawInput = server.trimmingCharacters(in: .whitespacesAndNewlines)
        if rawInput.lowercased() == "demo" {
            Task { await appState.login(server: URL(string: "http://localhost")!, username: "appledemo", password: "review") }
            return
        }

        server = normalizeServerURL(server)
        guard !server.isEmpty else { return }

        isConnecting = true
        error = nil
        lastUsedServer = server

        isConnecting = false
        step = .quickConnect
        startQuickConnect()
    }

    // MARK: - Quick Connect (same endpoints as iOS's LoginView)

    private func startQuickConnect() {
        let finalServer = normalizeServerURL(server)
        guard let url = URL(string: finalServer + "/QuickConnect/Initiate") else {
            error = "Invalid server URL"
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("0", forHTTPHeaderField: "Content-Length")

        let safeDeviceId = appState.deviceId.isEmpty ? UUID().uuidString : appState.deviceId
        let authHeader = "MediaBrowser Client=\"LiveFin\", Device=\"\(appState.clientDevice)\", DeviceId=\"\(safeDeviceId)\", Version=\"\(appState.clientVersion)\""
        request.setValue(authHeader, forHTTPHeaderField: "Authorization")

        Task {
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else { return }
                if http.statusCode == 200 {
                    let result = try JSONDecoder().decode(QuickConnectResult.self, from: data)
                    await MainActor.run {
                        self.quickConnectCode = result.Code
                        self.quickConnectSecret = result.Secret
                        self.pollQuickConnectStatus()
                    }
                } else {
                    await MainActor.run { self.error = "Failed to start Quick Connect (Status \(http.statusCode))" }
                }
            } catch {
                await MainActor.run { self.error = "Quick Connect failed: \(error.localizedDescription)" }
            }
        }
    }

    private func pollQuickConnectStatus() {
        quickConnectTimer?.invalidate()
        quickConnectTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { _ in
            let finalServer = normalizeServerURL(server)
            guard let url = URL(string: finalServer + "/QuickConnect/Connect?secret=\(quickConnectSecret)") else { return }
            var request = URLRequest(url: url)
            request.httpMethod = "GET"

            Task {
                do {
                    let (data, response) = try await URLSession.shared.data(for: request)
                    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return }
                    let result = try JSONDecoder().decode(QuickConnectResult.self, from: data)
                    if result.Authenticated == true {
                        await MainActor.run {
                            self.stopQuickConnectPolling()
                            self.authenticateQuickConnect(secret: result.Secret)
                        }
                    }
                } catch {
                    print("TVLoginView: Quick Connect polling error: \(error)")
                }
            }
        }
    }

    private func authenticateQuickConnect(secret: String) {
        let finalServer = normalizeServerURL(server)
        guard let url = URL(string: finalServer + "/Users/AuthenticateWithQuickConnect") else { return }

        isLoggingIn = true
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let safeDeviceId = appState.deviceId.isEmpty ? UUID().uuidString : appState.deviceId
        let authHeader = "MediaBrowser Client=\"LiveFin\", Device=\"\(appState.clientDevice)\", DeviceId=\"\(safeDeviceId)\", Version=\"\(appState.clientVersion)\""
        request.setValue(authHeader, forHTTPHeaderField: "Authorization")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["Secret": secret])

        Task {
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    await MainActor.run { self.isLoggingIn = false; self.error = "Invalid response" }
                    return
                }
                if http.statusCode == 200 {
                    struct LoginResponse: Decodable {
                        let AccessToken: String
                        let User: UserInfo
                        struct UserInfo: Decodable { let Id: String; let Name: String }
                    }
                    let authResponse = try JSONDecoder().decode(LoginResponse.self, from: data)
                    if let serverUrl = URL(string: finalServer) {
                        await appState.completeLogin(
                            server: serverUrl,
                            userId: authResponse.User.Id,
                            userName: authResponse.User.Name,
                            accessToken: authResponse.AccessToken
                        )
                    }
                    await MainActor.run { self.isLoggingIn = false }
                } else {
                    await MainActor.run {
                        self.isLoggingIn = false
                        self.error = "Quick Connect authorization failed (Status \(http.statusCode))"
                    }
                }
            } catch {
                await MainActor.run {
                    self.isLoggingIn = false
                    self.error = "Authentication error: \(error.localizedDescription)"
                }
            }
        }
    }

    private func stopQuickConnectPolling() {
        quickConnectTimer?.invalidate()
        quickConnectTimer = nil
        quickConnectCode = ""
        quickConnectSecret = ""
    }

    // MARK: - Manual Login

    private func performLogin() {
        Task {
            isLoggingIn = true
            error = nil
            defer { isLoggingIn = false }

            let finalServer = normalizeServerURL(server)
            guard let url = URL(string: finalServer) else {
                error = "Invalid server URL"
                return
            }
            await appState.login(server: url, username: username, password: password)
            if let loginError = appState.loginError {
                error = loginError
            }
        }
    }
}
