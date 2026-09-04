import Foundation
import XCTest
@testable import ThreeByThreeKit

final class FirmwareCatalogTests: XCTestCase {
    func testFindsLatestNewerRelease() throws {
        let catalog = try catalog(
            product: "actuatorETO",
            releases: [
                release(version: "1.8.3"),
                release(version: "1.8.6"),
                release(version: "1.8.5"),
            ]
        )

        XCTAssertEqual(
            catalog.latestUpdate(for: .actuatorETO, currentVersion: "1.8.3")?.version,
            "1.8.6"
        )
    }

    func testNormalizesLetterPrefixUnderscoreSuffixAndLeadingZeros() throws {
        let catalog = try catalog(
            product: "triggerSFT",
            releases: [release(version: "0.32.4")]
        )

        XCTAssertNil(
            catalog.latestUpdate(for: .triggerSFT, currentVersion: "T00.32.04_3x3")
        )
    }

    func testDoesNotOfferCurrentOrOlderRelease() throws {
        let catalog = try catalog(
            product: "actuatorHB",
            releases: [release(version: "2.0.2")]
        )

        XCTAssertNil(catalog.latestUpdate(for: .actuatorHB, currentVersion: "2.0.2"))
        XCTAssertNil(catalog.latestUpdate(for: .actuatorHB, currentVersion: "2.1.0"))
    }

    func testOffersStableReleaseForPrereleaseVersion() throws {
        let catalog = try catalog(
            product: "triggerHB",
            releases: [release(version: "0.0.0")]
        )

        XCTAssertEqual(
            catalog.latestUpdate(for: .triggerHB, currentVersion: "0.0.0-debug")?.version,
            "0.0.0"
        )
    }

    private func catalog(
        product: String,
        releases: [[String: String]]
    ) throws -> FirmwareCatalog {
        let products = [
            "triggerETO", "triggerHB", "actuatorETO", "actuatorHB", "triggerSFT",
        ]
        let payload = Dictionary(uniqueKeysWithValues: products.map {
            ($0, $0 == product ? releases : [])
        })
        return try JSONDecoder().decode(
            FirmwareCatalog.self,
            from: JSONSerialization.data(withJSONObject: payload)
        )
    }

    private func release(version: String) -> [String: String] {
        [
            "version": version,
            "url": "firmware.bin",
            "releaseDate": "2026-01-01T00:00:00",
        ]
    }
}