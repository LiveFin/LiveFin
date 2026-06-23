//
//  DemoHomeView.swift
//  LiveFin
//
//  Created by KPGamingz on 9/10/25.
//

import SwiftUI

struct DemoHomeView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    // Greeting
                    Text("Hi, \(appState.username)")
                        .font(.largeTitle).bold()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal)
                        .padding(.top, 8)

                    // On Now (simple demo cards derived from channels)
                    SectionHeader("On Now")
                    if !DemoChannelsData.channels.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(alignment: .top, spacing: 12) {
                                ForEach(DemoChannelsData.channels) { channel in
                                    NavigationLink(destination: DemoChannelDetailView(channel: channel)) {
                                        DemoNowCard(channel: channel)
                                            .frame(width: 220)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal)
                        }
                    } 

                    // Channels (logos)
                    SectionHeader("Channels")
                    // Use a demo-specific horizontal channel row that accepts DemoChannel
                    DemoHorizontalChannelsRow(channels: DemoChannelsData.channels)

                    // Shows
                    SectionHeader("Shows")
                    if !DemoChannelsData.channels.isEmpty {
                        HorizontalDemoSimpleRow(items: DemoChannelsData.channels.map { "\($0.name) — Best of" })
                    } 

                    // Movies
                    SectionHeader("Movies")
                    if !DemoChannelsData.channels.isEmpty {
                        HorizontalDemoSimpleRow(items: DemoChannelsData.channels.map { "\($0.name) — Movie" })
                    } 

                    // News
                    SectionHeader("News")
                    if !DemoChannelsData.channels.isEmpty {
                        HorizontalDemoSimpleRow(items: DemoChannelsData.channels.map { "\($0.name) — News" })
                    } 

                    // Sports
                    SectionHeader("Sports")
                    if !DemoChannelsData.channels.isEmpty {
                        HorizontalDemoSimpleRow(items: DemoChannelsData.channels.map { "\($0.name) — Highlights" })
                    } 

                    // Kids
                    SectionHeader("Kids")
                    if !DemoChannelsData.channels.isEmpty {
                        HorizontalDemoSimpleRow(items: DemoChannelsData.channels.map { "\($0.name) — Kids" })
                    } 

                    Spacer(minLength: 24)
                }
                .padding(.bottom, 24)
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: { appState.logout() }) {
                        Label("Exit", systemImage: "xmark.circle")
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    ToolbarView()
                }
            }
        }
    }
}

// MARK: - Demo subviews

private struct DemoNowCard: View {
    let channel: DemoChannel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .bottomLeading) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(UIColor.secondarySystemBackground))
                    .frame(height: 120)
                HStack(spacing: 12) {
                    Image(systemName: channel.imageName)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 56, height: 56)
                        .foregroundColor(.accentColor)
                        .padding(.leading, 12)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Live: \(channel.name)")
                            .font(.headline)
                        Text("Channel \(channel.number)")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                }
                .padding(.vertical, 12)
            }
            Text(channel.description)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .lineLimit(2)
        }
    }
}

// Demo-specific horizontal channels row that takes [DemoChannel]
private struct DemoHorizontalChannelsRow: View {
    let channels: [DemoChannel]
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .center, spacing: 16) {
                ForEach(channels) { channel in
                    NavigationLink(destination: DemoChannelDetailView(channel: channel)) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(Color(.systemBackground).opacity(0.6))
                                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.secondary.opacity(0.15), lineWidth: 1))
                            Image(systemName: channel.imageName)
                                .resizable()
                                .scaledToFit()
                                .frame(width: 48, height: 48)
                                .foregroundColor(.accentColor)
                        }
                        .frame(width: 84, height: 84)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)
            .frame(minHeight: 110)
        }
    }
}

private struct HorizontalDemoSimpleRow: View {
    let items: [String]
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(items, id: \.self) { item in
                    VStack(alignment: .leading, spacing: 6) {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color(UIColor.secondarySystemBackground))
                            .frame(width: 120, height: 80)
                            .overlay(Image(systemName: "film").foregroundColor(.secondary))
                        Text(item)
                            .font(.subheadline)
                            .lineLimit(1)
                    }
                    .frame(width: 120)
                }
            }
            .padding(.horizontal)
        }
    }
}

struct DemoHomeView_Previews: PreviewProvider {
    static var previews: some View {
        DemoHomeView()
            .environmentObject(AppState())
    }
}
