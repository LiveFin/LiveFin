//
//  DragonetPlayer.swift
//  LiveFin
//
//  Created by KPGamingz on 1/2/26.
//

import Foundation
import SwiftUI
import AVKit

struct DragonetPlayer: UIViewControllerRepresentable {
    var player: AVPlayer
    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.showsPlaybackControls = false
        
        return controller
    }
    
    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {
        
    }
}
