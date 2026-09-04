import Foundation
import XCTest
@testable import ThreeByThreeKit

final class DeviceTests: XCTestCase {
    func testRecognizesTriggerPairingCandidatesFromAdvertisementEvidence() {
        XCTAssertTrue(discoveredDevice(name: "TSW001").isTriggerCandidate)
        XCTAssertTrue(discoveredDevice(name: "Trigger-OTA").isTriggerCandidate)
        XCTAssertTrue(
            discoveredDevice(
                name: "Unknown",
                serviceUUIDs: ["180f"]
            ).isTriggerCandidate
        )
        XCTAssertTrue(
            discoveredDevice(
                name: "Unknown",
                manufacturerIdentifier: 3_394
            ).isTriggerCandidate
        )
    }

    func testDoesNotRecognizeGearAsTriggerPairingCandidate() {
        XCTAssertFalse(
            discoveredDevice(
                name: "3X3GEAR112411700373",
                manufacturerIdentifier: 3_222
            ).isTriggerCandidate
        )
    }

    func testDistinguishesTriggerAdvertisingModes() {
        let awake = discoveredDevice(
            name: "TSW001",
            manufacturerIdentifier: 3_394,
            manufacturerData: Data([0x42, 0x0D, 0x00])
        )
        let pairing = discoveredDevice(
            name: "TSW001",
            manufacturerIdentifier: 3_394,
            manufacturerData: Data([
                0x42, 0x0D, 0x02, 0xD2, 0xB4, 0x7F, 0xB8, 0x0A, 0x25,
                0x01, 0x00, 0x00, 0x00, 0x00
            ])
        )

        XCTAssertEqual(awake.triggerAdvertisingMode, .awake)
        XCTAssertFalse(awake.isReadyToConnect)
        XCTAssertEqual(pairing.triggerAdvertisingMode, .pairing)
        XCTAssertTrue(pairing.isReadyToConnect)
        XCTAssertEqual(
            pairing.advertisedTriggerMACAddress?.description,
            "D2:B4:7F:B8:0A:25"
        )
        XCTAssertNil(awake.advertisedTriggerMACAddress)
    }

    func testAllowsUnknownTriggerAdvertisingModes() {
        let device = discoveredDevice(
            name: "TSW001",
            manufacturerIdentifier: 3_394,
            manufacturerData: Data([0x42, 0x0D, 0x03])
        )

        XCTAssertEqual(device.triggerAdvertisingMode, .unknown)
        XCTAssertTrue(device.isReadyToConnect)
    }

    func testClassifiesTriggerByBatteryService() {
        XCTAssertEqual(
            DeviceClassifier.classify(
                serviceUUIDs: [BluetoothUUIDs.Service.diagnostics, "180f"]
            ),
            .trigger
        )
    }

    func testClassifiesGearWithoutBatteryService() {
        XCTAssertEqual(
            DeviceClassifier.classify(
                serviceUUIDs: [BluetoothUUIDs.Service.diagnostics]
            ),
            .gear
        )
    }

    func testClassifiesWebAppProductNames() {
        for modelNumber in ["148098-02", "142610", "143035-A", "141903"] {
            XCTAssertEqual(
                ThreeByThreeProduct(modelNumber: modelNumber),
                .actuatorETO
            )
        }
        XCTAssertEqual(
            ThreeByThreeProduct(modelNumber: "142729-01"),
            .triggerETO
        )
        XCTAssertEqual(
            ThreeByThreeProduct(modelNumber: "200000-01"),
            .actuatorHB
        )
        XCTAssertEqual(
            ThreeByThreeProduct(modelNumber: "300000"),
            .triggerHB
        )
        XCTAssertNil(ThreeByThreeProduct(modelNumber: "300000-01"))
        XCTAssertNil(ThreeByThreeProduct(modelNumber: "unknown"))
    }

    func testUsesButtonlessDFUProductBeforeModelNumber() {
        XCTAssertEqual(
            ThreeByThreeProduct(
                modelNumber: "148098-02",
                hasButtonlessDFU: true
            ),
            .triggerSFT
        )
    }

    func testUsesWebAppProductDisplayNames() {
        XCTAssertEqual(ThreeByThreeProduct.actuatorETO.displayName, "E9.XP")
        XCTAssertEqual(ThreeByThreeProduct.actuatorHB.displayName, "Actuator HB")
        XCTAssertEqual(ThreeByThreeProduct.triggerETO.displayName, "E.TR.ADJ")
        XCTAssertEqual(ThreeByThreeProduct.triggerHB.displayName, "Trigger HB")
        XCTAssertEqual(ThreeByThreeProduct.triggerSFT.displayName, "E.TR.CMD")
    }

    func testDecodesGearPosition() throws {
        let position = try GearPosition.decode(Data([0x02, 0xD2, 0x04]))

        XCTAssertEqual(position.status, 2)
        XCTAssertEqual(position.position, 12.34)
    }

    func testRejectsShortGearPosition() {
        XCTAssertThrowsError(try GearPosition.decode(Data([0x01, 0x02]))) { error in
            XCTAssertEqual(
                error as? DeviceError,
                .invalidPayload(
                    command: GearCommand.position.rawValue,
                    expectedAtLeast: 3,
                    actual: 2
                )
            )
        }
    }

    func testEncodesGearShiftDirections() async throws {
        let transport = MockTIFTransport()
        let gear = GearDevice(tifClient: TIFClient(transport: transport))

        try await gear.shift(.up)
        try await gear.shift(.down)

        let sent = await transport.sentData
        XCTAssertEqual(
            sent[0],
            Data([0xFE, 0xAF, 0x01, 0x00, 0x55, 0x6C, 0x0D, 0x01])
        )
        XCTAssertEqual(
            sent[1],
            Data([0xFE, 0xAF, 0x01, 0x00, 0x94, 0xAC, 0x0D, 0x00])
        )
    }

    func testEncodesGearMCUBLEBridgeEnable() async throws {
        let transport = MockTIFTransport()
        let gear = GearDevice(tifClient: TIFClient(transport: transport))

        try await gear.enableMCUBLEBridge()

        let sent = await transport.sentData
        let frame = try TIFFrame.decode(sent[0])
        XCTAssertEqual(frame.command, GearCommand.mcuBLEBridgeEnable.rawValue)
        XCTAssertTrue(frame.payload.isEmpty)
    }

    func testDecodesTriggerBatteryStatus() throws {
        let status = try TriggerBatteryStatus.decode(
            Data([0xE4, 0x0B, 87, 1])
        )

        XCTAssertEqual(status.voltageMillivolts, 3_044)
        XCTAssertEqual(status.percentage, 87)
        XCTAssertTrue(status.lowWarning)
    }

    func testRejectsShortTriggerBatteryStatus() {
        XCTAssertThrowsError(
            try TriggerBatteryStatus.decode(Data([0xE4, 0x0B, 87]))
        ) { error in
            XCTAssertEqual(
                error as? DeviceError,
                .invalidPayload(
                    command: TriggerCommand.batteryVoltage.rawValue,
                    expectedAtLeast: 4,
                    actual: 3
                )
            )
        }
    }

    private func discoveredDevice(
        name: String,
        manufacturerIdentifier: UInt16? = nil,
        manufacturerData: Data? = nil,
        serviceUUIDs: [String] = []
    ) -> DiscoveredDevice {
        DiscoveredDevice(
            id: UUID(),
            name: name,
            rssi: -50,
            manufacturerIdentifier: manufacturerIdentifier,
            manufacturerData: manufacturerData,
            serviceUUIDs: serviceUUIDs,
            isConnectable: true
        )
    }
}