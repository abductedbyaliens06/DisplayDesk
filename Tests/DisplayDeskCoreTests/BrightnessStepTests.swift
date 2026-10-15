import XCTest
@testable import DisplayDeskCore

final class BrightnessStepTests: XCTestCase {
    func testHardwareBoundariesAndFineSteps() {
        XCTAssertEqual(BrightnessStep.hardware(current: 0.99, delta: 0.05), 1)
        XCTAssertEqual(BrightnessStep.hardware(current: 0.01, delta: -0.05), 0)
        XCTAssertEqual(BrightnessStep.hardware(current: 0.5, delta: 0.01)!, 0.51, accuracy: 0.000001)
        XCTAssertNil(BrightnessStep.hardware(current: .nan, delta: 0.05))
    }
    func testSoftwareFallbackMovesInTheCorrectDirectionWithoutBoosting() {
        XCTAssertEqual(BrightnessStep.dimming(current: 0.5, delta: 0.05)!, 0.45, accuracy: 0.000001)
        XCTAssertEqual(BrightnessStep.dimming(current: 0, delta: 0.05), 0)
        XCTAssertEqual(BrightnessStep.dimming(current: 0.79, delta: -0.05), 0.8)
        XCTAssertNil(BrightnessStep.dimming(current: 0, delta: .infinity))
    }
}
