import Foundation
import XCTest
@testable import ThreeByThreeKit

final class TIFClientTests: XCTestCase {
    func testSendsOneWayCommand() async throws {
        let transport = MockTIFTransport()
        let client = TIFClient(transport: transport)

        try await client.send(GearCommand.shift, payload: Data([0x01]))

        let sent = await transport.sentData
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(
            try TIFFrame.decode(sent[0]),
            TIFFrame(command: GearCommand.shift, payload: Data([0x01]))
        )
    }

    func testReturnsMatchingResponse() async throws {
        let response = try TIFFrame(
            command: GearCommand.mcuInfo.rawValue | 0x80,
            payload: Data([0x02, 0x01])
        ).encoded()
        let transport = MockTIFTransport(responses: [response])
        let client = TIFClient(transport: transport)

        let received = try await client.request(GearCommand.mcuInfo)

        XCTAssertEqual(received.payload, Data([0x02, 0x01]))
        let sent = await transport.sentData
        XCTAssertEqual(try TIFFrame.decode(sent[0]).command, GearCommand.mcuInfo.rawValue)
    }

    func testIgnoresUnrelatedResponse() async throws {
        let unrelated = try TIFFrame(
            command: GearCommand.position.rawValue | 0x80
        ).encoded()
        let matching = try TIFFrame(
            command: GearCommand.shift.rawValue | 0x80,
            payload: Data([0x01])
        ).encoded()
        let client = TIFClient(
            transport: MockTIFTransport(responses: [unrelated, matching])
        )

        let received = try await client.request(GearCommand.shift)

        XCTAssertEqual(received.payload, Data([0x01]))
    }

    func testSurfacesDeviceError() async throws {
        let response = try TIFFrame(
            command: 0xFF,
            payload: Data([0x04])
        ).encoded()
        let client = TIFClient(transport: MockTIFTransport(responses: [response]))

        do {
            _ = try await client.request(TriggerCommand.batteryVoltage)
            XCTFail("Expected a device error")
        } catch {
            XCTAssertEqual(error as? TIFClientError, .device(Data([0x04])))
        }
    }

    func testTimesOutWithoutResponse() async throws {
        let client = TIFClient(
            transport: MockTIFTransport(),
            timeout: .milliseconds(10)
        )

        do {
            _ = try await client.request(GearCommand.position)
            XCTFail("Expected a timeout")
        } catch {
            XCTAssertEqual(
                error as? TIFClientError,
                .timedOut(command: GearCommand.position.rawValue)
            )
        }
    }

    func testSerializesOverlappingTransactions() async throws {
        let transport = ControlledTIFTransport()
        let client = TIFClient(transport: transport)

        async let position = client.request(GearCommand.position)
        await transport.waitForSentCount(1)
        async let shift: Void = client.send(
            GearCommand.shift,
            payload: Data([0x01])
        )
        try await Task.sleep(for: .milliseconds(20))
        let sentWhilePositionPending = await transport.sentCount
        XCTAssertEqual(sentWhilePositionPending, 1)

        await transport.respond(
            try TIFFrame(
                command: GearCommand.position.rawValue | 0x80,
                payload: Data([0x04, 0x2D, 0x00])
            ).encoded()
        )
        _ = try await position
        try await shift

        let finalSentCount = await transport.sentCount
        XCTAssertEqual(finalSentCount, 2)
    }
}

private actor ControlledTIFTransport: TIFTransport {
    private let stream: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation
    private(set) var sentCount = 0

    init() {
        var capturedContinuation: AsyncStream<Data>.Continuation?
        stream = AsyncStream { continuation in
            capturedContinuation = continuation
        }
        continuation = capturedContinuation!
    }

    func notifications() -> AsyncStream<Data> {
        stream
    }

    func send(_ data: Data) {
        sentCount += 1
    }

    func respond(_ data: Data) {
        continuation.yield(data)
    }

    func waitForSentCount(_ expectedCount: Int) async {
        while sentCount < expectedCount {
            await Task.yield()
        }
    }
}