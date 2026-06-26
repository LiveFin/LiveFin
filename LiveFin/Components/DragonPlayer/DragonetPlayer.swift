//
//  DragonetPlayer.swift
//  LiveFin
//
//  Created by KPGamingz on 1/2/26.
//

import Foundation
import SwiftUI
import AVKit

// MARK: - AirPlay picker

struct DragonetAirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.tintColor = .white
        v.activeTintColor = .systemBlue
        v.prioritizesVideoDevices = true
        return v
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {
    }
}

// MARK: - DragonetPlayer

struct DragonetPlayer: UIViewControllerRepresentable {

    let player: AVPlayer
    let streamURL: URL

    @Binding var isPiPActive: Bool
    @Binding var isCCEnabled: Bool
    @Binding var controlsVisible: Bool

    var onPlaybackError: ((String) -> Void)?
    /// Called once the UIViewController is ready (so the View layer can
    /// attach tap-gesture callbacks to it).
    var onControllerReady: ((DragonetPlayerController) -> Void)?

    // MARK: Coordinator

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    // MARK: UIViewControllerRepresentable

    func makeUIViewController(context: Context) -> DragonetPlayerController {
        let vc = DragonetPlayerController()
        vc.player = player
        vc.showsPlaybackControls = false
        
        vc.view.insetsLayoutMarginsFromSafeArea = false

        vc.allowsPictureInPicturePlayback = false
        
        // Disable AVKit from hijacking the Now Playing Info Center with HLS stream metadata
        vc.updatesNowPlayingInfoCenter = false
        
        vc.videoGravity = .resizeAspect
        
        vc.coordinator = context.coordinator
        context.coordinator.hostController = vc

        // Give layout a chance to settle before walking layer tree for PiP
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            context.coordinator.setupPiP(for: vc)
        }
        
        context.coordinator.observePlayer(player)
        context.coordinator.setupPiPNotification()
        
        onControllerReady?(vc)
        return vc
    }

    func updateUIViewController(_ vc: DragonetPlayerController, context: Context) {
        context.coordinator.updateCaptionSelection(isCCEnabled)
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, AVPictureInPictureControllerDelegate {

        var parent: DragonetPlayer
        weak var hostController: DragonetPlayerController?
        var pipController: AVPictureInPictureController?

        private var pipObserver: NSObjectProtocol?
        private var statusObserver: NSKeyValueObservation?
        private var itemErrorObserver: NSKeyValueObservation?
        private var itemStatusObserver: NSKeyValueObservation?

        init(_ parent: DragonetPlayer) { self.parent = parent }

        deinit {
            if let obs = pipObserver {
                NotificationCenter.default.removeObserver(obs)
            }
        }

        // MARK: PiP setup

        func setupPiP(for vc: AVPlayerViewController) {
            guard AVPictureInPictureController.isPictureInPictureSupported(),
                  let layer = findPlayerLayer(in: vc.view.layer) else { return }
            
            let pip: AVPictureInPictureController
            if let created = AVPictureInPictureController(playerLayer: layer) {
                pip = created
            } else {
                return
            }
            pip.delegate = self
            
            if #available(iOS 14.2, *) {
                pip.canStartPictureInPictureAutomaticallyFromInline = true
            }
            
            self.pipController = pip
        }

        private func findPlayerLayer(in layer: CALayer) -> AVPlayerLayer? {
            if let pl = layer as? AVPlayerLayer { return pl }
            for sub in layer.sublayers ?? [] {
                if let found = findPlayerLayer(in: sub) { return found }
            }
            return nil
        }

        func setupPiPNotification() {
            pipObserver = NotificationCenter.default.addObserver(
                forName: .dragonetTogglePiP, object: nil, queue: .main
            ) { [weak self] _ in
                guard let pip = self?.pipController else { return }
                if pip.isPictureInPictureActive {
                    pip.stopPictureInPicture()
                } else if pip.isPictureInPicturePossible {
                    pip.startPictureInPicture()
                }
            }
        }

        // MARK: CC

        func updateCaptionSelection(_ enabled: Bool) {
            guard let item = parent.player.currentItem,
                  let group = item.asset.mediaSelectionGroup(forMediaCharacteristic: .legible)
            else { return }
            
            if enabled {
                let opt = group.options.first {
                    !$0.hasMediaCharacteristic(.containsOnlyForcedSubtitles)
                }
                item.select(opt, in: group)
            } else {
                item.select(nil, in: group)
            }
        }

        // MARK: Player observation

        func observePlayer(_ player: AVPlayer) {
            itemStatusObserver = player.observe(\.currentItem?.status, options: [.initial, .new]) { p, _ in
                if p.currentItem?.status == .readyToPlay {
                    DispatchQueue.main.async { p.play() }
                }
            }
            
            statusObserver = player.observe(\.status, options: [.new]) { [weak self] p, _ in
                guard p.status == .failed else { return }
                let msg = p.error?.localizedDescription ?? "Playback error"
                DispatchQueue.main.async { self?.parent.onPlaybackError?(msg) }
            }
            
            itemErrorObserver = player.observe(\.currentItem?.error, options: [.new]) { [weak self] p, _ in
                guard let err = p.currentItem?.error else { return }
                DispatchQueue.main.async { self?.parent.onPlaybackError?(err.localizedDescription) }
            }
        }

        // MARK: AVPictureInPictureControllerDelegate

        func pictureInPictureControllerDidStartPictureInPicture(_: AVPictureInPictureController) {
            DispatchQueue.main.async { self.parent.isPiPActive = true }
        }
        
        func pictureInPictureControllerDidStopPictureInPicture(_: AVPictureInPictureController) {
            DispatchQueue.main.async { self.parent.isPiPActive = false }
        }
        
        func pictureInPictureController(
            _: AVPictureInPictureController,
            restoreUserInterfaceForPictureInPictureStopWithCompletionHandler ch: @escaping (Bool) -> Void
        ) { ch(true) }
        
        func pictureInPictureController(
            _: AVPictureInPictureController,
            failedToStartPictureInPictureWithError error: Error
        ) {
            DispatchQueue.main.async {
                self.parent.onPlaybackError?("PiP failed: \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - Notification bridge

extension Notification.Name {
    static let dragonetTogglePiP = Notification.Name("dragonetTogglePiP")
}
