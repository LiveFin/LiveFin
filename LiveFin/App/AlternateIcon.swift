//
//  AlternateIcon.swift
//  LiveFin
//
//  Created by KPGamingz on 10/31/25.
//

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
import OSLog

enum CustomAppIcon: String, CaseIterable, Identifiable {
    var id: String { self.rawValue }

    case `default` = "LiveFin"
    case Aura = "LiveFin-Aura"
    case Broken = "LiveFin-Broken"
    case Burple = "LiveFin-Burple"
    case Jelly = "LiveFin-Jelly"
    case Noir = "LiveFin-Noir"
    case Real = "LiveFin-Real"
    case Rojo = "LiveFin-Rojo"
    case Slime = "LiveFin-Slime"
    case Yolo = "LiveFin-Yolo"

    /// Clean display names for the UI
    var displayName: String {
        switch self {
        case .default: return "Default"
        case .Aura: return "Aura"
        case .Broken: return "Broken"
        case .Burple: return "Burple"
        case .Jelly: return "Jelly"
        case .Noir: return "Noir"
        case .Real: return "Real"
        case .Rojo: return "Rojo"
        case .Slime: return "Slime"
        case .Yolo: return "Yolo"
        }
    }

    var bundleValue: String? {
        switch self {
        case .default:
            return nil
        default:
            return self.rawValue
        }
    }
}

final class AppIconModel: ObservableObject {

    #if canImport(UIKit)
    @Published var appIcon: CustomAppIcon
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.unknown", category: "AppIconModel")

    init() {
        if #available(iOS 10.3, *) {
            if let iconName = UIApplication.shared.alternateIconName, let icon = CustomAppIcon(rawValue: iconName) {
                appIcon = icon
            } else {
                appIcon = .default
            }
        } else {
            appIcon = .default
        }
    }

    func setAlternateAppIcon(icon: CustomAppIcon) {
        guard #available(iOS 10.3, *) else {
            logger.warning("Alternate icons require iOS 10.3 or later.")
            return
        }

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            guard UIApplication.shared.supportsAlternateIcons else {
                self.logger.warning("Device does not support alternate app icons.")
                return
            }

            let iconName: String? = icon.bundleValue

            guard UIApplication.shared.alternateIconName != iconName else { return }

            UIApplication.shared.setAlternateIconName(iconName) { [weak self] error in
                if let error = error {
                    self?.logger.error("Failed request to update the app’s icon: \(error.localizedDescription)")
                } else {
                    self?.logger.info("Successfully changed app icon to \(iconName ?? "primary")")
                }

                DispatchQueue.main.async {
                    self?.appIcon = icon
                }
            }
        }
    }
    #else
    // Fallback for platforms without UIKit (e.g., watchOS, macOS SwiftUI targets, etc.)
    @Published var appIcon: CustomAppIcon = .default
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.unknown", category: "AppIconModel")

    init() {
        // No-op: alternate app icons are not supported here.
    }

    func setAlternateAppIcon(icon: CustomAppIcon) {
        // Log and do nothing on unsupported platforms.
        logger.info("Alternate icons are not supported on this platform. Requested icon: \(icon.rawValue)")
    }
    #endif
}

struct AlternateIconView: View {
    @StateObject private var model = AppIconModel()

    var body: some View {
        NavigationStack {
            List {
                Section("Choose App Icon") {
                    ForEach(CustomAppIcon.allCases) { icon in
                        Button(action: {
                            model.setAlternateAppIcon(icon: icon)
                        }) {
                            HStack(spacing: 16) {
                                // Image preview of the App Icon asset
                                Image(icon.rawValue)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 60, height: 60)
                                    .cornerRadius(12)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 12)
                                            .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                                    )
                                
                                Text(icon.displayName)
                                    .font(.headline)
                                    .foregroundColor(.primary)
                                
                                Spacer()
                                
                                // Show a checkmark next to the currently active icon
                                if model.appIcon == icon {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(.accentColor)
                                        .imageScale(.large)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
            .navigationTitle("App Icon")
        }
    }
}
