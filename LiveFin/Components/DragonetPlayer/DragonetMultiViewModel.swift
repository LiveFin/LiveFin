//
//  DragonetMultiViewModel.swift
//  LiveFin
//
//  Created by KPGamingz on 7/14/26.
//

import Foundation
import SwiftUI
import AVFoundation

@MainActor
final class DragonetMultiViewModel: ObservableObject {
    @Published var activeStreams: [DragonetPlayerViewModel] = []
    
    /// Auto-dismisses the MultiView layout if the count shrinks to 1
    @Published var shouldDismiss: Bool = false
    
    /// Holds the user's choice of stream to keep when exiting MultiView
    @Published var selectedStreamToKeep: DragonetPlayerViewModel?
    
    /// Tracks which stream currently plays audio. Others will be muted.
    @Published var activeAudioIndex: Int = 0 {
        didSet { updateAudioStates() }
    }
    
    let maxStreams = 6 // Upgraded to support 6 streams
    let appState: AppState
    
    init(appState: AppState) {
        self.appState = appState
        
        do {
            try AVAudioSession.sharedInstance().setCategory(
                .playback,
                mode: .moviePlayback,
                policy: .longFormVideo,
                options: []
            )
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("[DragonetMultiViewModel] AVAudioSession activation failed: \(error)")
        }
    }
    
    func adoptStream(_ vm: DragonetPlayerViewModel) {
        guard activeStreams.count < maxStreams else { return }
        wireStreamEndedHandler(vm)
        activeStreams.append(vm)
        updateAudioStates()
    }
    
    func addStream(url: URL, channel: LiveTvChannelDto?, program: JFProgram?) {
        guard activeStreams.count < maxStreams else { return }
        
        let newVM = DragonetPlayerViewModel(
            streamURL: url,
            channel: channel,
            program: program,
            appState: appState,
            isMultiView: true
        )
        
        wireStreamEndedHandler(newVM)
        activeStreams.append(newVM)
        updateAudioStates()
    }
    
    /// Hooks a stream's "it stopped" signal to automatically drop it from the grid,
    /// keeping the remaining tiles playing undisturbed.
    private func wireStreamEndedHandler(_ vm: DragonetPlayerViewModel) {
        vm.onStreamEnded = { [weak self, weak vm] in
            guard let self = self, let vm = vm else { return }
            self.removeStream(vm)
        }
    }
    
    /// Removes a stream by identity. Safer than index-based removal when the failure
    /// callback can fire asynchronously after other tiles have already shifted the array.
    func removeStream(_ vm: DragonetPlayerViewModel) {
        guard let index = activeStreams.firstIndex(where: { $0 === vm }) else { return }
        removeStream(at: index)
    }
    
    func removeStream(at index: Int) {
        guard activeStreams.indices.contains(index) else { return }
        let removed = activeStreams.remove(at: index)
        
        if removed.isMultiView {
            removed.explicitCleanup()
            removed.player.pause()
            removed.player.replaceCurrentItem(with: nil)
        } else {
            removed.player.isMuted = true
        }
        
        if activeStreams.count <= 1 {
            shouldDismiss = true
            return
        }
        
        if activeAudioIndex >= activeStreams.count {
            activeAudioIndex = max(0, activeStreams.count - 1)
        } else {
            updateAudioStates()
        }
    }
    
    func cleanup() {
        for vm in activeStreams {
            // Do not kill the stream we are transferring to the main player!
            if vm === selectedStreamToKeep { continue }
            
            if vm.isMultiView {
                vm.explicitCleanup()
                vm.player.pause()
                vm.player.replaceCurrentItem(with: nil)
            }
        }
        activeStreams.removeAll()
    }
    
    private func updateAudioStates() {
        for (index, vm) in activeStreams.enumerated() {
            vm.player.isMuted = (index != activeAudioIndex)
        }
    }
}
