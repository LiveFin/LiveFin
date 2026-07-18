// ProgramView.swift

import SwiftUI

struct UpcomingRecordingIcon: View {
    @StateObject private var vm: ProgramRecordingViewModel
    init(program: JFProgram, appState: AppState) {
        _vm = StateObject(wrappedValue: ProgramRecordingViewModel(program: program, appState: appState))
    }
    var body: some View {
        if vm.isRecordingScheduled {
            Image(systemName: "record.circle.fill")
                .font(.headline)
                .foregroundColor(.red)
                .padding(.trailing, 8)
        }
    }
}

struct ProgramView: View {
    let program: JFProgram
    @EnvironmentObject private var appState: AppState
    @StateObject private var viewModel: ProgramViewModel
    
    // Notification Deep Link Listener
    @StateObject private var notificationManager = NotificationManager.shared
    
    // Recording and Notification States
    @StateObject private var recordingViewModel: ProgramRecordingViewModel
    @State private var showRecordingSheet = false
    @State private var showNotificationSheet = false

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass: UserInterfaceSizeClass?
    #if os(iOS)
    private var isiPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }
    #else
    private var isiPad: Bool { false }
    #endif

    init(program: JFProgram, appState: AppState) {
        self.program = program
        _viewModel = StateObject(wrappedValue: ProgramViewModel(program: program, appState: appState))
        _recordingViewModel = StateObject(wrappedValue: ProgramRecordingViewModel(program: program, appState: appState))
    }

    // MARK: Layout constants

    private var moviePosterWidth: CGFloat {
        #if os(macOS)
        return 380
        #else
        return (isiPad || horizontalSizeClass == .regular) ? 360 : 240
        #endif
    }
    private var moviePosterHeight: CGFloat { moviePosterWidth * 1.5 }

    private var seriesImageHeight: CGFloat {
        #if os(macOS)
        return 460
        #else
        return (isiPad || horizontalSizeClass == .regular) ? 300 : 220
        #endif
    }

    private var moviePreferredRequestWidth: Int {
        #if os(macOS)
        return 2000
        #else
        return (isiPad || horizontalSizeClass == .regular) ? 1600 : 1100
        #endif
    }

    private var seriesPreferredRequestWidth: Int {
        #if os(macOS)
        return 1200
        #else
        return (isiPad || horizontalSizeClass == .regular) ? 1200 : 900
        #endif
    }

    // MARK: Body

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                imageSection
                titleSection
                ratingRow
                channelRow
                actionButtons
                metaChips
                overviewText
                relatedSection
                upcomingSection
                Spacer(minLength: 32)
            }
            .padding(.horizontal)
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showRecordingSheet) {
            RecordingConfigurationView(viewModel: recordingViewModel)
        }
        .sheet(isPresented: $showNotificationSheet) {
            NotificationConfigurationView(viewModel: recordingViewModel)
        }
        .fullScreenCover(item: $viewModel.streamItem) { item in
            DragonetPlayerView(
                streamURL: item.url,
                channel: viewModel.buildChannel(),
                program: program,
                appState: appState,
                onPlaybackError: { msg in
                    viewModel.streamItem = nil
                    viewModel.playbackErrorMessage = msg
                }
            )
            .environmentObject(appState)
        }
        .alert("Playback Error",
               isPresented: Binding(
                get: { viewModel.playbackErrorMessage != nil },
                set: { if !$0 { viewModel.playbackErrorMessage = nil } }
               )) {
            Button("OK", role: .cancel) { viewModel.playbackErrorMessage = nil }
        } message: {
            Text(viewModel.playbackErrorMessage ?? "An unknown error occurred while trying to play the channel.")
        }
        .onChange(of: notificationManager.requestedProgramId) { programId in
            // Handle if a user taps while they are already viewing this program
            if programId == program.id && notificationManager.autoPlayRequested {
                Task { await viewModel.startPlayback() }
                // Consume link
                notificationManager.requestedProgramId = nil
                notificationManager.autoPlayRequested = false
            }
        }
        .onAppear {
            viewModel.onAppear()
            recordingViewModel.checkPendingNotifications()
            
            // Handle if the view was just opened via deep link
            if notificationManager.requestedProgramId == program.id && notificationManager.autoPlayRequested {
                Task { await viewModel.startPlayback() }
                // Consume link
                notificationManager.requestedProgramId = nil
                notificationManager.autoPlayRequested = false
            }
        }
        .task(id: program.id) {
            await viewModel.load()
        }
    }

    // MARK: - Sections

    @ViewBuilder private var imageSection: some View {
        if program.isLikelyMovie {
            VStack {
                ProgramDetailImage(program: program, refreshSeed: 0, preferredWidth: moviePreferredRequestWidth)
                    .frame(width: moviePosterWidth, height: moviePosterHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .overlay(alignment: .bottomLeading) { progressOverlay }
                    .shadow(radius: 8, y: 4)
            }
            .frame(maxWidth: .infinity)
            .padding(.top)
        } else {
            ProgramDetailImage(program: program, refreshSeed: 0, preferredWidth: seriesPreferredRequestWidth)
                .frame(maxWidth: .infinity)
                .frame(height: seriesImageHeight)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(alignment: .bottomLeading) { progressOverlay }
                .padding(.top)
        }
    }

    @ViewBuilder private var progressOverlay: some View {
        if let p = viewModel.progressRatio, p > 0, p < 1 {
            ProgressView(value: p)
                .progressViewStyle(.linear)
                .tint(.white)
                .background(Color.black.opacity(0.3))
                .frame(width: program.isLikelyMovie
                       ? max(moviePosterWidth - 20, 120)
                       : ((isiPad || horizontalSizeClass == .regular) ? 240 : 160))
                .padding(8)
        }
    }

    @ViewBuilder private var titleSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(program.name)
                    .font(.title.bold())
                    .fixedSize(horizontal: false, vertical: true)
                if viewModel.showNew {
                    Text("New")
                        .font(.caption2).foregroundColor(.white)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.blue).cornerRadius(4)
                }
            }
            if let subtitle = viewModel.primarySubtitleLine() {
                Text(subtitle).font(.headline).foregroundColor(.secondary)
            }
        }
    }

    @ViewBuilder private var ratingRow: some View {
        if let rating = program.officialRating, !rating.isEmpty {
            HStack {
                Text(rating)
                    .font(.subheadline)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Color.gray.opacity(0.2))
                    .clipShape(Capsule())
                Spacer()
            }
        }
    }

    @ViewBuilder private var channelRow: some View {
        if let channelId = viewModel.effectiveChannelId {
            HStack(alignment: .center, spacing: 12) {
                ChannelImageView(baseUrl: appState.serverURL, apiKey: appState.apiKey, channelId: channelId)
                    .frame(width: 67, height: 67)
                VStack(alignment: .leading, spacing: 4) {
                    if !viewModel.timeLine.isEmpty {
                        Text(viewModel.timeLine).font(.subheadline).foregroundColor(.secondary)
                    }
                    Text(viewModel.channelName).font(.subheadline)
                    if viewModel.isLive { LiveBadge() }
                }
                Spacer()
            }
        } else if !viewModel.timeLine.isEmpty || !viewModel.channelName.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                if !viewModel.timeLine.isEmpty {
                    Text(viewModel.timeLine).font(.subheadline).foregroundColor(.secondary)
                }
                Text(viewModel.channelName).font(.subheadline)
                if viewModel.isLive { LiveBadge() }
            }
        }
    }
    
    @ViewBuilder private var actionButtons: some View {
        let isLikelySeries = program.isSeries || (program.seriesId != nil && !program.seriesId!.isEmpty) || (program.seriesName != nil && !program.seriesName!.isEmpty)

        HStack(spacing: 16) {
            if viewModel.isLive, viewModel.effectiveChannelId != nil {
                Button {
                    Task { await viewModel.startPlayback() }
                } label: {
                    Label("Play", systemImage: "play.fill")
                        .font(.headline)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .foregroundColor(.white)
                        .background(Color.blue.opacity(0.4))
                        .glassEffect(in: Capsule())
                }
            }
            
            // Only allow scheduling notifications if it's in the future OR it's a series (where we can schedule future eps)
            if !viewModel.isLive || isLikelySeries {
                Button {
                    showNotificationSheet = true
                } label: {
                    if viewModel.isLive {
                        Image(systemName: recordingViewModel.hasNotificationScheduled ? "bell.fill" : "bell")
                            .font(.headline)
                            .padding(12)
                            .foregroundColor(recordingViewModel.hasNotificationScheduled ? .yellow : .primary)
                            .background(recordingViewModel.hasNotificationScheduled ? Color.yellow.opacity(0.3) : Color.gray.opacity(0.2))
                            .glassEffect(in: Circle())
                    } else {
                        Label(
                            recordingViewModel.hasNotificationScheduled ? "Reminder Set" : "Notify Me",
                            systemImage: recordingViewModel.hasNotificationScheduled ? "bell.fill" : "bell"
                        )
                        .font(.headline)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .foregroundColor(recordingViewModel.hasNotificationScheduled ? .yellow : .primary)
                        .background(recordingViewModel.hasNotificationScheduled ? Color.yellow.opacity(0.3) : Color.gray.opacity(0.2))
                        .glassEffect(in: Capsule())
                    }
                }
            }
            
            Button {
                showRecordingSheet = true
            } label: {
                Image(systemName: recordingViewModel.isRecordingScheduled ? "record.circle.fill" : "record.circle")
                    .font(.headline)
                    .padding(12)
                    .foregroundColor(recordingViewModel.isRecordingScheduled ? .red : .primary)
                    .background(recordingViewModel.isRecordingScheduled ? Color.red.opacity(0.4) : Color.gray.opacity(0.2))
                    .glassEffect(in: Circle())
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder private var metaChips: some View {
        let chips = viewModel.chips()
        if !chips.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(chips, id: \.self) { chip in
                        Text(chip)
                            .font(.caption)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(Color.accentColor.opacity(0.15))
                            .foregroundColor(.accentColor)
                            .clipShape(Capsule())
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    @ViewBuilder private var overviewText: some View {
        if let ov = program.overview, !ov.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Text(ov).font(.body).foregroundColor(.primary).fixedSize(horizontal: false, vertical: true)
        } else {
            Text("No description available.").font(.body).foregroundColor(.secondary)
        }
    }

    @ViewBuilder private var relatedSection: some View {
        if viewModel.isLoadingRelated || !viewModel.relatedPrograms.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("Related").font(.title2).bold()
                if viewModel.isLoadingRelated {
                    RelatedSkeletonView()
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: 12) {
                            ForEach(viewModel.relatedPrograms) { rel in
                                NavigationLink(
                                    destination: ProgramView(program: rel, appState: appState)
                                        .environmentObject(appState)
                                ) {
                                    RelatedProgramCard(program: rel, loadImages: viewModel.loadRelatedImages)
                                        .environmentObject(appState)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.horizontal, 2)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private var upcomingSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Upcoming").font(.title2).bold()
            if viewModel.isLoadingUpcoming {
                UpcomingSkeletonView()
            } else if viewModel.combinedUpcoming.isEmpty {
                Text("No upcoming airings found in the next 7-14 days.")
                    .font(.subheadline).foregroundColor(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(viewModel.combinedUpcoming, id: \.airingKey) { up in
                        NavigationLink(
                            destination: ProgramView(program: up, appState: appState)
                                .environmentObject(appState)
                        ) {
                            HStack {
                                UpcomingProgramRow(
                                    program: up,
                                    referenceName: program.name,
                                    referenceStart: program.startDate
                                )
                                .environmentObject(appState)
                                
                                Spacer()
                                
                                UpcomingRecordingIcon(program: up, appState: appState)
                            }
                        }
                        .buttonStyle(.plain)
                        Divider().padding(.leading, 8)
                    }
                }
                .background(RoundedRectangle(cornerRadius: 12).fill(Color(UIColor.secondarySystemBackground)))
            }
        }
    }
}
