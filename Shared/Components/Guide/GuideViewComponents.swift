//
// GuideViewComponents.swift
// Moved UI components for GuideView into Components/Guide View
//

import SwiftUI

// Compact Channel Row used by GuideView
struct GuideChannelHeader: View {
let channel: LiveTvChannelDto
@EnvironmentObject var appState: AppState
@State private var hasLogo: Bool = false

var body: some View {
    HStack(spacing: 4) {
        // Shows favorite icon if favorited, otherwise shows the channel number.
        // A fixed frame ensures logos stay vertically aligned.
        ZStack {
            if channel.userData?.isFavorite == true {
                Image(systemName: "heart.fill")
                    .foregroundColor(.red)
                    .font(.caption2)
            } else if let number = channel.number, !number.isEmpty {
                Text(number)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
            }
        }
        .frame(width: 22, alignment: .center)
        
        ChannelImageView(baseUrl: appState.serverURL, apiKey: appState.apiKey, channelId: channel.id, hasImage: $hasLogo)
            .frame(width: 48, height: 48)
        
        VStack(alignment: .leading, spacing: 2) {
            if !hasLogo {
                Text(channel.name ?? "Unnamed Channel")
                    .font(.caption2)
                    .lineLimit(2)
                    .truncationMode(.tail)
            }
        }
        Spacer(minLength: 0)
    }
    .padding(.vertical, 6)
    .padding(.leading, 6)
    .padding(.trailing, 2)
}


}

// Simple program row used in compact lists in GuideView
struct GuideProgramRow: View {
let program: BaseItemDto

// Cache the formatted time-range string so Date.formatted() isn't called on every render pass.
private var timeRange: String? {
    guard let s = program.startDate, let e = program.endDate else { return nil }
    return "\(s.formatted(date: .omitted, time: .shortened)) — \(e.formatted(date: .omitted, time: .shortened))"
}

var body: some View {
    VStack(alignment: .leading, spacing: 4) {
        Text(program.name ?? "Untitled")
            .font(.subheadline).bold()
            .lineLimit(1)
        if let range = timeRange {
            Text(range)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        if let ep = program.episodeTitle, !ep.isEmpty {
            Text(ep)
                .font(.caption2)
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
    }
    .padding(.vertical, 6)
}


}
