//
//  TVChannel.swift
//  LiveFin
//
//  Created by Kervens on 7/17/26.
//

import SwiftUI
import Combine
import Foundation

// MARK: - Local Models (Assuming these sync with your Shared models later)
struct TVChannel: Identifiable, Codable, Hashable {
    let id: String
    var name: String?
    var number: String?
    var imageUrl: String?
}

@MainActor
final class TVAppState: ObservableObject {
    // Auth & Session
    @Published var serverURL: String = ""
    @Published var accessToken: String = ""
    @Published var userId: String = ""
    
    // Content
    @Published var channels: [TVChannel] = []
    @Published var isLoadingChannels: Bool = false
    @Published var lastError: String? = nil
    
    var isAuthenticated: Bool {
        !serverURL.isEmpty && !accessToken.isEmpty && !userId.isEmpty
    }
    
    private let defaults = UserDefaults.standard
    private let kServer = "tvos_serverURL"
    private let kToken = "tvos_accessToken"
    private let kUserId = "tvos_userId"
    
    init() {
        restoreCredentials()
    }
    
    func restoreCredentials() {
        if let s = defaults.string(forKey: kServer) { serverURL = s }
        if let t = defaults.string(forKey: kToken) { accessToken = t }
        if let u = defaults.string(forKey: kUserId) { userId = u }
        
        // For development/testing on Simulator, you can hardcode credentials here
        // serverURL = "http://your-jellyfin-server:8096"
        // accessToken = "YOUR_TOKEN"
        // userId = "YOUR_USER_ID"
    }
    
    func saveCredentials(server: String, token: String, user: String) {
        serverURL = server
        accessToken = token
        userId = user
        defaults.set(server, forKey: kServer)
        defaults.set(token, forKey: kToken)
        defaults.set(user, forKey: kUserId)
    }
    
    func logout() {
        serverURL = ""
        accessToken = ""
        userId = ""
        channels = []
        defaults.removeObject(forKey: kServer)
        defaults.removeObject(forKey: kToken)
        defaults.removeObject(forKey: kUserId)
    }
    
    // MARK: - API Methods
    private func setAuthHeader(on request: inout URLRequest) {
        let deviceName = "Apple TV"
        let deviceId = "livefin-tvos"
        let headerValue = "MediaBrowser Client=\"LiveFin tvOS\", Device=\"\(deviceName)\", DeviceId=\"\(deviceId)\", Version=\"1.0\", Token=\"\(accessToken)\""
        request.setValue(headerValue, forHTTPHeaderField: "Authorization")
    }
    
    func loadChannels() async {
        guard isAuthenticated, !isLoadingChannels else { return }
        guard let base = URL(string: serverURL) else { return }
        
        isLoadingChannels = true
        lastError = nil
        defer { isLoadingChannels = false }
        
        var comps = URLComponents(url: base.appendingPathComponent("LiveTv/Channels"), resolvingAgainstBaseURL: false)
        comps?.queryItems = [URLQueryItem(name: "userId", value: userId)]
        
        guard let url = comps?.url else { return }
        
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        setAuthHeader(on: &req)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let httpResp = resp as? HTTPURLResponse, httpResp.statusCode == 200 else {
                lastError = "Failed to load channels."
                return
            }
            
            // Minimal DTO mapping for the tvOS layer
            struct ChannelDTO: Decodable {
                let Id: String
                let Name: String?
                let Number: String?
                let ChannelNumber: String?
                
                var resolvedNumber: String? { Number ?? ChannelNumber }
            }
            
            struct RespDTO: Decodable { let Items: [ChannelDTO]? }
            
            let result = try JSONDecoder().decode(RespDTO.self, from: data)
            
            var mapped = (result.Items ?? []).map { 
                TVChannel(id: $0.Id, name: $0.Name, number: $0.resolvedNumber) 
            }
            
            mapped.sort { ($0.number ?? "") < ($1.number ?? "") }
            self.channels = mapped
            
        } catch {
            self.lastError = error.localizedDescription
        }
    }
}
