//
//  GuideView.swift
//  LiveFin
//

import SwiftUI
import Foundation
import Combine
import JellyfinAPI

#if canImport(UIKit)
import UIKit
#endif

struct GuideView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var vm = GuideViewModel.shared

    @State private var selectedDay: Date = guideStartOfDay(Date())
    @State private var currentTime: Date = Date()

    private let timelineTimer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    private var availableDaysSorted: [Date] {
        let cal = Calendar.current
        let today = guideStartOfDay(currentTime)
        return (0..<7).compactMap { cal.date(byAdding: .day, value: $0, to: today) }
    }

    private func computeBaseStart(for day: Date, relativeTo referenceDate: Date) -> Date {
        let startD = guideStartOfDay(day)
        guard Calendar.current.isDate(day, inSameDayAs: referenceDate) else { return startD }
        let cal = Calendar.current
        let comps = cal.dateComponents([.year, .month, .day, .hour, .minute], from: referenceDate)
        
        var newComps = DateComponents()
        newComps.year = comps.year
        newComps.month = comps.month
        newComps.day = comps.day
        newComps.hour = comps.hour
        newComps.minute = (comps.minute ?? 0) >= 30 ? 30 : 0
        newComps.second = 0
        newComps.nanosecond = 0
        
        let aligned = cal.date(from: newComps) ?? referenceDate
        return max(startD, aligned)
    }

    private var baseStart: Date { computeBaseStart(for: selectedDay, relativeTo: currentTime) }
    private var visibleMinutes: Double { guideEndOfDay(selectedDay).timeIntervalSince(baseStart) / 60.0 }
    private var visibleWidth: CGFloat { CGFloat(visibleMinutes) * guidePxPerMinute }
    private var totalGridHeight: CGFloat { CGFloat(vm.sortedChannels.count) * guideRowHeight }

    var body: some View {
        NavigationStack {
            Group {
                if vm.isLoading && vm.channels.isEmpty {
                    ProgressView("Loading Guide…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let msg = vm.errorMessage, vm.channels.isEmpty {
                    errorStateView(message: msg)
                } else if vm.channels.isEmpty {
                    emptyStateView
                } else {
                    guideContentView
                }
            }
            .navigationTitle("Guide")
            .task(id: appState.accessToken) {
                guard !appState.accessToken.isEmpty else { return }
                await vm.start(appState: appState, baseStart: baseStart, visibleWidth: visibleWidth)
            }
            .onReceive(timelineTimer) { newTime in
                let previousBase = baseStart
                currentTime = newTime
                let newBase = computeBaseStart(for: selectedDay, relativeTo: newTime)
                if previousBase != newBase {
                    Task {
                        await vm.scheduleCollapsePrograms(for: selectedDay, baseStart: newBase, visibleWidth: visibleWidth)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func errorStateView(message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundColor(.orange)
            
            VStack(spacing: 8) {
                Text("Unable to Load Guide")
                    .font(.title3.bold())
                Text(message)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            
            Button {
                Task {
                    await vm.start(appState: appState, baseStart: baseStart, visibleWidth: visibleWidth)
                    await vm.switchDay(selectedDay, appState: appState, visibleWidth: visibleWidth, baseStart: baseStart)
                }
            } label: {
                Text("Try Again")
                    .fontWeight(.semibold)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .background(Color.accentColor)
                    .foregroundColor(.white)
                    .clipShape(Capsule())
            }
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyStateView: some View {
        VStack(spacing: 12) {
            Text("No channels available").foregroundColor(.secondary)
            Button("Reload") {
                Task { await vm.start(appState: appState, baseStart: baseStart, visibleWidth: visibleWidth) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var guideContentView: some View {
        VStack(spacing: 0) {
            daySelectorHeader
            Divider()

            // 4-quadrant layout: Channel column stays locked on the left horizontally
            GuideSyncGridView(
                channelWidth: guideChannelLabelWidth,
                headerHeight: guideHeaderHeight,
                gridWidth: visibleWidth,
                totalHeight: totalGridHeight,
                timelineContent: {
                    hourTicksView
                        .frame(maxHeight: .infinity, alignment: .topLeading)
                },
                channelContent: {
                    VStack(spacing: 0) {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(vm.sortedChannels.enumerated()), id: \.element.id) { index, ch in
                                NavigationLink(
                                    destination: ChannelDetailView(channel: ch)
                                        .environmentObject(appState)
                                ) {
                                    GuideChannelHeader(channel: ch)
                                        .environmentObject(appState)
                                        .frame(width: guideChannelLabelWidth, height: guideRowHeight, alignment: .leading)
                                }
                                .buttonStyle(.plain)
                                .background(Color(.systemBackground))
                                .overlay(Rectangle().fill(Color.secondary.opacity(0.12)).frame(height: 1), alignment: .bottom)
                                .onAppear {
                                    vm.loadNextChunkIfNeeded(
                                        channelIndex: index,
                                        day: selectedDay,
                                        appState: appState,
                                        baseStart: baseStart,
                                        visibleWidth: visibleWidth
                                    )
                                }
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(width: guideChannelLabelWidth, alignment: .top)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .background(Color(.systemBackground))
                },
                gridContent: {
                    VStack(spacing: 0) {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(vm.sortedChannels.enumerated()), id: \.element.id) { index, ch in
                                channelProgramsRow(for: ch)
                                    .onAppear {
                                        vm.loadNextChunkIfNeeded(
                                            channelIndex: index,
                                            day: selectedDay,
                                            appState: appState,
                                            baseStart: baseStart,
                                            visibleWidth: visibleWidth
                                        )
                                    }
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(width: visibleWidth, alignment: .topLeading)
                    .frame(maxHeight: .infinity, alignment: .topLeading)
                }
            )
        }
    }

    private var daySelectorHeader: some View {
        HStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(availableDaysSorted, id: \.self) { day in
                            let isSel = Calendar.current.isDate(day, inSameDayAs: selectedDay)
                            Button {
                                selectedDay = day
                            } label: {
                                dayCapsuleLabel(day: day, isSelected: isSel)
                            }
                            .buttonStyle(.plain)
                            .id(guideStartOfDay(day))
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                }
                .onChange(of: selectedDay) { _, newDay in
                    withAnimation(.easeInOut) {
                        proxy.scrollTo(guideStartOfDay(newDay), anchor: .center)
                    }
                    Task {
                        let newBaseStart = computeBaseStart(for: newDay, relativeTo: currentTime)
                        let vWidth = CGFloat(guideEndOfDay(newDay).timeIntervalSince(newBaseStart) / 60.0) * guidePxPerMinute
                        await vm.switchDay(newDay, appState: appState, visibleWidth: vWidth, baseStart: newBaseStart)
                    }
                }
            }
            
            Button {
                Task {
                    let bStart = computeBaseStart(for: selectedDay, relativeTo: currentTime)
                    let vWidth = CGFloat(guideEndOfDay(selectedDay).timeIntervalSince(bStart) / 60.0) * guidePxPerMinute
                    await vm.manualRefresh(appState: appState, currentDay: selectedDay, baseStart: bStart, visibleWidth: vWidth)
                }
            } label: {
                refreshButtonLabel
            }
            .buttonStyle(.plain)
            .padding(.trailing, 8)
        }
    }

    @ViewBuilder
    private var refreshButtonLabel: some View {
        let icon = Group {
            if vm.isRefreshing {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 16, weight: .medium))
            }
        }
        .frame(width: 36, height: 36)
        .contentShape(Rectangle())

        if #available(iOS 26.0, *) {
            icon
                .clipShape(Circle())
                .glassEffect(.regular.interactive(), in: .circle)
        } else {
            icon
                .background(Color(.secondarySystemBackground))
                .clipShape(Circle())
        }
    }

    @ViewBuilder
    private func dayCapsuleLabel(day: Date, isSelected: Bool) -> some View {
        let label = guideFormatDayLabel(day)
        let bg = isSelected ? Color.accentColor : Color(.secondarySystemBackground)
        let fg = isSelected ? Color.white : Color.primary

        if #available(iOS 26.0, *) {
            Text(label)
                .font(.footnote)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(bg)
                .foregroundColor(fg)
                .clipShape(Capsule())
                .glassEffect()
        } else {
            Text(label)
                .font(.footnote)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(bg)
                .foregroundColor(fg)
                .clipShape(Capsule())
        }
    }

    private func channelProgramsRow(for ch: LiveTvChannelDto) -> some View {
        let blocks = vm.renderBlocks[selectedDay]?[ch.id] ?? []
        
        return ZStack(alignment: .topLeading) {
            RowGridBackground(visibleWidth: visibleWidth)
            
            ForEach(blocks) { b in
                ProgramBlockView(b: b, channel: ch, appState: appState)
            }
            
            NowLineOverlay(baseStart: baseStart, selectedDay: selectedDay, rowHeight: guideRowHeight, currentTime: currentTime)
        }
        .frame(width: visibleWidth, height: guideRowHeight)
        .overlay(Rectangle().fill(Color.secondary.opacity(0.1)).frame(height: 1), alignment: .bottom)
        .clipped()
    }

    private var hourTicksView: some View {
        let end = guideEndOfDay(selectedDay)
        let boundaries = calculatedHourBoundaries(from: baseStart, to: end)
        
        return ZStack(alignment: .topLeading) {
            Color.clear.frame(width: visibleWidth, height: guideHeaderHeight)
            
            ForEach(boundaries, id: \.self) { ts in
                let mins = ts.timeIntervalSince(baseStart) / 60.0
                let x = CGFloat(mins) * guidePxPerMinute
                
                Rectangle()
                    .fill(Color.secondary.opacity(0.4))
                    .frame(width: 1, height: guideHeaderHeight)
                    .offset(x: x)
                
                Text(guideHourTickFormatter.string(from: ts))
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .offset(x: x + 6, y: 6)
            }
            
            NowLineOverlay(baseStart: baseStart, selectedDay: selectedDay, rowHeight: guideHeaderHeight, currentTime: currentTime)
        }
        .frame(width: visibleWidth, height: guideHeaderHeight, alignment: .topLeading)
    }

    private func calculatedHourBoundaries(from: Date, to: Date) -> [Date] {
        var result: [Date] = []
        var cur = from
        let cal = Calendar.current
        while cur < to {
            result.append(cur)
            cur = cal.date(byAdding: .minute, value: 30, to: cur) ?? to
        }
        return result
    }
}

struct GuideSyncGridView<TimelineContent: View, ChannelContent: View, GridContent: View>: UIViewRepresentable {
    let channelWidth: CGFloat
    let headerHeight: CGFloat
    let gridWidth: CGFloat
    let totalHeight: CGFloat
    @ViewBuilder let timelineContent: () -> TimelineContent
    @ViewBuilder let channelContent: () -> ChannelContent
    @ViewBuilder let gridContent: () -> GridContent

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> GuideGridContainerView {
        let view = GuideGridContainerView(
            channelWidth: channelWidth,
            headerHeight: headerHeight,
            gridWidth: gridWidth,
            totalHeight: totalHeight,
            timelineContent: timelineContent(),
            channelContent: channelContent(),
            gridContent: gridContent(),
            coordinator: context.coordinator
        )
        return view
    }

    func updateUIView(_ uiView: GuideGridContainerView, context: Context) {
        uiView.update(
            channelWidth: channelWidth,
            headerHeight: headerHeight,
            gridWidth: gridWidth,
            totalHeight: totalHeight,
            timelineContent: timelineContent(),
            channelContent: channelContent(),
            gridContent: gridContent()
        )
    }

    class Coordinator: NSObject, UIScrollViewDelegate {
        weak var timelineScrollView: UIScrollView?
        weak var channelScrollView: UIScrollView?
        weak var gridScrollView: UIScrollView?

        private var isSyncing = false

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard !isSyncing else { return }
            isSyncing = true
            defer { isSyncing = false }

            if scrollView === gridScrollView {
                channelScrollView?.contentOffset.y = scrollView.contentOffset.y
                timelineScrollView?.contentOffset.x = scrollView.contentOffset.x
            } else if scrollView === channelScrollView {
                gridScrollView?.contentOffset.y = scrollView.contentOffset.y
            } else if scrollView === timelineScrollView {
                gridScrollView?.contentOffset.x = scrollView.contentOffset.x
            }
        }
    }

    class GuideGridContainerView: UIView {
        private var channelWidth: CGFloat
        private var headerHeight: CGFloat
        private var gridWidth: CGFloat
        private var totalHeight: CGFloat

        let cornerView = UIView()
        let timelineScrollView = UIScrollView()
        let channelScrollView = UIScrollView()
        let gridScrollView = UIScrollView()

        let cornerLabel = UILabel()
        var timelineHost: UIHostingController<TimelineContent>
        var channelHost: UIHostingController<ChannelContent>
        var gridHost: UIHostingController<GridContent>

        private let vSeparator = UIView()
        private let hSeparator = UIView()

        init(
            channelWidth: CGFloat,
            headerHeight: CGFloat,
            gridWidth: CGFloat,
            totalHeight: CGFloat,
            timelineContent: TimelineContent,
            channelContent: ChannelContent,
            gridContent: GridContent,
            coordinator: Coordinator
        ) {
            self.channelWidth = channelWidth
            self.headerHeight = headerHeight
            self.gridWidth = gridWidth
            self.totalHeight = totalHeight

            self.timelineHost = UIHostingController(rootView: timelineContent)
            self.channelHost = UIHostingController(rootView: channelContent)
            self.gridHost = UIHostingController(rootView: gridContent)

            super.init(frame: .zero)

            setupCornerView()
            setupScrollViews(coordinator: coordinator)
            setupSeparators()
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        private func setupCornerView() {
            cornerView.backgroundColor = .systemBackground
            cornerLabel.text = "Channel"
            cornerLabel.font = .boldSystemFont(ofSize: 11)
            cornerLabel.textColor = .secondaryLabel
            cornerLabel.textAlignment = .center
            cornerLabel.translatesAutoresizingMaskIntoConstraints = false
            cornerView.addSubview(cornerLabel)

            NSLayoutConstraint.activate([
                cornerLabel.centerXAnchor.constraint(equalTo: cornerView.centerXAnchor),
                cornerLabel.centerYAnchor.constraint(equalTo: cornerView.centerYAnchor)
            ])
            addSubview(cornerView)
        }

        private func setupScrollViews(coordinator: Coordinator) {
            // 1. Timeline ScrollView: Horizontal only, pinned to top
            timelineScrollView.delegate = coordinator
            timelineScrollView.showsHorizontalScrollIndicator = false
            timelineScrollView.showsVerticalScrollIndicator = false
            timelineScrollView.alwaysBounceVertical = false
            timelineScrollView.alwaysBounceHorizontal = true
            timelineScrollView.bounces = true
            timelineScrollView.backgroundColor = .systemBackground
            timelineScrollView.contentInsetAdjustmentBehavior = .never
            timelineScrollView.contentInset = .zero

            timelineHost.view.backgroundColor = .clear
            timelineHost.view.insetsLayoutMarginsFromSafeArea = false
            if #available(iOS 16.4, *) {
                timelineHost.safeAreaRegions = []
            }
            timelineScrollView.addSubview(timelineHost.view)
            addSubview(timelineScrollView)
            coordinator.timelineScrollView = timelineScrollView

            // 2. Channel ScrollView: Vertical only, pinned at x=0
            channelScrollView.delegate = coordinator
            channelScrollView.showsHorizontalScrollIndicator = false
            channelScrollView.showsVerticalScrollIndicator = false
            channelScrollView.alwaysBounceVertical = true
            channelScrollView.alwaysBounceHorizontal = false
            channelScrollView.bounces = true
            channelScrollView.backgroundColor = .systemBackground
            channelScrollView.contentInsetAdjustmentBehavior = .never
            channelScrollView.contentInset = .zero

            channelHost.view.backgroundColor = .clear
            channelHost.view.insetsLayoutMarginsFromSafeArea = false
            if #available(iOS 16.4, *) {
                channelHost.safeAreaRegions = []
            }
            channelScrollView.addSubview(channelHost.view)
            addSubview(channelScrollView)
            coordinator.channelScrollView = channelScrollView

            // 3. Grid ScrollView: Full 2D scrolling
            gridScrollView.delegate = coordinator
            gridScrollView.showsHorizontalScrollIndicator = true
            gridScrollView.showsVerticalScrollIndicator = true
            gridScrollView.alwaysBounceVertical = true
            gridScrollView.alwaysBounceHorizontal = true
            gridScrollView.bounces = true
            gridScrollView.backgroundColor = .clear
            gridScrollView.contentInsetAdjustmentBehavior = .never
            gridScrollView.contentInset = .zero

            gridHost.view.backgroundColor = .clear
            gridHost.view.insetsLayoutMarginsFromSafeArea = false
            if #available(iOS 16.4, *) {
                gridHost.safeAreaRegions = []
            }
            gridScrollView.addSubview(gridHost.view)
            addSubview(gridScrollView)
            coordinator.gridScrollView = gridScrollView
        }

        private func setupSeparators() {
            vSeparator.backgroundColor = UIColor.separator.withAlphaComponent(0.2)
            addSubview(vSeparator)

            hSeparator.backgroundColor = UIColor.separator.withAlphaComponent(0.2)
            addSubview(hSeparator)
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            attachHostingControllers()
        }

        private func attachHostingControllers() {
            guard let parentVC = findViewController() else { return }
            if timelineHost.parent == nil {
                parentVC.addChild(timelineHost)
                timelineHost.didMove(toParent: parentVC)
            }
            if channelHost.parent == nil {
                parentVC.addChild(channelHost)
                channelHost.didMove(toParent: parentVC)
            }
            if gridHost.parent == nil {
                parentVC.addChild(gridHost)
                gridHost.didMove(toParent: parentVC)
            }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            let w = bounds.width
            let h = bounds.height
            guard w > 0, h > 0 else { return }

            let gridViewportW = max(0, w - channelWidth)
            let gridViewportH = max(0, h - headerHeight)

            // Quad 1: Top Left Corner (Fixed)
            cornerView.frame = CGRect(x: 0, y: 0, width: channelWidth, height: headerHeight)

            // Quad 2: Top Right Timeline (Horizontal scroll only)
            timelineScrollView.frame = CGRect(x: channelWidth, y: 0, width: gridViewportW, height: headerHeight)
            timelineHost.view.frame = CGRect(x: 0, y: 0, width: gridWidth, height: headerHeight)
            timelineScrollView.contentSize = CGSize(width: gridWidth, height: headerHeight)

            // Quad 3: Bottom Left Channels (Vertical scroll only - pinned to left edge)
            channelScrollView.frame = CGRect(x: 0, y: headerHeight, width: channelWidth, height: gridViewportH)
            channelHost.view.frame = CGRect(x: 0, y: 0, width: channelWidth, height: totalHeight)
            channelScrollView.contentSize = CGSize(width: channelWidth, height: totalHeight)

            // Quad 4: Bottom Right Grid (2D scroll)
            gridScrollView.frame = CGRect(x: channelWidth, y: headerHeight, width: gridViewportW, height: gridViewportH)
            gridHost.view.frame = CGRect(x: 0, y: 0, width: gridWidth, height: totalHeight)
            gridScrollView.contentSize = CGSize(width: gridWidth, height: totalHeight)

            // Separators
            vSeparator.frame = CGRect(x: channelWidth, y: 0, width: 1, height: h)
            hSeparator.frame = CGRect(x: 0, y: headerHeight, width: w, height: 1)
        }

        func update(
            channelWidth: CGFloat,
            headerHeight: CGFloat,
            gridWidth: CGFloat,
            totalHeight: CGFloat,
            timelineContent: TimelineContent,
            channelContent: ChannelContent,
            gridContent: GridContent
        ) {
            self.channelWidth = channelWidth
            self.headerHeight = headerHeight
            self.gridWidth = gridWidth
            self.totalHeight = totalHeight

            timelineHost.rootView = timelineContent
            channelHost.rootView = channelContent
            gridHost.rootView = gridContent

            setNeedsLayout()
        }
    }
}

extension UIView {
    func findViewController() -> UIViewController? {
        var responder: UIResponder? = self
        while let next = responder?.next {
            if let vc = next as? UIViewController {
                return vc
            }
            responder = next
        }
        return nil
    }
}
