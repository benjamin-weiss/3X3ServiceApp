import XCTest
@testable import ThreeByThreeKit

final class RSSISmootherTests: XCTestCase {
    func testPreservesFirstSample() {
        var smoother = RSSISmoother()

        XCTAssertEqual(smoother.add(-72), -72)
    }

    func testDampensSubsequentSamples() {
        var smoother = RSSISmoother()

        XCTAssertEqual(smoother.add(-80), -80)
        XCTAssertEqual(smoother.add(-40), -70)
        XCTAssertEqual(smoother.add(-100), -78)
    }
}