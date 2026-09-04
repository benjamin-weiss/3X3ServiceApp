import Foundation
import XCTest
@testable import ThreeByThreeKit

final class TIFFrameTests: XCTestCase {
    func testEmptyCommandRoundTrip() throws {
        let frame = TIFFrame(command: GearCommand.mcuInfo)

        let encoded = try frame.encoded()
        let decoded = try TIFFrame.decode(encoded)

        XCTAssertEqual(encoded.count, TIFFrame.headerLength)
        XCTAssertEqual(decoded, frame)
    }

    func testHeaderLayout() throws {
        let encoded = try TIFFrame(
            command: GearCommand.position,
            payload: Data([0x01, 0x00])
        ).encoded()

        XCTAssertEqual(encoded[0], 0xFE)
        XCTAssertEqual(encoded[1], 0xAF)
        XCTAssertEqual(encoded[2], 0x02)
        XCTAssertEqual(encoded[3], 0x00)
        XCTAssertEqual(encoded[6], GearCommand.position.rawValue)
        XCTAssertEqual(Data(encoded.suffix(2)), Data([0x01, 0x00]))
    }

    func testInvalidChecksum() throws {
        var encoded = try TIFFrame(
            command: TriggerCommand.sendShift,
            payload: Data([0x01])
        ).encoded()
        encoded[encoded.startIndex + 7] ^= 0xFF

        XCTAssertThrowsError(try TIFFrame.decode(encoded)) { error in
            XCTAssertEqual(error as? TIFFrameError, .invalidChecksum)
        }
    }

    func testInvalidLength() throws {
        var encoded = try TIFFrame(
            command: GearCommand.shift,
            payload: Data([0x01, 0x02])
        ).encoded()
        encoded.removeLast()

        XCTAssertThrowsError(try TIFFrame.decode(encoded)) { error in
            XCTAssertEqual(
                error as? TIFFrameError,
                .invalidLength(expected: 9, actual: 8)
            )
        }
    }

    func testReassemblesFragmentedFrame() throws {
        let encoded = try TIFFrame(
            command: DiagnosticParameterCommand.read,
            payload: Data(repeating: 0xA5, count: 145)
        ).encoded()
        var accumulator = TIFFrameAccumulator()

        XCTAssertNil(try accumulator.append(encoded.prefix(50)))
        let complete = try accumulator.append(encoded.dropFirst(50))

        XCTAssertEqual(complete, encoded)
        XCTAssertNoThrow(try TIFFrame.decode(XCTUnwrap(complete)))
    }
}