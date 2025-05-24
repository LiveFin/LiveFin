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
        let imageType = "Primary"
        let baseUrl = baseUrl.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let path = "/Items/\(channelId)/Images/\(imageType)"
        let urlString = "\(baseUrl)\(path)?maxWidth=200&api_key=\(apiKey)"

        guard var components = URLComponents(string: urlString) else { return }
        // Always add a timestamp to force reload
        let timestampQuery = URLQueryItem(name: "t", value: "\(Date().timeIntervalSince1970)")
        components.queryItems = (components.queryItems ?? []) + [timestampQuery]

        guard let finalUrl = components.url else { return }

        let request = URLRequest(url: finalUrl)

        let task = URLSession.shared.dataTask(with: request) { data, response, _ in
            guard let data = data, let response = response else { return }

            DispatchQueue.main.async {
                self.imageUrl = finalUrl
            }
        }
        task.resume()
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
