//
//  DemoChannelsView.swift
//  LiveFin
//
//  Created for App Store Reviewer Demo Mode

import SwiftUI

struct DemoChannelsView: View {
    @EnvironmentObject var appState: AppState
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                List(DemoChannelsData.channels) { channel in
                    NavigationLink(destination: DemoChannelDetailView(channel: channel)) {
                        HStack {
                            Image(systemName: channel.imageName)
                                .resizable()
                                .frame(width: 40, height: 40)
                                .foregroundColor(.accentColor)
                            VStack(alignment: .leading) {
                                Text(channel.name)
                                    .font(.headline)
                                Text("Channel \(channel.number)")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(.vertical, 8)
                    }
                }
                .navigationTitle("Demo Channels")
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
}

struct DemoChannelsView_Previews: PreviewProvider {
    static var previews: some View {
        DemoChannelsView()
    }
}
