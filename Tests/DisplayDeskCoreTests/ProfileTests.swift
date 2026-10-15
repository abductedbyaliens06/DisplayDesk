import XCTest
@testable import DisplayDeskCore

final class ProfileTests: XCTestCase {
    private let mode = ModeSpec(width: 2560, height: 1440, pixelWidth: 5120, pixelHeight: 2880, refreshRate: 60)
    private func setting(uuid: String = "external-a") -> DisplaySetting {
        DisplaySetting(displayUUID: uuid, name: "Monitor", mode: mode, brightness: 0.7, dimming: 0.2)
    }
    func testRoundTripPreservesDisplayIdentityAndSettings() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = ProfileStore(fileURL: folder.appendingPathComponent("profiles.json"))
        XCTAssertEqual(try store.load(), [])
        let profile = try ProfileStore.makeProfile(name: " Work ", settings: [setting()], existing: [])
        try store.save([profile])
        XCTAssertEqual(try store.load(), [profile])
        XCTAssertEqual(profile.name, "Work")
    }
    func testProfileNamesAndInvalidHardwareValuesAreRejected() throws {
        let profile = try ProfileStore.makeProfile(name: "Work", settings: [setting()], existing: [])
        XCTAssertThrowsError(try ProfileStore.makeProfile(name: " work ", settings: [setting()], existing: [profile]))
        XCTAssertThrowsError(try ProfileStore.makeProfile(name: "  ", settings: [setting()], existing: []))
        for brightness in [-0.1, 1.1, Double.nan] {
            var invalid = setting(); invalid.brightness = brightness
            XCTAssertThrowsError(try ProfileStore.makeProfile(name: "Invalid", settings: [invalid], existing: []))
        }
        var invalid = setting(); invalid.dimming = 0.99
        XCTAssertThrowsError(try ProfileStore.makeProfile(name: "Invalid", settings: [invalid], existing: []))
        XCTAssertThrowsError(try ProfileStore.makeProfile(name: "Duplicate", settings: [setting(), setting()], existing: []))
    }
    func testDisconnectedDisplayIsNeverMatchedByName() throws {
        let profile = DisplayProfile(name: "Work", settings: [setting()])
        XCTAssertThrowsError(try ProfilePlan.resolved(profile, available: [setting(uuid: "different-monitor")], modes: ["different-monitor": [mode]]))
    }
    func testUnsupportedModesAreRejectedBeforeAnyApplication() throws {
        let profile = DisplayProfile(name: "Work", settings: [setting()])
        let incompatible = ModeSpec(width: 1920, height: 1080, pixelWidth: 1920, pixelHeight: 1080, refreshRate: 60)
        XCTAssertThrowsError(try ProfilePlan.resolved(profile, available: [setting()], modes: ["external-a": [incompatible]]))
    }
    func testResolutionAndRefreshBothMatter() throws {
        let profile = DisplayProfile(name: "Work", settings: [setting()])
        var almost = mode; almost.refreshRate = 59.9997
        let result = try ProfilePlan.resolved(profile, available: [setting()], modes: ["external-a": [almost]])
        XCTAssertEqual(result[0].mode, almost)
        var broadcastRate = mode; broadcastRate.refreshRate = 59.94
        XCTAssertThrowsError(try ProfilePlan.resolved(profile, available: [setting()], modes: ["external-a": [broadcastRate]]))
        var wrong = mode; wrong.refreshRate = 120
        XCTAssertThrowsError(try ProfilePlan.resolved(profile, available: [setting()], modes: ["external-a": [wrong]]))
        var nonRetina = mode; nonRetina.pixelWidth = 2560; nonRetina.pixelHeight = 1440
        XCTAssertFalse(mode.matches(nonRetina))
    }
    func testCorruptDataFailsInsteadOfSilentlyDiscardingProfiles() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("not-json".utf8).write(to: file)
        XCTAssertThrowsError(try ProfileStore(fileURL: file).load())
    }
}
