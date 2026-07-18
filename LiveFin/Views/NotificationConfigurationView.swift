//
//  NotificationConfigurationView.swift
//  LiveFin
//
//  Created by KPGamingz on 7/6/26.
//

import SwiftUI

struct NotificationConfigurationView: View {
    @ObservedObject var viewModel: ProgramRecordingViewModel
    @Environment(\.dismiss) private var dismiss

    // Compute if the current program is already live
    var isLive: Bool {
        guard let start = viewModel.program.startDate else { return false }
        let runTime = viewModel.program.runTimeSeconds > 0 ? viewModel.program.runTimeSeconds : 3600 // 1 hour fallback
        let end = viewModel.program.endDate ?? start.addingTimeInterval(runTime)
        return start <= Date() && Date() <= end
    }

    var body: some View {
        NavigationStack {
            Form {
                let isLikelySeries = viewModel.program.isSeries || (viewModel.program.seriesId != nil && !viewModel.program.seriesId!.isEmpty) || (viewModel.program.seriesName != nil && !viewModel.program.seriesName!.isEmpty)
                
                // Condition: If NOT live, allow notification of the current program only
                if !isLive {
                    Section(header: Text("Current Program Reminder"), footer: Text("We will send a push notification to your device so you don't miss this program.")) {
                        Picker("Notify Me", selection: Binding(
                            get: { viewModel.notificationConfig.notificationBufferSeconds / 60 },
                            set: { viewModel.notificationConfig.notificationBufferSeconds = $0 * 60 }
                        )) {
                            Text("At start time").tag(0)
                            Text("5 minutes before").tag(5)
                            Text("10 minutes before").tag(10)
                            Text("15 minutes before").tag(15)
                            Text("30 minutes before").tag(30)
                            Text("1 hour before").tag(60)
                            Text("2 hours before").tag(120)
                            Text("1 day before").tag(1440)
                        }
                        #if os(tvOS)
                        .pickerStyle(.navigationLink)
                        #endif
                    }
                } else if isLikelySeries {
                    Section(footer: Text("This program is currently airing. Reminders will be scheduled for future episodes.")) {
                        EmptyView()
                    }
                }
                
                Section(header: Text("Future Airings"), footer: Text("Manage reminders for upcoming episodes.")) {
                    if isLikelySeries {
                        if isLive {
                            // Lock toggle to true since we are modifying a live program
                            HStack {
                                Text("Remind for all upcoming episodes")
                                Spacer()
                                Image(systemName: "checkmark")
                                    .foregroundColor(.accentColor)
                                    .fontWeight(.bold)
                            }
                            Toggle("Only notify for new episodes", isOn: $viewModel.notificationConfig.notifyNewEpisodesOnly)
                        } else {
                            Toggle("Remind for all upcoming episodes", isOn: $viewModel.notificationConfig.notifySeries)
                            if viewModel.notificationConfig.notifySeries {
                                Toggle("Only notify for new episodes", isOn: $viewModel.notificationConfig.notifyNewEpisodesOnly)
                            }
                        }
                    }
                    
                    Toggle("Repeat notifications periodically", isOn: $viewModel.notificationConfig.repeatNotification)
                }
                
                Section {
                    if viewModel.hasNotificationScheduled {
                        Button(role: .destructive) {
                            viewModel.cancelLocalNotification()
                            dismiss()
                        } label: {
                            HStack {
                                Spacer()
                                Text("Remove Reminder")
                                Spacer()
                            }
                        }
                    } else {
                        Button {
                            Task {
                                await viewModel.scheduleLocalNotification()
                                dismiss()
                            }
                        } label: {
                            HStack {
                                Spacer()
                                Text("Set Reminder")
                                Spacer()
                            }
                        }
                    }
                }
            }
            .navigationTitle("Program Reminder")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .onAppear {
                let isLikelySeries = viewModel.program.isSeries || (viewModel.program.seriesId != nil && !viewModel.program.seriesId!.isEmpty) || (viewModel.program.seriesName != nil && !viewModel.program.seriesName!.isEmpty)
                if isLive && isLikelySeries {
                    viewModel.notificationConfig.notifySeries = true
                }
            }
        }
    }
}
