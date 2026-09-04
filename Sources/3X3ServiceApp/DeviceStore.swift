import Foundation
import Observation
import ThreeByThreeKit

@MainActor
@Observable
final class DeviceStore {
    enum Phase: Equatable {
        case idle
        case scanning
        case connecting(String)
        case connectionFailed(String)
        case connected(String, DeviceKind)
    }

    enum TriggerPairingPhase: Equatable {
        case idle
        case scanning
        case connecting(String)
        case readingIdentity(String)
        case updatingGear(String)
        case completed(String)
        case failed(String)

        var isBusy: Bool {
            switch self {
            case .connecting, .readingIdentity, .updatingGear:
                true
            case .idle, .scanning, .completed, .failed:
                false
            }
        }
    }

    var phase: Phase = .idle
    var devices: [DiscoveredDevice] = []
    var characteristics: [GATTCharacteristic] = []
    var position: GearPosition?
    var currentGear: Int?
    var modelNumber: String?
    var threeByThreeProductName: String?
    var serialNumber: String?
    var softwareVersion: String?
    var availableFirmwareVersion: String?
    var batteryLevel: Int?
    var batteryVoltageMillivolts: Int?
    var batteryLowWarning: Bool?
    var rememberedTriggerName: String?
    var rememberedTriggerMAC: BluetoothMACAddress?
    var pairedTriggerMAC: BluetoothMACAddress?
    var triggerPairingPhase: TriggerPairingPhase = .idle
    var triggerPairingCandidates: [DiscoveredDevice] = []
    var autoDownshiftEnabled: Bool?
    var autoDownshiftGear: Int?
    var isShifting = false
    var isCalibrating = false
    var isRotatingSecondGear = false
    var isUpdatingAutoDownshift = false
    var isUpdatingPairing = false
    private(set) var isTriggerPairingActive = false
    var completedShiftCount = 0
    var calibrationMessage: String?
    var secondGearRotationMessage: String?
    var errorMessage: String?
    private(set) var connectedBluetoothName: String?
    private(set) var connectedCustomName: String?
    private(set) var hasConnectionFailure = false
    private(set) var nearbyAdvertisementCount = 0
    private(set) var scanGeneration = 0
    private(set) var diagnosticEntries: [String] = []

    @ObservationIgnored private let discovery = BluetoothDiscovery()
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var scanObservationTask: Task<Void, Never>?
    @ObservationIgnored private var scanCleanupTask: Task<Void, Never>?
    @ObservationIgnored private var triggerPairingScanTask: Task<Void, Never>?
    @ObservationIgnored private var triggerPairingObservationTask: Task<Void, Never>?
    @ObservationIgnored private var triggerPairingCleanupTask: Task<Void, Never>?
    @ObservationIgnored private var positionPollingTask: Task<Void, Never>?
    @ObservationIgnored private var batteryPollingTask: Task<Void, Never>?
    @ObservationIgnored private var firmwareUpdateTask: Task<Void, Never>?
    @ObservationIgnored private var pendingShiftDirections: [GearShiftDirection] = []
    @ObservationIgnored private var testingDeviceTask: Task<Void, Never>?
    @ObservationIgnored private var testingTriggerPairingTask: Task<Void, Never>?
    @ObservationIgnored private var observedPeripheralIDs: Set<UUID> = []
    @ObservationIgnored private var advertisementSignatures: [UUID: String] = [:]
    @ObservationIgnored private var deviceLastSeen: [UUID: Date] = [:]
    @ObservationIgnored private var triggerPairingCandidateLastSeen: [UUID: Date] = [:]
    @ObservationIgnored private var session: PeripheralSession?
    @ObservationIgnored private var connectingDeviceID: UUID?
    @ObservationIgnored private var failedConnectionDevice: DiscoveredDevice?
    @ObservationIgnored private var connectedDeviceID: UUID?
    @ObservationIgnored private var customDeviceNames: [String: String]
    @ObservationIgnored private var triggerNamesByMAC: [String: String]
    @ObservationIgnored private var gearDevice: GearDevice?
    @ObservationIgnored private var triggerDevice: TriggerDevice?
    @ObservationIgnored private var gearCalibrationDevice: GearCalibrationDevice?
    @ObservationIgnored private var gearCalibrationVariant: GearCalibrationVariant?
    @ObservationIgnored private var secondGearRotationDevice: SecondGearRotationDevice?
    @ObservationIgnored private var gearPairingDevice: GearPairingDevice?
    @ObservationIgnored private var shiftSettingsDevice: GearShiftSettingsDevice?
    @ObservationIgnored private var isTestingSession = false

    init() {
        customDeviceNames = UserDefaults.standard.dictionary(
            forKey: Self.customDeviceNamesKey
        ) as? [String: String] ?? [:]
        triggerNamesByMAC = UserDefaults.standard.dictionary(
            forKey: Self.triggerNamesByMACKey
        ) as? [String: String] ?? [:]
        diagnosticEntries = Self.loadPersistedDiagnostics()
        appendDiagnostic("App session started")
    }

    private static let customDeviceNamesKey = "customDeviceNames"
    private static let triggerNamesByMACKey = "triggerNamesByMAC"
    private static let deviceExpirationInterval: TimeInterval = 5
    private static let awakeTriggerExpirationInterval: TimeInterval = 15
    private static let firmwareCatalogURL = URL(
        string: "https://service.3x3.bike/firmware/firmware.json"
    )!

    private struct TestingDeviceConfiguration {
        let id: UUID
        let name: String
        let kind: DeviceKind
        let product: ThreeByThreeProduct
        let modelNumber: String?
        let softwareVersion: String
    }

    private static let testingDevices: [TestingDeviceConfiguration] = [
        .init(id: testingID(0), name: String(localized: "E9.XP (Latest)"), kind: .gear, product: .actuatorETO, modelNumber: "148098-TESTING", softwareVersion: "1.8.6"),
        .init(id: testingID(1), name: String(localized: "E9.XP (Outdated)"), kind: .gear, product: .actuatorETO, modelNumber: "148098-TESTING", softwareVersion: "1.8.3"),
        .init(id: testingID(4), name: String(localized: "E.TR.ADJ (Latest)"), kind: .trigger, product: .triggerETO, modelNumber: "142729-TESTING", softwareVersion: "1.9.13"),
        .init(id: testingID(5), name: String(localized: "E.TR.ADJ (Outdated)"), kind: .trigger, product: .triggerETO, modelNumber: "142729-TESTING", softwareVersion: "1.9.11"),
        .init(id: testingID(8), name: String(localized: "E.TR.CMD (Latest)"), kind: .trigger, product: .triggerSFT, modelNumber: nil, softwareVersion: "T00.32.04_3x3"),
        .init(id: testingID(9), name: String(localized: "E.TR.CMD (Outdated)"), kind: .trigger, product: .triggerSFT, modelNumber: nil, softwareVersion: "T00.31.00_3x3"),
    ]
    private static let testingTriggerDeviceID = testingID(4)

    private static func testingID(_ suffix: Int) -> UUID {
        UUID(uuidString: "44444444-4444-4444-8444-44444444444\(suffix)")!
    }

    private static var shouldAddTestingDeviceEntries: Bool {
        ProcessInfo.processInfo.environment["ADD_TESTING_DEVICE_ENTRIES"] != nil
    }

    var diagnosticReport: String {
        let deviceHeader: String
        if case let .connected(name, kind) = phase {
            deviceHeader = "Device: \(name)\nType: \(kind == .gear ? "Actuator" : "Trigger")"
        } else {
            deviceHeader = "No connected device"
        }
        let rows = characteristics.map {
            "\($0.serviceUUID),\($0.uuid),\($0.properties.rawValue)"
        }
        let gatt = ([deviceHeader, "service,characteristic,properties"] + rows)
            .joined(separator: "\n")
        let trace = diagnosticEntries.isEmpty
            ? "No trace entries"
            : diagnosticEntries.joined(separator: "\n")
        return """
        3X3 Service diagnostics
        Exported: \(Self.timestampFormatter.string(from: Date()))
        Bluetooth: \(String(describing: discovery.availability))
        Persistent file: Library/Application Support/diagnostics.log

        GATT
        \(gatt)

        TRACE
        \(trace)
        """
    }

    var canSearchForTriggers: Bool {
        canPresentTriggerPairing
            && !isShifting
            && !isRotatingSecondGear
    }

    var canPresentTriggerPairing: Bool {
        guard case .connected(_, .gear) = phase else {
            return false
        }
        return (isTestingSession || gearPairingDevice != nil)
            && !isCalibrating
            && !isUpdatingAutoDownshift
            && !isUpdatingPairing
    }

    var canCalibrate: Bool {
        isTestingSession || (gearCalibrationDevice != nil && gearCalibrationVariant != nil)
    }

    var canRotateSecondGear: Bool {
        isTestingSession || secondGearRotationDevice != nil
    }

    var calibrationDurationDescription: String {
        gearCalibrationVariant == .hub
            ? String(localized: "about 30 seconds")
            : String(localized: "about five seconds")
    }

    func displayName(for device: DiscoveredDevice) -> String {
        customDeviceNames[device.id.uuidString] ?? device.name
    }

    func setConnectedDeviceName(_ name: String?) {
        guard let connectedDeviceID, let connectedBluetoothName else {
            return
        }
        let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedName, !trimmedName.isEmpty {
            customDeviceNames[connectedDeviceID.uuidString] = trimmedName
            connectedCustomName = trimmedName
        } else {
            customDeviceNames.removeValue(forKey: connectedDeviceID.uuidString)
            connectedCustomName = nil
        }
        UserDefaults.standard.set(customDeviceNames, forKey: Self.customDeviceNamesKey)

        let displayName = connectedCustomName ?? connectedBluetoothName
        if case let .connected(_, kind) = phase {
            phase = .connected(displayName, kind)
            if kind == .trigger, let rememberedTriggerMAC {
                rememberTrigger(name: displayName, mac: rememberedTriggerMAC)
            }
        }
        appendDiagnostic("Device alias updated: id=\(connectedDeviceID) name=\(displayName)")
    }

    func startScanning() {
        appendDiagnostic("Scan requested; Bluetooth=\(discovery.availability)")
        positionPollingTask?.cancel()
        positionPollingTask = nil
        batteryPollingTask?.cancel()
        batteryPollingTask = nil
        firmwareUpdateTask?.cancel()
        firmwareUpdateTask = nil
        scanGeneration += 1
        scanTask?.cancel()
        scanObservationTask?.cancel()
        scanCleanupTask?.cancel()
        testingDeviceTask?.cancel()
        observedPeripheralIDs = []
        advertisementSignatures = [:]
        deviceLastSeen = [:]
        nearbyAdvertisementCount = 0
        devices = []
        characteristics = []
        position = nil
        modelNumber = nil
        threeByThreeProductName = nil
        serialNumber = nil
        softwareVersion = nil
        availableFirmwareVersion = nil
        batteryLevel = nil
        batteryVoltageMillivolts = nil
        batteryLowWarning = nil
        pairedTriggerMAC = nil
        autoDownshiftEnabled = nil
        calibrationMessage = nil
        errorMessage = nil
        phase = .scanning

        if Self.shouldAddTestingDeviceEntries {
            testingDeviceTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(2))
                guard let self, !Task.isCancelled, phase == .scanning else {
                    return
                }
                let testingDevices = Self.testingDevices.enumerated().map { index, configuration in
                    DiscoveredDevice(
                        id: configuration.id,
                        name: configuration.name,
                        rssi: -42 - index,
                        manufacturerIdentifier: configuration.kind == .trigger ? 3_394 : 3_222,
                        serviceUUIDs: configuration.kind == .trigger
                            ? [BluetoothUUIDs.Service.battery]
                            : []
                    )
                }
                for device in testingDevices where !devices.contains(where: { $0.id == device.id }) {
                    devices.append(device)
                    deviceLastSeen[device.id] = Date()
                }
                devices.sort { $0.rssi > $1.rssi }
            }
        }

        let stream = discovery.discoveries()
        let observations = discovery.scanObservations()
        discovery.startScanning()
        scanObservationTask = Task { [weak self] in
            for await observation in observations {
                guard let self, !Task.isCancelled else {
                    return
                }
                observedPeripheralIDs.insert(observation.id)
                nearbyAdvertisementCount = observedPeripheralIDs.count
                let services = observation.serviceUUIDs.isEmpty
                    ? "none"
                    : observation.serviceUUIDs.joined(separator: ",")
                let manufacturerData = observation.manufacturerData?.map {
                    String(format: "%02X", $0)
                }.joined() ?? "none"
                let signature = [
                    observation.name ?? "none",
                    observation.isConnectable.map(String.init) ?? "unknown",
                    services,
                    manufacturerData
                ].joined(separator: "|")
                guard advertisementSignatures[observation.id] != signature else {
                    continue
                }
                let event = advertisementSignatures[observation.id] == nil
                    ? "Advertisement"
                    : "Advertisement changed"
                advertisementSignatures[observation.id] = signature
                appendDiagnostic(
                    "\(event) recognized=\(observation.isRecognized) "
                        + "name=\(observation.name ?? "none") id=\(observation.id) "
                        + "rssi=\(observation.rssi) "
                        + "company=\(observation.manufacturerIdentifier.map(String.init) ?? "none") "
                        + "connectable=\(observation.isConnectable.map(String.init) ?? "unknown") "
                        + "services=\(services) manufacturerData=\(manufacturerData)"
                )
            }
        }
        scanTask = Task { [weak self] in
            for await device in stream {
                guard let self, !Task.isCancelled else {
                    return
                }
                if let index = devices.firstIndex(where: { $0.id == device.id }) {
                    devices[index] = device
                } else {
                    devices.append(device)
                    appendDiagnostic(
                        "Discovered \(device.name) id=\(device.id) "
                            + "rssi=\(device.rssi) company=\(device.manufacturerIdentifier.map(String.init) ?? "none")"
                    )
                }
                deviceLastSeen[device.id] = Date()
                devices.sort { $0.rssi > $1.rssi }
            }
        }
        scanCleanupTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled, phase == .scanning else {
                    return
                }
                removeExpiredDevices()
            }
        }
    }

    private func removeExpiredDevices() {
        let now = Date()
        let protectedIDs = Set([connectingDeviceID, connectedDeviceID].compactMap { $0 })
        let expiredIDs = devices.compactMap { device -> UUID? in
                        guard !isTestingDevice(device),
                                    !protectedIDs.contains(device.id),
                  let lastSeen = deviceLastSeen[device.id] else {
                return nil
            }
            let expirationInterval = device.triggerAdvertisingMode == .awake
                ? Self.awakeTriggerExpirationInterval
                : Self.deviceExpirationInterval
            return now.timeIntervalSince(lastSeen) >= expirationInterval ? device.id : nil
        }
        guard !expiredIDs.isEmpty else {
            return
        }
        let expiredIDSet = Set(expiredIDs)
        devices.removeAll { expiredIDSet.contains($0.id) }
        if devices.isEmpty {
            scanGeneration += 1
        }
        for id in expiredIDs {
            deviceLastSeen.removeValue(forKey: id)
        }
    }

    func connect(to device: DiscoveredDevice) async {
        appendDiagnostic("Connect requested: \(device.name) id=\(device.id)")
        positionPollingTask?.cancel()
        positionPollingTask = nil
        batteryPollingTask?.cancel()
        batteryPollingTask = nil
        errorMessage = nil
        hasConnectionFailure = false
        failedConnectionDevice = nil
        let displayName = displayName(for: device)
        phase = .connecting(displayName)
        connectingDeviceID = device.id
        defer {
            if connectingDeviceID == device.id {
                connectingDeviceID = nil
            }
        }

        if let configuration = Self.testingDevices.first(where: { $0.id == device.id }) {
            try? await Task.sleep(for: .milliseconds(350))
            isTestingSession = true
            modelNumber = configuration.modelNumber
            threeByThreeProductName = configuration.product.displayName
            serialNumber = "TESTING-\(configuration.id.uuidString.suffix(4))"
            softwareVersion = configuration.softwareVersion
            batteryLevel = 84
            batteryVoltageMillivolts = 3_050
            batteryLowWarning = false
            characteristics = Self.testingCharacteristics
            setConnectedIdentity(for: device)
            phase = .connected(displayName, configuration.kind)
            if configuration.kind == .gear {
                currentGear = 5
                autoDownshiftEnabled = true
                autoDownshiftGear = 3
                position = GearPosition(status: 5, position: 167.25)
                gearCalibrationVariant = configuration.modelNumber.flatMap(
                    GearCalibrationVariant.init(modelNumber:)
                )
                pairedTriggerMAC = .zero
            } else {
                if let mac = try? BluetoothMACAddress(
                    rawValue: Data([0x33, 0x33, 0x33, 0x33, 0x33, 0x34])
                ) {
                    rememberTrigger(name: displayName, mac: mac)
                }
                startBatteryPolling()
            }
            scheduleFirmwareUpdateCheck(
                product: configuration.product,
                currentVersion: softwareVersion,
                connectedDeviceID: device.id
            )
            return
        }

        do {
            let session = try await discovery.connect(to: device.id)
            let characteristics = try await session.discoverAll()
            self.session = session
            self.characteristics = characteristics
            setConnectedIdentity(for: device, bluetoothName: session.name)
            phase = .connected(
                connectedCustomName ?? session.name,
                session.deviceKind
            )
            isTestingSession = false
            appendDiagnostic(
                "Connected: \(session.name) kind=\(session.deviceKind) "
                    + "GATT entries=\(characteristics.count)"
            )
            for characteristic in characteristics {
                appendDiagnostic(
                    "GATT service=\(characteristic.serviceUUID) "
                        + "characteristic=\(characteristic.uuid) properties=\(characteristic.properties.rawValue)"
                )
            }
            await readDeviceInformation(from: session)
            scheduleFirmwareUpdateCheck(
                product: ThreeByThreeProduct(
                    modelNumber: modelNumber,
                    hasButtonlessDFU: session.containsCharacteristic(
                        BluetoothUUIDs.NordicDFUCharacteristic.buttonless
                    )
                ),
                currentVersion: softwareVersion,
                connectedDeviceID: device.id
            )

            if session.deviceKind == .trigger,
               session.name.hasPrefix("TSW"),
               session.containsCharacteristic(
                   BluetoothUUIDs.AuthenticationCharacteristic.challenge
               ), session.containsCharacteristic(
                   BluetoothUUIDs.AuthenticationCharacteristic.responseFD
               ), session.containsCharacteristic(
                   BluetoothUUIDs.DiagnosticsCharacteristic.parameterData
               ) {
                do {
                    try await TRPAuthenticator(
                        session: session,
                        trace: diagnosticTrace
                    ).authenticate()
                    let pairingTransport = PeripheralDiagnosticParameterTransport(
                        session: session,
                        trace: diagnosticTrace
                    )
                    let mac = try await TriggerIdentityDevice(
                        transport: pairingTransport
                    ).readMACAddress()
                    rememberTrigger(
                        name: connectedCustomName ?? session.name,
                        mac: mac
                    )
                    appendDiagnostic("Trigger MAC read: \(mac.description)")
                } catch {
                    appendFailure("Trigger pairing identity", error: error)
                }
            }

            if session.deviceKind == .trigger,
               session.containsCharacteristic(
                   BluetoothUUIDs.DiagnosticsCharacteristic.tif
               ) {
                let transport = PeripheralTIFTransport(
                    session: session,
                    trace: diagnosticTrace
                )
                triggerDevice = TriggerDevice(
                    tifClient: TIFClient(transport: transport)
                )
                appendDiagnostic("Trigger TIF transport ready")
                await readTriggerBatteryStatus()
            }

            if session.deviceKind == .gear,
               session.containsCharacteristic(
                   BluetoothUUIDs.DiagnosticsCharacteristic.gatewayToMCU
               ) {
                secondGearRotationDevice = SecondGearRotationDevice(
                    transport: PeripheralSecondGearRotationTransport(
                        session: session,
                        trace: diagnosticTrace
                    )
                )
                gearCalibrationDevice = GearCalibrationDevice(
                    transport: PeripheralGearCalibrationTransport(
                        session: session,
                        trace: diagnosticTrace
                    )
                )
                gearCalibrationVariant = modelNumber.flatMap(
                    GearCalibrationVariant.init(modelNumber:)
                )
                appendDiagnostic(
                    "Gear calibration transport ready: model=\(modelNumber ?? "unknown") "
                        + "variant=\(gearCalibrationVariant.map(String.init(describing:)) ?? "unsupported")"
                )
                appendDiagnostic("Second-gear rotation transport ready")
            }

            if session.deviceKind == .gear,
               session.containsCharacteristic(
                   BluetoothUUIDs.DiagnosticsCharacteristic.tif
               ) {
                let transport = PeripheralTIFTransport(
                    session: session,
                    trace: diagnosticTrace
                )
                gearDevice = GearDevice(tifClient: TIFClient(transport: transport))
                appendDiagnostic("Gear TIF transport ready")

                if session.containsCharacteristic(
                    BluetoothUUIDs.DiagnosticsCharacteristic.parameterData
                ), session.containsCharacteristic(
                    BluetoothUUIDs.DiagnosticsCharacteristic.authentication
                ) {
                    do {
                        let authenticator = DiagnosticsAuthenticator(
                            session: session,
                            trace: diagnosticTrace
                        )
                        try await authenticator.authenticate()
                        let settingsTransport = PeripheralDiagnosticParameterTransport(
                            session: session,
                            trace: diagnosticTrace
                        )
                        let settingsDevice = GearShiftSettingsDevice(
                            transport: settingsTransport
                        )
                        let pairingDevice = GearPairingDevice(
                            transport: settingsTransport
                        )
                        shiftSettingsDevice = settingsDevice
                        gearPairingDevice = pairingDevice
                        do {
                            let settings = try await settingsDevice.read()
                            autoDownshiftEnabled = settings.autoDownshiftEnabled
                            autoDownshiftGear = settings.autoDownshiftGear
                            appendDiagnostic(
                                "Shift settings read: auto=\(settings.autoDownshiftEnabled) "
                                    + "target=\(settings.autoDownshiftGear) bytes=\(settings.rawValue.count)"
                            )
                        } catch {
                            shiftSettingsDevice = nil
                            appendFailure("Shift settings initialization", error: error)
                        }
                        do {
                            let mac = try await pairingDevice.readPairedMACAddress()
                            pairedTriggerMAC = mac
                            restoreRememberedTrigger(for: mac)
                            appendDiagnostic(
                                "Paired Trigger MAC read: \(pairedTriggerMAC?.description ?? "unknown")"
                            )
                        } catch {
                            appendFailure("Pairing initialization", error: error)
                        }
                    } catch {
                        shiftSettingsDevice = nil
                        gearPairingDevice = nil
                        appendFailure("Gear diagnostics initialization", error: error)
                        errorMessage = error.localizedDescription
                    }
                }

                do {
                    try await gearDevice?.enableMCUBLEBridge()
                    appendDiagnostic("Gear MCU BLE bridge enabled")
                } catch {
                    appendFailure("Gear MCU BLE bridge enable", error: error)
                }
                await readGearPosition()
                startPositionPolling()
            }

            if session.deviceKind == .trigger {
                startBatteryPolling()
            }
        } catch is CancellationError {
            appendDiagnostic("Connect cancelled: \(device.name)")
            phase = .idle
        } catch {
            appendFailure("Connect", error: error)
            hasConnectionFailure = true
            failedConnectionDevice = device
            phase = .connectionFailed(device.name)
            errorMessage = error.localizedDescription
        }
    }

    func retryConnection() async {
        guard let failedConnectionDevice else {
            return
        }
        await connect(to: failedConnectionDevice)
    }

    private func setConnectedIdentity(
        for device: DiscoveredDevice,
        bluetoothName: String? = nil
    ) {
        connectedDeviceID = device.id
        connectedBluetoothName = bluetoothName ?? device.name
        connectedCustomName = customDeviceNames[device.id.uuidString]
    }

    func readGearPosition(presentsErrors: Bool = true) async {
        if isTestingSession {
            try? await Task.sleep(for: .milliseconds(200))
            let gear = currentGear ?? 5
            position = GearPosition(
                status: UInt8(gear),
                position: Double(gear - 1) * 45
            )
            return
        }
        guard let gearDevice else {
            return
        }
        errorMessage = nil
        appendDiagnostic("Position read requested")
        do {
            position = try await gearDevice.readPosition()
            currentGear = Int(position?.status ?? 0)
            if let position {
                appendDiagnostic(
                    "Position read: status=\(position.status) position=\(position.position)"
                )
            }
        } catch {
            appendFailure("Position read", error: error)
            if presentsErrors {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func startPositionPolling() {
        positionPollingTask?.cancel()
        guard !isTriggerPairingActive else {
            positionPollingTask = nil
            return
        }
        positionPollingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else {
                    return
                }
                guard case .connected(_, .gear) = phase,
                        !isTriggerPairingActive,
                      !isShifting,
                      !isCalibrating,
                                            !isRotatingSecondGear,
                      !isUpdatingAutoDownshift,
                      !isUpdatingPairing,
                      let gearDevice
                else {
                    continue
                }
                do {
                    let nextPosition = try await gearDevice.readPosition()
                    guard !Task.isCancelled, !isTriggerPairingActive else {
                        continue
                    }
                    guard nextPosition != position else {
                        continue
                    }
                    position = nextPosition
                    currentGear = Int(nextPosition.status)
                    appendDiagnostic(
                        "External position change: status=\(nextPosition.status) "
                            + "position=\(nextPosition.position)"
                    )
                } catch {
                    appendFailure("Position polling", error: error)
                }
            }
        }
    }

    func beginTriggerPairing() {
        guard canSearchForTriggers, !isTriggerPairingActive else {
            return
        }
        isTriggerPairingActive = true
        positionPollingTask?.cancel()
        positionPollingTask = nil
        appendDiagnostic("Automatic Gear updates paused for Trigger pairing")
    }

    func endTriggerPairing() {
        guard isTriggerPairingActive else {
            return
        }
        isTriggerPairingActive = false
        appendDiagnostic("Automatic Gear updates resumed after Trigger pairing")
        if case .connected(_, .gear) = phase {
            startPositionPolling()
        }
    }

    func shift(_ direction: GearShiftDirection) async {
          guard !isCalibrating,
              !isRotatingSecondGear,
              !isUpdatingAutoDownshift,
              !isUpdatingPairing
          else {
            return
        }
        pendingShiftDirections.append(direction)
        appendDiagnostic(
            "Shift queued: \(direction) depth=\(pendingShiftDirections.count)"
        )
        guard !isShifting else {
            return
        }

        errorMessage = nil
        isShifting = true
        defer {
            isShifting = false
            pendingShiftDirections.removeAll()
        }

        while !pendingShiftDirections.isEmpty {
            guard !Task.isCancelled,
                  !isCalibrating,
                !isRotatingSecondGear,
                  !isUpdatingAutoDownshift,
                  !isUpdatingPairing
            else {
                return
            }
            let nextDirection = pendingShiftDirections.removeFirst()
            if nextDirection == .down, currentGear == 1 {
                appendDiagnostic("Queued shift skipped: already in gear 1")
                continue
            }
            if nextDirection == .up, currentGear == 9 {
                appendDiagnostic("Queued shift skipped: already in gear 9")
                continue
            }

            if isTestingSession {
                try? await Task.sleep(for: .milliseconds(250))
                let delta = nextDirection == .up ? 1 : -1
                let gear = min(9, max(1, (currentGear ?? 5) + delta))
                currentGear = gear
                position = GearPosition(
                    status: UInt8(gear),
                    position: Double(gear - 1) * 45
                )
                completedShiftCount += 1
                continue
            }

            guard let gearDevice else {
                return
            }
            let previousGear = currentGear
            appendDiagnostic("Shift requested: \(nextDirection)")
            do {
                try await gearDevice.shift(nextDirection)
                completedShiftCount += 1
                appendDiagnostic("Shift sent: \(nextDirection)")
                await refreshGearPosition(afterShiftFrom: previousGear)
            } catch {
                appendFailure("Shift \(nextDirection)", error: error)
                errorMessage = error.localizedDescription
                return
            }
        }
    }

    func calibrateGear() async {
        guard !isCalibrating,
              !isRotatingSecondGear,
              !isShifting,
              !isUpdatingAutoDownshift,
              !isUpdatingPairing,
              canCalibrate
        else {
            return
        }
        errorMessage = nil
        calibrationMessage = nil
        isCalibrating = true
        let pollingTask = positionPollingTask
        positionPollingTask = nil
        pollingTask?.cancel()
        await pollingTask?.value
        appendDiagnostic("Automatic Actuator updates paused for calibration")
        defer {
            isCalibrating = false
            if case .connected(_, .gear) = phase, !isTriggerPairingActive {
                appendDiagnostic("Automatic Actuator updates resumed after calibration")
                startPositionPolling()
            }
        }

        if isTestingSession {
            try? await Task.sleep(for: .seconds(2))
            guard case .connected(_, .gear) = phase else {
                return
            }
            currentGear = 5
            position = GearPosition(status: 5, position: 180)
            calibrationMessage = String(
                localized: "Auto-calibration cycle finished. Verify every gear before riding."
            )
            secondGearRotationMessage = nil
            return
        }

        guard let gearCalibrationDevice, let gearCalibrationVariant else {
            return
        }
        appendDiagnostic("Gear calibration requested")
        do {
            let result = try await gearCalibrationDevice.calibrate(
                variant: gearCalibrationVariant
            )
            appendDiagnostic("Gear calibration command sent")
            guard case .connected(_, .gear) = phase,
                  session?.isConnected == true,
                  let gearDevice else {
                throw PeripheralSessionError.disconnected(
                    "Calibration could not be verified."
                )
            }
            let nextPosition = try await gearDevice.readPosition()
            position = nextPosition
            currentGear = Int(nextPosition.status)
            switch result {
            case .completedWithoutConfirmation:
                calibrationMessage = String(
                    localized: "Auto-calibration cycle finished. Verify every gear before riding."
                )
            case .succeeded:
                calibrationMessage = String(
                    localized: "Auto-calibration completed. Verify every gear before riding."
                )
            case .failed:
                throw GearCalibrationError.deviceReportedFailure
            }
            secondGearRotationMessage = nil
            appendDiagnostic("Gear calibration completed: \(result)")
        } catch is CancellationError {
            appendDiagnostic("Gear calibration cancelled")
        } catch {
            appendFailure("Gear calibration", error: error)
            errorMessage = error.localizedDescription
        }
    }

    func rotateSecondGear(_ direction: SecondGearRotationDirection) async {
        guard !isRotatingSecondGear,
              !isCalibrating,
              !isShifting,
              !isUpdatingAutoDownshift,
              !isUpdatingPairing,
              canRotateSecondGear
        else {
            return
        }
        errorMessage = nil
        isRotatingSecondGear = true
        let pollingTask = positionPollingTask
        positionPollingTask = nil
        pollingTask?.cancel()
        await pollingTask?.value
        appendDiagnostic("Automatic Actuator updates paused for second-gear rotation")
        defer {
            isRotatingSecondGear = false
            if case .connected(_, .gear) = phase, !isTriggerPairingActive {
                appendDiagnostic("Automatic Actuator updates resumed after second-gear rotation")
                startPositionPolling()
            }
        }

        if isTestingSession {
            try? await Task.sleep(for: .milliseconds(250))
            calibrationMessage = nil
            secondGearRotationMessage = Self.secondGearRotationMessage
            return
        }

        guard let secondGearRotationDevice else {
            return
        }
        appendDiagnostic("Second-gear rotation requested: \(direction)")
        do {
            try await secondGearRotationDevice.rotate(direction)
            calibrationMessage = nil
            secondGearRotationMessage = Self.secondGearRotationMessage
            appendDiagnostic("Second-gear rotation sent: \(direction)")
        } catch {
            appendFailure("Second-gear rotation", error: error)
            errorMessage = error.localizedDescription
        }
    }

    private static let secondGearRotationMessage = String(
        localized: "2nd gear rotated. A calibration ride is now required."
    )

    private func refreshGearPosition(afterShiftFrom previousGear: Int?) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))

        repeat {
            await readGearPosition(presentsErrors: false)
            if currentGear != previousGear {
                return
            }
            try? await Task.sleep(for: .milliseconds(100))
        } while clock.now < deadline

        appendDiagnostic("Position refresh timed out: gear remained \(currentGear.map(String.init) ?? "unknown")")
    }

    func setAutoDownshiftGear(_ gear: Int) async {
          guard !isUpdatingAutoDownshift,
              !isCalibrating,
              !isRotatingSecondGear,
              !isUpdatingPairing
          else {
            return
        }
        errorMessage = nil
        isUpdatingAutoDownshift = true
        defer { isUpdatingAutoDownshift = false }

        if isTestingSession {
            try? await Task.sleep(for: .milliseconds(250))
            autoDownshiftGear = gear
            return
        }

        guard let shiftSettingsDevice else {
            return
        }
        appendDiagnostic("AutoDownShift target requested: gear=\(gear)")
        do {
            let settings = try await shiftSettingsDevice.setAutoDownshiftGear(gear)
            autoDownshiftGear = settings.autoDownshiftGear
            appendDiagnostic("AutoDownShift target written: gear=\(gear)")
        } catch {
            appendFailure("AutoDownShift write", error: error)
            errorMessage = error.localizedDescription
        }
    }

    func setAutoDownshiftEnabled(_ enabled: Bool) async {
          guard !isUpdatingAutoDownshift,
              !isCalibrating,
              !isRotatingSecondGear,
              !isUpdatingPairing
          else {
            return
        }
        errorMessage = nil
        isUpdatingAutoDownshift = true
        defer { isUpdatingAutoDownshift = false }

        if isTestingSession {
            try? await Task.sleep(for: .milliseconds(250))
            autoDownshiftEnabled = enabled
            return
        }

        guard let shiftSettingsDevice else {
            return
        }
        appendDiagnostic("AutoDownShift enabled requested: \(enabled)")
        do {
            let settings = try await shiftSettingsDevice.setAutoDownshiftEnabled(enabled)
            autoDownshiftEnabled = settings.autoDownshiftEnabled
            autoDownshiftGear = settings.autoDownshiftGear
            appendDiagnostic("AutoDownShift enabled written: \(enabled)")
        } catch {
            appendFailure("AutoDownShift enabled write", error: error)
            errorMessage = error.localizedDescription
        }
    }

    private func readTriggerBatteryStatus(isPolling: Bool = false) async {
        if isTestingSession {
            try? await Task.sleep(for: .milliseconds(200))
            batteryLevel = 84
            batteryVoltageMillivolts = 3_050
            batteryLowWarning = false
            return
        }
        if let triggerDevice {
            do {
                let status = try await triggerDevice.readBatteryStatus()
                let nextLevel = Int(status.percentage)
                let nextVoltage = Int(status.voltageMillivolts)
                let didChange = batteryLevel != nextLevel
                    || batteryVoltageMillivolts != nextVoltage
                    || batteryLowWarning != status.lowWarning
                batteryLevel = nextLevel
                batteryVoltageMillivolts = nextVoltage
                batteryLowWarning = status.lowWarning
                if !isPolling || didChange {
                    appendDiagnostic(
                        "Trigger battery read: voltage=\(status.voltageMillivolts)mV "
                            + "percentage=\(status.percentage) low=\(status.lowWarning)"
                    )
                }
            } catch {
                appendFailure("Trigger battery read", error: error)
            }
            return
        }

        guard let session,
              session.containsCharacteristic(
                  BluetoothUUIDs.StandardCharacteristic.batteryLevel
              ) else {
            return
        }
        do {
            let data = try await session.read(
                BluetoothUUIDs.StandardCharacteristic.batteryLevel
            )
            guard let nextLevel = data.first.map(Int.init) else {
                return
            }
            let didChange = batteryLevel != nextLevel
            batteryLevel = nextLevel
            if !isPolling || didChange {
                appendDiagnostic("Trigger battery level read: \(nextLevel)%")
            }
        } catch {
            appendFailure("Trigger battery level read", error: error)
        }
    }

    private func startBatteryPolling() {
        batteryPollingTask?.cancel()
        batteryPollingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled,
                      case .connected(_, .trigger) = phase else {
                    return
                }
                await readTriggerBatteryStatus(isPolling: true)
            }
        }
    }

    func startTriggerPairingScan() {
        guard canSearchForTriggers else {
            return
        }
        appendDiagnostic("Trigger pairing scan requested")
        stopTriggerPairingScan()
        triggerPairingCandidates = []
        triggerPairingCandidateLastSeen = [:]
        triggerPairingPhase = .scanning

        if isTestingSession {
            testingTriggerPairingTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, !Task.isCancelled,
                      triggerPairingPhase == .scanning else {
                    return
                }
                triggerPairingCandidates = [
                    DiscoveredDevice(
                        id: Self.testingTriggerDeviceID,
                        name: "Trigger",
                        rssi: -48,
                        manufacturerIdentifier: 3_394,
                        serviceUUIDs: [BluetoothUUIDs.Service.battery],
                        isConnectable: true
                    )
                ]
                triggerPairingCandidateLastSeen[Self.testingTriggerDeviceID] = Date()
            }
            return
        }

        let discoveries = discovery.discoveries()
        let observations = discovery.scanObservations()
        discovery.startScanning()
        triggerPairingScanTask = Task { [weak self] in
            for await device in discoveries {
                guard let self, !Task.isCancelled else {
                    return
                }
                guard device.isTriggerCandidate else {
                    continue
                }
                if let index = triggerPairingCandidates.firstIndex(
                    where: { $0.id == device.id }
                ) {
                    triggerPairingCandidates[index] = device
                } else {
                    triggerPairingCandidates.append(device)
                }
                triggerPairingCandidateLastSeen[device.id] = Date()
                triggerPairingCandidates.sort { $0.rssi > $1.rssi }
            }
        }
        triggerPairingObservationTask = Task { [weak self] in
            for await observation in observations {
                guard let self, !Task.isCancelled else {
                    return
                }
                let manufacturerData = observation.manufacturerData?.map {
                    String(format: "%02X", $0)
                }.joined() ?? "none"
                appendDiagnostic(
                    "Pairing advertisement name=\(observation.name ?? "none") "
                        + "id=\(observation.id) rssi=\(observation.rssi) "
                        + "company=\(observation.manufacturerIdentifier.map(String.init) ?? "none") "
                        + "connectable=\(observation.isConnectable.map(String.init) ?? "unknown") "
                        + "services=\(observation.serviceUUIDs.joined(separator: ",")) "
                        + "manufacturerData=\(manufacturerData)"
                )
            }
        }
        triggerPairingCleanupTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled,
                      triggerPairingPhase == .scanning else {
                    return
                }
                removeExpiredTriggerPairingCandidates()
            }
        }
    }

    private func removeExpiredTriggerPairingCandidates() {
        let now = Date()
        let expiredIDs = triggerPairingCandidates.compactMap { device -> UUID? in
            guard !isTestingDevice(device),
                device.id != connectingDeviceID,
                  device.id != connectedDeviceID,
                  let lastSeen = triggerPairingCandidateLastSeen[device.id] else {
                return nil
            }
            let expirationInterval = device.triggerAdvertisingMode == .awake
                ? Self.awakeTriggerExpirationInterval
                : Self.deviceExpirationInterval
            return now.timeIntervalSince(lastSeen) >= expirationInterval ? device.id : nil
        }
        guard !expiredIDs.isEmpty else {
            return
        }
        let expiredIDSet = Set(expiredIDs)
        triggerPairingCandidates.removeAll { expiredIDSet.contains($0.id) }
        for id in expiredIDs {
            triggerPairingCandidateLastSeen.removeValue(forKey: id)
        }
    }

    func stopTriggerPairingScan() {
        triggerPairingScanTask?.cancel()
        triggerPairingScanTask = nil
        triggerPairingObservationTask?.cancel()
        triggerPairingObservationTask = nil
        triggerPairingCleanupTask?.cancel()
        triggerPairingCleanupTask = nil
        testingTriggerPairingTask?.cancel()
        testingTriggerPairingTask = nil
        discovery.stopScanning()
        if !triggerPairingPhase.isBusy {
            triggerPairingPhase = .idle
        }
    }

    func pairTrigger(_ device: DiscoveredDevice) async {
        guard canSearchForTriggers, device.isReadyToConnect else {
            return
        }
        stopTriggerPairingScan()
        isUpdatingPairing = true
        triggerPairingPhase = .connecting(device.name)
        defer { isUpdatingPairing = false }

        if isTestingSession, device.id == Self.testingTriggerDeviceID {
            try? await Task.sleep(for: .milliseconds(300))
            let mac = try? BluetoothMACAddress(
                rawValue: Data([0x33, 0x33, 0x33, 0x33, 0x33, 0x34])
            )
            guard let mac else {
                return
            }
            triggerPairingPhase = .updatingGear(device.name)
            try? await Task.sleep(for: .milliseconds(300))
            rememberTrigger(name: displayName(for: device), mac: mac)
            pairedTriggerMAC = mac
            triggerPairingPhase = .completed(mac.description)
            return
        }

        do {
            let identity = try await readTriggerPairingIdentity(from: device)
            defer {
                appendDiagnostic("Pairing Trigger disconnected after Gear confirmation")
                discovery.disconnect(identity.session)
            }
            triggerPairingPhase = .updatingGear(identity.name)
            guard let gearPairingDevice else {
                throw TriggerPairingFlowError.gearUnavailable
            }
            let confirmedMAC = try await waitForGearPairing(
                identity.mac,
                using: gearPairingDevice
            )
            rememberTrigger(name: identity.name, mac: identity.mac)
            pairedTriggerMAC = confirmedMAC
            appendDiagnostic("Pair Trigger confirmed: \(confirmedMAC.description)")
            triggerPairingPhase = .completed(confirmedMAC.description)
        } catch {
            appendFailure("Pair Trigger workflow", error: error)
            triggerPairingPhase = .failed(error.localizedDescription)
        }
    }

    private func readTriggerPairingIdentity(
        from device: DiscoveredDevice
    ) async throws -> (
        name: String,
        mac: BluetoothMACAddress,
        session: PeripheralSession
    ) {
        appendDiagnostic("Pairing Trigger connect requested: \(device.name) id=\(device.id)")
        let triggerSession = try await discovery.connect(to: device.id)
        do {
            let characteristics = try await triggerSession.discoverAll()
            appendDiagnostic(
                "Pairing Trigger connected: \(triggerSession.name) "
                    + "kind=\(triggerSession.deviceKind) GATT entries=\(characteristics.count)"
            )
            for characteristic in characteristics {
                appendDiagnostic(
                    "Pairing GATT service=\(characteristic.serviceUUID) "
                        + "characteristic=\(characteristic.uuid) "
                        + "properties=\(characteristic.properties.rawValue)"
                )
            }
            guard triggerSession.deviceKind == .trigger else {
                throw TriggerPairingFlowError.notTrigger
            }

            guard triggerSession.containsCharacteristic(
                BluetoothUUIDs.AuthenticationCharacteristic.challenge
            ), triggerSession.containsCharacteristic(
                BluetoothUUIDs.AuthenticationCharacteristic.responseFD
            ) else {
                throw TriggerPairingFlowError.authenticationUnavailable
            }

            triggerPairingPhase = .readingIdentity(triggerSession.name)
            try await TRPAuthenticator(
                session: triggerSession,
                trace: diagnosticTrace
            ).authenticate()
            appendDiagnostic("Pairing Trigger authenticated")

            guard triggerSession.containsCharacteristic(
                BluetoothUUIDs.DiagnosticsCharacteristic.parameterData
            ) else {
                guard let mac = device.advertisedTriggerMACAddress else {
                    throw TriggerPairingFlowError.identityUnavailable
                }
                appendDiagnostic(
                    "Pairing Trigger MAC from advertisement after authentication: "
                        + mac.description
                )
                return (displayName(for: device), mac, triggerSession)
            }

            let transport = PeripheralDiagnosticParameterTransport(
                session: triggerSession,
                trace: diagnosticTrace
            )
            let mac = try await TriggerIdentityDevice(
                transport: transport
            ).readMACAddress()
            appendDiagnostic("Pairing Trigger MAC read: \(mac.description)")
            return (displayName(for: device), mac, triggerSession)
        } catch {
            discovery.disconnect(triggerSession)
            throw error
        }
    }

    private func waitForGearPairing(
        _ expectedMAC: BluetoothMACAddress,
        using gearPairingDevice: GearPairingDevice
    ) async throws -> BluetoothMACAddress {
        appendDiagnostic("Waiting for Gear to pair with \(expectedMAC.description)")
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(20))

        while clock.now < deadline {
            try Task.checkCancellation()
            let actualMAC = try await gearPairingDevice.readPairedMACAddress()
            appendDiagnostic("Pairing check: Gear reports \(actualMAC.description)")
            if actualMAC == expectedMAC {
                return actualMAC
            }
            if !actualMAC.isZero {
                throw TriggerPairingFlowError.verificationFailed(
                    expected: expectedMAC,
                    actual: actualMAC
                )
            }
            try await Task.sleep(for: .seconds(1))
        }

        throw TriggerPairingFlowError.pairingTimedOut
    }

    func unpairTrigger() async {
        guard !isUpdatingPairing, !isCalibrating, !isRotatingSecondGear else {
            return
        }
        isUpdatingPairing = true
        errorMessage = nil
        defer { isUpdatingPairing = false }

        if isTestingSession {
            try? await Task.sleep(for: .milliseconds(300))
            pairedTriggerMAC = .zero
            return
        }

        guard let gearPairingDevice else {
            return
        }
        appendDiagnostic("Unpair Trigger requested")
        do {
            _ = try await gearPairingDevice.unpair()
            let confirmedMAC = try await gearPairingDevice.readPairedMACAddress()
            guard confirmedMAC.isZero else {
                throw TriggerPairingFlowError.verificationFailed(
                    expected: .zero,
                    actual: confirmedMAC
                )
            }
            pairedTriggerMAC = confirmedMAC
            appendDiagnostic("Unpair Trigger confirmed")
        } catch {
            appendFailure("Unpair Trigger", error: error)
            errorMessage = error.localizedDescription
        }
    }

    private func readDeviceInformation(from session: PeripheralSession) async {
        modelNumber = await readTextCharacteristic(
            BluetoothUUIDs.StandardCharacteristic.modelNumber,
            label: "Model number",
            from: session
        )
        threeByThreeProductName = ThreeByThreeProduct(
            modelNumber: modelNumber,
            hasButtonlessDFU: session.containsCharacteristic(
                BluetoothUUIDs.NordicDFUCharacteristic.buttonless
            )
        )?.displayName
        appendDiagnostic(
            "3X3 product identified: \(threeByThreeProductName ?? "unknown")"
        )
        serialNumber = await readTextCharacteristic(
            BluetoothUUIDs.StandardCharacteristic.serialNumber,
            label: "Serial number",
            from: session
        )
        let softwareUUID = session.containsCharacteristic(
            BluetoothUUIDs.StandardCharacteristic.softwareRevision
        )
            ? BluetoothUUIDs.StandardCharacteristic.softwareRevision
            : BluetoothUUIDs.StandardCharacteristic.firmwareRevision
        softwareVersion = await readTextCharacteristic(
            softwareUUID,
            label: "Software version",
            from: session
        )

        let uuid = BluetoothUUIDs.StandardCharacteristic.batteryLevel
        guard session.containsCharacteristic(uuid) else {
            appendDiagnostic("Battery level unavailable")
            return
        }
        do {
            let data = try await session.read(uuid)
            batteryLevel = data.first.map(Int.init)
            appendDiagnostic("Battery level read: \(batteryLevel.map(String.init) ?? "invalid")")
        } catch {
            appendFailure("Battery level read", error: error)
        }
    }

    private func rememberTrigger(name: String, mac: BluetoothMACAddress) {
        rememberedTriggerName = name
        rememberedTriggerMAC = mac
        triggerNamesByMAC[mac.description] = name
        UserDefaults.standard.set(triggerNamesByMAC, forKey: Self.triggerNamesByMACKey)
    }

    private func restoreRememberedTrigger(for mac: BluetoothMACAddress) {
        guard !mac.isZero else {
            return
        }
        rememberedTriggerMAC = mac
        rememberedTriggerName = triggerNamesByMAC[mac.description]
    }

    private func readTextCharacteristic(
        _ uuid: String,
        label: String,
        from session: PeripheralSession
    ) async -> String? {
        guard session.containsCharacteristic(uuid) else {
            appendDiagnostic("\(label) unavailable")
            return nil
        }
        do {
            let data = try await session.read(uuid)
            let value = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
            appendDiagnostic("\(label) read: \(value)")
            return value.isEmpty ? nil : value
        } catch {
            appendFailure("\(label) read", error: error)
            return nil
        }
    }

    private func checkForFirmwareUpdate(
        product: ThreeByThreeProduct?,
        currentVersion: String?,
        connectedDeviceID expectedDeviceID: UUID
    ) async {
        availableFirmwareVersion = nil
        guard let product, let currentVersion else {
            appendDiagnostic("Firmware update check skipped: device identity unavailable")
            return
        }

        do {
            var request = URLRequest(
                url: Self.firmwareCatalogURL,
                cachePolicy: .reloadIgnoringLocalCacheData,
                timeoutInterval: 15
            )
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let response = response as? HTTPURLResponse,
                  (200..<300).contains(response.statusCode) else {
                appendDiagnostic("Firmware catalog request returned a non-success response")
                return
            }
            let catalog = try JSONDecoder().decode(FirmwareCatalog.self, from: data)
            guard connectedDeviceID == expectedDeviceID else {
                return
            }
            availableFirmwareVersion = catalog.latestUpdate(
                for: product,
                currentVersion: currentVersion
            )?.version
            appendDiagnostic(
                "Firmware update check: current=\(currentVersion) "
                    + "available=\(availableFirmwareVersion ?? "none")"
            )
        } catch is CancellationError {
            appendDiagnostic("Firmware update check cancelled")
        } catch {
            appendFailure("Firmware update check", error: error)
        }
    }

    private func scheduleFirmwareUpdateCheck(
        product: ThreeByThreeProduct?,
        currentVersion: String?,
        connectedDeviceID: UUID
    ) {
        firmwareUpdateTask?.cancel()
        firmwareUpdateTask = Task { [weak self] in
            await self?.checkForFirmwareUpdate(
                product: product,
                currentVersion: currentVersion,
                connectedDeviceID: connectedDeviceID
            )
        }
    }

    func disconnect() {
        appendDiagnostic("Disconnect requested")
        positionPollingTask?.cancel()
        positionPollingTask = nil
        batteryPollingTask?.cancel()
        batteryPollingTask = nil
        firmwareUpdateTask?.cancel()
        firmwareUpdateTask = nil
        pendingShiftDirections.removeAll()
        stopTriggerPairingScan()
        if let connectingDeviceID {
            discovery.cancelConnection(to: connectingDeviceID)
            self.connectingDeviceID = nil
        }
        if let session {
            discovery.disconnect(session)
        }
        self.session = nil
        connectedDeviceID = nil
        connectedBluetoothName = nil
        connectedCustomName = nil
        failedConnectionDevice = nil
        gearDevice = nil
        triggerDevice = nil
        gearCalibrationDevice = nil
        gearCalibrationVariant = nil
        secondGearRotationDevice = nil
        gearPairingDevice = nil
        shiftSettingsDevice = nil
        phase = .idle
        characteristics = []
        position = nil
        currentGear = nil
        modelNumber = nil
        threeByThreeProductName = nil
        serialNumber = nil
        softwareVersion = nil
        availableFirmwareVersion = nil
        batteryLevel = nil
        batteryVoltageMillivolts = nil
        batteryLowWarning = nil
        pairedTriggerMAC = nil
        triggerPairingCandidates = []
        triggerPairingPhase = .idle
        autoDownshiftEnabled = nil
        autoDownshiftGear = nil
        isShifting = false
        isCalibrating = false
        calibrationMessage = nil
        isRotatingSecondGear = false
        secondGearRotationMessage = nil
        isUpdatingAutoDownshift = false
        isUpdatingPairing = false
        isTriggerPairingActive = false
        isTestingSession = false
    }

    func isTestingDevice(_ device: DiscoveredDevice) -> Bool {
        Self.testingDevices.contains { $0.id == device.id }
    }

    private var diagnosticTrace: @MainActor @Sendable (String) -> Void {
        { [weak self] message in
            self?.appendDiagnostic(message)
        }
    }

    private func appendFailure(_ operation: String, error: Error) {
        appendDiagnostic("ERROR \(operation): \(String(reflecting: error))")
    }

    private func appendDiagnostic(_ message: String) {
        let timestamp = Self.timestampFormatter.string(from: Date())
        let entry = "[\(timestamp)] \(message)"
        diagnosticEntries.append(entry)
        if diagnosticEntries.count > 500 {
            diagnosticEntries.removeFirst(diagnosticEntries.count - 500)
        }
        Self.persistDiagnostic(entry)
    }

    private static func loadPersistedDiagnostics() -> [String] {
        guard let url = diagnosticsURL,
              let contents = try? String(contentsOf: url, encoding: .utf8)
        else {
            return []
        }
        return contents
            .split(separator: "\n")
            .suffix(500)
            .map(String.init)
    }

    private static func persistDiagnostic(_ entry: String) {
        guard let url = diagnosticsURL,
              let data = "\(entry)\n".data(using: .utf8)
        else {
            return
        }

        if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attributes[.size] as? NSNumber,
           size.intValue >= 1_000_000 {
            try? FileManager.default.removeItem(at: url)
        }

        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: data)
            return
        }

        do {
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.close()
        } catch {
            return
        }
    }

    private static var diagnosticsURL: URL? {
        guard let directory = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else {
            return nil
        }
        return directory.appendingPathComponent("diagnostics.log")
    }

    private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let testingCharacteristics = [
        GATTCharacteristic(
            serviceUUID: BluetoothUUIDs.Service.deviceInformation,
            uuid: BluetoothUUIDs.StandardCharacteristic.serialNumber,
            properties: [.read]
        ),
        GATTCharacteristic(
            serviceUUID: BluetoothUUIDs.Service.deviceInformation,
            uuid: BluetoothUUIDs.StandardCharacteristic.firmwareRevision,
            properties: [.read]
        ),
        GATTCharacteristic(
            serviceUUID: BluetoothUUIDs.Service.deviceInformation,
            uuid: BluetoothUUIDs.StandardCharacteristic.softwareRevision,
            properties: [.read]
        ),
        GATTCharacteristic(
            serviceUUID: BluetoothUUIDs.Service.battery,
            uuid: BluetoothUUIDs.StandardCharacteristic.batteryLevel,
            properties: [.read, .notify]
        ),
        GATTCharacteristic(
            serviceUUID: BluetoothUUIDs.Service.diagnostics,
            uuid: BluetoothUUIDs.DiagnosticsCharacteristic.tif,
            properties: [.write, .notify]
        ),
        GATTCharacteristic(
            serviceUUID: BluetoothUUIDs.Service.diagnostics,
            uuid: BluetoothUUIDs.DiagnosticsCharacteristic.parameterData,
            properties: [.read, .write]
        ),
    ]
}

private enum TriggerPairingFlowError: LocalizedError {
    case notTrigger
    case authenticationUnavailable
    case identityUnavailable
    case gearUnavailable
    case pairingTimedOut
    case verificationFailed(
        expected: BluetoothMACAddress,
        actual: BluetoothMACAddress
    )

    var errorDescription: String? {
        switch self {
        case .notTrigger:
            String(localized: "The selected Bluetooth device is not a Trigger.")
        case .authenticationUnavailable:
            String(localized: "The Trigger is not exposing its pairing authentication service. Put it in pairing mode and try again.")
        case .identityUnavailable:
            String(localized: "The Trigger is not exposing its pairing identity. Put it in pairing mode and try again.")
        case .gearUnavailable:
            String(localized: "The Actuator pairing connection is no longer available.")
        case .pairingTimedOut:
            String(localized: "The Actuator did not confirm the Trigger pairing. Keep both devices close and try again.")
        case let .verificationFailed(expected, actual):
            String(
                localized: "The Actuator reported \(actual.description) after pairing instead of \(expected.description)."
            )
        }
    }
}