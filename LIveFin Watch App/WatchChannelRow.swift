//
//  WatchChannelRow.swift
//  LiveFin watchOS
//
//  Created by KPGamingz on 9/26/25.
//

import SwiftUI

// Models + WatchAppState are defined in WatchAppState.swift
struct WatchChannelRow: View {
    let channel: WatchChannel
    let baseURL: String
    let apiKey: String

    var body: some View {
        HStack(spacing: 8) {
            Text(channel.number ?? "")
                .font(.caption2)
                .foregroundColor(.secondary)
                .frame(width: 26, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(channel.name ?? "Channel")
                    .font(.body)
                    .lineLimit(1)
                if let prog = channel.currentProgram, let name = prog.name, !name.isEmpty {
                    Text("• \(name)")
                        .font(.caption2)
                        .foregroundColor(.red)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .transition(.opacity)
                }
            }
            Spacer()
        }
        .contentShape(Rectangle())
    }
}

#Preview {
    List {
        WatchChannelRow(channel: .init(id: "1", name: "News", number: "2", currentProgram: .init(id: "p1", name: "Morning Brief", episodeTitle: nil, overview: nil, officialRating: nil, channelId: "1", startDate: Date().addingTimeInterval(-600), endDate: Date().addingTimeInterval(1800))), baseURL: "", apiKey: "")
        WatchChannelRow(channel: .init(id: "2", name: "Sports", number: "10", currentProgram: nil), baseURL: "", apiKey: "")
    }
}
