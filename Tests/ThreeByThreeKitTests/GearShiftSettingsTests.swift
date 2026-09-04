import Foundation
import XCTest
@testable import ThreeByThreeKit

final class GearShiftSettingsTests: XCTestCase {
    func testReadsAutoDownshiftGear() async throws {
        var rawValue = Data(repeating: 0xAA, count: GearShiftSettings.byteCount)
        rawValue[0] = 1
        rawValue[1] = 4
        let response = try TIFFrame(
            command: DiagnosticParameterCommand.read.rawValue | 0x80,
            payload: parameterReadPayload(rawValue: rawValue)
        ).encoded()
        let transport = MockDiagnosticParameterTransport(responses: [response])

        let settings = try await GearShiftSettingsDevice(transport: transport).read()

        XCTAssertTrue(settings.autoDownshiftEnabled)
        XCTAssertEqual(settings.autoDownshiftGear, 4)
        let requests = await transport.requests
        let request = try TIFFrame.decode(requests[0])
        XCTAssertEqual(request.command, DiagnosticParameterCommand.read.rawValue)
        XCTAssertEqual(request.payload, Data([0x6F, 0, 0, 0, 1]))
    }

    func testUpdatesGearAndPreservesRemainingParameters() async throws {
        var rawValue = Data((0..<GearShiftSettings.byteCount).map(UInt8.init))
        rawValue[0] = 0
        rawValue[1] = 2
        rawValue[2] = 0
        let readResponse = try TIFFrame(
            command: DiagnosticParameterCommand.read.rawValue | 0x80,
            payload: parameterReadPayload(rawValue: rawValue)
        ).encoded()
        let writeResponse = try TIFFrame(
            command: DiagnosticParameterCommand.write.rawValue | 0x80,
            payload: Data([0])
        ).encoded()
        let transport = MockDiagnosticParameterTransport(
            responses: [readResponse, writeResponse]
        )

        let settings = try await GearShiftSettingsDevice(
            transport: transport
        ).setAutoDownshiftGear(6)

        XCTAssertEqual(settings.autoDownshiftGear, 6)
        let requests = await transport.requests
        let write = try TIFFrame.decode(requests[1])
        XCTAssertEqual(write.command, DiagnosticParameterCommand.write.rawValue)
        XCTAssertEqual(write.payload.prefix(8), Data([0x6F, 0, 0, 0, 1, 1, 6, 6]))
        XCTAssertEqual(write.payload.dropFirst(8), rawValue.dropFirst(3))
    }

    func testDisablesAutoDownshiftAndPreservesRemainingParameters() async throws {
        var rawValue = Data((0..<GearShiftSettings.byteCount).map(UInt8.init))
        rawValue[0] = 1
        rawValue[1] = 5
        rawValue[2] = 5
        let readResponse = try TIFFrame(
            command: DiagnosticParameterCommand.read.rawValue | 0x80,
            payload: parameterReadPayload(rawValue: rawValue)
        ).encoded()
        let writeResponse = try TIFFrame(
            command: DiagnosticParameterCommand.write.rawValue | 0x80,
            payload: Data([0])
        ).encoded()
        let transport = MockDiagnosticParameterTransport(
            responses: [readResponse, writeResponse]
        )

        let settings = try await GearShiftSettingsDevice(
            transport: transport
        ).setAutoDownshiftEnabled(false)

        XCTAssertFalse(settings.autoDownshiftEnabled)
        XCTAssertEqual(settings.autoDownshiftGear, 5)
        let requests = await transport.requests
        let write = try TIFFrame.decode(requests[1])
        XCTAssertEqual(write.payload.prefix(6), Data([0x6F, 0, 0, 0, 1, 0]))
        XCTAssertEqual(write.payload.dropFirst(6), rawValue.dropFirst())
    }

    func testRejectsGearOutsideOneThroughNine() async throws {
        let rawValue = Data(repeating: 0, count: GearShiftSettings.byteCount)
        let readResponse = try TIFFrame(
            command: DiagnosticParameterCommand.read.rawValue | 0x80,
            payload: parameterReadPayload(rawValue: rawValue)
        ).encoded()
        let transport = MockDiagnosticParameterTransport(responses: [readResponse])

        do {
            _ = try await GearShiftSettingsDevice(
                transport: transport
            ).setAutoDownshiftGear(10)
            XCTFail("Expected invalid gear")
        } catch {
            XCTAssertEqual(error as? GearShiftSettingsError, .invalidGear(10))
        }
    }

    func testReportsDeviceRejectionFromShortReadResponse() async throws {
        let response = try TIFFrame(
            command: DiagnosticParameterCommand.read.rawValue | 0x80,
            payload: Data([0x6F, 0, 0, 0, 0xF6, 0xFF, 0xFF, 0xFF])
        ).encoded()
        let transport = MockDiagnosticParameterTransport(responses: [response])

        do {
            _ = try await GearShiftSettingsDevice(transport: transport).read()
            XCTFail("Expected device rejection")
        } catch {
            XCTAssertEqual(
                error as? GearShiftSettingsError,
                .deviceRejected(tableID: 111, result: -10)
            )
            XCTAssertEqual(
                error.localizedDescription,
                "The device rejected parameter table 111 with result -10. Authentication may be required."
            )
        }
    }
}

private func parameterReadPayload(rawValue: Data) -> Data {
    Data([0x6F, 0, 0, 0, 0, 0, 0, 0]) + rawValue
}

private actor MockDiagnosticParameterTransport: DiagnosticParameterTransport {
    private var responses: [Data]
    private(set) var requests: [Data] = []

    init(responses: [Data]) {
        self.responses = responses
    }

    func exchange(_ request: Data) throws -> Data {
        requests.append(request)
        return responses.removeFirst()
    }
}