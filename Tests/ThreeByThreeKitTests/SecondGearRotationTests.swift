import Foundation
import XCTest
@testable import ThreeByThreeKit

final class SecondGearRotationTests: XCTestCase {
    func testSendsBundleConfirmedCounterclockwiseRequest() async throws {
        let transport = MockSecondGearRotationTransport()
        let device = SecondGearRotationDevice(transport: transport)

        try await device.rotate(.counterclockwise)

        let requests = await transport.requests
        XCTAssertEqual(
            requests,
            [Data([0x09, 0x08, 0x1A, 0x01, 0x00, 0xFE, 0x01, 0x14, 0x00, 0x00])]
        )
    }

    func testSendsBundleConfirmedClockwiseRequest() async throws {
        let transport = MockSecondGearRotationTransport()
        let device = SecondGearRotationDevice(transport: transport)

        try await device.rotate(.clockwise)

        let requests = await transport.requests
        XCTAssertEqual(
            requests,
            [Data([0x09, 0x08, 0x1A, 0x01, 0x00, 0xFE, 0x02, 0x14, 0x00, 0x00])]
        )
    }
}

private actor MockSecondGearRotationTransport: SecondGearRotationTransport {
    private(set) var requests: [Data] = []

    func sendRotationRequest(_ request: Data) {
        requests.append(request)
    }
}