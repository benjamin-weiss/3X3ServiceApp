import Foundation
import XCTest
@testable import ThreeByThreeKit

final class PairingTests: XCTestCase {
    func testReadsTSWTriggerMACFromTable113() async throws {
        let mac = Data([0x11, 0x22, 0x33, 0x44, 0x55, 0x66])
        let transport = PairingTransport(responses: [
            try response(command: .read, tableID: 113, value: mac)
        ])

        let result = try await TriggerIdentityDevice(
            transport: transport
        ).readMACAddress()

        XCTAssertEqual(result.description, "11:22:33:44:55:66")
        let request = try TIFFrame.decode(await transport.requests[0])
        XCTAssertEqual(request.payload, Data([0x71, 0, 0, 0, 1]))
    }

    func testPairsTriggerWhilePreservingBLEParameters() async throws {
        let original = Data((0..<137).map(UInt8.init))
        let target = try BluetoothMACAddress(
            rawValue: Data([0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF])
        )
        let transport = PairingTransport(responses: [
            try response(command: .read, tableID: 106, value: original),
            try response(command: .write, tableID: 106)
        ])

        _ = try await GearPairingDevice(transport: transport).pair(with: target)

        let write = try TIFFrame.decode(await transport.requests[1])
        XCTAssertEqual(write.payload.prefix(5), Data([0x6A, 0, 0, 0, 1]))
        XCTAssertEqual(write.payload[5..<11], target.rawValue)
        XCTAssertEqual(write.payload[12], 4)
        XCTAssertEqual(write.payload[11], original[6])
        XCTAssertEqual(write.payload[13...], original[8...])
    }

    func testUnpairsTriggerWhilePreservingBLEParameters() async throws {
        var original = Data((0..<137).map(UInt8.init))
        original.replaceSubrange(0..<6, with: Data(repeating: 0xAA, count: 6))
        original[7] = 4
        let transport = PairingTransport(responses: [
            try response(command: .read, tableID: 106, value: original),
            try response(command: .write, tableID: 106)
        ])

        _ = try await GearPairingDevice(transport: transport).unpair()

        let write = try TIFFrame.decode(await transport.requests[1])
        XCTAssertEqual(write.payload[5..<11], Data(repeating: 0, count: 6))
        XCTAssertEqual(write.payload[12], 0)
        XCTAssertEqual(write.payload[11], original[6])
        XCTAssertEqual(write.payload[13...], original[8...])
    }

    private func response(
        command: DiagnosticParameterCommand,
        tableID: UInt32,
        value: Data = Data()
    ) throws -> Data {
        var payload = Data([
            UInt8(tableID & 0xFF),
            UInt8((tableID >> 8) & 0xFF),
            UInt8((tableID >> 16) & 0xFF),
            UInt8((tableID >> 24) & 0xFF),
            0, 0, 0, 0,
        ])
        payload.append(value)
        return try TIFFrame(
            command: command.rawValue | 0x80,
            payload: payload
        ).encoded()
    }
}

private actor PairingTransport: DiagnosticParameterTransport {
    private var responses: [Data]
    private(set) var requests: [Data] = []

    init(responses: [Data]) {
        self.responses = responses
    }

    func exchange(_ request: Data) -> Data {
        requests.append(request)
        return responses.removeFirst()
    }
}