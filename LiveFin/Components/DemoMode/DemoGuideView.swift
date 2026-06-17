//
//  DemoGuideView.swift
//  LiveFin
//
//  Created by KPGamingz on 9/10/25.
//

import SwiftUI

private struct DemoProgram: Identifiable {
    let id: String
    let name: String
    let start: Date
    let end: Date
    let episodeTitle: String?
}

struct DemoGuideView: View {
    @EnvironmentObject var appState: AppState
    @State private var selectedDay: Date = Date()

    // Build a short list of demo programs per channel
    private func programs(for channel: DemoChannel) -> [DemoProgram] {
        let now = Date()
        // Create 4 half-hour programs starting from the current hour boundary
        let cal = Calendar.current
        let hour = cal.component(.hour, from: now)
        let startOfHour = cal.date(bySettingHour: hour, minute: 0, second: 0, of: now) ?? now
        var out: [DemoProgram] = []
        for i in 0..<4 {
            let s = cal.date(byAdding: .minute, value: i * 30, to: startOfHour) ?? now
            let e = cal.date(byAdding: .minute, value: (i + 1) * 30, to: startOfHour) ?? s.addingTimeInterval(30*60)
            let title = "\(channel.name) Show \(i + 1)"
            out.append(DemoProgram(id: "\(channel.id)-p-\(i)", name: title, start: s, end: e, episodeTitle: i % 2 == 0 ? "Episode \(i + 1)" : nil))
        }
        return out
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Simple day selector
                HStack(spacing: 8) {
                    Button(action: { selectedDay = Calendar.current.startOfDay(for: Date()) }) {
                        Text("Today").padding(8).background(Calendar.current.isDateInToday(selectedDay) ? Color.accentColor.opacity(0.2) : Color(.secondarySystemBackground)).clipShape(Capsule())
                    }.buttonStyle(.plain)
                    Button(action: { selectedDay = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: Date())) ?? selectedDay }) {
                        Text("Tomorrow").padding(8).background(!Calendar.current.isDateInToday(selectedDay) ? Color.accentColor.opacity(0.2) : Color(.secondarySystemBackground)).clipShape(Capsule())
                    }.buttonStyle(.plain)
                    Spacer()
                    Button(action: { /* refresh no-op for demo */ }) { Image(systemName: "arrow.clockwise") }.buttonStyle(.plain)
                }
                .padding()

                List {
                    ForEach(DemoChannelsData.channels) { channel in
                        Section(header: HStack(spacing: 12) {
                            Image(systemName: channel.imageName)
                                .resizable()
                                .frame(width: 36, height: 36)
                                .foregroundColor(.accentColor)
                            VStack(alignment: .leading) {
                                Text(channel.name).font(.headline)
                                Text("Channel \(channel.number)").font(.caption).foregroundColor(.secondary)
                            }
                            Spacer()
                            NavigationLink(destination: DemoChannelDetailView(channel: channel)) { EmptyView() }.opacity(0)
                        }) {
                            ForEach(programs(for: channel)) { prog in
                                NavigationLink(destination: DemoChannelDetailView(channel: channel)) {
                                    HStack(spacing: 12) {
                                        VStack(alignment: .leading) {
                                            Text(prog.name).font(.subheadline).bold().lineLimit(1)
                                            if let ep = prog.episodeTitle { Text(ep).font(.caption).foregroundColor(.secondary) }
                                        }
                                        Spacer()
                                        VStack(alignment: .trailing) {
                                            Text(prog.start.formatted(date: .omitted, time: .shortened)).font(.caption)
                                            Text(prog.end.formatted(date: .omitted, time: .shortened)).font(.caption).foregroundColor(.secondary)
                                        }
                                    }
                                    .padding(.vertical, 6)
                                }
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
            .navigationTitle("Demo Guide")
            .toolbar { ToolbarView() }
        }
    }
}

struct DemoGuideView_Previews: PreviewProvider {
    static var previews: some View {
        DemoGuideView().environmentObject(AppState())
    }
}
