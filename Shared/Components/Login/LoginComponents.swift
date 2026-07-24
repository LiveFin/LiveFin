//
//  LoginComponents.swift
//  LiveFin
//
//  Created by Kervens on 7/18/26.
//

import SwiftUI
import Combine

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

// MARK: - Shared server URL normalization (identical logic used by both platforms)

func normalizeServerURL(_ urlString: String) -> String {
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
