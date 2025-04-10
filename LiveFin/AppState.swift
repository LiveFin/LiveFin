import SwiftUI
import Foundation
@preconcurrency import JellyfinAPI


final class AppState: ObservableObject {
    @Published var client: JellyfinClient?
    @Published var isLoggedIn = false
    @Published var user: UserDto?
    @Published var serverURL: String = ""
    @Published var accessToken: String = ""
    @Published var userID: String = ""
    @Published var username: String = "" // Added property for username
    @Published var deviceId: String = UUID().uuidString  // Unique device ID for each session
    @Published var apiKey: String = "" // Add this to AppState

    @MainActor
    func login(server: URL, username: String, password: String) async {
        do {
            let config = JellyfinClient.Configuration(
                url: server,
                client: "LiveFin",
                deviceName: "iPhone",
                deviceID: UUID().uuidString,
                version: "1.0.0"
            )
            let client = JellyfinClient(configuration: config)

            let requestBody: [String: Any] = [
                "Username": username,
                "Pw": password
            ]
            let requestData = try JSONSerialization.data(withJSONObject: requestBody)

            let url = server.appendingPathComponent("/Users/AuthenticateByName")
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.httpBody = requestData
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")

            let (data, _) = try await URLSession.shared.data(for: request)

            struct LoginResponse: Decodable {
                let AccessToken: String
                let User: UserInfo

                struct UserInfo: Decodable {
                    let Id: String
                    let Name: String
                }
            }

            let authResponse = try JSONDecoder().decode(LoginResponse.self, from: data)

            // Store the access token and initialize the client
            self.accessToken = authResponse.AccessToken
            self.client = client
            self.user = UserDto(id: authResponse.User.Id, name: authResponse.User.Name)
            self.userID = authResponse.User.Id
            print("DEBUG: userID assigned to AppState: \(self.userID)")
            
            // Save userID to Keychain
            KeychainHelper.save(key: "userId", value: authResponse.User.Id)
            print("DEBUG: Saved userID to Keychain: \(authResponse.User.Id)")

            self.isLoggedIn = true
            
            // Save the API key to Keychain after login
            let newApiKey = UUID().uuidString
            self.apiKey = newApiKey
            KeychainHelper.save(key: "apiKey", value: newApiKey)

            // Persist credentials
            KeychainHelper.saveCredentials(server: server.absoluteString, username: username, accessToken: authResponse.AccessToken)

            print("Debug: Access token set to: \(self.accessToken)")
            print("Debug: Client initialized: \(self.client != nil)")
        } catch {
            print("Login failed: \(error.localizedDescription)")
        }
    }

    @MainActor
    func restoreLogin() {
        let creds = KeychainHelper.retrieveCredentials()
        guard let server = creds.serverURL,
              let username = creds.username,
              let token = creds.accessToken else {
            return
        }

        let config = JellyfinClient.Configuration(
            url: URL(string: server)!,
            client: "LiveFin",
            deviceName: "iPhone",
            deviceID: UUID().uuidString,
            version: "1.0.0"
        )
        self.client = JellyfinClient(configuration: config)
        self.serverURL = server
        self.accessToken = token
        self.username = username
        self.isLoggedIn = true
        
        // Restore the API key from Keychain during app startup
        if let storedApiKey = KeychainHelper.load(key: "apiKey") {
            self.apiKey = storedApiKey
            print("DEBUG: Restored apiKey from Keychain: \(self.apiKey)")
        }
        
        if let storedUserId = KeychainHelper.load(key: "userId") {
            self.userID = storedUserId
            print("DEBUG: Restored userID from Keychain: \(self.userID)")
        }

        if let id = KeychainHelper.load(key: "userId"), let name = creds.username {
            self.user = UserDto(id: id, name: name)
            print("DEBUG: Reconstructed user: \(name) (\(id))")
        }
    }

    struct LiveTvChannelDto: Codable, Identifiable {
        let id: String
        let name: String?
        let number: String?
        let imageUrl: String?

        enum CodingKeys: String, CodingKey {
            case id = "Id"
            case name = "Name"
            case number = "Number"
            case imageUrl = "ImageUrl"
        }

        func fullImageUrl(baseURL: String) -> String? {
            guard let imageUrl = imageUrl else { return nil }
            if imageUrl.starts(with: "http") {
                return imageUrl
            } else {
                return "\(baseURL)\(imageUrl)"
            }
        }
    }
    
    func logout() {
        self.isLoggedIn = false
        self.client = nil
        self.accessToken = ""
        self.serverURL = ""
        // Optionally, clear any stored data (e.g., remove credentials from Keychain)
        KeychainHelper.deleteCredentials()
    }
}
