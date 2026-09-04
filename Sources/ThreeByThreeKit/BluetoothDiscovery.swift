@preconcurrency import CoreBluetooth
import Foundation

public struct DiscoveredDevice: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let rssi: Int
    public let manufacturerIdentifier: UInt16?
    public let manufacturerData: Data?
    public let serviceUUIDs: [String]
    public let isConnectable: Bool?

    public init(
        id: UUID,
        name: String,
        rssi: Int,
        manufacturerIdentifier: UInt16?,
        manufacturerData: Data? = nil,
        serviceUUIDs: [String] = [],
        isConnectable: Bool? = nil
    ) {
        self.id = id
        self.name = name
        self.rssi = rssi
        self.manufacturerIdentifier = manufacturerIdentifier
        self.manufacturerData = manufacturerData
        self.serviceUUIDs = serviceUUIDs
        self.isConnectable = isConnectable
    }

    public var isTriggerCandidate: Bool {
        name.hasPrefix("TSW")
            || name == "Trigger-OTA"
            || name == "OTA_Trigger"
            || serviceUUIDs.contains {
                $0.caseInsensitiveCompare(BluetoothUUIDs.Service.battery) == .orderedSame
            }
            || manufacturerIdentifier == 3_394
    }

    public var triggerAdvertisingMode: TriggerAdvertisingMode? {
        guard isTriggerCandidate,
              manufacturerIdentifier == 3_394,
              let manufacturerData,
              manufacturerData.count >= 3
        else {
            return nil
        }
        return switch manufacturerData[manufacturerData.startIndex + 2] {
        case 0x00: .awake
        case 0x02: .pairing
        default: .unknown
        }
    }

    public var isReadyToConnect: Bool {
        isConnectable != false && triggerAdvertisingMode != .awake
    }

    public var advertisedTriggerMACAddress: BluetoothMACAddress? {
        guard triggerAdvertisingMode == .pairing,
              let manufacturerData,
              manufacturerData.count >= 9
        else {
            return nil
        }
        return try? BluetoothMACAddress(
            rawValue: manufacturerData.subdata(in: 3..<9)
        )
    }
}

public enum TriggerAdvertisingMode: Equatable, Sendable {
    case awake
    case pairing
    case unknown
}

public struct BluetoothScanObservation: Equatable, Sendable {
    public let id: UUID
    public let name: String?
    public let rssi: Int
    public let manufacturerIdentifier: UInt16?
    public let manufacturerData: Data?
    public let serviceUUIDs: [String]
    public let isConnectable: Bool?
    public let isRecognized: Bool

    public init(
        id: UUID,
        name: String?,
        rssi: Int,
        manufacturerIdentifier: UInt16?,
        manufacturerData: Data?,
        serviceUUIDs: [String],
        isConnectable: Bool?,
        isRecognized: Bool
    ) {
        self.id = id
        self.name = name
        self.rssi = rssi
        self.manufacturerIdentifier = manufacturerIdentifier
        self.manufacturerData = manufacturerData
        self.serviceUUIDs = serviceUUIDs
        self.isConnectable = isConnectable
        self.isRecognized = isRecognized
    }
}

struct RSSISmoother {
    private let alpha: Double
    private var smoothedValue: Double?

    init(alpha: Double = 0.25) {
        precondition((0...1).contains(alpha))
        self.alpha = alpha
    }

    mutating func add(_ sample: Int) -> Int {
        let sample = Double(sample)
        let nextValue = smoothedValue.map {
            alpha * sample + (1 - alpha) * $0
        } ?? sample
        smoothedValue = nextValue
        return Int(nextValue.rounded())
    }
}

public enum BluetoothAvailability: Equatable, Sendable {
    case unknown
    case resetting
    case unsupported
    case unauthorized
    case poweredOff
    case poweredOn
}

@MainActor
public final class BluetoothDiscovery: NSObject {
    public private(set) var availability: BluetoothAvailability = .unknown

    private lazy var central = CBCentralManager(delegate: self, queue: nil)
    private var continuation: AsyncStream<DiscoveredDevice>.Continuation?
    private var discoveryStreamID: UUID?
    private var observationContinuation: AsyncStream<BluetoothScanObservation>.Continuation?
    private var observationStreamID: UUID?
    private var shouldScan = false
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var rssiSmoothers: [UUID: RSSISmoother] = [:]
    private var connectionContinuations: [
        UUID: CheckedContinuation<PeripheralSession, Error>
    ] = [:]
    private var connectionTimeoutTasks: [UUID: Task<Void, Never>] = [:]
    private var sessions: [UUID: PeripheralSession] = [:]

    public override init() {
        super.init()
        _ = central
    }

    public func discoveries() -> AsyncStream<DiscoveredDevice> {
        AsyncStream { continuation in
            let streamID = UUID()
            let previousContinuation = self.continuation
            self.continuation = continuation
            self.discoveryStreamID = streamID
            previousContinuation?.finish()
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.discoveryStreamID == streamID else {
                        return
                    }
                    self.continuation = nil
                    self.discoveryStreamID = nil
                    self.stopScanning()
                }
            }
        }
    }

    public func scanObservations() -> AsyncStream<BluetoothScanObservation> {
        AsyncStream { continuation in
            let streamID = UUID()
            let previousContinuation = self.observationContinuation
            self.observationContinuation = continuation
            self.observationStreamID = streamID
            previousContinuation?.finish()
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.observationStreamID == streamID else {
                        return
                    }
                    self.observationContinuation = nil
                    self.observationStreamID = nil
                }
            }
        }
    }

    public func startScanning() {
        shouldScan = true
        rssiSmoothers.removeAll()
        guard central.state == .poweredOn else {
            return
        }
        central.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        )
    }

    public func stopScanning() {
        shouldScan = false
        central.stopScan()
    }

    public func connect(to identifier: UUID) async throws -> PeripheralSession {
        guard availability == .poweredOn else {
            throw BluetoothConnectionError.bluetoothUnavailable(availability)
        }
        guard connectionContinuations[identifier] == nil else {
            throw BluetoothConnectionError.connectionAlreadyPending
        }
        guard let peripheral = peripherals[identifier]
            ?? central.retrievePeripherals(withIdentifiers: [identifier]).first
        else {
            throw BluetoothConnectionError.peripheralNotFound(identifier)
        }

        stopScanning()
        return try await withCheckedThrowingContinuation { continuation in
            connectionContinuations[identifier] = continuation
            central.connect(peripheral)
            connectionTimeoutTasks[identifier] = Task { [weak self] in
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled,
                      let self,
                      let continuation = self.connectionContinuations.removeValue(
                          forKey: identifier
                      )
                else {
                    return
                }
                self.connectionTimeoutTasks.removeValue(forKey: identifier)
                self.central.cancelPeripheralConnection(peripheral)
                continuation.resume(
                    throwing: BluetoothConnectionError.connectionTimedOut
                )
            }
        }
    }

    public func disconnect(_ session: PeripheralSession) {
        central.cancelPeripheralConnection(session.peripheral)
    }

    public func cancelConnection(to identifier: UUID) {
        connectionTimeoutTasks.removeValue(forKey: identifier)?.cancel()
        guard let continuation = connectionContinuations.removeValue(
            forKey: identifier
        ) else {
            return
        }
        if let peripheral = peripherals[identifier]
            ?? central.retrievePeripherals(withIdentifiers: [identifier]).first {
            central.cancelPeripheralConnection(peripheral)
        }
        continuation.resume(throwing: CancellationError())
    }
}

public enum BluetoothConnectionError: Error, Equatable, Sendable, LocalizedError {
    case bluetoothUnavailable(BluetoothAvailability)
    case connectionAlreadyPending
    case peripheralNotFound(UUID)
    case connectionTimedOut
    case connectionFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .bluetoothUnavailable(availability):
            "Bluetooth is unavailable (\(availability))."
        case .connectionAlreadyPending:
            "A connection attempt is already in progress."
        case let .peripheralNotFound(identifier):
            "The device is no longer available (\(identifier)). Scan again."
        case .connectionTimedOut:
            "Bluetooth connection timed out. Wake the switch and try again."
        case let .connectionFailed(detail):
            "Bluetooth connection failed: \(detail)"
        }
    }
}

@MainActor
extension BluetoothDiscovery: @preconcurrency CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        availability = BluetoothAvailability(central.state)
        if central.state == .poweredOn, shouldScan {
            startScanning()
        }
    }

    public func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let advertisedName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let name = peripheral.name ?? advertisedName
        let manufacturerData = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data
        let manufacturerIdentifier = manufacturerData?.companyIdentifier
        let serviceUUIDs = (
            advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        ).map(\.uuidString)
        let isConnectable = (
            advertisementData[CBAdvertisementDataIsConnectable] as? NSNumber
        )?.boolValue
        let isRecognized = AdvertisementMatcher.matches(
            name: name,
            manufacturerData: manufacturerData
        )
        var rssiSmoother = rssiSmoothers[peripheral.identifier] ?? RSSISmoother()
        let smoothedRSSI = rssiSmoother.add(RSSI.intValue)
        rssiSmoothers[peripheral.identifier] = rssiSmoother

        observationContinuation?.yield(
            BluetoothScanObservation(
                id: peripheral.identifier,
                name: name,
                rssi: smoothedRSSI,
                manufacturerIdentifier: manufacturerIdentifier,
                manufacturerData: manufacturerData,
                serviceUUIDs: serviceUUIDs,
                isConnectable: isConnectable,
                isRecognized: isRecognized
            )
        )

        guard isRecognized else {
            return
        }

        peripherals[peripheral.identifier] = peripheral
        continuation?.yield(
            DiscoveredDevice(
                id: peripheral.identifier,
                name: name ?? "3X3 Device",
                rssi: smoothedRSSI,
                manufacturerIdentifier: manufacturerIdentifier,
                manufacturerData: manufacturerData,
                serviceUUIDs: serviceUUIDs,
                isConnectable: isConnectable
            )
        )
    }

    public func centralManager(
        _ central: CBCentralManager,
        didConnect peripheral: CBPeripheral
    ) {
        connectionTimeoutTasks.removeValue(forKey: peripheral.identifier)?.cancel()
        let continuation = connectionContinuations.removeValue(
            forKey: peripheral.identifier
        )
        guard let continuation else {
            central.cancelPeripheralConnection(peripheral)
            return
        }
        let session = PeripheralSession(peripheral: peripheral)
        sessions[peripheral.identifier] = session
        continuation.resume(returning: session)
    }

    public func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        connectionTimeoutTasks.removeValue(forKey: peripheral.identifier)?.cancel()
        let continuation = connectionContinuations.removeValue(
            forKey: peripheral.identifier
        )
        continuation?.resume(
            throwing: BluetoothConnectionError.connectionFailed(
                Self.connectionFailureDetail(peripheral: peripheral, error: error)
            )
        )
    }

    public func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        connectionTimeoutTasks.removeValue(forKey: peripheral.identifier)?.cancel()
        let detail = Self.connectionFailureDetail(peripheral: peripheral, error: error)
        sessions.removeValue(forKey: peripheral.identifier)?.handleDisconnect(detail)
        guard let continuation = connectionContinuations.removeValue(
            forKey: peripheral.identifier
        ) else {
            return
        }
        continuation.resume(
            throwing: BluetoothConnectionError.connectionFailed(
                "Disconnected while connecting; " + detail
            )
        )
    }

    private static func connectionFailureDetail(
        peripheral: CBPeripheral,
        error: Error?
    ) -> String {
        let state = "peripheralState=\(peripheral.state.rawValue)"
        guard let error else {
            return "\(state); no CoreBluetooth error"
        }
        let nsError = error as NSError
        return "\(state); domain=\(nsError.domain); code=\(nsError.code); "
            + nsError.localizedDescription
    }
}

private extension BluetoothAvailability {
    init(_ state: CBManagerState) {
        self = switch state {
        case .unknown: .unknown
        case .resetting: .resetting
        case .unsupported: .unsupported
        case .unauthorized: .unauthorized
        case .poweredOff: .poweredOff
        case .poweredOn: .poweredOn
        @unknown default: .unknown
        }
    }
}

private extension Data {
    var companyIdentifier: UInt16? {
        guard count >= 2 else {
            return nil
        }
        return UInt16(self[startIndex]) | UInt16(self[startIndex + 1]) << 8
    }
}