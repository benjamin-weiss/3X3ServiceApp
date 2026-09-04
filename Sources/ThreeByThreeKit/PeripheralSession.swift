@preconcurrency import CoreBluetooth
import Foundation

public struct GATTCharacteristic: Equatable, Sendable {
    public let serviceUUID: String
    public let uuid: String
    public let properties: GATTCharacteristicProperties

    public init(
        serviceUUID: String,
        uuid: String,
        properties: GATTCharacteristicProperties
    ) {
        self.serviceUUID = serviceUUID
        self.uuid = uuid
        self.properties = properties
    }
}

public struct GATTCharacteristicProperties: OptionSet, Equatable, Sendable {
    public let rawValue: UInt16

    public init(rawValue: UInt16) {
        self.rawValue = rawValue
    }

    public static let broadcast = Self(rawValue: 1 << 0)
    public static let read = Self(rawValue: 1 << 1)
    public static let writeWithoutResponse = Self(rawValue: 1 << 2)
    public static let write = Self(rawValue: 1 << 3)
    public static let notify = Self(rawValue: 1 << 4)
    public static let indicate = Self(rawValue: 1 << 5)
}

public enum PeripheralSessionError: Error, Equatable, LocalizedError, Sendable {
    case operationAlreadyPending(String)
    case disconnected(String)
    case serviceDiscoveryFailed(String)
    case characteristicDiscoveryFailed(String)
    case characteristicNotFound(String)
    case readFailed(String)
    case writeFailed(String)
    case notificationStateFailed(String)
    case missingValue(String)

    public var errorDescription: String? {
        switch self {
        case let .operationAlreadyPending(operation):
            "A Bluetooth operation is already pending: \(operation)."
        case let .disconnected(detail):
            "The Bluetooth device disconnected. \(detail)"
        case let .serviceDiscoveryFailed(detail):
            "Bluetooth service discovery failed: \(detail)"
        case let .characteristicDiscoveryFailed(detail):
            "Bluetooth characteristic discovery failed: \(detail)"
        case let .characteristicNotFound(uuid):
            "Bluetooth characteristic \(uuid) is unavailable."
        case let .readFailed(detail):
            "Bluetooth read failed: \(detail)"
        case let .writeFailed(detail):
            "Bluetooth write failed: \(detail)"
        case let .notificationStateFailed(detail):
            "Bluetooth notifications could not be enabled: \(detail)"
        case let .missingValue(uuid):
            "Bluetooth characteristic \(uuid) returned no value."
        }
    }
}

@MainActor
public final class PeripheralSession: NSObject, @unchecked Sendable {
    public let identifier: UUID
    public let name: String
    public private(set) var serviceUUIDs: Set<String> = []
    public private(set) var isConnected = true

    public var deviceKind: DeviceKind {
        DeviceClassifier.classify(serviceUUIDs: serviceUUIDs)
    }

    let peripheral: CBPeripheral
    private var characteristics: [String: CBCharacteristic] = [:]
    private var serviceContinuation: CheckedContinuation<Void, Error>?
    private var characteristicContinuation: CheckedContinuation<Void, Error>?
    private var pendingCharacteristicServices = 0
    private var readContinuations: [String: CheckedContinuation<Data, Error>] = [:]
    private var writeContinuations: [String: CheckedContinuation<Void, Error>] = [:]
    private var notificationContinuations: [
        String: AsyncStream<Data>.Continuation
    ] = [:]
    private var notificationStreamIDs: [String: UUID] = [:]
    private var notificationStateContinuations: [
        String: CheckedContinuation<Void, Error>
    ] = [:]
    private var disconnectionError: PeripheralSessionError?

    init(peripheral: CBPeripheral) {
        self.peripheral = peripheral
        identifier = peripheral.identifier
        name = peripheral.name ?? "3X3 Device"
        super.init()
        peripheral.delegate = self
    }

    public func discoverAll() async throws -> [GATTCharacteristic] {
        try ensureConnected()
        guard serviceContinuation == nil, characteristicContinuation == nil else {
            throw PeripheralSessionError.operationAlreadyPending("discovery")
        }

        try await withCheckedThrowingContinuation { continuation in
            serviceContinuation = continuation
            peripheral.discoverServices(nil)
        }

        let services = peripheral.services ?? []
        serviceUUIDs = Set(services.map { $0.uuid.uuidString })
        guard !services.isEmpty else {
            return []
        }
        pendingCharacteristicServices = services.count
        try await withCheckedThrowingContinuation { continuation in
            characteristicContinuation = continuation
            for service in services {
                peripheral.discoverCharacteristics(nil, for: service)
            }
        }

        return characteristics.values.map { characteristic in
            GATTCharacteristic(
                serviceUUID: characteristic.service?.uuid.uuidString ?? "",
                uuid: characteristic.uuid.uuidString,
                properties: GATTCharacteristicProperties(characteristic.properties)
            )
        }
        .sorted { ($0.serviceUUID, $0.uuid) < ($1.serviceUUID, $1.uuid) }
    }

    public func containsCharacteristic(_ uuid: String) -> Bool {
        characteristics[Self.normalized(uuid)] != nil
    }

    public func read(_ uuid: String) async throws -> Data {
        try ensureConnected()
        let key = Self.normalized(uuid)
        guard let characteristic = characteristics[key] else {
            throw PeripheralSessionError.characteristicNotFound(uuid)
        }
        guard readContinuations[key] == nil else {
            throw PeripheralSessionError.operationAlreadyPending("read \(uuid)")
        }
        return try await withCheckedThrowingContinuation { continuation in
            readContinuations[key] = continuation
            peripheral.readValue(for: characteristic)
        }
    }

    public func write(
        _ data: Data,
        to uuid: String,
        withResponse: Bool
    ) async throws {
        try ensureConnected()
        let key = Self.normalized(uuid)
        guard let characteristic = characteristics[key] else {
            throw PeripheralSessionError.characteristicNotFound(uuid)
        }

        if !withResponse {
            peripheral.writeValue(data, for: characteristic, type: .withoutResponse)
            return
        }
        guard writeContinuations[key] == nil else {
            throw PeripheralSessionError.operationAlreadyPending("write \(uuid)")
        }
        try await withCheckedThrowingContinuation { continuation in
            writeContinuations[key] = continuation
            peripheral.writeValue(data, for: characteristic, type: .withResponse)
        }
    }

    public func notifications(for uuid: String) async throws -> AsyncStream<Data> {
        try ensureConnected()
        let key = Self.normalized(uuid)
        guard let characteristic = characteristics[key] else {
            throw PeripheralSessionError.characteristicNotFound(uuid)
        }
        guard notificationStateContinuations[key] == nil else {
            throw PeripheralSessionError.operationAlreadyPending("notify \(uuid)")
        }

        let streamID = UUID()
        let stream = AsyncStream<Data> { continuation in
            let previousContinuation = notificationContinuations[key]
            notificationContinuations[key] = continuation
            notificationStreamIDs[key] = streamID
            previousContinuation?.finish()
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in
                    guard let self,
                          self.notificationStreamIDs[key] == streamID
                    else {
                        return
                    }
                    self.notificationContinuations.removeValue(forKey: key)
                    self.notificationStreamIDs.removeValue(forKey: key)
                    self.peripheral.setNotifyValue(false, for: characteristic)
                }
            }
        }
        try await withCheckedThrowingContinuation { continuation in
            notificationStateContinuations[key] = continuation
            peripheral.setNotifyValue(true, for: characteristic)
        }
        return stream
    }

    private static func normalized(_ uuid: String) -> String {
        CBUUID(string: uuid).uuidString
    }

    func handleDisconnect(_ detail: String) {
        let error = PeripheralSessionError.disconnected(detail)
        isConnected = false
        disconnectionError = error

        serviceContinuation?.resume(throwing: error)
        serviceContinuation = nil
        characteristicContinuation?.resume(throwing: error)
        characteristicContinuation = nil
        pendingCharacteristicServices = 0

        let reads = readContinuations.values
        readContinuations.removeAll()
        for continuation in reads {
            continuation.resume(throwing: error)
        }
        let writes = writeContinuations.values
        writeContinuations.removeAll()
        for continuation in writes {
            continuation.resume(throwing: error)
        }
        let notificationStates = notificationStateContinuations.values
        notificationStateContinuations.removeAll()
        for continuation in notificationStates {
            continuation.resume(throwing: error)
        }
        let notifications = notificationContinuations.values
        notificationContinuations.removeAll()
        notificationStreamIDs.removeAll()
        for continuation in notifications {
            continuation.finish()
        }
    }

    private func ensureConnected() throws {
        if let disconnectionError {
            throw disconnectionError
        }
    }
}

@MainActor
extension PeripheralSession: @preconcurrency CBPeripheralDelegate {
    public func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverServices error: Error?
    ) {
        let continuation = serviceContinuation
        serviceContinuation = nil
        if let error {
            continuation?.resume(
                throwing: PeripheralSessionError.serviceDiscoveryFailed(
                    error.localizedDescription
                )
            )
        } else {
            continuation?.resume()
        }
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        if let error {
            let continuation = characteristicContinuation
            characteristicContinuation = nil
            pendingCharacteristicServices = 0
            continuation?.resume(
                throwing: PeripheralSessionError.characteristicDiscoveryFailed(
                    error.localizedDescription
                )
            )
            return
        }

        for characteristic in service.characteristics ?? [] {
            characteristics[characteristic.uuid.uuidString] = characteristic
        }
        pendingCharacteristicServices -= 1
        if pendingCharacteristicServices == 0 {
            let continuation = characteristicContinuation
            characteristicContinuation = nil
            continuation?.resume()
        }
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        let key = characteristic.uuid.uuidString
        if let continuation = readContinuations.removeValue(forKey: key) {
            if let error {
                continuation.resume(
                    throwing: PeripheralSessionError.readFailed(
                        error.localizedDescription
                    )
                )
            } else if let value = characteristic.value {
                continuation.resume(returning: value)
            } else {
                continuation.resume(
                    throwing: PeripheralSessionError.missingValue(key)
                )
            }
            return
        }

        if let value = characteristic.value {
            notificationContinuations[key]?.yield(value)
        }
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        let key = characteristic.uuid.uuidString
        let continuation = writeContinuations.removeValue(forKey: key)
        if let error {
            continuation?.resume(
                throwing: PeripheralSessionError.writeFailed(
                    error.localizedDescription
                )
            )
        } else {
            continuation?.resume()
        }
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        let key = characteristic.uuid.uuidString
        let stateContinuation = notificationStateContinuations.removeValue(forKey: key)
        if let error {
            notificationContinuations.removeValue(forKey: key)?.finish()
            stateContinuation?.resume(
                throwing: PeripheralSessionError.notificationStateFailed(
                    error.localizedDescription
                )
            )
        } else {
            stateContinuation?.resume()
        }
    }
}

private extension GATTCharacteristicProperties {
    init(_ properties: CBCharacteristicProperties) {
        var result: GATTCharacteristicProperties = []
        if properties.contains(.broadcast) { result.insert(.broadcast) }
        if properties.contains(.read) { result.insert(.read) }
        if properties.contains(.writeWithoutResponse) { result.insert(.writeWithoutResponse) }
        if properties.contains(.write) { result.insert(.write) }
        if properties.contains(.notify) { result.insert(.notify) }
        if properties.contains(.indicate) { result.insert(.indicate) }
        self = result
    }
}