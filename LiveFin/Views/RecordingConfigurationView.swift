//
//  RecordingConfigurationView.swift
//  LiveFin
//
//  Created by KPGamingz on 7/6/26.
//

import SwiftUI

struct RecordingConfigurationView: View {
    @ObservedObject var viewModel: ProgramRecordingViewModel
    @Environment(\.dismiss) private var dismiss
    
    // Extracted bindings to prevent Swift compiler timeout errors
    private var prePaddingBinding: Binding<Int> {
        Binding<Int>(
            get: { viewModel.configuration.prePaddingSeconds / 60 },
            set: { viewModel.configuration.prePaddingSeconds = $0 * 60 }
        )
    }
    
    private var postPaddingBinding: Binding<Int> {
        Binding<Int>(
            get: { viewModel.configuration.postPaddingSeconds / 60 },
            set: { viewModel.configuration.postPaddingSeconds = $0 * 60 }
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                let isLikelySeries = viewModel.program.isSeries || (viewModel.program.seriesId != nil && !viewModel.program.seriesId!.isEmpty) || (viewModel.program.seriesName != nil && !viewModel.program.seriesName!.isEmpty)
                
                if isLikelySeries {
                    Section(header: Text("Recording Type"), footer: Text("Series timers automatically schedule future airings of this show.")) {
                        Picker("Type", selection: $viewModel.configuration.isSeriesTimer) {
                            Text("Single Program").tag(false)
                            Text("Multiple Episodes").tag(true)
                        }
                        .pickerStyle(.segmented)
                        
                        if viewModel.configuration.isSeriesTimer {
                            Toggle("Record New Episodes Only", isOn: $viewModel.configuration.recordNewOnly)
                            Toggle("Record at Any Time", isOn: $viewModel.configuration.recordAnyTime)
                            Toggle("Record on Any Channel", isOn: $viewModel.configuration.recordAnyChannel)
                        }
                    }
                }
                
                Section(header: Text("Padding")) {
                    Stepper("Start Early: \(prePaddingBinding.wrappedValue) min",
                            value: prePaddingBinding,
                            in: 0...30)
                    
                    Stepper("End Late: \(postPaddingBinding.wrappedValue) min",
                            value: postPaddingBinding,
                            in: 0...60)
                }
                
                Section(header: Text("Recording Options")) {
                    // Corrected to use .notificationConfig instead of .configuration
                    Toggle("Notify when recording finishes", isOn: $viewModel.notificationConfig.notifyOnFinish)
                }
                
                if let errorMessage = viewModel.errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundColor(.red)
                            .font(.caption)
                    }
                }
                
                Section {
                    if viewModel.isRecordingScheduled {
                        Button(role: .destructive) {
                            Task {
                                await viewModel.cancelRecording()
                                dismiss()
                            }
                        } label: {
                            HStack {
                                Spacer()
                                if viewModel.isScheduling {
                                    ProgressView()
                                } else {
                                    Text("Cancel Recording")
                                }
                                Spacer()
                            }
                        }
                    } else {
                        Button {
                            Task {
                                await viewModel.scheduleRecording()
                                dismiss()
                            }
                        } label: {
                            HStack {
                                Spacer()
                                if viewModel.isScheduling {
                                    ProgressView()
                                } else {
                                    Text("Schedule Recording")
                                }
                                Spacer()
                            }
                        }
                    }
                }
            }
            .navigationTitle("Recording Options")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }
}
