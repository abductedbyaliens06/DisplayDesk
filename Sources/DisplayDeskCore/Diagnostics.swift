import Foundation

public enum DiagnosticControlPath: String, Codable, Sendable {
    case apple, ddc, ddcReadOnly, softwareOnly, checking
    public var label: String {
        switch self {
        case .apple: return "Apple display controls"
        case .ddc: return "DDC/CI"
        case .ddcReadOnly: return "DDC/CI readback unchanged"
        case .softwareOnly: return "Software dimming only"
        case .checking: return "Checking hardware"
        }
    }
}

/// Deliberate allowlist: no names, UUIDs, serials, paths, profile descriptions,
/// logs or arbitrary system-error strings enter exported reports.
public struct DiagnosticScreen: Codable, Sendable {
    public let number: Int
    public let builtIn: Bool
    public let mode: ModeSpec
    public let controlPath: DiagnosticControlPath
    public let brightness: Double?
    public let hdrSupported: Bool
    public let hdrEnabled: Bool
    public let edrHeadroom: Double
    public let boost: Double
    public let metalBoost: Bool
    public let customColorProfile: Bool
    public init(number: Int, builtIn: Bool, mode: ModeSpec, controlPath: DiagnosticControlPath, brightness: Double?,
                hdrSupported: Bool, hdrEnabled: Bool, edrHeadroom: Double, boost: Double, metalBoost: Bool, customColorProfile: Bool) {
        self.number = number; self.builtIn = builtIn; self.mode = mode; self.controlPath = controlPath
        self.brightness = brightness.flatMap { $0.isFinite ? min(1, max(0, $0)) : nil }
        self.hdrSupported = hdrSupported; self.hdrEnabled = hdrEnabled
        self.edrHeadroom = edrHeadroom.isFinite ? max(1, edrHeadroom) : 1
        self.boost = boost.isFinite ? min(2, max(1, boost)) : 1
        self.metalBoost = metalBoost; self.customColorProfile = customColorProfile
    }
    public var observations: [String] {
        var messages: [String] = []
        if controlPath == .ddcReadOnly {
            messages.append("The display answers DDC queries, but its brightness readback did not change. A monitor preset may lock brightness; test the physical brightness control with HDR off. Some adapters also limit DDC writes.")
        } else if controlPath == .softwareOnly {
            messages.append("Hardware brightness was not detected. Check the monitor's DDC/CI setting and connection. Software dimming remains available; this does not identify a specific cable or monitor fault.")
        } else if controlPath == .checking {
            messages.append("Hardware discovery is not finished. Refresh before drawing conclusions about support.")
        }
        if !hdrSupported {
            messages.append("macOS does not expose this app's HDR switch for the active display/mode. This alone does not prove the panel lacks HDR capability.")
        } else if hdrEnabled && edrHeadroom <= 1.02 {
            messages.append("HDR is enabled, but no useful extra brightness headroom is currently reported. Peak panel specifications do not describe sustained full-screen output.")
        }
        if boost > 1 {
            messages.append(metalBoost ? "Metal boost is rendering the desktop locally. It adds latency and GPU work and tone-maps captured HDR content." : "Colour-curve boost is active. HDR highlights can clip and colour rendering can change.")
        }
        if customColorProfile {
            messages.append("A custom colour profile is assigned. Assignment does not verify that it was measured for the current monitor preset.")
        }
        if messages.isEmpty { messages.append("No compatibility issue is indicated by the current readings. Physical luminance and colour accuracy have not been measured.") }
        return messages
    }
}

public struct DiagnosticReport: Encodable, Sendable {
    public let formatVersion = 1
    public let appVersion: String
    public let macOSVersion: String
    public let screenCaptureAllowed: Bool
    public let accessibilityAllowed: Bool
    public let screens: [DiagnosticScreen]
    public init(appVersion: String, macOSVersion: String, screenCaptureAllowed: Bool, accessibilityAllowed: Bool, screens: [DiagnosticScreen]) {
        self.appVersion = Self.numericVersion(appVersion)
        self.macOSVersion = Self.numericVersion(macOSVersion)
        self.screenCaptureAllowed = screenCaptureAllowed; self.accessibilityAllowed = accessibilityAllowed; self.screens = screens
    }
    private static func numericVersion(_ value: String) -> String {
        guard !value.isEmpty, value.count < 40, value.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }) else { return "unknown" }
        return value
    }
    public func data() throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
}
