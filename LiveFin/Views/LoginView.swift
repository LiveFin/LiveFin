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
#if canImport(UIKit)
import UIKit
#endif

enum LoginStep {
    case splash
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
    @AppStorage("recentServers") private var recentServersJSON: String = "[]"
    
    // Form States
    @State private var server: String = ""
    @State private var username: String = ""
    @State private var password: String = ""
    
    // Quick Connect States
    @State private var quickConnectCode: String = ""
    @State private var quickConnectSecret: String = ""
    @State private var quickConnectTimer: Timer? = nil
    
    // Status States
    @State private var error: String? = nil
    @State private var isFetchingUsers: Bool = false
    @State private var isLoggingIn: Bool = false
    
    // Flow States (Starts on the splash screen)
    @State private var step: LoginStep = .splash
    @State private var publicUsers: [PublicUser] = []
    @State private var selectedUser: PublicUser? = nil
    
    private var recentServers: [String] {
        get {
            guard let data = recentServersJSON.data(using: .utf8),
                  let list = try? JSONDecoder().decode([String].self, from: data) else {
                return lastUsedServer.isEmpty ? [] : [lastUsedServer]
            }
            return list
        }
        nonmutating set {
            if let data = try? JSONEncoder().encode(newValue),
               let string = String(data: data, encoding: .utf8) {
                recentServersJSON = string
            }
        }
    }
    
    var body: some View {
        NavigationStack {
            ZStack {
                if step == .splash {
                    splashScreenView
                        .transition(.opacity)
                } else {
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
                            case .splash:
                                EmptyView()
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
                    }
                    .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                            removal: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.3), value: step)
        }
        .onAppear {
            appState.restoreLogin()
            
            // Auto-fill stored server for when they proceed
            if server.isEmpty {
                if let first = recentServers.first, !first.isEmpty {
                    server = first
                } else if !lastUsedServer.isEmpty {
                    server = lastUsedServer
                }
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
    
    // MARK: - Reusable Error Banner
    @ViewBuilder
    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.red)
                .font(.subheadline)
            
            Text(message)
                .foregroundColor(.red)
                .font(.footnote)
                .fixedSize(horizontal: false, vertical: true)
            
            Spacer()
        }
        .padding(10)
        .background(Color.red.opacity(0.12))
        .cornerRadius(8)
    }

    // MARK: - Splash Screen View
    private var isPad: Bool {
        #if canImport(UIKit)
        return UIDevice.current.userInterfaceIdiom == .pad
        #else
        return false
        #endif
    }
    
    private var splashScreenView: some View {
        ZStack {
            // Adaptive Device Background
            Image(isPad ? "SplashBackgroundiPad" : "SplashBackgroundiOS")
                .resizable()
                .scaledToFill()
                .ignoresSafeArea()
            
            VStack {
                // Reduced top spacing to place logo higher toward the top
                Spacer()
                    .frame(height: isPad ? 70 : 48)
                
                // Enlarged LiveFin Logo positioned toward top
                Image("Logo with Text")
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: isPad ? 360 : 270)
                    .shadow(color: .black.opacity(0.18), radius: 14, x: 0, y: 7)
                    .padding(.horizontal, 24)
                
                // Expanded bottom spacer to push CTA to bottom
                Spacer()
                
                // "Login with Jellyfin" CTA Button
                Button {
                    withAnimation {
                        let targetServer = !server.isEmpty ? server : (recentServers.first ?? lastUsedServer)
                        if !targetServer.isEmpty {
                            server = targetServer
                            connectToServer()
                        } else {
                            step = .server
                        }
                    }
                } label: {
                    HStack(spacing: 12) {
                        // Jellyfin Brand Icon
                        Image("Jellyfin Logo")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 28, height: 28)
                        
                        Text("Login with Jellyfin")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundColor(Color(.label))
                    }
                    .padding(.horizontal, 28)
                    .padding(.vertical, 14)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Color(.systemBackground).opacity(0.95))
                            .shadow(color: .black.opacity(0.18), radius: 14, x: 0, y: 6)
                    )
                }
                .buttonStyle(.plain)
                .padding(.bottom, isPad ? 56 : 40)
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
                    errorBanner(error)
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
            
            if !recentServers.isEmpty {
                Section(header: Text("Recent Servers")) {
                    ForEach(recentServers, id: \.self) { savedServer in
                        Button {
                            server = savedServer
                            connectToServer()
                        } label: {
                            HStack(spacing: 12) {
                                Text(savedServer)
                                    .foregroundColor(.primary)
                                    .font(.subheadline)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                
                                Spacer()
                                
                                Image(systemName: "chevron.right")
                                    .font(.caption2.bold())
                                    .foregroundColor(.secondary.opacity(0.7))
                            }
                        }
                    }
                    .onDelete(perform: deleteRecentServer)
                }
            }
            
            Section {
                Button("Back") {
                    withAnimation {
                        step = .splash
                        error = nil
                    }
                }
                .foregroundColor(.secondary)
            }
        }
    }
    
    // MARK: - Step 2: User Selection
    private var userSelectionView: some View {
        Form {
            Section(header: Text("Who's watching?").font(.headline)) {
                if let error = error {
                    errorBanner(error)
                        .padding(.vertical, 4)
                }
                
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
                    .onChange(of: password) { _ in
                        if error != nil { error = nil }
                    }
                
                if let error = error {
                    errorBanner(error)
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
                    .onChange(of: username) { _ in
                        if error != nil { error = nil }
                    }
                
                SecureField("Password", text: $password)
                    .onSubmit { performLogin(targetUsername: username) }
                    .onChange(of: password) { _ in
                        if error != nil { error = nil }
                    }
                
                if let error = error {
                    errorBanner(error)
                }
                
                Button("Sign In") {
                    performLogin(targetUsername: username)
                }
                .disabled(isLoggingIn || username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                
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
                        errorBanner(error)
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
        request.httpMethod = "POST"
        request.setValue("0", forHTTPHeaderField: "Content-Length")
        
        let safeDeviceId = appState.deviceId.isEmpty ? UUID().uuidString : appState.deviceId
        let authHeader = "MediaBrowser Client=\"LiveFin\", Device=\"\(appState.clientDevice)\", DeviceId=\"\(safeDeviceId)\", Version=\"\(appState.clientVersion)\""
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
        
        let safeDeviceId = appState.deviceId.isEmpty ? UUID().uuidString : appState.deviceId
        let authHeader = "MediaBrowser Client=\"LiveFin\", Device=\"\(appState.clientDevice)\", DeviceId=\"\(safeDeviceId)\", Version=\"\(appState.clientVersion)\""
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

    // MARK: - Recent Servers Management
    private func saveServerToRecent(_ serverUrl: String) {
        let clean = normalizeURL(serverUrl)
        guard !clean.isEmpty else { return }
        var current = recentServers
        current.removeAll { $0.caseInsensitiveCompare(clean) == .orderedSame }
        current.insert(clean, at: 0)
        if current.count > 5 {
            current = Array(current.prefix(5))
        }
        recentServers = current
        lastUsedServer = clean
    }
    
    private func deleteRecentServer(at offsets: IndexSet) {
        var list = recentServers
        list.remove(atOffsets: offsets)
        recentServers = list
    }

    // MARK: - URL Normalization
    private func normalizeURL(_ urlString: String) -> String {
        var str = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        if str.isEmpty { return "" }
        
        let lower = str.lowercased()
        if !lower.hasPrefix("http://") && !lower.hasPrefix("https://") {
            let isIPv4 = lower.range(of: "^[0-9]{1,3}\\.[0-9]{1,3}\\.[0-9]{1,3}\\.[0-9]{1,3}(:[0-9]+)?$", options: .regularExpression) != nil
            let isIPv6 = lower.hasPrefix("[")
            let isLocal = lower.hasPrefix("localhost") || lower.contains(".local")
            
            if isIPv4 || isIPv6 || isLocal {
                str = "http://" + str
            } else {
                str = "https://" + str
            }
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
        guard !server.isEmpty else {
            withAnimation { step = .server }
            return
        }
        
        Task {
            await MainActor.run {
                isFetchingUsers = true
                error = nil
            }
            defer {
                Task { @MainActor in isFetchingUsers = false }
            }
            
            guard let url = URL(string: server + "/Users/Public") else {
                await MainActor.run {
                    error = "Invalid server URL format"
                    withAnimation { step = .server }
                }
                return
            }
            
            var request = URLRequest(url: url)
            request.timeoutInterval = 10
            
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse else {
                    await MainActor.run {
                        error = "Invalid response from server."
                        withAnimation { step = .server }
                    }
                    return
                }
                
                if httpResponse.statusCode == 200 {
                    let users = try JSONDecoder().decode([PublicUser].self, from: data)
                    await MainActor.run {
                        self.saveServerToRecent(self.server)
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
                        self.saveServerToRecent(self.server)
                        withAnimation { self.step = .manual }
                    }
                }
            } catch {
                await MainActor.run {
                    self.error = "Could not connect: \(error.localizedDescription)"
                    withAnimation { step = .server }
                }
            }
        }
    }
    
    // MARK: - Login Logic
    private func performLogin(targetUsername: String?) {
        let userToLogin = targetUsername ?? self.username
        guard !userToLogin.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            self.error = "Username cannot be empty."
            return
        }
        
        Task {
            await MainActor.run {
                isLoggingIn = true
                error = nil
            }
            
            let finalServer = normalizeURL(server)
            if let url = URL(string: finalServer) {
                await appState.login(server: url, username: userToLogin, password: password)
                
                await MainActor.run {
                    isLoggingIn = false
                    if !appState.isLoggedIn {
                        // Display server-provided message if available, otherwise show clear authentication warning
                        if let loginError = appState.loginError, !loginError.isEmpty {
                            self.error = loginError
                        } else {
                            self.error = "Invalid username or password. Please try again."
                        }
                    }
                }
            } else {
                await MainActor.run {
                    isLoggingIn = false
                    self.error = "Invalid server URL"
                }
            }
        }
    }
}
