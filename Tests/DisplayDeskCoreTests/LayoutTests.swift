import XCTest
@testable import DisplayDeskCore

final class LayoutTests: XCTestCase {
    private func screen(_ id: String, x: Int, y: Int = 0, main: Bool = false) -> LayoutScreen {
        LayoutScreen(id: id, width: 1920, height: 1080, placement: .init(x: x, y: y, isMain: main))
    }
    func testValidLayoutsIncludeNegativeCoordinatesAndConnectedChains() throws {
        try DisplayLayout.validate([screen("a", x: 0, main: true), screen("b", x: -1920), screen("c", x: -1920, y: -1080)])
        try DisplayLayout.validate([screen("a", x: 0, main: true)])
    }
    func testOverlapGapAndCornerContactAreRejected() {
        let main = screen("a", x: 0, main: true)
        for other in [screen("b", x: 1919), screen("b", x: 1921), screen("b", x: 1920, y: 1080)] {
            XCTAssertThrowsError(try DisplayLayout.validate([main, other]))
        }
    }
    func testMainChangePreservesRelativeGeometry() throws {
        let original = [screen("a", x: 0, main: true), screen("b", x: 1920)]
        let changed = try DisplayLayout.normalized(original, mainID: "b")
        XCTAssertEqual(changed[0].placement, .init(x: -1920, y: 0))
        XCTAssertEqual(changed[1].placement, .init(x: 0, y: 0, isMain: true))
        try DisplayLayout.validate(changed)
    }
    func testMalformedAndExtremeCoordinatesAreRejectedWithoutOverflow() {
        XCTAssertThrowsError(try DisplayLayout.validate([]))
        XCTAssertThrowsError(try DisplayLayout.validate([screen("a", x: Int.max, main: true)]))
        XCTAssertThrowsError(try DisplayLayout.normalized([screen("a", x: Int.min)], mainID: "a"))
        XCTAssertThrowsError(try DisplayLayout.validate([screen("a", x: 1, main: true)]))
        XCTAssertThrowsError(try DisplayLayout.validate([screen("a", x: 0, main: true), screen("a", x: 1920)]))
        XCTAssertThrowsError(try DisplayLayout.validate([screen("a", x: 0), screen("b", x: 1920)]))
        var invalid = screen("a", x: 0, main: true); invalid.width = 0
        XCTAssertThrowsError(try DisplayLayout.validate([invalid]))
    }
    func testSnappingFindsAdjacentEdgesAndDoesNotBridgeDistantGaps() throws {
        let main = screen("a", x: 0, main: true)
        let near = screen("b", x: 1930, y: 12)
        XCTAssertEqual(DisplayLayout.snapped(near, among: [main, near]), .init(x: 1920, y: 0))
        let above = screen("b", x: 10, y: -1090)
        XCTAssertEqual(DisplayLayout.snapped(above, among: [main, above]), .init(x: 0, y: -1080))
        let distant = screen("b", x: 2200)
        XCTAssertEqual(DisplayLayout.snapped(distant, among: [main, distant]), distant.placement)
    }
    private func setting(_ screen: LayoutScreen) -> DisplaySetting {
        DisplaySetting(displayUUID: screen.id, name: "Display", mode: .init(width: screen.width, height: screen.height, pixelWidth: screen.width, pixelHeight: screen.height, refreshRate: 60), brightness: nil, dimming: 0, placement: screen.placement)
    }
    func testProfileRoundTripAndExactTopologyMatching() throws {
        let settings = [setting(screen("a", x: 0, main: true)), setting(screen("b", x: 1920))]
        let profile = try ProfileStore.makeProfile(name: "Desk", settings: settings, existing: [])
        let decoded = try JSONDecoder().decode(DisplayProfile.self, from: JSONEncoder().encode(profile))
        XCTAssertEqual(profile, decoded)
        let modes = Dictionary(uniqueKeysWithValues: settings.map { ($0.displayUUID, [$0.mode]) })
        XCTAssertEqual(try ProfilePlan.resolved(profile, available: settings, modes: modes), settings)
        XCTAssertThrowsError(try ProfilePlan.resolved(profile, available: settings + [setting(screen("c", x: -1920))], modes: modes))
        XCTAssertThrowsError(try ProfilePlan.resolved(profile, available: [settings[0]], modes: modes))
        var mixed = settings; mixed[1].placement = nil
        XCTAssertThrowsError(try ProfileStore.validate(DisplayProfile(name: "Mixed", settings: mixed)))
    }
    func testLegacyProfileHasNoArrangementAndCanApplyWithExtraDisplays() throws {
        var saved = setting(screen("a", x: 0, main: true)); saved.placement = nil
        let profile = DisplayProfile(name: "Legacy", settings: [saved])
        let json = try JSONEncoder().encode(profile)
        XCTAssertFalse(String(decoding: json, as: UTF8.self).contains("placement"))
        let decoded = try JSONDecoder().decode(DisplayProfile.self, from: json)
        let result = try ProfilePlan.resolved(decoded, available: [saved, setting(screen("b", x: 1920))], modes: ["a": [saved.mode]])
        XCTAssertNil(result[0].placement)
    }
}
