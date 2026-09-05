//
//  TVLoginView.swift
//  LiveFin
//
//  Created by KPGamingz on 7/18/26.
//

import SwiftUI

private enum TVLoginStep {
    case server
    case userSelection
    case password
    case quickConnect
    case manual
}

struct TVLoginView: View {
    @EnvironmentObject var appState: AppState

    @AppStorage("lastUsedServer") private var lastUsedServer: String = ""

    // Form States
    @State private var server = ""
    @State private var username = ""
    @State private var password = ""

    // Quick Connect States
    @State private var quickConnectCode = ""
    @State private var quickConnectSecret = ""
    @State private var quickConnectTimer: Timer?

    // Status States
    @State private var error: String?
    @State private var isConnecting = false
    @State private var isLoggingIn = false
    @State private var isFetchingUsers = false

    // Flow States
    @State private var step: TVLoginStep = .server
    @State private var publicUsers: [PublicUser] = []
    @State private var selectedUser: PublicUser? = nil
    
    @FocusState private var serverFieldFocused: Bool

    var body: some View {
        ZStack {
            // Updated gradient to match the app icon (cyan/teal to deeper blue)
            LinearGradient(
                colors: [Color(hex: "#00E5FF"), Color(hex: "#007AFF")],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 40) {
                Text("LiveFin")
                    .font(.system(size: 80, weight: .black, design: .rounded))
                    .foregroundColor(.white)
                    .shadow(color: .black.opacity(0.3), radius: 10, x: 0, y: 5)
                    .padding(.top, 40)

                Group {
                    switch step {
                    case .server: serverEntryView
                    case .userSelection: userSelectionView
                    case .password: passwordEntryView
                    case .quickConnect: quickConnectView
                    case .manual: manualLoginView
                    }
                }
                .frame(maxWidth: .infinity)
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
                .foregroundColor(.white.opacity(0.9))

            TextField("e.g. 192.168.1.100:8096", text: $server)
                .textFieldStyle(.plain)
                .focused($serverFieldFocused)
                .onSubmit { connectToServer() }
                .frame(maxWidth: 900)

            if let error {
                Text(error).foregroundColor(.red).font(.callout)
            }

            Button {
                connectToServer()
            } label: {
                if isFetchingUsers || isConnecting {
                    ProgressView()
                } else {
                    Text("Connect").frame(maxWidth: .infinity)
                }
            }
            .disabled(server.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isFetchingUsers || isConnecting)
            .frame(maxWidth: 900)
        }
        .onAppear { serverFieldFocused = true }
    }
    
    // MARK: - Step 2: User Selection
    
    private var userSelectionView: some View {
        VStack(spacing: 40) {
            Text("Who's watching?")
                .font(.title2)
                .foregroundColor(.white.opacity(0.9))
            
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 40) {
                    ForEach(publicUsers) { user in
                        Button {
                            withAnimation {
                                selectedUser = user
                                error = nil
                                password = ""
                                
                                if user.HasPassword == false {
                                    performLogin(targetUsername: user.Name)
                                } else {
                                    step = .password
                                }
                            }
                        } label: {
                            VStack(spacing: 16) {
                                userAvatar(for: user)
                                Text(user.Name)
                                    .font(.title3)
                                    .lineLimit(1)
                            }
                            .frame(width: 220)
                            .padding(.vertical, 20)
                        }
                        .buttonStyle(.card)
                    }
                    
                    Button {
                        withAnimation {
                            step = .quickConnect
                            error = nil
                            startQuickConnect()
                        }
                    } label: {
                        VStack(spacing: 16) {
                            ZStack {
                                Circle().fill(Color.white.opacity(0.2)).frame(width: 150, height: 150)
                                Image(systemName: "tv.and.mediabox.fill").font(.system(size: 60)).foregroundColor(.white)
                            }
                            Text("Quick Connect").font(.title3)
                        }
                        .frame(width: 220)
                        .padding(.vertical, 20)
                    }
                    .buttonStyle(.card)
                    
                    Button {
                        withAnimation {
                            step = .manual
                            error = nil
                            username = ""
                            password = ""
                        }
                    } label: {
                        VStack(spacing: 16) {
                            ZStack {
                                Circle().fill(Color.white.opacity(0.1)).frame(width: 150, height: 150)
                                Image(systemName: "person.badge.key.fill").font(.system(size: 60)).foregroundColor(.white)
                            }
                            Text("Manual Login").font(.title3)
                        }
                        .frame(width: 220)
                        .padding(.vertical, 20)
                    }
                    .buttonStyle(.card)
                }
                .padding(40)
                // Center the items if they don't fill the screen (1920 tvOS width minus 120 padding)
                .frame(minWidth: 1800, alignment: .center)
            }
            
            Button("Change Server") {
                withAnimation {
                    step = .server
                    error = nil
                }
            }
            .padding(.top, 20)
        }
    }
    
    // MARK: - Step 3: Password Entry
    
    private var passwordEntryView: some View {
        VStack(spacing: 24) {
            if let user = selectedUser {
                userAvatar(for: user)
                Text(user.Name)
                    .font(.title)
                    .foregroundColor(.white)
            }
            
            SecureField("Password", text: $password)
                .textFieldStyle(.plain)
                .onSubmit { performLogin(targetUsername: selectedUser?.Name) }
                .frame(maxWidth: 900)
            
            if let error {
                Text(error).foregroundColor(.red).font(.callout)
            }
            
            Button {
                performLogin(targetUsername: selectedUser?.Name)
            } label: {
                if isLoggingIn {
                    ProgressView()
                } else {
                    Text("Sign In").frame(maxWidth: .infinity)
                }
            }
            .disabled(isLoggingIn)
            .frame(maxWidth: 900)
            
            Button("Back to Users") {
                withAnimation {
                    step = .userSelection
                    error = nil
                    password = ""
                }
            }
            .frame(maxWidth: 900)
        }
    }

    // MARK: - Step 4: Manual Login

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
            .frame(maxWidth: 900)

            HStack(spacing: 24) {
                Button("Back") {
                    withAnimation {
                        step = publicUsers.isEmpty ? .server : .userSelection
                        error = nil
                    }
                }
                Button("Change Server") {
                    step = .server
                    error = nil
                }
            }
        }
        .frame(maxWidth: 900)
    }

    // MARK: - Step 5: Quick Connect

    private var quickConnectView: some View {
        VStack(spacing: 20) {
            Text("On your phone or computer, sign in to this server and go to your account's Quick Connect settings. Enter the code below.")
                .font(.body)
                .foregroundColor(.white.opacity(0.9))
                .multilineTextAlignment(.center)

            if quickConnectCode.isEmpty {
                ProgressView("Generating code…")
            } else {
                Text(quickConnectCode)
                    .font(.system(size: 64, weight: .bold, design: .monospaced))
                    .tracking(12)
                    .foregroundColor(.white)
                    .padding(24)
                    .background(Color.white.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 16))

                HStack(spacing: 8) {
                    ProgressView()
                    Text("Waiting for approval…").font(.callout).foregroundColor(.white.opacity(0.8))
                }
            }

            if let error {
                Text(error).foregroundColor(.red).font(.callout).multilineTextAlignment(.center)
            }

            HStack(spacing: 24) {
                Button("Back") {
                    withAnimation {
                        stopQuickConnectPolling()
                        step = publicUsers.isEmpty ? .server : .userSelection
                        error = nil
                    }
                }
                Button("Change Server") {
                    stopQuickConnectPolling()
                    step = .server
                    error = nil
                }
            }
        }
        .frame(maxWidth: 900)
    }

    // MARK: - Server Connection & User Fetch

    private func connectToServer() {
        let rawInput = server.trimmingCharacters(in: .whitespacesAndNewlines)
        if rawInput.lowercased() == "demo" {
            Task { await appState.login(server: URL(string: "http://localhost")!, username: "appledemo", password: "review") }
            return
        }

        server = normalizeServerURL(server)
        guard !server.isEmpty else { return }

        Task {
            isFetchingUsers = true
            error = nil
            defer { isFetchingUsers = false }
            
            guard let url = URL(string: server + "/Users/Public") else {
                error = "Invalid server URL Format"
                return
            }
            
            var request = URLRequest(url: url)
            request.timeoutInterval = 10
            
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse else {
                    error = "Invalid response from server."
                    return
                }
                
                if httpResponse.statusCode == 200 {
                    let users = try JSONDecoder().decode([PublicUser].self, from: data)
                    await MainActor.run {
                        self.lastUsedServer = self.server
                        self.publicUsers = users
                        withAnimation {
                            if users.isEmpty {
                                self.step = .manual
                            } else {
                                self.step = .userSelection
                            }
                        }
                    }
                } else {
                    await MainActor.run {
                        self.lastUsedServer = self.server
                        withAnimation {
                            self.step = .manual
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    if step == .server {
                        self.error = "Could not connect: \(error.localizedDescription)"
                    }
                }
            }
        }
    }

    // MARK: - Quick Connect Logic

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

    // MARK: - Login Action

    private func performLogin(targetUsername: String? = nil) {
        let userToLogin = targetUsername ?? self.username
        Task {
            isLoggingIn = true
            error = nil
            defer { isLoggingIn = false }

            let finalServer = normalizeServerURL(server)
            guard let url = URL(string: finalServer) else {
                error = "Invalid server URL"
                return
            }
            await appState.login(server: url, username: userToLogin, password: password)
            if let loginError = appState.loginError {
                error = loginError
            }
        }
    }
    
    // MARK: - Avatar Helper

    @ViewBuilder
    private func userAvatar(for user: PublicUser) -> some View {
        let finalServer = normalizeServerURL(server)
        let urlString = "\(finalServer)/Users/\(user.Id)/Images/Primary?tag=\(user.PrimaryImageTag ?? "")"
        
        if let _ = user.PrimaryImageTag, let url = URL(string: urlString) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .empty:
                    ZStack {
                        Circle().fill(Color.gray.opacity(0.2))
                        ProgressView()
                    }
                    .frame(width: 150, height: 150)
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFill()
                        .frame(width: 150, height: 150)
                        .clipShape(Circle())
                case .failure:
                    defaultAvatar()
                @unknown default:
                    defaultAvatar()
                }
            }
        } else {
            defaultAvatar()
        }
    }
    
    @ViewBuilder
    private func defaultAvatar() -> some View {
        Image(systemName: "person.circle.fill")
            .resizable()
            .foregroundColor(.white.opacity(0.8))
            .frame(width: 150, height: 150)
            .background(Circle().fill(Color.white.opacity(0.2)))
    }
}
