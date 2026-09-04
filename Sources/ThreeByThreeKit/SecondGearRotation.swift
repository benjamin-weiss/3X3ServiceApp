import Foundation

public protocol SecondGearRotationTransport: Sendable {
    func sendRotationRequest(_ request: Data) async throws
}

public enum SecondGearRotationDirection: Equatable, Sendable {
    case counterclockwise
    case clockwise
}

public struct SecondGearRotationDevice: Sendable {
    private let transport: any SecondGearRotationTransport

    public init(transport: any SecondGearRotationTransport) {
        self.transport = transport
    }

    public func rotate(_ direction: SecondGearRotationDirection) async throws {
        try await transport.sendRotationRequest(Self.request(for: direction))
    }

    static func request(for direction: SecondGearRotationDirection) -> Data {
        Data([
            0x09, 0x08, 0x1A, 0x01, 0x00, 0xFE,
            direction == .counterclockwise ? 0x01 : 0x02,
            0x14, 0x00, 0x00,
        ])
    }
}

@MainActor
public final class PeripheralSecondGearRotationTransport:
    SecondGearRotationTransport,
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

    public func sendRotationRequest(_ request: Data) async throws {
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