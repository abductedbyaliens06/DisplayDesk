import XCTest
@testable import DisplayDeskCore

final class DiagnosticsTests: XCTestCase {
    private func screen(path: DiagnosticControlPath = .ddc) -> DiagnosticScreen {
        DiagnosticScreen(number: 1, builtIn: false, mode: ModeSpec(width: 1920, height: 1080, pixelWidth: 3840, pixelHeight: 2160, refreshRate: 60), controlPath: path, brightness: .nan, hdrSupported: true, hdrEnabled: false, edrHeadroom: .infinity, boost: .nan, metalBoost: false, customColorProfile: false)
    }
    func testExportAllowlistAndInvalidNumericReadings() throws {
        let report = DiagnosticReport(appVersion: "/Users/private-person/app", macOSVersion: "27.0.1", screenCaptureAllowed: false, accessibilityAllowed: false, screens: [screen()])
        let data = try report.data()
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["formatVersion", "appVersion", "macOSVersion", "screenCaptureAllowed", "accessibilityAllowed", "screens"])
        XCTAssertEqual(json["appVersion"] as? String, "unknown")
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("private-person"))
        XCTAssertFalse(text.contains("displayUUID"))
        XCTAssertFalse(text.contains("serial"))
        XCTAssertFalse(text.contains("colorProfilePath"))
        XCTAssertNil(screen().brightness)
        XCTAssertEqual(screen().edrHeadroom, 1)
        XCTAssertEqual(screen().boost, 1)
    }
    func testReadOnlyObservationDoesNotPretendToKnowThePreset() {
        let notes = screen(path: .ddcReadOnly).observations.joined(separator: " ")
        XCTAssertTrue(notes.contains("readback did not change"))
        XCTAssertTrue(notes.contains("may lock"))
        XCTAssertFalse(notes.contains("Your monitor is in"))
    }
}
