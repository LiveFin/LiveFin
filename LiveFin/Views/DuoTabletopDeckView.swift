//
//  DuoTabletopDeckView.swift
//  LiveFin
//
//  Created by KPGamingz on 9/18/26
//

import SwiftUI
import UIKit
import Darwin
import AVFoundation
import MediaPlayer

// MARK: - Tabletop Card Button Style

struct TabletopCardButtonStyle: ButtonStyle {
    var cornerRadius: CGFloat = 14
    var isSelected: Bool = false
    var accentColor: Color? = nil
    
    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let fill: Color = isSelected ? (accentColor?.opacity(0.3) ?? Color.white.opacity(0.18)) : Color.white.opacity(0.08)
        let stroke: Color = isSelected ? (accentColor?.opacity(0.6) ?? Color.white.opacity(0.4)) : Color.white.opacity(0.14)
        
        return configuration.label
            .background(
                shape
                    .fill(fill)
                    .overlay(shape.stroke(stroke, lineWidth: 1))
            )
            .glassEffect(in: shape)
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

// MARK: - Duo Tabletop Status Badge

struct DuoTabletopStatusBadge: View {
    var isLive: Bool = true
    var customText: String? = nil
    
    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(isLive ? Color.red : Color.blue)
                .frame(width: 7, height: 7)
            
            Text(customText ?? (isLive ? "LIVE" : "PLAYING"))
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            Capsule()
                .fill(Color.black.opacity(0.65))
                .overlay(
                    Capsule()
                        .stroke(Color.white.opacity(0.15), lineWidth: 0.8)
                )
        )
        .glassEffect(in: Capsule())
    }
}

// MARK: - Dragonet (Live TV) Tabletop Deck View

struct DragonetTabletopDeckView: View {
    @ObservedObject var vm: DragonetPlayerViewModel
    @ObservedObject var appState: AppState
    var dismiss: () -> Void
    
    @Binding var showChannelDrawer: Bool
    @Binding var showStatsSidebar: Bool
    @Binding var showAddChannelSheet: Bool
    @Binding var showRecordingSheet: Bool
    
    var playerController: DragonetPlayerController?
    var effectiveProgram: JFProgram?
    
    var body: some View {
        VStack(spacing: 12) {
            // ── Top Bar ──
            HStack(spacing: 10) {
                // Dismiss / Close Button
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(TabletopCardButtonStyle(cornerRadius: 12))
                .accessibilityLabel("Close Player")
                
                // Channel / Program Info Card (Tap opens Channel Switcher)
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        showChannelDrawer.toggle()
                    }
                    if showChannelDrawer { playerController?.cancelTimer() }
                } label: {
                    HStack(spacing: 10) {
                        if let cid = vm.channel?.id {
                            ChannelImageView(
                                baseUrl: appState.serverURL,
                                apiKey: appState.accessToken,
                                channelId: cid
                            )
                            .frame(width: 30, height: 30)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        }
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Text(vm.channel?.name ?? "Live TV")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                            
                            if let pName = effectiveProgram?.name {
                                Text(pName)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.65))
                                    .lineLimit(1)
                            }
                        }
                        
                        Spacer()
                        
                        Image(systemName: showChannelDrawer ? "chevron.down" : "chevron.up")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white.opacity(0.5))
                            .padding(.trailing, 2)
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 44)
                }
                .buttonStyle(TabletopCardButtonStyle(cornerRadius: 12, isSelected: showChannelDrawer))
                
                // Right Actions (CC removed as requested)
                HStack(spacing: 8) {
                    // PiP Button
                    Button {
                        NotificationCenter.default.post(name: .dragonetTogglePiP, object: nil)
                    } label: {
                        Image(systemName: vm.isPiPActive ? "rectangle.on.rectangle.slash" : "rectangle.on.rectangle")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(vm.isPiPActive ? Color.blue : .white)
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(TabletopCardButtonStyle(cornerRadius: 12, isSelected: vm.isPiPActive))
                    .accessibilityLabel("Picture in Picture")
                    
                    // AirPlay Button
                    DragonetAirPlayButton(player: vm.player)
                        .frame(width: 44, height: 44)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color.white.opacity(0.08))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .stroke(Color.white.opacity(0.14), lineWidth: 1)
                                )
                        )
                        .glassEffect(in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
            
            // ── Primary Playback Controls Row (3 Cards) ──
            HStack(spacing: 12) {
                // Rewind 10s Card
                Button {
                    vm.skipBackward(seconds: 10)
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: "gobackward.10")
                            .font(.system(size: 26, weight: .semibold))
                            .foregroundStyle(.white)
                        Text("10s")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 68)
                }
                .buttonStyle(TabletopCardButtonStyle(cornerRadius: 16))
                .accessibilityLabel("Rewind 10 seconds")
                
                // Big Center Play / Pause Card
                Button {
                    vm.togglePlayPause()
                } label: {
                    Image(systemName: vm.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 34, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 68)
                }
                .buttonStyle(TabletopCardButtonStyle(cornerRadius: 16, isSelected: true))
                .accessibilityLabel(vm.isPlaying ? "Pause" : "Play")
                
                // Fast Forward 10s / Jump to Live Card
                Button {
                    if vm.isAtLiveEdge {
                        vm.skipForward(seconds: 10)
                    } else {
                        vm.goToLive()
                    }
                } label: {
                    VStack(spacing: 4) {
                        if !vm.isAtLiveEdge {
                            Image(systemName: "dot.radiowaves.right")
                                .font(.system(size: 24, weight: .bold))
                                .foregroundStyle(.red)
                            Text("LIVE")
                                .font(.system(size: 10, weight: .black))
                                .foregroundStyle(.red)
                        } else {
                            Image(systemName: "goforward.10")
                                .font(.system(size: 26, weight: .semibold))
                                .foregroundStyle(.white)
                            Text("10s")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white.opacity(0.6))
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 68)
                }
                .buttonStyle(TabletopCardButtonStyle(cornerRadius: 16, isSelected: !vm.isAtLiveEdge, accentColor: .red))
                .accessibilityLabel(!vm.isAtLiveEdge ? "Jump to Live" : "Fast forward 10 seconds")
            }
            
            // ── Scrubber Row ──
            deckScrubberRow
            
            // ── Bottom Utility Row ──
            HStack(spacing: 10) {
                // 1. Channel Switcher Button
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        showChannelDrawer.toggle()
                    }
                    if showChannelDrawer { playerController?.cancelTimer() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "tv")
                            .font(.system(size: 14, weight: .bold))
                        Text("Channels")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                }
                .buttonStyle(TabletopCardButtonStyle(cornerRadius: 12, isSelected: showChannelDrawer))
                
                // 2. MultiView Add Button
                Button {
                    showAddChannelSheet = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "square.grid.2x2")
                            .font(.system(size: 14, weight: .bold))
                        Text("MultiView")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                }
                .buttonStyle(TabletopCardButtonStyle(cornerRadius: 12))
                
                // 3. Sports Stats Button (Temporarily removed, saving for 2.4.1)
                /*
                if vm.isSportsProgram || vm.detectedMatchQuery != nil {
                    Button {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                            showStatsSidebar.toggle()
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "sportscourt.fill")
                                .font(.system(size: 13, weight: .bold))
                            Text("Stats")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .foregroundStyle(vm.liveGameScore != nil ? Color.green : .white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                    }
                    .buttonStyle(TabletopCardButtonStyle(cornerRadius: 12, isSelected: showStatsSidebar, accentColor: .green))
                }
                */
                
                // 4. Record Button
                Button {
                    showRecordingSheet = true
                } label: {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(vm.isRecording ? Color.red : Color.white.opacity(0.8))
                            .frame(width: 8, height: 8)
                        Text(vm.isRecording ? "Rec" : "Record")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(vm.isRecording ? Color.red : .white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                }
                .buttonStyle(TabletopCardButtonStyle(cornerRadius: 12, isSelected: vm.isRecording, accentColor: .red))
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.ignoresSafeArea())
    }
    
    // MARK: - Scrubber Row
    
    private var deckScrubberRow: some View {
        let rangeStart: Double = max(vm.seekableStart, 0)
        let rangeEnd: Double = max(vm.seekableEnd, rangeStart + 1)
        
        let sliderBinding = Binding<Double>(
            get: { max(min(vm.currentTime, rangeEnd), rangeStart) },
            set: { val in vm.currentTime = val }
        )
        
        return HStack(spacing: 12) {
            Text(formatTime(vm.currentTime - rangeStart))
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.8))
                .frame(width: 48, alignment: .trailing)
            
            Slider(
                value: sliderBinding,
                in: rangeStart...rangeEnd,
                onEditingChanged: { editing in
                    vm.isScrubbing = editing
                    if !editing {
                        let targetTime = CMTime(seconds: vm.currentTime, preferredTimescale: 600)
                        vm.player.seek(to: targetTime)
                    }
                }
            )
            .tint(.red)
            
            if vm.isRecording {
                Text("-" + formatTime(max(rangeEnd - vm.currentTime, 0)))
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.6))
                    .frame(width: 52, alignment: .leading)
            } else if !vm.isAtLiveEdge {
                Button {
                    vm.goToLive()
                } label: {
                    HStack(spacing: 4) {
                        Circle().fill(Color.red).frame(width: 6, height: 6)
                        Text("LIVE")
                            .font(.system(size: 11, weight: .black))
                            .foregroundStyle(.red)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.red.opacity(0.18))
                    .clipShape(Capsule())
                }
            } else {
                HStack(spacing: 4) {
                    Circle().fill(Color.red).frame(width: 6, height: 6)
                    Text("LIVE")
                        .font(.system(size: 11, weight: .black))
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.white.opacity(0.12))
                .clipShape(Capsule())
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.white.opacity(0.1), lineWidth: 0.8)
                )
        )
        .glassEffect(in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
    
    private func formatTime(_ seconds: Double) -> String {
        guard seconds > 0 && seconds.isFinite else { return "00:00" }
        let min = Int(seconds) / 60
        let sec = Int(seconds) % 60
        if min > 59 {
            let hr = min / 60
            let m = min % 60
            return String(format: "%d:%02d:%02d", hr, m, sec)
        }
        return String(format: "%02d:%02d", min, sec)
    }
}

// MARK: - Dragonet MultiView Tabletop Deck View

struct DragonetTabletopMultiViewDeckView: View {
    @ObservedObject var multiVM: DragonetMultiViewModel
    @ObservedObject var appState: AppState
    
    @Binding var showAddChannelSheet: Bool
    @Binding var showFullScreenMultiView: Bool
    var onExitMultiView: () -> Void
    var onDismiss: () -> Void
    
    private var prominentVM: DragonetPlayerViewModel? {
        let index = multiVM.activeAudioIndex
        if multiVM.activeStreams.indices.contains(index) {
            return multiVM.activeStreams[index]
        }
        return multiVM.activeStreams.first
    }
    
    private var otherStreams: [(index: Int, vm: DragonetPlayerViewModel)] {
        multiVM.activeStreams.enumerated()
            .filter { $0.offset != multiVM.activeAudioIndex }
            .map { ($0.offset, $0.element) }
    }
    
    var body: some View {
        VStack(spacing: 12) {
            // ── Top Bar ──
            HStack(spacing: 10) {
                // Exit MultiView Button
                Button {
                    onExitMultiView()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .bold))
                        Text("Exit MultiView")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .frame(height: 44)
                }
                .buttonStyle(TabletopCardButtonStyle(cornerRadius: 12))
                
                // Prominent Stream Indicator Card
                HStack(spacing: 8) {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 7, height: 7)
                    
                    if let cid = prominentVM?.channel?.id {
                        ChannelImageView(
                            baseUrl: appState.serverURL,
                            apiKey: appState.accessToken,
                            channelId: cid
                        )
                        .frame(width: 24, height: 24)
                        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    }
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text(prominentVM?.channel?.name ?? prominentVM?.program?.name ?? "Prominent")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        
                        Text("Audio Active")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    
                    Spacer()
                    
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.blue)
                }
                .padding(.horizontal, 12)
                .frame(height: 44)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.white.opacity(0.08))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(Color.white.opacity(0.14), lineWidth: 1)
                        )
                )
                .glassEffect(in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                
                // Add Channel Button
                if multiVM.activeStreams.count < multiVM.maxStreams {
                    Button {
                        showAddChannelSheet = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(TabletopCardButtonStyle(cornerRadius: 12))
                    .accessibilityLabel("Add Channel to MultiView")
                }
                
                // Expand to Fullscreen Grid Button
                Button {
                    showFullScreenMultiView = true
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(TabletopCardButtonStyle(cornerRadius: 12))
                .accessibilityLabel("Fullscreen MultiView Grid")
            }
            
            // ── Rest Streams Section (Secondary Streams with Tap to Switch) ──
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("OTHER STREAMS")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.55))
                    
                    Spacer()
                    
                    Text("Tap to switch to top")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.45))
                }
                .padding(.horizontal, 4)
                
                if otherStreams.count == 1, let single = otherStreams.first {
                    restStreamTile(index: single.index, streamVM: single.vm)
                        .frame(maxWidth: .infinity)
                        .frame(height: 160)
                } else if otherStreams.count == 2 {
                    HStack(spacing: 10) {
                        ForEach(otherStreams, id: \.index) { item in
                            restStreamTile(index: item.index, streamVM: item.vm)
                                .frame(maxWidth: .infinity)
                                .frame(height: 140)
                        }
                    }
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: 10) {
                            ForEach(otherStreams, id: \.index) { item in
                                restStreamTile(index: item.index, streamVM: item.vm)
                                    .frame(width: 200, height: 125)
                            }
                        }
                        .padding(.horizontal, 2)
                    }
                    .frame(height: 130)
                }
            }
            
            Spacer(minLength: 4)
            
            // ── Primary Playback Controls Row (Controls Prominent Stream) ──
            if let pVM = prominentVM {
                HStack(spacing: 12) {
                    // Rewind 10s Card
                    Button {
                        pVM.skipBackward(seconds: 10)
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: "gobackward.10")
                                .font(.system(size: 24, weight: .semibold))
                                .foregroundStyle(.white)
                            Text("10s")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white.opacity(0.6))
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 64)
                    }
                    .buttonStyle(TabletopCardButtonStyle(cornerRadius: 14))
                    .accessibilityLabel("Rewind 10 seconds")
                    
                    // Big Center Play / Pause Card
                    Button {
                        pVM.togglePlayPause()
                    } label: {
                        Image(systemName: pVM.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 32, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 64)
                    }
                    .buttonStyle(TabletopCardButtonStyle(cornerRadius: 14, isSelected: true))
                    .accessibilityLabel(pVM.isPlaying ? "Pause" : "Play")
                    
                    // Fast Forward 10s or Live Card
                    Button {
                        if pVM.isAtLiveEdge {
                            pVM.skipForward(seconds: 10)
                        } else {
                            pVM.goToLive()
                        }
                    } label: {
                        VStack(spacing: 4) {
                            if !pVM.isAtLiveEdge {
                                Image(systemName: "dot.radiowaves.right")
                                    .font(.system(size: 22, weight: .bold))
                                    .foregroundStyle(.red)
                                Text("LIVE")
                                    .font(.system(size: 10, weight: .black))
                                    .foregroundStyle(.red)
                            } else {
                                Image(systemName: "goforward.10")
                                    .font(.system(size: 24, weight: .semibold))
                                    .foregroundStyle(.white)
                                Text("10s")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(.white.opacity(0.6))
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 64)
                    }
                    .buttonStyle(TabletopCardButtonStyle(cornerRadius: 14, isSelected: !pVM.isAtLiveEdge, accentColor: .red))
                    .accessibilityLabel(!pVM.isAtLiveEdge ? "Jump to Live" : "Fast forward 10 seconds")
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.ignoresSafeArea())
    }
    
    @ViewBuilder
    private func restStreamTile(index: Int, streamVM: DragonetPlayerViewModel) -> some View {
        ZStack(alignment: .topTrailing) {
            DragonetPlayer(
                player: streamVM.player,
                streamURL: streamVM.streamURL,
                isPiPActive: .constant(false),
                isCCEnabled: .constant(false),
                controlsVisible: .constant(false),
                onPlaybackError: { [weak streamVM] _ in
                    guard let streamVM = streamVM else { return }
                    multiVM.removeStream(streamVM)
                }
            ) { _ in
                streamVM.startPlayback()
            }
            .allowsHitTesting(false)
            
            // Tap area to switch stream
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        multiVM.activeAudioIndex = index
                    }
                }
            
            // Top-leading Channel Info & Sports Score
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if let cid = streamVM.channel?.id {
                        ChannelImageView(
                            baseUrl: appState.serverURL,
                            apiKey: appState.accessToken,
                            channelId: cid
                        )
                        .frame(width: 20, height: 20)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    }
                    
                    Text(streamVM.channel?.name ?? streamVM.program?.name ?? "Stream \(index + 1)")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    Capsule()
                        .fill(Color.black.opacity(0.75))
                        .overlay(Capsule().stroke(Color.white.opacity(0.15), lineWidth: 0.6))
                )
                
                // Sports score pill (Temporarily removed, saving for 2.4.1)
                /*
                if let score = streamVM.liveGameScore {
                    HStack(spacing: 4) {
                        Circle().fill(Color.red).frame(width: 5, height: 5)
                        Text(score.statusDisplay)
                            .font(.system(size: 10, weight: .black, design: .rounded))
                            .foregroundStyle(.white)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.black.opacity(0.8)))
                }
                */
                
                Spacer()
                
                // Bottom "Switch to Top" indicator pill
                HStack(spacing: 4) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 10, weight: .bold))
                    Text("Switch to Top")
                        .font(.system(size: 10, weight: .bold))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    Capsule()
                        .fill(Color.black.opacity(0.75))
                        .overlay(Capsule().stroke(Color.white.opacity(0.15), lineWidth: 0.6))
                )
                .foregroundStyle(.white)
            }
            .padding(8)
            .allowsHitTesting(false)
            
            // Top-trailing Close (X) button
            Button {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    multiVM.removeStream(at: index)
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Color.black.opacity(0.75)))
                    .overlay(Circle().stroke(Color.white.opacity(0.2), lineWidth: 0.8))
            }
            .padding(6)
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.18), lineWidth: 1)
        )
    }
}

// MARK: - Plankton (VOD) Tabletop Deck View

struct PlanktonTabletopDeckView: View {
    @ObservedObject var vm: PlanktonPlayerViewModel
    @ObservedObject var appState: AppState
    var dismiss: () -> Void
    @Binding var showEpisodesDrawer: Bool
    var playerController: DragonetPlayerController?
    
    @State private var playbackRate: Float = 1.0
    
    var body: some View {
        VStack(spacing: 16) {
            // ── Top Bar ──
            HStack(spacing: 12) {
                // Dismiss / Close Button
                Button {
                    vm.stopAndDismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 54, height: 54)
                }
                .buttonStyle(TabletopCardButtonStyle(cornerRadius: 14))
                .accessibilityLabel("Close Player")
                
                // Content Title & Episode Info Card (Tap toggles episode switcher)
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        showEpisodesDrawer.toggle()
                    }
                    if showEpisodesDrawer {
                        playerController?.cancelTimer()
                    }
                } label: {
                    HStack(spacing: 12) {
                        Image("Logo")
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 36, height: 36)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        
                        VStack(alignment: .leading, spacing: 3) {
                            let activeSeriesName = vm.seriesName ?? vm.currentItem?.SeriesName
                            if vm.isEpisode, let series = activeSeriesName, !series.isEmpty {
                                Text(series)
                                    .font(.system(size: 15, weight: .bold))
                                    .foregroundStyle(.white)
                                    .lineLimit(1)
                                
                                let s = vm.currentItem?.ParentIndexNumber.map { String(format: "S%02d", $0) } ?? ""
                                let e = vm.currentItem?.IndexNumber.map { String(format: "E%02d", $0) } ?? ""
                                let se = [s, e].filter { !$0.isEmpty }.joined()
                                let epName = vm.currentItem?.Name ?? ""
                                let sub = se.isEmpty ? epName : "\(se): \(epName)"
                                
                                Text(sub)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.7))
                                    .lineLimit(1)
                            } else {
                                Text(vm.currentItem?.Name ?? "Media")
                                    .font(.system(size: 15, weight: .bold))
                                    .foregroundStyle(.white)
                                    .lineLimit(1)
                            }
                        }
                        
                        Spacer()
                        
                        if vm.playlist.count > 1 || vm.isEpisode {
                            if vm.playlist.count > 1 {
                                Text("\(vm.currentIndex + 1)/\(vm.playlist.count)")
                                    .font(.system(size: 12, weight: .bold, design: .rounded))
                                    .foregroundStyle(.white.opacity(0.5))
                            }
                            
                            Image(systemName: showEpisodesDrawer ? "chevron.down" : "chevron.up")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(.white.opacity(0.5))
                                .padding(.trailing, 4)
                        }
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 54)
                }
                .buttonStyle(TabletopCardButtonStyle(cornerRadius: 14, isSelected: showEpisodesDrawer))
                
                // Right Actions
                HStack(spacing: 10) {
                    // PiP Button
                    Button {
                        NotificationCenter.default.post(name: .dragonetTogglePiP, object: nil)
                    } label: {
                        Image(systemName: vm.isPiPActive ? "rectangle.on.rectangle.slash" : "rectangle.on.rectangle")
                            .font(.system(size: 19, weight: .medium))
                            .foregroundStyle(vm.isPiPActive ? Color.blue : .white)
                            .frame(width: 54, height: 54)
                    }
                    .buttonStyle(TabletopCardButtonStyle(cornerRadius: 14, isSelected: vm.isPiPActive))
                    .accessibilityLabel("Picture in Picture")
                    
                    // AirPlay Button
                    DragonetAirPlayButton(player: vm.player)
                        .frame(width: 54, height: 54)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(Color.white.opacity(0.08))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .stroke(Color.white.opacity(0.14), lineWidth: 1)
                                )
                        )
                        .glassEffect(in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }
            
            // ── Primary Playback Controls Row (3 Large Cards) ──
            HStack(spacing: 14) {
                // Rewind 10s Card
                Button {
                    vm.skipBackward()
                } label: {
                    VStack(spacing: 6) {
                        Image(systemName: "gobackward.10")
                            .font(.system(size: 32, weight: .semibold))
                            .foregroundStyle(.white)
                        Text("10s")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 88)
                }
                .buttonStyle(TabletopCardButtonStyle(cornerRadius: 18))
                .accessibilityLabel("Rewind 10 seconds")
                
                // Big Center Play / Pause Card
                Button {
                    vm.togglePlayPause()
                } label: {
                    Image(systemName: vm.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 42, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 88)
                }
                .buttonStyle(TabletopCardButtonStyle(cornerRadius: 18, isSelected: true))
                .accessibilityLabel(vm.isPlaying ? "Pause" : "Play")
                
                // Fast Forward 10s Card
                Button {
                    vm.skipForward()
                } label: {
                    VStack(spacing: 6) {
                        Image(systemName: "goforward.10")
                            .font(.system(size: 32, weight: .semibold))
                            .foregroundStyle(.white)
                        Text("10s")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 88)
                }
                .buttonStyle(TabletopCardButtonStyle(cornerRadius: 18))
                .accessibilityLabel("Fast forward 10 seconds")
            }
            
            // ── Scrubber Bar with Blue Progression Line ──
            HStack(spacing: 12) {
                Text(formatTime(vm.currentTime))
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 50, alignment: .trailing)
                
                Slider(value: $vm.currentTime, in: 0...max(vm.duration, 1)) { editing in
                    vm.isScrubbing = editing
                    if !editing {
                        vm.seek(to: vm.currentTime)
                        vm.updateNowPlayingPlaybackState()
                    }
                }
                .tint(Color.blue)
                
                Text("-" + formatTime(max(vm.duration - vm.currentTime, 0)))
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.65))
                    .frame(width: 50, alignment: .leading)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.white.opacity(0.05))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(Color.white.opacity(0.1), lineWidth: 0.8)
                    )
            )
            .glassEffect(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            
            // ── Bottom Utility Deck (4 Pill Buttons) ──
            HStack(spacing: 12) {
                // 1. Episodes / Playlist Drawer Button
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        showEpisodesDrawer.toggle()
                    }
                    if showEpisodesDrawer { playerController?.cancelTimer() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "list.bullet")
                            .font(.system(size: 15, weight: .bold))
                        Text(vm.isEpisode ? "Episodes" : "Playlist")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                }
                .buttonStyle(TabletopCardButtonStyle(cornerRadius: 14, isSelected: showEpisodesDrawer))
                
                // 2. Playback Speed Menu
                Menu {
                    Button("0.5x")  { setRate(0.5) }
                    Button("0.75x") { setRate(0.75) }
                    Button("1.0x (Normal)") { setRate(1.0) }
                    Button("1.25x") { setRate(1.25) }
                    Button("1.5x")  { setRate(1.5) }
                    Button("2.0x")  { setRate(2.0) }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "gauge.with.dots.needle.bottom.50percent")
                            .font(.system(size: 15, weight: .bold))
                        Text(playbackRate == 1.0 ? "Speed" : String(format: "%.2fx", playbackRate))
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                }
                .buttonStyle(TabletopCardButtonStyle(cornerRadius: 14, isSelected: playbackRate != 1.0, accentColor: .blue))
                
                // 3. Audio & Subtitles Menu
                Menu {
                    Section("Audio Track") {
                        ForEach(vm.availableAudioTracks, id: \.self) { track in
                            Button {
                                vm.selectAudioTrack(track)
                            } label: {
                                HStack {
                                    Text(track.safeDisplayName)
                                    if vm.selectedAudioTrack == track {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    }
                    
                    Section("Subtitles") {
                        Button {
                            vm.selectSubtitleTrack(nil)
                        } label: {
                            HStack {
                                Text("Off")
                                if !vm.isCCEnabled || vm.selectedSubtitleTrack == nil {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                        
                        ForEach(vm.availableSubtitleTracks, id: \.self) { track in
                            Button {
                                vm.selectSubtitleTrack(track)
                            } label: {
                                HStack {
                                    Text(track.safeDisplayName)
                                    if vm.isCCEnabled && vm.selectedSubtitleTrack == track {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "speaker.wave.2.fill")
                            .font(.system(size: 15, weight: .bold))
                        Text(vm.isCCEnabled ? "Audio/CC" : "Audio")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(vm.isCCEnabled ? Color.blue : .white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                }
                .buttonStyle(TabletopCardButtonStyle(cornerRadius: 14, isSelected: vm.isCCEnabled))
                
                // 4. Next Episode Button
                Button {
                    vm.skipToNextEpisode()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "forward.end.fill")
                            .font(.system(size: 15, weight: .bold))
                        Text("Next Ep")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                }
                .buttonStyle(TabletopCardButtonStyle(cornerRadius: 14))
                .disabled(!vm.hasNextEpisode)
                .opacity(vm.hasNextEpisode ? 1.0 : 0.4)
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.ignoresSafeArea())
    }
    
    private func setRate(_ rate: Float) {
        playbackRate = rate
        vm.player.rate = rate
    }
    
    private func formatTime(_ seconds: Double) -> String {
        guard !seconds.isNaN && !seconds.isInfinite && seconds > 0 else { return "0:00" }
        let totalSeconds = Int(seconds)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let secs = totalSeconds % 60
        
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        } else {
            return String(format: "%d:%02d", minutes, secs)
        }
    }
}

// MARK: - iPhone Duo Device Detection

extension UIDevice {
    static var isiPhoneDuo: Bool {
        #if targetEnvironment(simulator)
        if let simName = ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"],
           simName.localizedCaseInsensitiveContains("Duo") {
            return true
        }
        if let simModel = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"],
           simModel.localizedCaseInsensitiveContains("Duo") {
            return true
        }
        #endif
        if UIDevice.current.name.localizedCaseInsensitiveContains("Duo") {
            return true
        }
        var systemInfo = utsname()
        uname(&systemInfo)
        let machine = withUnsafeBytes(of: &systemInfo.machine) { ptr in
            String(cString: ptr.baseAddress!.assumingMemoryBound(to: CChar.self))
        }
        if machine.localizedCaseInsensitiveContains("Duo") {
            return true
        }
        return false
    }
}

// MARK: - Apple iPhone Duo Tabletop Layout Container

@available(iOS 27.1, *)
struct DuoTabletopArrangementView<Primary: View, Secondary: View>: View {
    @ViewBuilder let primary: () -> Primary
    @ViewBuilder let secondary: () -> Secondary
    
    var body: some View {
        ArrangementView {
            primary()
        } secondary: {
            secondary()
        }
        .arrangementViewStyle(.split)
        .background(Color.black.ignoresSafeArea())
    }
}

struct DuoTabletopSplitLayout<Primary: View, Secondary: View, Normal: View>: View {
    var isPartiallyFolded: Bool
    @ViewBuilder let primary: () -> Primary
    @ViewBuilder let secondary: () -> Secondary
    @ViewBuilder let normal: () -> Normal
    
    init(isPartiallyFolded: Bool, @ViewBuilder primary: @escaping () -> Primary, @ViewBuilder secondary: @escaping () -> Secondary, @ViewBuilder normal: @escaping () -> Normal) {
        self.isPartiallyFolded = isPartiallyFolded
        self.primary = primary
        self.secondary = secondary
        self.normal = normal
    }
    
    init(isTabletop: Bool, @ViewBuilder primary: @escaping () -> Primary, @ViewBuilder secondary: @escaping () -> Secondary, @ViewBuilder normal: @escaping () -> Normal) {
        self.isPartiallyFolded = isTabletop
        self.primary = primary
        self.secondary = secondary
        self.normal = normal
    }
    
    var body: some View {
        if !UIDevice.isiPhoneDuo {
            normal()
        } else {
            GeometryReader { proxy in
                let isPortrait = proxy.size.height > proxy.size.width
                // Tabletop mode is strictly enabled ONLY when content is in portrait and partially folded (not landscape)
                let isTabletop = isPartiallyFolded && isPortrait
                
                ZStack {
                    Color.black.ignoresSafeArea()
                    
                    Group {
                        if isTabletop {
                            if #available(iOS 27.1, *) {
                                DuoTabletopArrangementView(primary: primary, secondary: secondary)
                            } else {
                                VStack(spacing: 0) {
                                    primary()
                                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                                    secondary()
                                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                                }
                            }
                        } else {
                            normal()
                        }
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
                .background(Color.black.ignoresSafeArea())
            }
        }
    }
}

// MARK: - Hinge Observation Modifier

extension View {
    @ViewBuilder
    func duoHingeObservation(isPartiallyFolded: Binding<Bool>) -> some View {
        if #available(iOS 27.1, *), UIDevice.isiPhoneDuo {
            self.onHingeChange { oldCtx, newCtx in
                if let hinge = newCtx.hinge {
                    let folded = (hinge.status == .partiallyOpen)
                    if isPartiallyFolded.wrappedValue != folded {
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.82)) {
                            isPartiallyFolded.wrappedValue = folded
                        }
                    }
                } else {
                    if isPartiallyFolded.wrappedValue {
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.82)) {
                            isPartiallyFolded.wrappedValue = false
                        }
                    }
                }
            }
        } else {
            self
        }
    }
    
    @ViewBuilder
    func duoHingeObservation(isTabletop: Binding<Bool>) -> some View {
        duoHingeObservation(isPartiallyFolded: isTabletop)
    }
}
