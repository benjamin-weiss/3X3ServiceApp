import SwiftUI
import ThreeByThreeKit

struct ContentView: View {
    @State private var store = DeviceStore()
    @State private var isDeviceFlowPresented = false
    @State private var isCalibrationFlowPresented = false
    @State private var isTriggerPairingPresented = false
    @State private var isRenameDevicePresented = false
    @State private var proposedDeviceName = ""

    var body: some View {
        NavigationStack {
            discoveryView
                .navigationDestination(isPresented: deviceFlowPresentation) {
                    deviceFlowView
                }
        }
        .toolbarBackground(.visible, for: .navigationBar)
        .sheet(isPresented: $isCalibrationFlowPresented) {
            CalibrationFlowView(
                store: store,
                isPresented: $isCalibrationFlowPresented
            )
                .interactiveDismissDisabled()
        }
        .alert(
            "Operation failed",
            isPresented: Binding(
                get: { store.errorMessage != nil },
                set: { if !$0 { store.errorMessage = nil } }
            )
        ) {
            if case .connectionFailed = store.phase {
                Button("Retry") {
                    Task { await store.retryConnection() }
                }
                Button("Abort", role: .cancel) {
                    isDeviceFlowPresented = false
                }
            } else {
                Button("OK", role: .cancel) {}
            }
        } message: {
            Text(store.errorMessage ?? String(localized: "Unknown error"))
        }
        .tint(Color(red: 0.83, green: 0.12, blue: 0.16))
        .task {
            if store.phase == .idle {
                store.startScanning()
            }
        }
    }

    @ViewBuilder
    private var deviceFlowView: some View {
        Group {
            switch store.phase {
            case let .connecting(name):
                connectingView(name: name)
            case let .connectionFailed(name):
                connectingView(name: name)
            case let .connected(name, kind):
                connectedView(name: name, kind: kind)
            case .idle, .scanning:
                EmptyView()
            }
        }
    }

    private var deviceFlowPresentation: Binding<Bool> {
        Binding(
            get: { isDeviceFlowPresented },
            set: { isPresented in
                isDeviceFlowPresented = isPresented
                guard !isPresented, store.phase != .idle else {
                    return
                }
                store.disconnect()
                store.startScanning()
            }
        )
    }

    private var discoveryView: some View {
        List {
            Section {
                if store.devices.isEmpty {
                    HStack {
                        Spacer()
                        ProgressView()
                            .controlSize(.large)
                            .tint(Color(red: 0.83, green: 0.12, blue: 0.16))
                            .scaleEffect(1.2)
                            .id(store.scanGeneration)
                        Spacer()
                    }
                    .padding(.vertical, 24)
                } else {
                    ForEach(store.devices) { device in
                        Button {
                            isDeviceFlowPresented = true
                            Task {
                                await store.connect(to: device)
                            }
                        } label: {
                            DiscoveredDeviceRow(store: store, device: device)
                        }
                        .buttonStyle(.plain)
                        .disabled(!device.isReadyToConnect)
                    }
                }
            } header: {
                HStack(spacing: 8) {
                    Text("Scanning for devices")
                    Spacer()
                    if store.phase == .scanning {
                        if !store.devices.isEmpty {
                            ProgressView()
                                .controlSize(.small)
                        }
                        #if DEBUG
                            Text(
                                String(
                                    localized: "\(store.nearbyAdvertisementCount) nearby"
                                )
                            )
                                .foregroundStyle(.secondary)
                        #endif
                    }
                }
            }

            if store.hasConnectionFailure {
                Section {
                    ShareLink(item: store.diagnosticReport) {
                        Label(
                            "Share connection diagnostics",
                            systemImage: "square.and.arrow.up"
                        )
                    }
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Image("OfficialLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 100, height: 26)
                    .foregroundStyle(.primary)
                    .accessibilityLabel("3X3 Service")
            }
        }
                .navigationBarTitleDisplayMode(.inline)
        .contentMargins(.top, 0, for: .scrollContent)
        .refreshable {
            store.startScanning()
        }
    }

    private func connectingView(name: String) -> some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
            Text("Connecting to \(name)")
                .font(.headline)
            Text("Discovering services and characteristics")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, 32)
        .navigationTitle("Connecting")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
    }

    private func connectedView(
        name: String,
        kind: DeviceKind
    ) -> some View {
        List {
            Section("Device") {
                HStack {
                    Text("Name")
                    Spacer()
                    Text(name)
                        .foregroundStyle(.secondary)
                    Button {
                        proposedDeviceName = store.connectedCustomName ?? name
                        isRenameDevicePresented = true
                    } label: {
                        Image(systemName: "pencil")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Rename device")
                }
                if store.connectedCustomName != nil,
                   let bluetoothName = store.connectedBluetoothName {
                    LabeledContent("Bluetooth name", value: bluetoothName)
                }
                LabeledContent(
                    "Type",
                    value: store.threeByThreeProductName ?? String(localized: "Unavailable")
                )
                if kind == .gear || store.modelNumber != nil {
                    LabeledContent(
                        "Model number",
                        value: store.modelNumber ?? String(localized: "Unavailable")
                    )
                }
                LabeledContent(
                    "Serial number",
                    value: store.serialNumber ?? String(localized: "Unavailable")
                )
                LabeledContent(
                    "Software version",
                    value: store.softwareVersion ?? String(localized: "Unavailable")
                )
                if kind == .trigger {
                    if let mac = store.rememberedTriggerMAC {
                        LabeledContent("Pairing address", value: mac.description)
                    }
                }
                if let version = store.availableFirmwareVersion {
                    Label {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Software version \(version) is available")
                                .font(.subheadline.weight(.semibold))
                            Text("Use the 3X3 Web App to perform the update.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "arrow.down.circle.fill")
                            .foregroundStyle(.blue)
                    }
                }
            }

            if kind == .trigger {
                Section("Battery") {
                    LabeledContent(
                        "Level",
                        value: store.batteryLevel.map { "\($0)%" }
                            ?? String(localized: "Unavailable")
                    )
                    if let voltage = store.batteryVoltageMillivolts {
                        LabeledContent(
                            "Voltage",
                            value: (Double(voltage) / 1_000).formatted(
                                .number.precision(.fractionLength(2))
                            ) + " V"
                        )
                    }
                    if store.batteryLowWarning == true {
                        Label("Low battery", systemImage: "battery.25percent")
                            .foregroundStyle(.red)
                    }
                }
            }

            if kind == .gear {
                Section("Shifting") {
                    ShiftRocker(
                        currentGear: store.currentGear,
                        isInteractionDisabled: store.isCalibrating
                            || store.isRotatingSecondGear
                            || store.isUpdatingAutoDownshift
                            || store.isUpdatingPairing,
                        shiftDown: {
                            Task { await store.shift(.down) }
                        },
                        shiftUp: {
                            Task { await store.shift(.up) }
                        }
                    )
                    .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                    .alignmentGuide(.listRowSeparatorTrailing) { dimensions in
                        dimensions.width
                    }

                    if let autoDownshiftEnabled = store.autoDownshiftEnabled {
                        Toggle(
                            "AutoDownShift",
                            isOn: Binding(
                                get: { autoDownshiftEnabled },
                                set: { enabled in
                                    Task { await store.setAutoDownshiftEnabled(enabled) }
                                }
                            )
                        )
                        .disabled(
                            store.isUpdatingAutoDownshift
                                || store.isCalibrating
                                || store.isRotatingSecondGear
                        )
                    }

                    if let autoDownshiftGear = store.autoDownshiftGear,
                       let autoDownshiftEnabled = store.autoDownshiftEnabled {
                        Picker(
                            "AutoDownShift gear",
                            selection: Binding(
                                get: { autoDownshiftGear },
                                set: { gear in
                                    Task { await store.setAutoDownshiftGear(gear) }
                                }
                            )
                        ) {
                            ForEach(1...9, id: \.self) { gear in
                                Text("\(gear)").tag(gear)
                            }
                        }
                        .pickerStyle(.menu)
                        .tint(.primary)
                        .disabled(
                            store.isUpdatingAutoDownshift
                                || store.isCalibrating
                                || store.isRotatingSecondGear
                                || !autoDownshiftEnabled
                        )
                    }

                    #if DEBUG
                        if let position = store.position {
                            LabeledContent(
                                "Position",
                                value: position.position.formatted(
                                    .number.precision(.fractionLength(2))
                                )
                            )
                        }
                    #endif
                }

                Section("Pairing") {
                    LabeledContent(
                        "Paired trigger",
                        value: pairedTriggerDescription
                    )

                    if store.pairedTriggerMAC?.isZero != false {
                        Button("Pair trigger…", systemImage: "link.badge.plus") {
                            store.beginTriggerPairing()
                            isTriggerPairingPresented = true
                        }
                        .disabled(!store.canPresentTriggerPairing)
                    }

                    if store.pairedTriggerMAC?.isZero == false {
                        Button("Unpair trigger", systemImage: "link.badge.minus") {
                            Task { await store.unpairTrigger() }
                        }
                        .foregroundStyle(Color(red: 0.83, green: 0.12, blue: 0.16))
                        .disabled(
                            store.isUpdatingPairing
                                || store.isCalibrating
                        )
                    }
                }

                Section {
                    Text(
                        String(
                            localized: "Auto-calibration shifts through every gear to synchronize the hub and Actuator for smooth shifting. It is essential after the hub and Actuator have been separated. The process takes \(store.calibrationDurationDescription)."
                        )
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                    if store.isCalibrating {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text("Auto-Calibrating")
                        }
                    } else {
                        Button("Start Auto-Calibration", systemImage: "arrow.triangle.2.circlepath") {
                            guard !store.isRotatingSecondGear, !store.isShifting else {
                                return
                            }
                            isCalibrationFlowPresented = true
                        }
                        .disabled(
                            !store.canCalibrate
                                || store.isUpdatingAutoDownshift
                                || store.isUpdatingPairing
                        )
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                    }

                    if let message = store.secondGearRotationMessage {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                    }
                } header: {
                    Text("Auto-Calibration")
                } footer: {
                    if !store.canCalibrate {
                        Text("Auto-calibration is unavailable for this Actuator model.")
                    }
                }

                SecondGearRotationSection(store: store)

            }

            #if DEBUG
                if kind != .trigger {
                    Section("GATT characteristics") {
                        ForEach(
                            Array(store.characteristics.enumerated()),
                            id: \.offset
                        ) { _, characteristic in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(characteristic.uuid)
                                    .font(.caption.monospaced())
                                Text("Service \(characteristic.serviceUUID)")
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                            .textSelection(.enabled)
                        }
                    }
                }
            #endif
        }
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .contentMargins(.top, 0, for: .scrollContent)
        .alert("Rename device", isPresented: $isRenameDevicePresented) {
            TextField("Custom name", text: $proposedDeviceName)
            Button("Save") {
                store.setConnectedDeviceName(proposedDeviceName)
            }
            .disabled(
                proposedDeviceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            )
            if store.connectedCustomName != nil {
                Button("Remove custom name", role: .destructive) {
                    store.setConnectedDeviceName(nil)
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(
            isPresented: $isTriggerPairingPresented,
            onDismiss: dismissTriggerPairing
        ) {
            TriggerPairingView(
                store: store,
                isPresented: $isTriggerPairingPresented
            )
                .interactiveDismissDisabled(store.triggerPairingPhase.isBusy)
        }
        .sensoryFeedback(.impact, trigger: store.completedShiftCount)
    }

    private func dismissTriggerPairing() {
        store.stopTriggerPairingScan()
        store.endTriggerPairing()
    }

    private var pairedTriggerDescription: String {
        guard let mac = store.pairedTriggerMAC, !mac.isZero else {
            return String(localized: "None")
        }
        if mac == store.rememberedTriggerMAC,
           let name = store.rememberedTriggerName {
            #if DEBUG
                return "\(name) (\(mac.description))"
            #else
            return name
            #endif
        }
        return mac.description
    }
}

private struct ShiftRocker: View {
    let currentGear: Int?
    let isInteractionDisabled: Bool
    let shiftDown: () -> Void
    let shiftUp: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            rockerButton(
                systemImage: "chevron.down",
                accessibilityLabel: "Shift down",
                action: shiftDown
            )
            .disabled(isInteractionDisabled || currentGear == 1)

            Divider()
                .frame(height: 44)

            VStack(spacing: 2) {
                Text("GEAR")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                Text(currentGearText)
                    .font(.title2.weight(.semibold))
                    .contentTransition(.numericText())
            }
            .frame(width: 82)
            .frame(maxHeight: .infinity)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Current gear")
            .accessibilityValue(currentGearText)

            Divider()
                .frame(height: 44)

            rockerButton(
                systemImage: "chevron.up",
                accessibilityLabel: "Shift up",
                action: shiftUp
            )
            .disabled(isInteractionDisabled || currentGear == 9)
        }
        .frame(height: 76)
        .background(Color.secondary.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.22), lineWidth: 1)
        }
    }

    private var currentGearText: String {
        currentGear.map { String($0) } ?? "–"
    }

    private func rockerButton(
        systemImage: String,
        accessibilityLabel: LocalizedStringKey,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.title3.weight(.semibold))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .buttonStyle(RockerButtonStyle())
        .accessibilityLabel(accessibilityLabel)
    }
}

struct RockerButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.primary)
            .background(
                Color.secondary.opacity(configuration.isPressed ? 0.18 : 0)
            )
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

#Preview {
    ContentView()
}