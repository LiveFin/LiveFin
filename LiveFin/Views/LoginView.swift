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

// MARK: - Models
struct PublicUser: Codable, Identifiable {
    let Id: String
    let Name: String
    let PrimaryImageTag: String?
    let HasPassword: Bool?
    var id: String { Id }
}

struct QuickConnectResult: Codable {
    let Secret: String
    let Code: String
    let Authenticated: Bool?
}

enum LoginStep {
    case server
    case userSelection
    case password
    case manual
    case quickConnect
}

struct LoginView: View {
    @EnvironmentObject var appState: AppState
    
    // Persistent Storage
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
    @State private var isFetchingUsers = false
    @State private var isLoggingIn = false
    
    // Flow States
    @State private var step: LoginStep = .server
    @State private var publicUsers: [PublicUser] = []
    @State private var selectedUser: PublicUser? = nil
    
    var body: some View {
        NavigationStack {
            ZStack {
                VStack(alignment: .leading, spacing: 0) {
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
                        .padding(.top, 24)
                        .padding(.bottom, 16)
                    
                    Group {
                        switch step {
                        case .server:
                            serverEntryView
                        case .userSelection:
                            userSelectionView
                        case .password:
                            passwordEntryView
                        case .manual:
                            manualLoginView
                        case .quickConnect:
                            quickConnectView
                        }
                    }
                    .transition(.opacity)
                }
            }
        }
        .onAppear {
            appState.restoreLogin()
            
            if !appState.isLoggedIn && !lastUsedServer.isEmpty {
                server = lastUsedServer
                connectToServer()
            }
        }
        .onDisappear {
            stopQuickConnectPolling()
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
    
    // MARK: - Step 1: Server Entry
    private var serverEntryView: some View {
        Form {
            Section(header: Text("Server Details")) {
                TextField("Server Address (e.g. 192.168.1.100:8096)", text: $server)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                    .keyboardType(.URL)
                    .onSubmit { connectToServer() }
                
                if let error = error {
                    Text(error)
                        .foregroundColor(.red)
                        .font(.caption)
                }
                
                Button("Connect") {
                    connectToServer()
                }
                .disabled(server.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isFetchingUsers)
                
                if isFetchingUsers {
                    ProgressView("Reaching Server...")
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }
        }
    }
    
    // MARK: - Step 2: User Selection
    private var userSelectionView: some View {
        Form {
            Section(header: Text("Who's watching?").font(.headline)) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 16) {
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
                                VStack {
                                    userAvatar(for: user)
                                    Text(user.Name)
                                        .foregroundColor(.primary)
                                        .font(.subheadline)
                                        .multilineTextAlignment(.center)
                                        .lineLimit(2)
                                        .frame(height: 40, alignment: .top)
                                }
                                .frame(width: 96)
                            }
                        }
                        
                        Button {
                            withAnimation {
                                step = .quickConnect
                                error = nil
                                startQuickConnect()
                            }
                        } label: {
                            VStack {
                                ZStack {
                                    Circle()
                                        .fill(Color.blue)
                                        .frame(width: 80, height: 80)
                                    Image(systemName: "tv.and.mediabox.fill")
                                        .font(.system(size: 32))
                                        .foregroundColor(.white)
                                }
                                Text("Quick Connect")
                                    .foregroundColor(.primary)
                                    .font(.subheadline)
                                    .multilineTextAlignment(.center)
                                    .lineLimit(2)
                                    .frame(height: 40, alignment: .top)
                            }
                            .frame(width: 96)
                        }
                        
                        Button {
                            withAnimation {
                                step = .manual
                                error = nil
                                username = ""
                                password = ""
                            }
                        } label: {
                            VStack {
                                ZStack {
                                    Circle()
                                        .fill(Color.secondary.opacity(0.2))
                                        .frame(width: 80, height: 80)
                                    Image(systemName: "person.badge.key.fill")
                                        .font(.title2)
                                        .foregroundColor(.primary)
                                }
                                Text("Manual Login")
                                    .foregroundColor(.primary)
                                    .font(.subheadline)
                                    .multilineTextAlignment(.center)
                                    .lineLimit(2)
                                    .frame(height: 40, alignment: .top)
                            }
                            .frame(width: 96)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 16)
                }
                .listRowInsets(EdgeInsets())
            }
            
            Section {
                Button("Change Server") {
                    withAnimation {
                        step = .server
                        error = nil
                    }
                }
                .foregroundColor(.red)
            }
        }
    }
    
    // MARK: - Step 3: Password Entry
    private var passwordEntryView: some View {
        Form {
            Section {
                HStack {
                    Spacer()
                    VStack(spacing: 12) {
                        if let user = selectedUser {
                            userAvatar(for: user)
                            Text(user.Name)
                                .font(.headline)
                        }
                    }
                    Spacer()
                }
                .padding(.vertical, 8)
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
            
            Section {
                SecureField("Password", text: $password)
                    .onSubmit { performLogin(targetUsername: selectedUser?.Name) }
                
                if let error = error {
                    Text(error)
                        .foregroundColor(.red)
                        .font(.caption)
                }
                
                Button("Sign In") {
                    performLogin(targetUsername: selectedUser?.Name)
                }
                .disabled(isLoggingIn)
                
                if isLoggingIn {
                    ProgressView("Signing in...")
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }
            
            Section {
                Button("Back to Users") {
                    withAnimation {
                        step = .userSelection
                        error = nil
                        password = ""
                    }
                }
                .foregroundColor(.red)
            }
        }
    }
    
    // MARK: - Step 3b: Manual Login
    private var manualLoginView: some View {
        Form {
            Section(header: Text("Manual Login")) {
                TextField("Username", text: $username)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                
                SecureField("Password", text: $password)
                    .onSubmit { performLogin(targetUsername: username) }
                
                if let error = error {
                    Text(error)
                        .foregroundColor(.red)
                        .font(.caption)
                }
                
                Button("Sign In") {
                    performLogin(targetUsername: username)
                }
                .disabled(isLoggingIn || username.isEmpty)
                
                if isLoggingIn {
                    ProgressView("Signing in...")
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }
            
            Section {
                Button("Back") {
                    withAnimation {
                        step = publicUsers.isEmpty ? .server : .userSelection
                        error = nil
                    }
                }
                .foregroundColor(.red)
            }
        }
    }
    
    // MARK: - Step 3c: Quick Connect View
    private var quickConnectView: some View {
        Form {
            Section(header: Text("Quick Connect Status")) {
                VStack(spacing: 16) {
                    Text("Authorize this device by navigating to Settings > Quick Connect on another logged-in client and entering the following code:")
                        .font(.body)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 4)
                    
                    if quickConnectCode.isEmpty {
                        ProgressView("Generating Code...")
                    } else {
                        Text(quickConnectCode)
                            .font(.system(size: 38, weight: .bold, design: .monospaced))
                            .tracking(8)
                            .foregroundColor(.primary)
                            .padding()
                            .frame(maxWidth: .infinity)
                            .background(Color.secondary.opacity(0.1))
                            .cornerRadius(12)
                    }
                    
                    if let error = error {
                        Text(error)
                            .foregroundColor(.red)
                            .font(.caption)
                            .multilineTextAlignment(.center)
                    }
                    
                    if !quickConnectCode.isEmpty && !isLoggingIn {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("Waiting for authentication approval...")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    
                    if isLoggingIn {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("Logging in...")
                                .font(.caption)
                                .foregroundColor(.blue)
                        }
                    }
                }
                .padding(.vertical, 12)
            }
            
            Section {
                Button("Cancel") {
                    withAnimation {
                        stopQuickConnectPolling()
                        step = .userSelection
                    }
                }
                .foregroundColor(.red)
            }
        }
    }
    
    // MARK: - Quick Connect Implementation
    private func startQuickConnect() {
        let finalServer = normalizeURL(server)
        guard let url = URL(string: finalServer + "/QuickConnect/Initiate") else {
            error = "Invalid URL layout"
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        
        let authHeader = "MediaBrowser Client=\"LiveFin\", Device=\"\(appState.clientDevice)\", DeviceId=\"\(appState.deviceId)\", Version=\"\(appState.clientVersion)\""
        request.setValue(authHeader, forHTTPHeaderField: "Authorization")
        
        Task {
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse else { return }
                
                if httpResponse.statusCode == 200 {
                    let result = try JSONDecoder().decode(QuickConnectResult.self, from: data)
                    await MainActor.run {
                        self.quickConnectCode = result.Code
                        self.quickConnectSecret = result.Secret
                        self.pollQuickConnectStatus()
                    }
                } else {
                    await MainActor.run { self.error = "Failed to initiate (Status \(httpResponse.statusCode))" }
                }
            } catch {
                await MainActor.run { self.error = "Quick Connect Failed: \(error.localizedDescription)" }
            }
        }
    }
    
    private func pollQuickConnectStatus() {
        quickConnectTimer?.invalidate()
        quickConnectTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { _ in
            let finalServer = normalizeURL(server)
            guard let url = URL(string: finalServer + "/QuickConnect/Connect?secret=\(quickConnectSecret)") else { return }
            
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            
            Task {
                do {
                    let (data, response) = try await URLSession.shared.data(for: request)
                    guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else { return }
                    
                    let result = try JSONDecoder().decode(QuickConnectResult.self, from: data)
                    
                    if result.Authenticated == true {
                        await MainActor.run {
                            self.stopQuickConnectPolling()
                            self.authenticateQuickConnect(secret: result.Secret)
                        }
                    }
                } catch {
                    print("Quick Connect polling error: \(error)")
                }
            }
        }
    }
    
    private func authenticateQuickConnect(secret: String) {
        let finalServer = normalizeURL(server)
        guard let url = URL(string: finalServer + "/Users/AuthenticateWithQuickConnect") else { return }
        
        isLoggingIn = true
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let authHeader = "MediaBrowser Client=\"LiveFin\", Device=\"\(appState.clientDevice)\", DeviceId=\"\(appState.deviceId)\", Version=\"\(appState.clientVersion)\""
        request.setValue(authHeader, forHTTPHeaderField: "Authorization")
        
        let body = ["Secret": secret]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        
        Task {
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse else {
                    await MainActor.run { self.isLoggingIn = false; self.error = "Invalid Response" }
                    return
                }
                
                if httpResponse.statusCode == 200 {
                    struct LoginResponse: Decodable {
                        let AccessToken: String
                        let User: UserInfo
                        struct UserInfo: Decodable {
                            let Id: String
                            let Name: String
                        }
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
                        self.error = "Quick Connect Auth Failed (Status \(httpResponse.statusCode))"
                    }
                }
            } catch {
                await MainActor.run {
                    self.isLoggingIn = false
                    self.error = "Authentication Error: \(error.localizedDescription)"
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
    
    // MARK: - Avatar Helper
    @ViewBuilder
    private func userAvatar(for user: PublicUser) -> some View {
        let finalServer = normalizeURL(server)
        let urlString = "\(finalServer)/Users/\(user.Id)/Images/Primary?tag=\(user.PrimaryImageTag ?? "")"
        
        if let _ = user.PrimaryImageTag, let url = URL(string: urlString) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .empty:
                    ZStack {
                        Circle().fill(Color.gray.opacity(0.2))
                        ProgressView()
                    }
                    .frame(width: 80, height: 80)
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFill()
                        .frame(width: 80, height: 80)
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
            .foregroundColor(.gray)
            .frame(width: 80, height: 80)
            .background(Circle().fill(Color.white))
    }

    // MARK: - URL Normalization
    private func normalizeURL(_ urlString: String) -> String {
        var str = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        if str.isEmpty { return "" }
        if !str.lowercased().hasPrefix("http://") && !str.lowercased().hasPrefix("https://") {
            str = "http://" + str
        }
        while str.hasSuffix("/") {
            str.removeLast()
        }
        return str
    }
    
    // MARK: - Server Connection & Fetch Users
    private func connectToServer() {
        let rawInput = server.trimmingCharacters(in: .whitespacesAndNewlines)
        
        if rawInput.lowercased() == "demo" {
            Task {
                await appState.login(server: URL(string: "http://localhost")!, username: "appledemo", password: "review")
            }
            return
        }
        
        server = normalizeURL(server)
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
                        withAnimation { self.step = .manual }
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
    
    // MARK: - Login Logic
    private func performLogin(targetUsername: String?) {
        let userToLogin = targetUsername ?? self.username
        Task {
            isLoggingIn = true
            error = nil
            defer { isLoggingIn = false }
            
            let finalServer = normalizeURL(server)
            if let url = URL(string: finalServer) {
                await appState.login(server: url, username: userToLogin, password: password)
                if let loginError = appState.loginError {
                    error = loginError
                }
            } else {
                error = "Invalid server URL"
            }
        }
    }
}
