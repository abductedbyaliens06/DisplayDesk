import XCTest
@testable import DisplayDeskCore

final class ImagingTests: XCTestCase {
    func testBoostPreservesRelativeChannelCalibrationAndStartsFromBaseline() throws {
        let baseline: [[Float]] = [[0, 0.4, 0.9], [0, 0.5, 1], [0.01, 0.45, 0.95]]
        let boosted = try GammaCurve.scaled(baseline, factor: 1.5)
        XCTAssertEqual(boosted[0][2], 1.35, accuracy: 0.00001)
        XCTAssertEqual(boosted[1][2], 1.5, accuracy: 0.00001)
        XCTAssertEqual(boosted[2][0], 0.015, accuracy: 0.00001)
        XCTAssertEqual(try GammaCurve.scaled(baseline, factor: 1), baseline)
        XCTAssertEqual(baseline[1][2], 1)
    }
    func testRejectsMalformedGammaAndNonfiniteOrOutOfRangeBoost() {
        let valid: [[Float]] = [[0, 1], [0, 1], [0, 1]]
        for factor in [Double.nan, .infinity, 0.9, 2.01] {
            XCTAssertThrowsError(try GammaCurve.scaled(valid, factor: factor))
        }
        for invalid: [[Float]] in [[], [[0, 1]], [[0, 1], [0], [0, 1]], [[0, .nan], [0, 1], [0, 1]], [[0, -1], [0, 1], [0, 1]]] {
            XCTAssertThrowsError(try GammaCurve.scaled(invalid, factor: 1.2))
        }
    }
    func testLegacyProfilesDecodeWithoutChangingColorOrHDR() throws {
        let json = """
        {"displayUUID":"screen","name":"Screen","mode":{"width":1920,"height":1080,"pixelWidth":1920,"pixelHeight":1080,"refreshRate":60},"dimming":0}
        """
        let setting = try JSONDecoder().decode(DisplaySetting.self, from: Data(json.utf8))
        XCTAssertNil(setting.colorProfilePath)
        XCTAssertNil(setting.hdrEnabled)
        XCTAssertNil(setting.hdrBoost)
    }
    func testImagingProfileRoundTripAndValidation() throws {
        var setting = DisplaySetting(displayUUID: "screen", name: "Screen", mode: ModeSpec(width: 1920, height: 1080, pixelWidth: 1920, pixelHeight: 1080, refreshRate: 60), brightness: 0.8, dimming: 0, colorProfilePath: "/tmp/measured.icc", hdrEnabled: true, hdrBoost: 1.5, hdrBoostMethod: "metal")
        var profile = DisplayProfile(name: "HDR", settings: [setting])
        try ProfileStore.validate(profile)
        XCTAssertEqual(try JSONDecoder().decode(DisplayProfile.self, from: JSONEncoder().encode(profile)), profile)
        setting.hdrEnabled = false; profile.settings = [setting]
        XCTAssertThrowsError(try ProfileStore.validate(profile))
        setting.hdrBoost = 1; setting.colorProfilePath = "../../profile.icc"; profile.settings = [setting]
        XCTAssertThrowsError(try ProfileStore.validate(profile))
        setting.colorProfilePath = "factory"; profile.settings = [setting]
        try ProfileStore.validate(profile)
        setting.hdrBoostMethod = "unknown"; profile.settings = [setting]
        XCTAssertThrowsError(try ProfileStore.validate(profile))
    }
}
