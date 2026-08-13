import SwiftUI
import SwiftData

/// Focus session setup: choose task, duration, and optional warm-up.
/// Presented from TaskEventView when user taps "Start a focus session" (tasks only).
struct FocusSessionSetupView: View {
    @StateObject private var viewModel: FocusSessionSetupViewModel
    @Environment(\.dismiss) private var dismiss

    init(task: TaskEvent, onStart: @escaping (FocusSession) -> Void) {
        _viewModel = StateObject(wrappedValue: FocusSessionSetupViewModel(task: task, onStart: onStart))
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color(uiColor: .systemGroupedBackground)
                    .ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 24) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Task to focus on")
                                .font(.system(size: 13))
                                .foregroundColor(.secondary)
                                .padding(.horizontal, 16)

                            Button {
                                viewModel.showTaskPicker = true
                            } label: {
                                HStack {
                                    Text(viewModel.task.title)
                                        .font(.system(size: 17))
                                        .foregroundColor(DesignTokens.Color.labelPrimary)
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundColor(DesignTokens.Color.labelSecondary)
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 16)
                                .background(Color(uiColor: .secondarySystemGroupedBackground))
                                .cornerRadius(12)
                            }
                            .padding(.horizontal, 16)
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Duration")
                                .font(.system(size: 13))
                                .foregroundColor(DesignTokens.Color.labelSecondary)
                                .padding(.horizontal, 16)

                            DurationSegmentedPicker(
                                options: viewModel.durationOptions,
                                selection: $viewModel.selectedDurationOption,
                                onEditableTapped: {
                                    viewModel.showCustomDurationPicker = true
                                }
                            )
                            .padding(.horizontal, 16)
                        }

                        VStack(alignment: .leading, spacing: 12) {
                            Text("Allowed Apps")
                                .font(.system(size: 13))
                                .foregroundColor(DesignTokens.Color.labelSecondary)
                                .padding(.horizontal, 16)

                            VStack(spacing: 0) {
                                HStack {
                                    Text("Warm up")
                                        .font(.system(size: 17))
                                        .foregroundColor(DesignTokens.Color.labelPrimary)
                                    Spacer()
                                    Toggle("", isOn: $viewModel.warmUpEnabled)
                                        .labelsHidden()
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 12)

                                if viewModel.warmUpEnabled {
                                    Divider()
                                        .padding(.leading, 16)

                                    Picker("Warm up duration", selection: $viewModel.selectedWarmUpOption) {
                                        ForEach(FocusSessionSetupViewModel.WarmUpOption.allCases) { option in
                                            Text(option.rawValue).tag(option)
                                        }
                                    }
                                    .pickerStyle(.segmented)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 12)
                                }
                            }
                            .background(Color(uiColor: .secondarySystemGroupedBackground))
                            .cornerRadius(12)
                            .padding(.horizontal, 16)
                        }
                    }
                    .padding(.top, 24)
                    .padding(.bottom, 100)
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    viewModel.startFocusSession()
                    dismiss()
                } label: {
                    Text("Start")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(viewModel.isReadyToStart ? DesignTokens.Color.brandBlue : DesignTokens.Color.labelSecondary)
                        .cornerRadius(12)
                }
                .disabled(!viewModel.isReadyToStart)
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundColor(DesignTokens.Color.labelPrimary)
                    }
                }

                ToolbarItem(placement: .principal) {
                    Text("Focus")
                        .font(.system(size: 17, weight: .semibold))
                }
            }
        }
        .sheet(isPresented: $viewModel.showTaskPicker) {
            FocusSessionTaskPickerSheet(selectedTask: Binding(
                get: { viewModel.task },
                set: { viewModel.updateTask($0) }
            ))
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $viewModel.showCustomDurationPicker) {
            FocusSessionCustomDurationPickerView(
                duration: $viewModel.customDuration,
                isPresented: $viewModel.showCustomDurationPicker
            ) {
                viewModel.setCustomDuration(viewModel.customDuration)
            }
        }
        .sheet(isPresented: $viewModel.showCustomWarmUpPicker) {
            FocusSessionCustomDurationPickerView(
                duration: $viewModel.customWarmUpDuration,
                isPresented: $viewModel.showCustomWarmUpPicker
            ) {
                viewModel.setCustomWarmUpDuration(viewModel.customWarmUpDuration)
            }
        }
    }
}

// MARK: - Duration Segmented Picker

private struct DurationSegmentedPicker: View {
    let options: [FocusSessionSetupViewModel.DurationOption]
    @Binding var selection: FocusSessionSetupViewModel.DurationOption
    var onEditableTapped: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.element.id) { index, option in
                Button {
                    if option.isEditable {
                        selection = option
                        onEditableTapped()
                    } else {
                        selection = option
                    }
                } label: {
                    HStack(spacing: 3) {
                        Text(option.label)
                            .font(.system(size: 13, weight: selection == option ? .semibold : .regular))
                        if option.isEditable {
                            Image(systemName: "pencil")
                                .font(.system(size: 10, weight: .semibold))
                        }
                    }
                    .foregroundColor(selection == option ? .white : DesignTokens.Color.labelPrimary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(
                        selection == option
                            ? DesignTokens.Color.brandBlue
                            : Color.clear
                    )
                    .cornerRadius(7)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .cornerRadius(9)
    }
}

// MARK: - Custom Duration Picker (for focus session setup)

private struct FocusSessionCustomDurationPickerView: View {
    @Binding var duration: TimeInterval
    @Binding var isPresented: Bool
    var onSave: () -> Void

    @State private var hours: Int = 0
    @State private var minutes: Int = 25

    var body: some View {
        NavigationStack {
            VStack {
                HStack(spacing: 0) {
                    Picker("Hours", selection: $hours) {
                        ForEach(0..<5, id: \.self) { hour in
                            Text("\(hour)").tag(hour)
                        }
                    }
                    .pickerStyle(.wheel)
                    .frame(maxWidth: .infinity)

                    Text("hours")
                        .foregroundColor(DesignTokens.Color.labelSecondary)

                    Picker("Minutes", selection: $minutes) {
                        ForEach(0..<60, id: \.self) { minute in
                            Text("\(minute)").tag(minute)
                        }
                    }
                    .pickerStyle(.wheel)
                    .frame(maxWidth: .infinity)

                    Text("min")
                        .foregroundColor(.secondary)
                }
                .padding()
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        isPresented = false
                    }
                }

                ToolbarItem(placement: .principal) {
                    Text("Custom Duration")
                        .font(.system(size: 17, weight: .semibold))
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        duration = TimeInterval(hours * 3600 + minutes * 60)
                        onSave()
                        isPresented = false
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .onAppear {
            hours = Int(duration) / 3600
            minutes = (Int(duration) % 3600) / 60
        }
    }
}
