//
//  ChannelImageView.swift
//  LiveFin
//
//  Created by KPGamingz on 4/12/25.
//

import SwiftUI
import JellyfinAPI

struct ChannelImageView: View {
    let baseUrl: String
    let apiKey: String
    let channelId: String

    @State private var imageUrl: URL?

    func fetchImageUrl() {
        // Construct the image URL manually similar to GetItemImageAPI.swift
        let imageType = "Primary"
        let baseUrl = baseUrl.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let apiKey = apiKey
        let path = "/Items/\(channelId)/Images/\(imageType)"
        var urlString = "\(baseUrl)\(path)?maxWidth=200&api_key=\(apiKey)"
        
        if var components = URLComponents(string: urlString) {
            let timestampQuery = URLQueryItem(name: "t", value: "\(Date().timeIntervalSince1970)")
            if components.queryItems != nil {
                components.queryItems?.append(timestampQuery)
            } else {
                components.queryItems = [timestampQuery]
            }
            if let finalUrl = components.url {
                DispatchQueue.main.async {
                    self.imageUrl = finalUrl
                }
            }
        }
    }

    var body: some View {
        AsyncImage(url: imageUrl) { phase in
            switch phase {
            case .empty:
                ProgressView()
            case .success(let image):
                image
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            case .failure:
                Image(systemName: "photo")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .foregroundColor(.gray)
            @unknown default:
                EmptyView()
            }
        }
        .frame(width: 50, height: 50)
        .id(channelId)
        .task {
            fetchImageUrl()
        }
    }
}
