import Foundation

public protocol GearCalibrationTransport: Sendable {
    func notifications() async throws -> AsyncStream<Data>
    func sendCalibrationRequest(_ request: Data) async throws
}

public enum GearCalibrationVariant: Equatable, Sendable {
    case standard
    case hub

    public init?(modelNumber: String) {
        let modelNumber = modelNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        if modelNumber.hasPrefix("200000") {
            self = .hub
        } else if ["148098", "142610", "143035", "141903"].contains(
            where: modelNumber.hasPrefix
        ) {
            self = .standard
        } else {
            return nil
        }
    }
}

public enum GearCalibrationResult: Equatable, Sendable {
    case completedWithoutConfirmation
    case succeeded
    case failed
}

public struct GearCalibrationDevice: Sendable {
    public static let startRequest = Data([
        0x09, 0x08, 0x1A, 0x00, 0x00, 0xFF, 0x00, 0x00, 0x00, 0x00,
    ])

    private let transport: any GearCalibrationTransport
    private let standardDuration: Duration
    private let hubTimeout: Duration

    public init(
        transport: any GearCalibrationTransport,
        standardDuration: Duration = .seconds(7),
        hubTimeout: Duration = .seconds(90)
    ) {
        self.transport = transport
        self.standardDuration = standardDuration
        self.hubTimeout = hubTimeout
    }

    public func calibrate(
        variant: GearCalibrationVariant
    ) async throws -> GearCalibrationResult {
        let notifications = variant == .hub
            ? try await transport.notifications()
            : nil
        try await transport.sendCalibrationRequest(Self.startRequest)

        switch variant {
        case .standard:
            try await Task.sleep(for: standardDuration)
            return .completedWithoutConfirmation
        case .hub:
            guard let notifications else {
                throw GearCalibrationError.notificationStreamEnded
            }
            return try await waitForHubResult(notifications)
        }
    }

    private func waitForHubResult(
        _ notifications: AsyncStream<Data>
    ) async throws -> GearCalibrationResult {
        try await withThrowingTaskGroup(of: GearCalibrationResult.self) { group in
            group.addTask {
                for await data in notifications {
                    guard let result = Self.decodeHubResult(data) else {
                        continue
                    }
                    return result
                }
                throw GearCalibrationError.notificationStreamEnded
            }
            group.addTask { [hubTimeout] in
                try await Task.sleep(for: hubTimeout)
                throw GearCalibrationError.timedOut
            }

            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw GearCalibrationError.notificationStreamEnded
            }
            return result
        }
    }

    static func decodeHubResult(_ data: Data) -> GearCalibrationResult? {
        guard data.count == 8,
              data[data.startIndex] == 0x07,
              data[data.startIndex + 1] == 0x06,
              data[data.startIndex + 2] == 0x1A
        else {
            return nil
        }
        return data[data.startIndex + 4] == 1 ? .succeeded : .failed
    }
}

public enum GearCalibrationError: Error, Equatable, LocalizedError, Sendable {
    case deviceReportedFailure
    case notificationStreamEnded
    case timedOut

    public var errorDescription: String? {
        switch self {
        case .deviceReportedFailure:
            "The Gear reported that calibration failed. Check the drivetrain and try again."
        case .notificationStreamEnded:
            "Calibration notifications stopped before the Gear reported a result."
        case .timedOut:
            "Calibration timed out before the Gear reported a result."
        }
    }
}

@MainActor
public final class PeripheralGearCalibrationTransport:
    GearCalibrationTransport,
    @unchecked Sendable
{
    private let session: PeripheralSession
    private let trace: @MainActor @Sendable (String) -> Void

    public init(
        session: PeripheralSession,
        trace: @escaping @MainActor @Sendable (String) -> Void = { _ in }
    ) {
        self.session = session
        self.trace = trace
    }

    public func notifications() async throws -> AsyncStream<Data> {
        try await session.notifications(
            for: BluetoothUUIDs.DiagnosticsCharacteristic.gatewayToMCU
        )
    }

    public func sendCalibrationRequest(_ request: Data) async throws {
        let uuid = BluetoothUUIDs.DiagnosticsCharacteristic.gatewayToMCU
        trace("MCU TX \(request.hexadecimal)")
        try await session.write(request, to: uuid, withResponse: true)
    }
}

private extension Data {
    var hexadecimal: String {
        map { String(format: "%02X", $0) }.joined(separator: " ")
    }
}
