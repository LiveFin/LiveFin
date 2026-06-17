// GuideViewComponents.swift
// Moved UI components for GuideView into Components/Guide View

import SwiftUI

// Compact Channel Row used by GuideView
struct GuideChannelHeader: View {
    let channel: LiveTvChannelDto
    @EnvironmentObject var appState: AppState
    @State private var hasLogo: Bool = false
    var body: some View {
        HStack(spacing: 8) {
            if let number = channel.number, !number.isEmpty {
                Text(number)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(minWidth: 22, alignment: .leading)
            }
            ChannelImageView(baseUrl: appState.serverURL, apiKey: appState.apiKey, channelId: channel.id, hasImage: $hasLogo)
                .frame(width: 60, height: 60)
            if !hasLogo {
                Text(channel.name ?? "Unnamed Channel")
                    .font(.footnote)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .padding(.leading, 16)
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

// Lightweight RenderBlock type used by GuideView's layout computations.
// Single canonical definition — GuideView.swift must NOT redefine this struct.
struct RenderBlock: Identifiable {
    let id: String
    let item: BaseItemDto
    let s: Date
    let e: Date
    let x: CGFloat
    let w: CGFloat
}
