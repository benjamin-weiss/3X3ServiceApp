import Foundation

public protocol DiagnosticParameterTransport: Sendable {
    func exchange(_ request: Data) async throws -> Data
}

public struct GearShiftSettings: Equatable, Sendable {
    public static let byteCount = 138

    public let rawValue: Data

    public var autoDownshiftEnabled: Bool {
        rawValue[rawValue.startIndex] != 0
    }

    public var autoDownshiftGear: Int {
        Int(rawValue[rawValue.startIndex + 1])
    }

    public init(rawValue: Data) throws {
        guard rawValue.count == Self.byteCount else {
            throw GearShiftSettingsError.invalidValueLength(rawValue.count)
        }
        self.rawValue = rawValue
    }

    func settingAutoDownshiftEnabled(_ enabled: Bool) throws -> GearShiftSettings {
        var updated = rawValue
        updated[updated.startIndex] = enabled ? 1 : 0
        return try GearShiftSettings(rawValue: updated)
    }

    func settingAutoDownshiftGear(_ gear: Int) throws -> GearShiftSettings {
        guard Self.validGears.contains(gear) else {
            throw GearShiftSettingsError.invalidGear(gear)
        }
        var updated = rawValue
        updated[updated.startIndex] = 1
        updated[updated.startIndex + 1] = UInt8(gear)
        updated[updated.startIndex + 2] = UInt8(gear)
        return try GearShiftSettings(rawValue: updated)
    }

    private static let validGears = 1...9
}

public actor GearShiftSettingsDevice {
    private static let tableID: UInt32 = 111
    private let transport: any DiagnosticParameterTransport

    public init(transport: any DiagnosticParameterTransport) {
        self.transport = transport
    }

    public func read() async throws -> GearShiftSettings {
        let response = try await exchange(
            command: .read,
            payload: Self.tableHeader
        )
        guard response.payload.count >= 8 else {
            throw GearShiftSettingsError.invalidResponseLength(response.payload.count)
        }
        let tableID = response.payload.littleEndianUInt32(at: 0)
        guard tableID == Self.tableID else {
            throw GearShiftSettingsError.unexpectedTableID(tableID)
        }
        let result = Int32(bitPattern: response.payload.littleEndianUInt32(at: 4))
        guard response.payload.count >= GearShiftSettings.byteCount + 8 else {
            if result < 0 {
                throw GearShiftSettingsError.deviceRejected(tableID: tableID, result: result)
            }
            throw GearShiftSettingsError.invalidResponseLength(response.payload.count)
        }
        return try GearShiftSettings(
            rawValue: response.payload.subdata(in: 8..<(GearShiftSettings.byteCount + 8))
        )
    }

    @discardableResult
    public func setAutoDownshiftGear(_ gear: Int) async throws -> GearShiftSettings {
        let updated = try await read().settingAutoDownshiftGear(gear)
        return try await write(updated)
    }

    @discardableResult
    public func setAutoDownshiftEnabled(_ enabled: Bool) async throws -> GearShiftSettings {
        let updated = try await read().settingAutoDownshiftEnabled(enabled)
        return try await write(updated)
    }

    private func write(_ settings: GearShiftSettings) async throws -> GearShiftSettings {
        var payload = Self.tableHeader
        payload.append(settings.rawValue)
        _ = try await exchange(command: .write, payload: payload)
        return settings
    }

    private func exchange(
        command: DiagnosticParameterCommand,
        payload: Data
    ) async throws -> TIFFrame {
        let request = try TIFFrame(command: command, payload: payload).encoded()
        let responseData = try await transport.exchange(request)
        let response = try TIFFrame.decode(responseData)
        guard response.command == command.rawValue | 0x80 else {
            throw GearShiftSettingsError.unexpectedResponse(response.command)
        }
        return response
    }

    private static var tableHeader: Data {
        var tableID = tableID.littleEndian
        var data = withUnsafeBytes(of: &tableID) { Data($0) }
        data.append(1)
        return data
    }
}

public enum GearShiftSettingsError: Error, Equatable, LocalizedError, Sendable {
    case invalidGear(Int)
    case invalidValueLength(Int)
    case invalidResponseLength(Int)
    case unexpectedTableID(UInt32)
    case deviceRejected(tableID: UInt32, result: Int32)
    case unexpectedResponse(UInt8)
    case notificationStreamEnded
    case timedOut

    public var errorDescription: String? {
        switch self {
        case .invalidGear(let gear):
            "Gear \(gear) is outside the supported range."
        case .invalidValueLength(let length):
            "Shift settings contain \(length) bytes instead of \(GearShiftSettings.byteCount)."
        case .invalidResponseLength(let length):
            "The shift-settings response has an unexpected length of \(length) bytes."
        case .unexpectedTableID(let tableID):
            "Received parameter table \(tableID) while waiting for table 111."
        case .deviceRejected(let tableID, let result):
            "The device rejected parameter table \(tableID) with result \(result). Authentication may be required."
        case .unexpectedResponse(let command):
            "Received unexpected parameter response command \(command)."
        case .notificationStreamEnded:
            "Parameter notifications stopped before the device responded."
        case .timedOut:
            "Timed out waiting for the parameter response."
        }
    }
}

@MainActor
public final class PeripheralDiagnosticParameterTransport:
    DiagnosticParameterTransport,
    @unchecked Sendable
{
    private let session: PeripheralSession
    private let trace: @MainActor @Sendable (String) -> Void
    private let timeout: Duration

    public init(
        session: PeripheralSession,
        timeout: Duration = .seconds(5),
        trace: @escaping @MainActor @Sendable (String) -> Void = { _ in }
    ) {
        self.session = session
        self.timeout = timeout
        self.trace = trace
    }

    public func exchange(_ request: Data) async throws -> Data {
        let uuid = BluetoothUUIDs.DiagnosticsCharacteristic.parameterData
        let notifications = try await session.notifications(for: uuid)
        trace("PARAM notifications enabled")
        trace("PARAM TX \(request.hexadecimal)")
        try await session.write(request, to: uuid, withResponse: true)

        let response = try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask { [trace] in
                var accumulator = TIFFrameAccumulator()
                for await data in notifications {
                    if let response = try accumulator.append(data) {
                        return response
                    }
                    await trace("PARAM RX fragment \(data.hexadecimal)")
                }
                throw GearShiftSettingsError.notificationStreamEnded
            }
            group.addTask { [timeout] in
                try await Task.sleep(for: timeout)
                throw GearShiftSettingsError.timedOut
            }

            defer { group.cancelAll() }
            guard let response = try await group.next() else {
                throw GearShiftSettingsError.notificationStreamEnded
            }
            return response
        }
        trace("PARAM RX \(response.hexadecimal)")
        return response
    }
}

private extension Data {
    func littleEndianUInt32(at offset: Int) -> UInt32 {
        let index = startIndex + offset
        return UInt32(self[index])
            | UInt32(self[index + 1]) << 8
            | UInt32(self[index + 2]) << 16
            | UInt32(self[index + 3]) << 24
    }

    var hexadecimal: String {
        map { String(format: "%02X", $0) }.joined(separator: " ")
    }
}