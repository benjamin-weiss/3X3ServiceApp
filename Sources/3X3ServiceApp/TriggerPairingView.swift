import SwiftUI

struct TriggerPairingView: View {
    let store: DeviceStore
    @Binding var isPresented: Bool

    var body: some View {
        NavigationStack {
            List {
                content
            }
            .navigationTitle("Pair Trigger")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(dismissTitle) {
                        isPresented = false
                    }
                    .disabled(store.triggerPairingPhase.isBusy)
                }
            }
            .task {
                if store.triggerPairingPhase == .idle {
                    store.startTriggerPairingScan()
                }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch store.triggerPairingPhase {
        case .idle, .scanning:
            Section {
                if store.triggerPairingCandidates.isEmpty {
                    HStack {
                        Spacer()
                        ProgressView()
                            .controlSize(.large)
                        Spacer()
                    }
                    .padding(.vertical, 24)
                } else {
                    ForEach(store.triggerPairingCandidates) { device in
                        Button {
                            Task { await store.pairTrigger(device) }
                        } label: {
                            DiscoveredDeviceRow(
                                store: store,
                                device: device,
                                showsConnectionHint: false
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(!device.isReadyToConnect)
                    }
                }
            } header: {
                HStack {
                    Text("Nearby triggers")
                    Spacer()
                    if !store.triggerPairingCandidates.isEmpty {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
            } footer: {
                Text(pairingInstruction)
            }

        case let .connecting(name):
            progress(
                title: "Connecting to \(name)",
                detail: "Keeping the Actuator connected"
            )
        case let .readingIdentity(name):
            progress(
                title: "Reading \(name)",
                detail: "Authenticating and reading its pairing address"
            )
        case let .updatingGear(name):
            progress(
                title: "Pairing \(name)",
                detail: "Waiting for the Actuator to confirm the Trigger"
            )
        case let .completed(mac):
            Section {
                Label("Trigger paired", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                LabeledContent("Pairing address", value: mac)
            }
        case let .failed(message):
            Section {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Button("Scan again", systemImage: "arrow.clockwise") {
                    store.startTriggerPairingScan()
                }
            }
        }
    }

    private func progress(
        title: LocalizedStringKey,
        detail: LocalizedStringKey
    ) -> some View {
        Section {
            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.large)
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
        }
    }

    private var pairingInstruction: LocalizedStringKey {
        store.triggerPairingCandidates.contains { $0.isReadyToConnect }
            ? "Select a Trigger to pair."
            : "Hold function button for 10 seconds to connect"
    }

    private var dismissTitle: LocalizedStringKey {
        if case .completed = store.triggerPairingPhase {
            return "Done"
        }
        return "Cancel"
    }
}