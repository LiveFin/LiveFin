//
//  TVProgramView.swift
//  LiveFin
//
//  Created by KPGamingz on 7/18/26.
//

import SwiftUI
import Combine

struct TVProgramView: View {
    let program: JFProgram
    @ObservedObject var appState: AppState
    @EnvironmentObject var coordinator: GlobalPlayerCoordinator
    @StateObject private var vm: ProgramViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var vodItemToPlay: JFItemDto? = nil

    init(program: JFProgram, appState: AppState) {
        self.program = program
        self.appState = appState
        _vm = StateObject(wrappedValue: ProgramViewModel(program: program, appState: appState))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 36) {
                hero

                if let overview = program.overview, !overview.isEmpty {
                    Text(overview)
                        .font(.title3)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 60)
                }

                if vm.isLoadingUpcoming && vm.displayedUpcoming.isEmpty {
                    sectionHeader("Upcoming Airings")
                    UpcomingSkeletonView()
                        .padding(.horizontal, 60)
                } else if !vm.displayedUpcoming.isEmpty {
                    upcomingSection
                }

                if vm.isLoadingRelated && vm.relatedPrograms.isEmpty {
                    sectionHeader("Related")
                    RelatedSkeletonView()
                        .padding(.horizontal, 60)
                } else if !vm.relatedPrograms.isEmpty {
                    relatedSection
                }
            }
            .padding(.bottom, 60)
        }
        .environmentObject(appState)
        .task {
            vm.onAppear()
            await vm.load()
        }
        .fullScreenCover(item: $vodItemToPlay) { item in
            TVPlanktonPlayerView(playlist: [item], startIndex: 0)
                .environmentObject(appState)
        }
        .alert("Playback Error", isPresented: Binding(
            get: { vm.playbackErrorMessage != nil },
            set: { if !$0 { vm.playbackErrorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { vm.playbackErrorMessage = nil }
        } message: {
            Text(vm.playbackErrorMessage ?? "")
        }
        .onExitCommand { dismiss() }
    }

    // MARK: - Hero

    private var hero: some View {
        HStack(alignment: .top, spacing: 48) {
            VStack(alignment: .leading, spacing: 14) {
                if vm.isLive {
                    LiveBadge()
                }

                Text(program.name)
                    .font(.system(size: 56, weight: .bold))
                    .foregroundColor(.primary)

                if let subtitle = vm.primarySubtitleLine() {
                    Text(subtitle)
                        .font(.title3)
                        .foregroundColor(.secondary)
                }

                HStack(spacing: 16) {
                    Text(vm.timeLine)
                    Text("•")
                    Text(vm.channelName)
                    if let rating = program.officialRating, !rating.isEmpty {
                        Text("•")
                        Text(rating)
                    }
                }
                .font(.title3)
                .foregroundColor(.secondary)

                if !vm.chips().isEmpty {
                    HStack(spacing: 10) {
                        ForEach(vm.chips(), id: \.self) { chip in
                            Text(chip)
                                .font(.callout.weight(.medium))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 6)
                                .background(Color.platformTertiaryFill)
                                .clipShape(Capsule())
                        }
                    }
                }

                Button {
                    handlePlayAction()
                } label: {
                    Label("Play", systemImage: "play.fill")
                        .font(.title3.weight(.semibold))
                        .padding(.horizontal, 8)
                }
                .buttonStyle(.card)
                .padding(.top, 8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            ProgramDetailImage(program: program, refreshSeed: 0, preferredWidth: 700)
                .frame(width: 320, height: 480)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .shadow(color: .black.opacity(0.3), radius: 12, x: 0, y: 6)
        }
        .padding(.horizontal, 60)
        .padding(.top, 60)
    }

    private func handlePlayAction() {
        if vm.isLive, let channelId = program.channelId,
           let channel = JFChannel(json: ["Id": channelId, "Name": program.channelName ?? program.name]) {
            coordinator.startChannelPlayback(channel, appState: appState, fullScreen: true)
        } else {
            // Close the live PiP before starting on-demand playback
            coordinator.closePlayback(appState: appState)
            let dict: [String: Any] = ["Id": program.id, "Name": program.name]
            if let data = try? JSONSerialization.data(withJSONObject: dict),
               let dto = try? JSONDecoder().decode(JFItemDto.self, from: data) {
                self.vodItemToPlay = dto
            }
        }
    }

    // MARK: - Upcoming

    private var upcomingSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeader("Upcoming Airings")
            LazyVStack(spacing: 0) {
                ForEach(vm.displayedUpcoming) { upcoming in
                    NavigationLink(destination: TVProgramView(program: upcoming, appState: appState)
                        .environmentObject(coordinator)) {
                        UpcomingProgramRow(
                            program: upcoming,
                            referenceName: vm.program.name,
                            referenceStart: vm.program.startDate
                        )
                    }
                    .buttonStyle(.card)
                    .onAppear {
                        if upcoming.id == vm.displayedUpcoming.last?.id {
                            Task { await vm.fetchNextUpcomingPage() }
                        }
                    }
                }
                if vm.isLoadingMoreUpcoming {
                    ProgressView()
                        .padding(.vertical, 16)
                }
            }
            .padding(.horizontal, 60)
        }
    }

    // MARK: - Related

    private var relatedSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeader("Related")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 28) {
                    ForEach(vm.relatedPrograms) { related in
                        NavigationLink(destination: TVProgramView(program: related, appState: appState)
                            .environmentObject(coordinator)) {
                            RelatedProgramCard(program: related, loadImages: vm.loadRelatedImages)
                        }
                        .buttonStyle(.card)
                    }
                }
                .padding(.horizontal, 60)
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 34, weight: .bold))
            .padding(.horizontal, 60)
    }
}
