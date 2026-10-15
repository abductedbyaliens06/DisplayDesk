import XCTest
@testable import DisplayDeskCore

final class AutomaticProfileTests: XCTestCase {
    func testOptInExactTopologyAndStableIdentity() {
        let profile = UUID()
        var configuration = AutomaticProfileConfiguration()
        configuration.rules = [.init(profileID: profile, externalDisplayUUIDs: ["left", "right"])]
        XCTAssertNil(configuration.matchingProfile(externalDisplayUUIDs: ["left", "right"], availableProfileIDs: [profile]))
        configuration.enabled = true
        XCTAssertEqual(configuration.matchingProfile(externalDisplayUUIDs: ["right", "left"], availableProfileIDs: [profile]), profile)
        XCTAssertNil(configuration.matchingProfile(externalDisplayUUIDs: ["left"], availableProfileIDs: [profile]))
        XCTAssertNil(configuration.matchingProfile(externalDisplayUUIDs: ["left", "right", "extra"], availableProfileIDs: [profile]))
        XCTAssertNil(configuration.matchingProfile(externalDisplayUUIDs: [], availableProfileIDs: [profile]))
        XCTAssertNil(configuration.matchingProfile(externalDisplayUUIDs: ["left", "right"], availableProfileIDs: []))
    }
    func testAmbiguousAndDisabledRulesDoNotChooseTheWrongProfile() {
        let first = UUID(), second = UUID()
        var configuration = AutomaticProfileConfiguration(); configuration.enabled = true
        configuration.rules = [.init(profileID: first, externalDisplayUUIDs: ["screen"]), .init(profileID: second, externalDisplayUUIDs: ["screen"])]
        XCTAssertNil(configuration.matchingProfile(externalDisplayUUIDs: ["screen"], availableProfileIDs: [first, second]))
        configuration.rules[1].enabled = false
        XCTAssertEqual(configuration.matchingProfile(externalDisplayUUIDs: ["screen"], availableProfileIDs: [first, second]), first)
    }
    func testConfigurationPersistenceAndMissingFileDefaults() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AutomaticProfileStore(fileURL: directory.appendingPathComponent("automation.json"))
        XCTAssertFalse(try store.load().enabled)
        var configuration = AutomaticProfileConfiguration(); configuration.enabled = true
        configuration.rules = [.init(profileID: UUID(), externalDisplayUUIDs: ["a", "b", "a"])]
        try store.save(configuration)
        XCTAssertEqual(try store.load(), configuration)
        configuration.rules[0].externalDisplayUUIDs = []
        XCTAssertThrowsError(try store.save(configuration))
    }
}
