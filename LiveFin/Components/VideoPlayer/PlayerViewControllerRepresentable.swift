//
//  PlayerViewControllerRepresentable.swift
//  LiveFin
//
//  Created by KPGamingz on 12/23/2025.
//

import SwiftUI
import AVKit
import AVFoundation
import UIKit
import MediaPlayer
import Combine

struct PlayerViewControllerRepresentable: UIViewControllerRepresentable {
    let streamURL: URL
    let channel: LiveTvChannelDto?
    let appState: AppState
    let onClose: () -> Void
    let onPlaybackError: ((String) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.delegate = context.coordinator
        controller.allowsPictureInPicturePlayback = true
        controller.exitsFullScreenWhenPlaybackEnds = false
        controller.showsPlaybackControls = true

        let userAgent = "LiveFin iOS/\(appState.clientVersion)"
        var headers: [String: String] = ["User-Agent": userAgent]
        headers["X-Emby-Token"] = appState.accessToken
        headers["X-Emby-User-Id"] = appState.userID

        // Create asset but don't block — load keys async before handing to AVPlayerItem
        let asset = AVURLAsset(url: streamURL, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
        let player = AVPlayer()
        controller.player = player

        context.coordinator.controller = controller
        context.coordinator.player = player
        context.coordinator.appState = appState
        context.coordinator.channelId = channel?.id
        context.coordinator.onClose = onClose
        context.coordinator.onPlaybackError = onPlaybackError

        context.coordinator.subscribeToAppState()

        // FIX: Load asset keys asynchronously so AVPlayer doesn't stall probing the stream
        asset.loadValuesAsynchronously(forKeys: ["playable", "tracks", "duration"]) {
            DispatchQueue.main.async {
                var error: NSError?
                let status = asset.statusOfValue(forKey: "playable", error: &error)
                if status == .failed {
                    let errDesc = error?.localizedDescription ?? "Asset not playable"
                    context.coordinator.onPlaybackError?("Stream unavailable: \(errDesc)")
                    context.coordinator.onClose?()
                    return
                }

                let item = AVPlayerItem(asset: asset)

                // FIX: Reduce buffer duration so playback starts quickly instead of
                // waiting for AVPlayer's default large buffer to fill
                item.preferredForwardBufferDuration = 2.0

                // FIX: Tell AVPlayer this is a live stream so it uses the live edge
                // instead of trying to seek to a VOD-style start position
                item.automaticallyPreservesTimeOffsetFromLive = true
                item.configuredTimeOffsetFromLive = CMTime(seconds: 3, preferredTimescale: 1)

                player.replaceCurrentItem(with: item)
                // FIX: Refresh metadata NOW that the item exists, not before
                context.coordinator.refreshMetadata(forceArtwork: true)
                context.coordinator.startPlayback()
            }
        }

        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        context.coordinator.appState = appState
        // NOTE: Do NOT call refreshMetadata() here - it triggers on every view update
        // and causes flickering. Metadata updates are handled by subscribeToAppState().
    }

    static func dismantleUIViewController(_ controller: AVPlayerViewController, coordinator: Coordinator) {
        coordinator.cleanupOnExit()
    }

    // MARK: - Coordinator
    final class Coordinator: NSObject, AVPlayerViewControllerDelegate {
        var parent: PlayerViewControllerRepresentable
        var controller: AVPlayerViewController?
        var player: AVPlayer?
        var appState: AppState?
        var channelId: String?
        var progressObserver: Any?
        var pauseKVO: NSKeyValueObservation?
        var itemStatusKVO: NSKeyValueObservation?
        var onClose: (() -> Void)?
        var onPlaybackError: ((String) -> Void)?
        var cancellables: Set<AnyCancellable> = []
        var lastProgramId: String? // Track program ID to only update when program changes

        init(_ parent: PlayerViewControllerRepresentable) {
            self.parent = parent
            super.init()
        }

        func startPlayback() {
            guard let player = player else { return }
            do {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playback, mode: .moviePlayback, options: [.allowAirPlay])
                try session.setActive(true)
            } catch {
                print("[AudioSession] Failed: \(error)")
            }

            UIApplication.shared.beginReceivingRemoteControlEvents()
            setupRemoteCommands()

            if let itemId = channelId, let app = appState {
                Task { @MainActor in
                    app.reportPlaybackStart(itemId: itemId, canSeek: false)
                    app.reportFullClientCapabilities()
                    app.startEPGPolling(for: itemId)
                }
            }

            addObservers()
            observeItem(player.currentItem)
            player.play()
        }

        private func setupRemoteCommands() {
            let center = MPRemoteCommandCenter.shared()
            center.playCommand.isEnabled = true
            center.pauseCommand.isEnabled = true
            center.togglePlayPauseCommand.isEnabled = true

            center.playCommand.addTarget { [weak self] _ in
                self?.player?.play()
                return .success
            }
            center.pauseCommand.addTarget { [weak self] _ in
                self?.player?.pause()
                return .success
            }
            center.togglePlayPauseCommand.addTarget { [weak self] _ in
                guard let p = self?.player else { return .commandFailed }
                p.rate == 0 ? p.play() : p.pause()
                return .success
            }
        }

        func subscribeToAppState() {
            guard let app = appState else { return }

            // Debounce 300ms so all the individual @Published properties (title, subtitle,
            // imageTag, etc.) settle before we read them. AppState sets them as separate
            // assignments; Combine fires on each one individually, so without the debounce
            // refreshMetadata can run while subtitle/artwork are still nil.
            app.$currentProgramId
                .removeDuplicates()
                .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
                .sink { [weak self] newProgramId in
                    guard let self = self else { return }
                    if self.lastProgramId != newProgramId {
                        self.lastProgramId = newProgramId
                        self.refreshMetadata(forceArtwork: true)
                    }
                }
                .store(in: &cancellables)

            // Also watch subtitle independently so a nil→value transition after the
            // program ID fires still updates the Now Playing artist field.
            app.$currentProgramSubtitle
                .removeDuplicates()
                .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
                .sink { [weak self] _ in
                    self?.refreshMetadata(forceArtwork: false)
                }
                .store(in: &cancellables)

            // Fast initial load: if program is already set, refresh after a short delay
            // so all properties have time to finish being written.
            if appState?.currentProgramId != nil && lastProgramId == nil {
                lastProgramId = appState?.currentProgramId
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                    self?.refreshMetadata(forceArtwork: true)
                }
            }
        }

        func addObservers() {
            guard let player = player else { return }

            if let itemId = parent.channel?.id, let appState = appState {
                let interval = CMTime(seconds: 10, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
                progressObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { time in
                    let seconds = CMTimeGetSeconds(time)
                    let ticks = Int64(seconds * 10_000_000)
                    Task { @MainActor in
                        appState.reportPlaybackProgress(itemId: itemId, positionTicks: ticks, canSeek: false)
                    }
                }
            }

            pauseKVO = player.observe(\.rate, options: [.initial, .new]) { [weak self] player, _ in
                guard let self = self, let itemId = self.channelId, let app = self.appState else { return }
                let paused = player.rate == 0
                let ticks = Int64(player.currentTime().seconds * 10_000_000)
                Task { @MainActor in
                    app.reportPlaybackProgress(itemId: itemId, positionTicks: ticks, canSeek: false, isPaused: paused)
                }
            }
        }

        private func observeItem(_ item: AVPlayerItem?) {
            guard let item = item else { return }
            itemStatusKVO = item.observe(\.status, options: [.initial, .new]) { observedItem, _ in
                switch observedItem.status {
                case .readyToPlay:
                    print("[Item] Ready to play")
                case .failed:
                    let errDesc = observedItem.error?.localizedDescription ?? "Unknown error"
                    print("[Item] Failed: \(errDesc)")
                    DispatchQueue.main.async { [weak self] in
                        self?.onPlaybackError?("Playback failed: \(errDesc)")
                        self?.onClose?()
                    }
                case .unknown:
                    print("[Item] Status unknown")
                @unknown default:
                    print("[Item] Status unknown")
                }
            }
        }

        func refreshMetadata(forceArtwork: Bool = false) {
            guard let item = player?.currentItem else { return }

            // Use EPG data only when it's actually populated — fall back gracefully.
            // nilIfEmpty prevents an empty string from silently replacing good data.
            let title    = appState?.currentProgramTitle?.nilIfEmpty ?? parent.channel?.name ?? "Live Stream"
            let subtitle = appState?.currentProgramSubtitle ?? ""
            let channel  = parent.channel?.name ?? ""
            let artist   = subtitle.isEmpty ? channel : subtitle

            // AVPlayer external metadata (system player overlay)
            let makeItem: (AVMetadataIdentifier, String) -> AVMutableMetadataItem = { id, value in
                let m = AVMutableMetadataItem()
                m.identifier = id
                m.keySpace   = .common
                m.value      = value as NSString
                return m
            }
            var metadataItems: [AVMetadataItem] = [
                makeItem(.commonIdentifierTitle,     title),
                makeItem(.commonIdentifierArtist,    artist),
                makeItem(.commonIdentifierAlbumName, channel)
            ]
            if !subtitle.isEmpty {
                metadataItems.append(makeItem(.commonIdentifierDescription, subtitle))
            }
            item.externalMetadata = metadataItems

            // Merge into existing dict — never replace keys with empty/nil values,
            // and never touch the artwork key here (only fetchArtworkData writes it).
            var nowPlaying = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
            nowPlaying[MPMediaItemPropertyTitle]             = title
            nowPlaying[MPMediaItemPropertyArtist]            = artist.isEmpty ? nil : artist
            nowPlaying[MPMediaItemPropertyAlbumTitle]        = channel
            nowPlaying[MPNowPlayingInfoPropertyIsLiveStream] = true
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlaying

            // Only fetch artwork on an explicit force (program change), not on every poll tick.
            if forceArtwork, let progId = appState?.currentProgramId, !progId.isEmpty {
                fetchArtworkData(programId: progId)
            }
        }

        private func fetchArtworkData(programId: String?) {
            guard let app = appState, let progId = programId, !progId.isEmpty else { return }
            let server = app.serverURL.hasSuffix("/") ? String(app.serverURL.dropLast()) : app.serverURL
            let url = URL(string: "\(server)/Items/\(progId)/Images/Primary?maxWidth=512")
            guard var url = url else { return }

            if !app.accessToken.isEmpty {
                url.append(queryItems: [URLQueryItem(name: "api_key", value: app.accessToken)])
            }

            URLSession.shared.dataTask(with: url) { data, _, _ in
                guard let data = data, !data.isEmpty else { return }
                DispatchQueue.main.async {
                    if let image = UIImage(data: data) {
                        // FIX: Only update artwork, preserve all other existing metadata
                        var np = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
                        np[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                        MPNowPlayingInfoCenter.default().nowPlayingInfo = np
                    }
                }
            }.resume()
        }

        func cleanupOnExit() {
            if let token = progressObserver, let player = player {
                player.removeTimeObserver(token)
            }
            pauseKVO?.invalidate()
            itemStatusKVO?.invalidate()
            cancellables.removeAll()

            if let itemId = parent.channel?.id, let app = appState {
                Task { @MainActor in
                    app.reportPlaybackStopped(itemId: itemId, positionTicks: 0)
                    app.stopEPGPolling()
                }
            }

            player?.pause()
            controller?.player = nil
            controller = nil
            player = nil
            UIApplication.shared.endReceivingRemoteControlEvents()
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        }
    }
}
    

// MARK: - Helpers

fileprivate extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
