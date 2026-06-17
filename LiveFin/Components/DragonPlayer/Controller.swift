//
//  Controller.swift
//  LiveFin
//
//  Created by KPGamingz on 2/21/26.
//

import UIKit
import AVKit

// MARK: - DragonetPlayerController

/// Subclass of AVPlayerViewController that owns:
///   - Tap-to-toggle gesture for the controls overlay
///   - 3-second auto-hide timer
///   - Landscape-only orientation lock when fullscreen
final class DragonetPlayerController: AVPlayerViewController {

    // MARK: Wired by Coordinator

    weak var coordinator: DragonetPlayer.Coordinator?

    // MARK: Callbacks → SwiftUI

    /// Called on every tap inside the video area.
    var onTap: (() -> Void)?

    /// Fires when the auto-hide timer expires and controls should disappear.
    var onAutoHide: (() -> Void)?

    // MARK: State

    /// Set by DragonetPlayerView when the layout switches to fullscreen;
    /// triggers an orientation update.
    var isFullscreen: Bool = false {
        didSet {
            guard oldValue != isFullscreen else { return }
            setNeedsUpdateOfSupportedInterfaceOrientations()
        }
    }

    // MARK: Private

    private static let autoHideDelay: TimeInterval = 3.5
    private var hideTimer: Timer?

    // MARK: Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        tap.numberOfTapsRequired = 1
        
        // 💥 FIX FOR BUGGY GESTURES 💥
        // Prevents the tap gesture from swallowing touches meant for internal views
        // or aggressively cancelling SwiftUI interactions.
        tap.cancelsTouchesInView = false
        
        view.addGestureRecognizer(tap)
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        
        // Force it to play the exact moment the view is fully presented on the screen.
        player?.play()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        cancelTimer()
    }

    // MARK: Orientation & Layout Fixes

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        isFullscreen ? .landscape : .all
    }
    override var shouldAutorotate: Bool { true }
    
    // 💥 FIX FOR LAYOUT SHIFT 💥
    override var prefersStatusBarHidden: Bool { return true }
    override var prefersHomeIndicatorAutoHidden: Bool { return true }

    // MARK: Tap

    @objc private func handleTap() {
        onTap?()
    }

    // MARK: Auto-hide timer

    func resetAutoHideTimer() {
        cancelTimer()
        hideTimer = Timer.scheduledTimer(
            withTimeInterval: Self.autoHideDelay,
            repeats: false
        ) { [weak self] _ in
            DispatchQueue.main.async { self?.onAutoHide?() }
        }
    }

    func cancelTimer() {
        hideTimer?.invalidate()
        hideTimer = nil
    }
}
