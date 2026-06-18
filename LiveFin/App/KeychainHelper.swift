//
//  KeychainHelper.swift
//  LiveFin
//
//  Created by KPGamingz on 4/10/25.
//


import Security
import SwiftUI

class KeychainHelper {
    static func save(key: String, value: String) {
        print("DEBUG: Saving to Keychain — key: \(key), value: \(value)")
        guard let valueData = value.data(using: .utf8) else { return }
        let addQuery: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrAccount: key,
            kSecValueData: valueData
        ]
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        if status == errSecDuplicateItem {
            // Update existing item
            let updateQuery: [CFString: Any] = [
                kSecClass: kSecClassGenericPassword,
                kSecAttrAccount: key
            ]
            let attrs: [CFString: Any] = [kSecValueData: valueData]
            let updateStatus = SecItemUpdate(updateQuery as CFDictionary, attrs as CFDictionary)
            if updateStatus != errSecSuccess {
                print("DEBUG: Keychain update failed for key \(key) status=\(updateStatus)")
            } else {
                print("DEBUG: Keychain updated existing key \(key)")
            }
        } else if status != errSecSuccess {
            print("DEBUG: Keychain add failed for key \(key) status=\(status)")
        }
    }

    static func load(key: String) -> String? {
        print("DEBUG: Loading from Keychain — key: \(key)")
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrAccount: key,
            kSecReturnData: kCFBooleanTrue!,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        
        if status == errSecSuccess, let data = result as? Data {
            let decoded = String(data: data, encoding: .utf8)
            print("DEBUG: Loaded value from Keychain for key \(key): \(decoded ?? "nil")")
            return decoded
        } else {
            return nil
        }
    }
    
    static func delete(key: String) {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrAccount: key
        ]
        
        SecItemDelete(query as CFDictionary)
    }
    
    @MainActor static func generateSessionKey() -> String {
        let uuidKey = "deviceUUID"
        if let savedUUID = load(key: uuidKey) {
            return savedUUID
        } else {
            let newUUID = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
            save(key: uuidKey, value: newUUID)
            return newUUID
        }
    }
    
    @MainActor static func saveCredentials(server: String, username: String, accessToken: String) {
        let sessionKey = generateSessionKey()  // Generate a new session key
        save(key: "serverURL", value: server)
        save(key: "username", value: username)
        save(key: "accessToken", value: accessToken)
        save(key: "sessionKey", value: sessionKey)  // Save the session key
    }
    
    static func retrieveCredentials() -> (serverURL: String?, username: String?, accessToken: String?, sessionKey: String?) {
        let savedServerURL = load(key: "serverURL")
        let savedUsername = load(key: "username")
        let savedAccessToken = load(key: "accessToken")
        let savedSessionKey = load(key: "sessionKey")  // Retrieve the session key
        return (savedServerURL, savedUsername, savedAccessToken, savedSessionKey)
    }
    
    static func deleteCredentials() {
        delete(key: "serverURL")
        delete(key: "username")
        delete(key: "accessToken")
        delete(key: "sessionKey")  // Delete the session key
    }
    
    static func saveUser<T: Codable>(_ user: T, forKey key: String = "user") {
        do {
            let data = try JSONEncoder().encode(user)
            let base64String = data.base64EncodedString()
            save(key: key, value: base64String)
        } catch {
            print("DEBUG: Failed to encode user: \(error)")
        }
    }
    
    static func loadUser<T: Codable>(forKey key: String = "user", as type: T.Type) -> T? {
        guard let base64String = load(key: key),
              let data = Data(base64Encoded: base64String) else {
            return nil
        }

        do {
            let user = try JSONDecoder().decode(T.self, from: data)
            return user
        } catch {
            print("DEBUG: Failed to decode user: \(error)")
            return nil
        }
    }
}
