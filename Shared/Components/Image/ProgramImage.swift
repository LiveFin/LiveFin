//
//  ProgramImage.swift
//  LiveFin
//
//  Created by KPGamingz on 12/31/25.
//

import Foundation
import SwiftUI
import JellyfinAPI

struct ProgramImage: View {
    let program: JFProgram
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var vm: HomeViewModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass: UserInterfaceSizeClass?
    #if os(iOS)
    private var isiPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }
    #else
    private var isiPad: Bool { false }
    #endif

    var body: some View {
        if let url = imageURL() {
            // Replaced custom AsyncImage with CachedAsyncImage for instant scroll loads
            CachedAsyncImage(url: url) { phase in
                switch phase {
                case .empty:
                    ZStack { ProgressView() }
                case .success(let img):
                    if isiPad || horizontalSizeClass == .regular {
                        img.resizable().scaledToFit()
                    } else {
                        img.resizable().scaledToFill()
                    }
                case .failure:
                    ZStack { Image(systemName: "film").imageScale(.large).foregroundColor(.secondary) }
                @unknown default:
                    EmptyView()
                }
            }
        } else {
            ZStack { Image(systemName: "film").imageScale(.large).foregroundColor(.secondary) }
        }
    }

    private func imageURL() -> URL? {
        guard !appState.serverURL.isEmpty, !appState.apiKey.isEmpty else { return nil }
        let base = appState.serverURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let path = "/Items/\(program.id)/Images/Primary"
        var comps = URLComponents(string: base + path)
        #if os(macOS)
        let maxWidth = "900"
        #elseif targetEnvironment(macCatalyst)
        let maxWidth = "800"
        #else
        let maxWidth = (isiPad || horizontalSizeClass == .regular) ? "700" : "600"
        #endif
        
        // Removed dynamic dynamic timestamp parameter "t" to allow cache indexing
        comps?.queryItems = [
            URLQueryItem(name: "maxWidth", value: maxWidth),
            URLQueryItem(name: "api_key", value: appState.apiKey)
        ]
        return comps?.url
    }
}
