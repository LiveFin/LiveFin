//
// WatchChannelDetailView.swift
//  LiveFin watchOS
//
//  Created by KPGamingz on 9/26/25.
//

import SwiftUI

struct WatchChannelDetailView: View {
    let channel: WatchChannel
    @EnvironmentObject var appState: WatchAppState
    @State private var programs: [WatchProgram] = []
    @State private var isLoading = false

    private var now: Date { Date() }
    // Date formatter for day/month display
    private static let dayFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "MMM d"
        return df
    }()

    var body: some View {
        List {
            if isLoading && programs.isEmpty {
                ProgressView("Loading…")
            } else if programs.isEmpty {
                Text("No upcoming programs")
                    .foregroundColor(.secondary)
            } else {
                ForEach(programs) { prog in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(prog.name ?? "Program")
                                .font(.headline)
                                .lineLimit(2)
                            // New badge heuristic matches iOS ChannelDetailView (isRepeat false OR unknown) AND has episode info
                            let showNew = ((prog.isRepeat == false) || prog.isRepeat == nil) && (prog.episodeTitle != nil || prog.isNew == true)
                            if showNew {
                                Text("New")
                                    .font(.caption2)
                                    .foregroundColor(.white)
                                    .padding(.horizontal,6)
                                    .padding(.vertical,2)
                                    .background(Color.blue)
                                    .cornerRadius(4)
                            }
                            if isLive(prog) {
                                Text("Live")
                                    .font(.caption2.bold())
                                    .foregroundColor(.white)
                                    .padding(.horizontal,4)
                                    .padding(.vertical,2)
                                    .background(Color.red.cornerRadius(4))
                            }
                        }
                        if let ep = prog.episodeTitle { Text(ep).font(.caption).foregroundColor(.secondary) }
                        if let window = dateTimeRangeString(prog) { Text(window).font(.caption2).foregroundColor(.secondary) }
                        if let rating = prog.officialRating { Text(rating).font(.caption2).foregroundColor(.secondary) }
                        if let ov = trimmedOverview(prog) { Text(ov).font(.caption2).foregroundColor(.secondary).lineLimit(3) }
                    }
                    .padding(.vertical,4)
                }
            }
        }
        .navigationTitle(channel.name ?? "Channel")
        .toolbar { ToolbarItem(placement: .topBarTrailing) { refreshButton } }
        .task { await load() }
        .refreshable { await load(force: true) }
    }

    private var refreshButton: some View {
        Button(action: { Task { await load(force: true) } }) {
            Image(systemName: "arrow.clockwise")
        }.disabled(isLoading)
    }

    private func load(force: Bool = false) async {
        if isLoading { return }
        isLoading = true
        defer { isLoading = false }
        let fetched = await appState.fetchPrograms(for: channel)
        let nowRef = Date()
        // Remove programs that have fully ended
        let filtered = fetched.filter { prog in
            if let end = prog.endDate { return end >= nowRef } // keep if still airing or future
            return true // if no end date, keep
        }
        // Always sort chronologically (start, then end, fallback name) to guarantee ordering
        let sorted = filtered.sorted { a, b in
            let sa = a.startDate ?? .distantFuture
            let sb = b.startDate ?? .distantFuture
            if sa != sb { return sa < sb }
            let ea = a.endDate ?? .distantFuture
            let eb = b.endDate ?? .distantFuture
            if ea != eb { return ea < eb }
            return (a.name ?? "") < (b.name ?? "")
        }
        if force || programs.isEmpty || !sorted.isEmpty {
            programs = sorted
        }
    }

    private func isLive(_ p: WatchProgram) -> Bool {
        guard let s = p.startDate, let e = p.endDate else { return false }
        return s <= now && now <= e
    }

    private func dateTimeRangeString(_ p: WatchProgram) -> String? {
        guard let s = p.startDate, let e = p.endDate else { return nil }
        let dayStart = Self.dayFormatter.string(from: s)
        let dayEnd = Self.dayFormatter.string(from: e)
        let timeStyle: Date.FormatStyle = .init(date: .omitted, time: .shortened)
        if dayStart == dayEnd {
            return "\(dayStart) \(timeStyle.format(s)) - \(timeStyle.format(e))"
        } else {
            return "\(dayStart) \(timeStyle.format(s)) - \(dayEnd) \(timeStyle.format(e))"
        }
    }

    private func trimmedOverview(_ p: WatchProgram) -> String? {
        guard let o = p.overview?.trimmingCharacters(in: .whitespacesAndNewlines), !o.isEmpty else { return nil }
        return o
    }
}

#Preview {
    NavigationStack { WatchChannelDetailView(channel: .init(id: "1", name: "News", number: "2")).environmentObject(WatchAppState()) }
}
