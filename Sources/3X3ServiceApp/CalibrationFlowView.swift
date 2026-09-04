import SwiftUI

struct CalibrationFlowView: View {
    let store: DeviceStore
    @Binding var isPresented: Bool

    @State private var isStarting = false
    @State private var isComplete = false

    var body: some View {
        NavigationStack {
            Group {
                if isStarting || store.isCalibrating {
                    blockingView
                } else if isComplete {
                    completionView
                } else {
                    preparationView
                }
            }
            .navigationTitle("Auto-Calibration")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(dismissTitle) {
                        isPresented = false
                    }
                    .disabled(isStarting || store.isCalibrating)
                }
            }
        }
    }

    private var preparationView: some View {
        VStack(spacing: 32) {
            Spacer()

            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.orange)

            VStack(spacing: 12) {
                Text("Start Auto-Calibration?")
                    .font(.title2.bold())
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
                Text(
                    "Make sure the rear wheel is mounted and lifted clear of the ground. Do not load or turn the pedals. Keep hands, clothing, and tools away from the drivetrain."
                )
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            }

            VStack(spacing: 12) {
                Button {
                    isStarting = true
                    Task {
                        await store.calibrateGear()
                        isStarting = false
                        if store.calibrationMessage != nil {
                            isComplete = true
                        } else {
                            isPresented = false
                        }
                    }
                } label: {
                    HStack(alignment: .center, spacing: 8) {
                        Text("Start")
                            .multilineTextAlignment(.center)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
            }

            Spacer()

        }
        .padding(32)
        .background(Color(uiColor: .systemGroupedBackground))
    }

    private var completionView: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.green)

            VStack(spacing: 8) {
                Text("Auto-Calibration Finished")
                    .font(.title2.bold())
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
                Text(
                    store.calibrationMessage
                        ?? String(
                            localized: "Auto-calibration cycle finished. Verify every gear before riding."
                        )
                )
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            }

            Spacer()
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemGroupedBackground))
    }

    private var blockingView: some View {
        VStack(spacing: 24) {
            ProgressView()
                .controlSize(.large)
                .tint(Color(red: 0.83, green: 0.12, blue: 0.16))
                .scaleEffect(1.4)

            VStack(spacing: 8) {
                Text("Auto-Calibration in Progress")
                    .font(.title2.bold())
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
                Text("The Actuator is shifting through every gear. Please wait for the process to finish.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemGroupedBackground))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "Actuator auto-calibration in progress. Shifting through every gear."
        )
    }

    private var dismissTitle: LocalizedStringKey {
        isComplete ? "Done" : "Cancel"
    }
}