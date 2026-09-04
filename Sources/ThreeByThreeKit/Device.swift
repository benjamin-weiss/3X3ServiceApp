import Foundation

public enum DeviceKind: Equatable, Sendable {
    case gear
    case trigger
}

public enum DeviceClassifier {
    public static func classify(serviceUUIDs: some Sequence<String>) -> DeviceKind {
        serviceUUIDs.contains {
            $0.caseInsensitiveCompare(BluetoothUUIDs.Service.battery) == .orderedSame
        } ? .trigger : .gear
    }
}

public enum ThreeByThreeProduct: Equatable, Sendable {
    case actuatorETO
    case actuatorHB
    case triggerETO
    case triggerHB
    case triggerSFT

    public init?(modelNumber: String?, hasButtonlessDFU: Bool = false) {
        if hasButtonlessDFU {
            self = .triggerSFT
            return
        }
        guard let modelNumber = modelNumber?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        else {
            return nil
        }
        if ["148098", "142610", "143035", "141903"].contains(
            where: modelNumber.hasPrefix
        ) {
            self = .actuatorETO
        } else if modelNumber.hasPrefix("142729") {
            self = .triggerETO
        } else if modelNumber.hasPrefix("200000") {
            self = .actuatorHB
        } else if modelNumber == "300000" {
            self = .triggerHB
        } else {
            return nil
        }
    }

    public var displayName: String {
        switch self {
        case .actuatorETO:
            "E9.XP"
        case .actuatorHB:
            "Actuator HB"
        case .triggerETO:
            "E.TR.ADJ"
        case .triggerHB:
            "Trigger HB"
        case .triggerSFT:
            "E.TR.CMD"
        }
    }
}

public struct GearPosition: Equatable, Sendable {
    public let status: UInt8
    public let position: Double

    public init(status: UInt8, position: Double) {
        self.status = status
        self.position = position
    }

    public static func decode(_ payload: Data) throws -> GearPosition {
        guard payload.count >= 3 else {
            throw DeviceError.invalidPayload(
                command: GearCommand.position.rawValue,
                expectedAtLeast: 3,
                actual: payload.count
            )
        }
        let rawPosition = UInt16(payload[payload.startIndex + 1])
            | UInt16(payload[payload.startIndex + 2]) << 8
        return GearPosition(
            status: payload[payload.startIndex],
            position: Double(rawPosition) / 100
        )
    }
}

public enum DeviceError: Error, Equatable, Sendable {
    case invalidPayload(command: UInt8, expectedAtLeast: Int, actual: Int)
}

public enum GearShiftDirection: UInt8, Equatable, Sendable {
    case down = 0
    case up = 1
}

public actor GearDevice {
    private let tifClient: TIFClient

    public init(tifClient: TIFClient) {
        self.tifClient = tifClient
    }

    public func enableMCUBLEBridge() async throws {
        try await tifClient.send(GearCommand.mcuBLEBridgeEnable)
    }

    public func readPosition() async throws -> GearPosition {
        let requestPayload = Data([0x01, 0x00])
        let response = try await tifClient.request(
            GearCommand.position,
            payload: requestPayload
        )
        return try GearPosition.decode(response.payload)
    }

    public func shift(_ direction: GearShiftDirection) async throws {
        try await tifClient.send(
            GearCommand.shift,
            payload: Data([direction.rawValue])
        )
    }
}

public struct TriggerBatteryStatus: Equatable, Sendable {
    public let voltageMillivolts: UInt16
    public let percentage: UInt8
    public let lowWarning: Bool

    public init(voltageMillivolts: UInt16, percentage: UInt8, lowWarning: Bool) {
        self.voltageMillivolts = voltageMillivolts
        self.percentage = percentage
        self.lowWarning = lowWarning
    }

    public static func decode(_ payload: Data) throws -> TriggerBatteryStatus {
        guard payload.count >= 4 else {
            throw DeviceError.invalidPayload(
                command: TriggerCommand.batteryVoltage.rawValue,
                expectedAtLeast: 4,
                actual: payload.count
            )
        }
        let voltage = UInt16(payload[payload.startIndex])
            | UInt16(payload[payload.startIndex + 1]) << 8
        return TriggerBatteryStatus(
            voltageMillivolts: voltage,
            percentage: payload[payload.startIndex + 2],
            lowWarning: payload[payload.startIndex + 3] != 0
        )
    }
}

public actor TriggerDevice {
    private let tifClient: TIFClient

    public init(tifClient: TIFClient) {
        self.tifClient = tifClient
    }

    public func readBatteryStatus() async throws -> TriggerBatteryStatus {
        let response = try await tifClient.request(TriggerCommand.batteryVoltage)
        return try TriggerBatteryStatus.decode(response.payload)
    }
}