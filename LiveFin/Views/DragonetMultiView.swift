//
//  DragonetMultiView.swift
//  LiveFin
//
//  Created by KPGamingz on 7/14/26.
//

import SwiftUI
import AVKit

struct DragonetMultiView: View {
    @StateObject var multiVM: DragonetMultiViewModel
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var appState: AppState
    
    @State private var showChannelPicker = false
    @State private var controlsVisible = true
    @State private var autoHideTask: Task<Void, Never>?
    @State private var showExitConfirmation = false
    
    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()
                    .onTapGesture {
                        withAnimation { controlsVisible.toggle() }
                        if controlsVisible { resetAutoHideTimer() }
                    }
                
                let count = multiVM.activeStreams.count
                let rows: Int = count <= 2 ? 1 : 2
                let cols: Int = count <= 4 ? 2 : 3
                
                let availableWidth = max(0, geo.size.width - CGFloat(cols - 1) * 2)
                let availableHeight = max(0, geo.size.height - CGFloat(rows - 1) * 2)
                
                let widthFromHeight = (availableHeight / CGFloat(rows)) * (16.0 / 9.0)
                let widthFromWidth = availableWidth / CGFloat(cols)
                
                let cellWidth = min(widthFromHeight, widthFromWidth)
                let cellHeight = cellWidth * (9.0 / 16.0)
                
                // Smart Custom Grid Layout for proper centering
                VStack(spacing: 2) {
                    if count == 2 {
                        gridRow(start: 0, end: 2, cellWidth: cellWidth, cellHeight: cellHeight)
                    } else if count == 3 {
                        gridRow(start: 0, end: 2, cellWidth: cellWidth, cellHeight: cellHeight)
                        gridRow(start: 2, end: 3, cellWidth: cellWidth, cellHeight: cellHeight)
                    } else if count == 4 {
                        gridRow(start: 0, end: 2, cellWidth: cellWidth, cellHeight: cellHeight)
                        gridRow(start: 2, end: 4, cellWidth: cellWidth, cellHeight: cellHeight)
                    } else if count == 5 {
                        gridRow(start: 0, end: 3, cellWidth: cellWidth, cellHeight: cellHeight)
                        gridRow(start: 3, end: 5, cellWidth: cellWidth, cellHeight: cellHeight)
                    } else if count >= 6 {
                        gridRow(start: 0, end: 3, cellWidth: cellWidth, cellHeight: cellHeight)
                        gridRow(start: 3, end: 6, cellWidth: cellWidth, cellHeight: cellHeight)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                
                // Top Left Controls
                VStack {
                    HStack(spacing: 12) {
                        Button {
                            if multiVM.activeStreams.count > 1 {
                                showExitConfirmation = true
                            } else {
                                multiVM.selectedStreamToKeep = multiVM.activeStreams.first
                                dismiss()
                            }
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 20, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 44, height: 44)
                        }
                        .glassEffect(in: Circle())
                        
                        if multiVM.activeStreams.count < multiVM.maxStreams {
                            Button {
                                resetAutoHideTimer()
                                showChannelPicker = true
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "plus")
                                        .font(.system(size: 16, weight: .bold))
                                    Text("Add Channel")
                                        .font(.system(size: 16, weight: .semibold))
                                }
                                .foregroundStyle(.white)
                                .padding(.horizontal, 16)
                                .frame(height: 44)
                            }
                            .glassEffect(in: Capsule())
                        }
                        
                        Spacer()
                    }
                    .padding()
                    Spacer()
                }
                .opacity(controlsVisible ? 1 : 0)
                .allowsHitTesting(controlsVisible)
                .animation(.easeOut(duration: 0.3), value: controlsVisible)
            }
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .sheet(isPresented: $showChannelPicker) {
            let activeIds = multiVM.activeStreams.compactMap { $0.channel?.id }
            MultiViewChannelPickerView(appState: appState, activeChannelIds: activeIds) { url, channel, program in
                multiVM.addStream(url: url, channel: channel, program: program)
            }
        }
        .confirmationDialog("Continue Watching", isPresented: $showExitConfirmation, titleVisibility: .visible) {
            ForEach(multiVM.activeStreams.indices, id: \.self) { index in
                let stream = multiVM.activeStreams[index]
                Button(stream.channel?.name ?? stream.program?.name ?? "Stream \(index + 1)") {
                    multiVM.selectedStreamToKeep = stream
                    dismiss()
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Choose which stream to continue watching.")
        }
        .onChange(of: multiVM.shouldDismiss) { should in
            if should {
                multiVM.selectedStreamToKeep = multiVM.activeStreams.first
                dismiss()
            }
        }
        .onAppear {
            resetAutoHideTimer()
        }
        .onDisappear {
            autoHideTask?.cancel()
        }
        .onChange(of: showChannelPicker) { isPresented in
            if !isPresented { resetAutoHideTimer() }
        }
    }
    
    // Shows the controls, then schedules them to fade out again after a few seconds of inactivity.
    private func resetAutoHideTimer() {
        autoHideTask?.cancel()
        
        if !controlsVisible {
            controlsVisible = true
        }
        
        autoHideTask = Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            controlsVisible = false
        }
    }
    
    // Centers rows that have fewer active items perfectly within the geometry space
    @ViewBuilder
    private func gridRow(start: Int, end: Int, cellWidth: CGFloat, cellHeight: CGFloat) -> some View {
        HStack(spacing: 2) {
            ForEach(start..<end, id: \.self) { i in
                streamView(for: i)
                    .frame(width: cellWidth, height: cellHeight)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }
    
    @ViewBuilder
    private func streamView(for index: Int) -> some View {
        if multiVM.activeStreams.indices.contains(index) {
            let vm = multiVM.activeStreams[index]
            let isActiveAudio = (multiVM.activeAudioIndex == index)
            
            ZStack(alignment: .topTrailing) {
                DragonetPlayer(
                    player: vm.player,
                    streamURL: vm.streamURL,
                    isPiPActive: .constant(false),
                    isCCEnabled: .constant(false),
                    controlsVisible: .constant(false),
                    onPlaybackError: { [weak vm] _ in
                        guard let vm = vm else { return }
                        multiVM.removeStream(vm)
                    }
                ) { vc in
                    if vm.isMultiView {
                        vm.startPlayback()
                    }
                }
                
                // Tap to switch Audio OR toggle controls if already active
                Color.white.opacity(0.001)
                    .onTapGesture {
                        if multiVM.activeAudioIndex == index {
                            withAnimation { controlsVisible.toggle() }
                            if controlsVisible { resetAutoHideTimer() }
                        } else {
                            withAnimation { multiVM.activeAudioIndex = index }
                            withAnimation { controlsVisible = true }
                            resetAutoHideTimer()
                        }
                    }
                
                // Quadrant Remove Button (Only for > 2 streams)
                if multiVM.activeStreams.count > 2 {
                    Button {
                        multiVM.removeStream(at: index)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption.bold())
                            .foregroundColor(.white)
                            .padding(8)
                            .background(Circle().fill(Color.black.opacity(0.7)))
                    }
                    .padding(8)
                    .opacity(controlsVisible ? 1 : 0)
                    .allowsHitTesting(controlsVisible)
                    .animation(.easeOut(duration: 0.3), value: controlsVisible)
                }
                
                // Bottom Labels
                VStack {
                    Spacer()
                    HStack {
                        if let name = vm.channel?.name {
                            Text(name)
                                .font(.caption.bold())
                                .foregroundStyle(.white)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Capsule().fill(.black.opacity(0.6)))
                                .padding(8)
                        }
                        
                        Spacer()
                        
                        if isActiveAudio {
                            Image(systemName: "speaker.wave.2.fill")
                                .font(.caption)
                                .foregroundStyle(.white)
                                .padding(6)
                                .background(Circle().fill(Color.blue))
                                .padding(8)
                        }
                    }
                }
                .opacity(controlsVisible ? 1 : 0)
                .animation(.easeOut(duration: 0.3), value: controlsVisible)
            }
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(isActiveAudio ? Color.blue : Color.white.opacity(0.15), lineWidth: isActiveAudio ? 4 : 1)
            )
            .clipped()
        }
    }
}
