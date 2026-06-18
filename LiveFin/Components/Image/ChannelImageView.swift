//
//  ChannelImageView.swift
//  LiveFin
//
//  Created by KPGamingz on 4/12/25.
//

import SwiftUI
import JellyfinAPI
import UIKit

struct ChannelImageView: View {
    let baseUrl: String
    let apiKey: String
    let channelId: String
    // Optional binding the caller can use to know whether an image is available
    var hasImage: Binding<Bool>? = nil

    @State private var imageUrl: URL?
    @State private var uiImage: UIImage?
    @Environment(\.colorScheme) private var colorScheme

    func buildImageUrl() -> URL? {
        let imageType = "Primary"
        let baseUrl = baseUrl.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let path = "/Items/\(channelId)/Images/\(imageType)"
        let urlString = "\(baseUrl)\(path)?maxWidth=200&api_key=\(apiKey)"
        return URL(string: urlString)
    }

    private func loadImageIfNeeded(from url: URL) {
        // First, check our shared cache (memory+disk)
        if let cached = ImageCacheManager.shared.imageIfCached(for: url) {
            self.uiImage = cached
            return
        }
        // Not cached: fetch and cache via manager
        ImageCacheManager.shared.load(url) { image in
            guard let image else { return }
            self.uiImage = image
        }
    }

    var body: some View {
        Group {
            if let img = uiImage {
                Image(uiImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .modifier(ShadowIfLight(colorScheme: colorScheme))
            } else if let url = imageUrl {
                // Show lightweight placeholder while loading from cache/network
                ZStack {
                    ProgressView()
                }
                .onAppear { loadImageIfNeeded(from: url) }
            } else {
                ProgressView()
            }
        }
        .onAppear {
            if imageUrl == nil { imageUrl = buildImageUrl() }
            // Try to populate instantly from cache to avoid flicker
            if let url = imageUrl, uiImage == nil, let cached = ImageCacheManager.shared.imageIfCached(for: url) {
                self.uiImage = cached
            }
        }
        .onChange(of: uiImage) { oldValue, newValue in
            // notify caller when an image becomes available
            if newValue != nil { hasImage?.wrappedValue = true }
        }
    }
}

private struct ShadowIfLight: ViewModifier {
    let colorScheme: ColorScheme
    func body(content: Content) -> some View {
        Group {
            if colorScheme == .light {
                content.shadow(color: Color.black.opacity(0.6), radius: 4, x: 0, y: 1)
            } else {
                content
            }
        }
    }
}

