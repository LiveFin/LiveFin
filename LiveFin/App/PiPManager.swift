// filepath: /Users/kp/Desktop/LiveFin/LiveFin/App Specific/PiPManager.swift
import Foundation
import AVKit
import AVFoundation
import UIKit

final class PiPManager: NSObject, AVPictureInPictureControllerDelegate {
    static let shared = PiPManager()
    private override init() { super.init() }

    private var pipController: AVPictureInPictureController?
    private var playerLayer: AVPlayerLayer?
    // Strongly retain the player's coordinator while in PiP so delegates survive
    private var retainedCoordinator: AnyObject?

    private(set) var isActive: Bool = false

    var isSupported: Bool { AVPictureInPictureController.isPictureInPictureSupported() }
    var isPossible: Bool { pipController?.isPictureInPicturePossible ?? false }

    func configureIfNeeded(with player: AVPlayer) {
        guard isSupported else { return }
        if let existing = playerLayer, existing.player === player {
            return // already configured for this player
        }
        let layer = AVPlayerLayer(player: player)
        layer.frame = .zero
        playerLayer = layer
#if !os(tvOS)
        pipController = AVPictureInPictureController(playerLayer: layer)
        pipController?.delegate = self
#endif
    }

    func start(with player: AVPlayer, completion: ((Bool) -> Void)? = nil) {
        guard isSupported else { completion?(false); return }
        configureIfNeeded(with: player)
        guard let pip = pipController, pip.isPictureInPicturePossible else { completion?(false); return }
        pip.startPictureInPicture()
        // Heuristic: if delegate hasn't fired within a short delay, still report started
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            completion?(self?.isActive == true || self?.pipController?.isPictureInPictureActive == true)
        }
    }

    func stop() {
        pipController?.stopPictureInPicture()
    }

    // Expose simple retain/release hooks
    func retain(coordinator: AnyObject) {
        retainedCoordinator = coordinator
    }
    func releaseCoordinator() {
        retainedCoordinator = nil
    }

    // MARK: AVPictureInPictureControllerDelegate
    func pictureInPictureControllerWillStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        isActive = true
    }
    func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        isActive = true
    }
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
        isActive = false
    }
    func pictureInPictureControllerWillStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        // no-op
    }
    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        isActive = false
    }
}
