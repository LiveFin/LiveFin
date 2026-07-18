//
//  TVPlayerView.swift
//  LiveFin
//
//  Created by Kervens on 7/17/26.
//


//
//  TVPlayerView.swift
//  LiveFin tvOS
//

import SwiftUI
import AVKit

struct TVPlayerView: View {
    var channel: TVChannel?
    
    var body: some View {
        ZStack {
            Color.black.edgesIgnoringSafeArea(.all)
            
            VStack(spacing: 20) {
                Image(systemName: "play.tv.fill")
                    .font(.system(size: 120))
                    .foregroundColor(.white.opacity(0.8))
                
                if let channel = channel {
                    Text("Playing: \(channel.name ?? "Unknown")")
                        .font(.title2)
                        .foregroundColor(.white)
                } else {
                    Text("MultiView Setup Hub")
                        .font(.title2)
                        .foregroundColor(.white)
                    Text("Select up to 4 channels to stream simultaneously")
                        .foregroundColor(.gray)
                }
            }
        }
        // Allows the view to take up the full screen, hiding the tab bar when playing
        .ignoresSafeArea() 
    }
}