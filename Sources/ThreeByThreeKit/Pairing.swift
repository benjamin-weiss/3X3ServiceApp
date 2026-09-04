import Foundation

public struct BluetoothMACAddress: Equatable, Sendable, CustomStringConvertible {
    public static let byteCount = 6

    public let rawValue: Data

    public init(rawValue: Data) throws {
        guard rawValue.count == Self.byteCount else {
            throw PairingError.invalidMACLength(rawValue.count)
        }
        self.rawValue = rawValue
    }

    public var isZero: Bool {
        rawValue.allSatisfy { $0 == 0 }
    }

    public var description: String {
        rawValue.map { String(format: "%02X", $0) }.joined(separator: ":")
    }

    public static let zero = try! BluetoothMACAddress(
        rawValue: Data(repeating: 0, count: byteCount)
    )
}

public actor TriggerIdentityDevice {
    private static let tableID: UInt32 = 113
    private let transport: any DiagnosticParameterTransport

    public init(transport: any DiagnosticParameterTransport) {
        self.transport = transport
    }

    public func readMACAddress() async throws -> BluetoothMACAddress {
        let response = try await exchange(command: .read, payload: Self.tableHeader)
        let payload = try Self.validatedPayload(response, minimumLength: 14)
        return try BluetoothMACAddress(rawValue: payload.subdata(in: 8..<14))
    }

    private func exchange(
        command: DiagnosticParameterCommand,
        payload: Data
    ) async throws -> TIFFrame {
        let request = try TIFFrame(command: command, payload: payload).encoded()
        let response = try TIFFrame.decode(await transport.exchange(request))
        guard response.command == command.rawValue | 0x80 else {
            throw PairingError.unexpectedResponse(response.command)
        }
        return response
    }

    private static func validatedPayload(
        _ response: TIFFrame,
        minimumLength: Int
    ) throws -> Data {
        guard response.payload.count >= 8 else {
            throw PairingError.invalidResponseLength(response.payload.count)
        }
        let tableID = response.payload.littleEndianUInt32(at: 0)
        guard tableID == Self.tableID else {
            throw PairingError.unexpectedTableID(tableID)
        }
        let result = Int32(bitPattern: response.payload.littleEndianUInt32(at: 4))
        guard result >= 0 else {
            throw PairingError.deviceRejected(tableID: tableID, result: result)
        }
        guard response.payload.count >= minimumLength else {
            throw PairingError.invalidResponseLength(response.payload.count)
        }
        return response.payload
    }

    private static var tableHeader: Data {
        Data([0x71, 0, 0, 0, 1])
    }
}

public actor GearPairingDevice {
    private static let tableID: UInt32 = 106
    private static let valueLength = 137
    private let transport: any DiagnosticParameterTransport

    public init(transport: any DiagnosticParameterTransport) {
        self.transport = transport
    }

    public func readPairedMACAddress() async throws -> BluetoothMACAddress {
        try await read().macAddress
    }

    @discardableResult
    public func pair(with macAddress: BluetoothMACAddress) async throws -> BluetoothMACAddress {
        var parameters = try await read()
        parameters.rawValue.replaceSubrange(0..<6, with: macAddress.rawValue)
        parameters.rawValue[7] = 4
        try await write(parameters.rawValue)
        return macAddress
    }

    @discardableResult
    public func unpair() async throws -> BluetoothMACAddress {
        var parameters = try await read()
        parameters.rawValue.replaceSubrange(0..<6, with: BluetoothMACAddress.zero.rawValue)
        parameters.rawValue[7] = 0
        try await write(parameters.rawValue)
        return .zero
    }

    private func read() async throws -> Parameters {
        let response = try await exchange(command: .read, payload: Self.tableHeader)
        let payload = try validatedPayload(response, minimumLength: 8 + Self.valueLength)
        return try Parameters(
            rawValue: payload.subdata(in: 8..<(8 + Self.valueLength))
        )
    }

    private func write(_ value: Data) async throws {
        var payload = Self.tableHeader
        payload.append(value)
        let response = try await exchange(command: .write, payload: payload)
        _ = try validatedPayload(response, minimumLength: 8)
    }

    private func exchange(
        command: DiagnosticParameterCommand,
        payload: Data
    ) async throws -> TIFFrame {
        let request = try TIFFrame(command: command, payload: payload).encoded()
        let response = try TIFFrame.decode(await transport.exchange(request))
        guard response.command == command.rawValue | 0x80 else {
            throw PairingError.unexpectedResponse(response.command)
        }
        return response
    }

    private func validatedPayload(
        _ response: TIFFrame,
        minimumLength: Int
    ) throws -> Data {
        guard response.payload.count >= 8 else {
            throw PairingError.invalidResponseLength(response.payload.count)
        }
        let tableID = response.payload.littleEndianUInt32(at: 0)
        guard tableID == Self.tableID else {
            throw PairingError.unexpectedTableID(tableID)
        }
        let result = Int32(bitPattern: response.payload.littleEndianUInt32(at: 4))
        guard result >= 0 else {
            throw PairingError.deviceRejected(tableID: tableID, result: result)
        }
        guard response.payload.count >= minimumLength else {
            throw PairingError.invalidResponseLength(response.payload.count)
        }
        return response.payload
    }

    private static var tableHeader: Data {
        Data([0x6A, 0, 0, 0, 1])
    }

    private struct Parameters {
        var rawValue: Data

        init(rawValue: Data) throws {
            guard rawValue.count == GearPairingDevice.valueLength else {
                throw PairingError.invalidParameterLength(rawValue.count)
            }
            self.rawValue = rawValue
        }

        var macAddress: BluetoothMACAddress {
            get throws {
                try BluetoothMACAddress(rawValue: rawValue.prefix(6))
            }
        }
    }
}

public enum PairingError: Error, Equatable, LocalizedError, Sendable {
    case invalidMACLength(Int)
    case invalidParameterLength(Int)
    case invalidResponseLength(Int)
    case unexpectedTableID(UInt32)
    case deviceRejected(tableID: UInt32, result: Int32)
    case unexpectedResponse(UInt8)

    public var errorDescription: String? {
        switch self {
        case .invalidMACLength(let length):
            "The Trigger MAC address contains \(length) bytes instead of 6."
        case .invalidParameterLength(let length):
            "BLE parameter table 106 contains \(length) bytes instead of 137."
        case .invalidResponseLength(let length):
            "The pairing response has an unexpected length of \(length) bytes."
        case .unexpectedTableID(let tableID):
            "Received parameter table \(tableID) while waiting for pairing data."
        case .deviceRejected(let tableID, let result):
            "The device rejected parameter table \(tableID) with result \(result)."
        case .unexpectedResponse(let command):
            "Received unexpected pairing response command \(command)."
        }
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
}