import Foundation
import XCTest
@testable import ThreeByThreeKit

final class DiagnosticsAuthenticatorTests: XCTestCase {
    func testEncryptsChallengeWithBundleKeyUsingAES128ECB() throws {
        let challenge = Data([
            0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77,
            0x88, 0x99, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF,
        ])

        let encrypted = try DiagnosticsChallengeCipher.encrypt(challenge)

        XCTAssertEqual(
            encrypted,
            Data([
                0x62, 0xF6, 0x79, 0xBE, 0x2B, 0xF0, 0xD9, 0x31,
                0x64, 0x1E, 0x03, 0x9C, 0xA3, 0x40, 0x1B, 0xB2,
            ])
        )
    }

    func testRejectsNonBlockSizedChallenge() {
        XCTAssertThrowsError(try DiagnosticsChallengeCipher.encrypt(Data([0]))) { error in
            XCTAssertEqual(
                error as? DiagnosticsAuthenticationError,
                .unexpectedNotificationLength(1)
            )
        }
    }

    func testEncryptsTRPChallengeWithReversedBundleKey() throws {
        let challenge = Data([
            0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77,
            0x88, 0x99, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF,
        ])
        let expected = Data([
            0xDA, 0x4A, 0x08, 0xFF, 0xFA, 0x92, 0xB3, 0x19,
            0x12, 0x3A, 0x07, 0x13, 0x2A, 0x20, 0x65, 0xC6,
        ])

        XCTAssertEqual(try TRPChallengeCipher.encrypt(challenge), expected)
    }
}