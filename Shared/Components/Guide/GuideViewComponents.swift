//
//  GuideViewComponents.swift
//  LiveFin
//

import SwiftUI
import JellyfinAPI

struct GuideChannelHeader: View {
    let channel: LiveTvChannelDto
    @EnvironmentObject var appState: AppState
    @State private var hasLogo: Bool = false

    var body: some View {
        HStack(spacing: 4) {
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

struct GuideProgramRow: View {
    let program: BaseItemDto

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

struct ProgramBlockView: View, Equatable {
    let b: RenderBlock
    let channel: LiveTvChannelDto
    let appState: AppState

    static func == (lhs: ProgramBlockView, rhs: ProgramBlockView) -> Bool {
        return lhs.b == rhs.b
    }

    var body: some View {
        let jf = buildJFProgram(from: b.item, channel: channel, clampedStart: b.s, clampedEnd: b.e)

        NavigationLink(destination: ProgramView(program: jf, appState: appState).environmentObject(appState)) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .top) {
                    Text(b.item.name ?? "Untitled")
                        .font(.caption).bold()
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .allowsTightening(true)
                    
                    if b.isRecording {
                        Spacer(minLength: 2)
                        Image(systemName: "record.circle")
                            .foregroundColor(.red)
                            .font(.system(size: 10))
                    }
                }
                Text(b.formattedTimeString)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            .padding(6)
            .frame(width: max(0, b.w), height: guideRowHeight - 8, alignment: .leading)
            .background(b.color.opacity(0.15))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(b.color.opacity(0.3), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .offset(x: b.x, y: 4)
        .id(b.id)
    }

    private func buildJFProgram(from item: BaseItemDto, channel: LiveTvChannelDto, clampedStart s: Date, clampedEnd e: Date) -> JFProgram {
        let fallbackId = item.id ?? "epg_\(channel.id)_\(Int(s.timeIntervalSince1970))"
        var dict: [String: Any] = [
            "Id": fallbackId,
            "Name": item.name ?? "",
            "StartDate": guideIso8601InternetDateTime.string(from: s),
            "EndDate": guideIso8601InternetDateTime.string(from: e),
            "ChannelId": channel.id
        ]
        if let cn = channel.name { dict["ChannelName"] = cn }
        if let ov = item.overview { dict["Overview"] = ov }
        if let et = item.episodeTitle { dict["EpisodeTitle"] = et }
        if let r = item.officialRating { dict["OfficialRating"] = r }
        if let pi = item.parentIndexNumber { dict["ParentIndexNumber"] = pi }
        if let idx = item.indexNumber { dict["IndexNumber"] = idx }
        if let rep = item.isRepeat { dict["IsRepeat"] = rep }
        if let isM = item.isMovie { dict["IsMovie"] = isM }
        if let gs = item.genres { dict["Genres"] = gs }
        if let iid = item.id { dict["ItemId"] = iid }
        if let sid = item.seriesId { dict["SeriesId"] = sid }
        if let isS = item.isSeries { dict["IsSeries"] = isS }
        if let sname = item.seriesName { dict["SeriesName"] = sname }
        if let viaJSON = JFProgram(json: dict) {
            return viaJSON
        }
        let minDict: [String: Any] = ["Id": fallbackId, "Name": item.name ?? ""]
        return JFProgram(json: minDict) ?? JFProgram(json: ["Id": fallbackId, "Name": ""])!
    }
}

struct RowGridBackground: View {
    let visibleWidth: CGFloat
    
    var body: some View {
        Canvas { context, size in
            let blockWidth = 30 * guidePxPerMinute
            var currentX: CGFloat = 0
            
            let fillStyle = Color.secondary.opacity(0.04)
            let borderStyle = Color.secondary.opacity(0.15)
            
            while currentX < size.width {
                let rect = CGRect(x: currentX, y: 0, width: blockWidth, height: size.height)
                context.fill(Path(rect), with: .color(fillStyle))
                
                let lineRect = CGRect(x: currentX, y: 0, width: 1, height: size.height)
                context.fill(Path(lineRect), with: .color(borderStyle))
                
                currentX += blockWidth
            }
        }
        .frame(width: visibleWidth, height: guideRowHeight)
    }
}

struct NowLineOverlay: View {
    let baseStart: Date
    let selectedDay: Date
    let rowHeight: CGFloat
    let currentTime: Date

    private var nowX: CGFloat? {
        guard Calendar.current.isDate(selectedDay, inSameDayAs: currentTime) else { return nil }
        let end = guideEndOfDay(selectedDay)
        if currentTime < baseStart || currentTime >= end {
            return nil
        }
        let mins = currentTime.timeIntervalSince(baseStart) / 60.0
        return CGFloat(mins) * guidePxPerMinute
    }

    var body: some View {
        Group {
            if let x = nowX {
                Rectangle()
                    .fill(Color.red)
                    .frame(width: 2, height: rowHeight)
                    .offset(x: x)
                    .allowsHitTesting(false)
            }
        }
    }
}
