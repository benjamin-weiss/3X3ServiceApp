import Foundation
import XCTest
@testable import ThreeByThreeKit

final class GearCalibrationTests: XCTestCase {
    func testSendsBundleConfirmedGatewayRequest() async throws {
        let transport = MockGearCalibrationTransport()
        let device = GearCalibrationDevice(
            transport: transport,
            standardDuration: .zero
        )

        let result = try await device.calibrate(variant: .standard)

        let requests = await transport.requests
        XCTAssertEqual(result, .completedWithoutConfirmation)
        XCTAssertEqual(
            requests,
            [Data([0x09, 0x08, 0x1A, 0x00, 0x00, 0xFF, 0x00, 0x00, 0x00, 0x00])]
        )
    }

    func testDecodesHubCompletion() {
        XCTAssertEqual(
            GearCalibrationDevice.decodeHubResult(
                Data([0x07, 0x06, 0x1A, 0x00, 0x01, 0x00, 0x00, 0x00])
            ),
            .succeeded
        )
        XCTAssertEqual(
            GearCalibrationDevice.decodeHubResult(
                Data([0x07, 0x06, 0x1A, 0x00, 0x00, 0x00, 0x00, 0x00])
            ),
            .failed
        )
        XCTAssertNil(
            GearCalibrationDevice.decodeHubResult(
                Data([0x07, 0x06, 0x15, 0x00, 0x01, 0x00, 0x00, 0x00])
            )
        )
    }

    func testReturnsHubCompletionResult() async throws {
        let transport = MockGearCalibrationTransport(
            responses: [Data([0x07, 0x06, 0x1A, 0x00, 0x01, 0x00, 0x00, 0x00])]
        )
        let device = GearCalibrationDevice(transport: transport)

        let result = try await device.calibrate(variant: .hub)

        XCTAssertEqual(result, .succeeded)
    }

    func testFailsWhenHubNotificationStreamEnds() async {
        let transport = MockGearCalibrationTransport(finishesAfterRequest: true)
        let device = GearCalibrationDevice(
            transport: transport,
            hubTimeout: .seconds(1)
        )

        do {
            _ = try await device.calibrate(variant: .hub)
            XCTFail("Expected notification stream failure")
        } catch {
            XCTAssertEqual(error as? GearCalibrationError, .notificationStreamEnded)
        }
    }

    func testFailsWhenHubCalibrationTimesOut() async {
        let transport = MockGearCalibrationTransport()
        let device = GearCalibrationDevice(
            transport: transport,
            hubTimeout: .milliseconds(10)
        )

        do {
            _ = try await device.calibrate(variant: .hub)
            XCTFail("Expected calibration timeout")
        } catch {
            XCTAssertEqual(error as? GearCalibrationError, .timedOut)
        }
    }

    func testClassifiesKnownActuatorModels() {
        XCTAssertEqual(GearCalibrationVariant(modelNumber: "148098-01"), .standard)
        XCTAssertEqual(GearCalibrationVariant(modelNumber: "200000"), .hub)
        XCTAssertNil(GearCalibrationVariant(modelNumber: "unknown"))
    }
}

private actor MockGearCalibrationTransport: GearCalibrationTransport {
    private let stream: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation
    private let responses: [Data]
    private let finishesAfterRequest: Bool
    private(set) var requests: [Data] = []

    init(responses: [Data] = [], finishesAfterRequest: Bool = false) {
        var capturedContinuation: AsyncStream<Data>.Continuation?
        stream = AsyncStream { continuation in
            capturedContinuation = continuation
        }
        continuation = capturedContinuation!
        self.responses = responses
        self.finishesAfterRequest = finishesAfterRequest
    }

    func notifications() -> AsyncStream<Data> {
        stream
    }

    func sendCalibrationRequest(_ request: Data) {
        requests.append(request)
        for response in responses {
            continuation.yield(response)
        }
        if finishesAfterRequest {
            continuation.finish()
        }
    }
}
