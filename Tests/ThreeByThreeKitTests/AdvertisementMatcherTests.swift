import Foundation
import XCTest
@testable import ThreeByThreeKit

final class AdvertisementMatcherTests: XCTestCase {
    func testMatchesKnownManufacturerIdentifiers() {
        XCTAssertTrue(
            AdvertisementMatcher.matches(
                name: nil,
                manufacturerData: Data([0x42, 0x0D, 0x01])
            )
        )
        XCTAssertTrue(
            AdvertisementMatcher.matches(
                name: nil,
                manufacturerData: Data([0x96, 0x0C])
            )
        )
    }

    func testMatchesKnownNames() {
        XCTAssertTrue(
            AdvertisementMatcher.matches(
                name: "Gear-OTA",
                manufacturerData: nil
            )
        )
        XCTAssertTrue(
            AdvertisementMatcher.matches(
                name: "TSW-1234",
                manufacturerData: nil
            )
        )
    }

    func testRejectsUnrelatedAdvertisement() {
        XCTAssertFalse(
            AdvertisementMatcher.matches(
                name: "Headphones",
                manufacturerData: Data([0x4C, 0x00])
            )
        )
        XCTAssertFalse(
            AdvertisementMatcher.matches(
                name: nil,
                manufacturerData: Data([0x42])
            )
        )
    }
}