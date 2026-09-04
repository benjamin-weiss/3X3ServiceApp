import Foundation

@MainActor
public final class PeripheralTIFTransport: TIFTransport, @unchecked Sendable {
    private let session: PeripheralSession
    private let writeWithResponse: Bool
    private let trace: @MainActor @Sendable (String) -> Void

    public init(
        session: PeripheralSession,
        writeWithResponse: Bool = true,
        trace: @escaping @MainActor @Sendable (String) -> Void = { _ in }
    ) {
        self.session = session
        self.writeWithResponse = writeWithResponse
        self.trace = trace
    }

    public func notifications() async throws -> AsyncStream<Data> {
        let notifications = try await session.notifications(
            for: BluetoothUUIDs.DiagnosticsCharacteristic.tif
        )
        trace("TIF notifications enabled")
        return AsyncStream { continuation in
            let task = Task { @MainActor [trace] in
                for await data in notifications {
                    trace("TIF RX \(data.hexadecimal)")
                    continuation.yield(data)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    public func send(_ data: Data) async throws {
        trace("TIF TX \(data.hexadecimal)")
        try await session.write(
            data,
            to: BluetoothUUIDs.DiagnosticsCharacteristic.tif,
            withResponse: writeWithResponse
        )
    }
}

private extension Data {
    var hexadecimal: String {
        map { String(format: "%02X", $0) }.joined(separator: " ")
    }
}