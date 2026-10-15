import Foundation

public struct ModeSpec: Codable, Hashable, Sendable, Identifiable {
    public var width: Int
    public var height: Int
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var refreshRate: Double
    public var id: String { "\(width)x\(height)-\(pixelWidth)x\(pixelHeight)-\(Int((refreshRate * 100).rounded()))" }
    public var isHiDPI: Bool { pixelWidth > width || pixelHeight > height }
    public var resolutionID: String { "\(width)x\(height)-\(pixelWidth)x\(pixelHeight)" }
    public var refreshLabel: String {
        refreshRate <= 0 ? "Adaptive / Default" : String(format: "%g Hz", (refreshRate * 100).rounded() / 100)
    }
    public var resolutionLabel: String { "\(width) × \(height)\(isHiDPI ? " · HiDPI" : "")" }
    public init(width: Int, height: Int, pixelWidth: Int, pixelHeight: Int, refreshRate: Double) {
        self.width = width; self.height = height; self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight; self.refreshRate = refreshRate
    }
    public func matches(_ other: ModeSpec) -> Bool {
        resolutionID == other.resolutionID && abs(refreshRate - other.refreshRate) < 0.005
    }
}

public struct DisplaySetting: Codable, Equatable, Sendable {
    public var displayUUID: String
    public var name: String
    public var mode: ModeSpec
    public var brightness: Double?
    public var dimming: Double
    public var colorProfilePath: String?
    public var hdrEnabled: Bool?
    public var hdrBoost: Double?
    public var placement: DisplayPlacement?
    public var hdrBoostMethod: String?
    public init(displayUUID: String, name: String, mode: ModeSpec, brightness: Double?, dimming: Double,
                colorProfilePath: String? = nil, hdrEnabled: Bool? = nil, hdrBoost: Double? = nil, hdrBoostMethod: String? = nil, placement: DisplayPlacement? = nil) {
        self.displayUUID = displayUUID; self.name = name; self.mode = mode
        self.brightness = brightness; self.dimming = dimming
        self.colorProfilePath = colorProfilePath; self.hdrEnabled = hdrEnabled; self.hdrBoost = hdrBoost
        self.hdrBoostMethod = hdrBoostMethod; self.placement = placement
    }
}

public struct DisplayProfile: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var settings: [DisplaySetting]
    public var createdAt: Date
    public init(id: UUID = UUID(), name: String, settings: [DisplaySetting], createdAt: Date = Date()) {
        self.id = id; self.name = name; self.settings = settings; self.createdAt = createdAt
    }
}

public enum ProfileError: LocalizedError {
    case emptyName, duplicateName, invalidSettings
    public var errorDescription: String? {
        switch self {
        case .emptyName: return "Give your profile a name."
        case .duplicateName: return "A profile with that name already exists."
        case .invalidSettings: return "The profile contains invalid brightness or display values."
        }
    }
}

public struct ProfileStore: Sendable {
    public let fileURL: URL
    public init(fileURL: URL) { self.fileURL = fileURL }
    public func load() throws -> [DisplayProfile] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let profiles = try JSONDecoder().decode([DisplayProfile].self, from: Data(contentsOf: fileURL))
        for profile in profiles { try Self.validate(profile) }
        return profiles
    }
    public func save(_ profiles: [DisplayProfile]) throws {
        for profile in profiles { try Self.validate(profile) }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(profiles).write(to: fileURL, options: .atomic)
    }
    public static func makeProfile(name: String, settings: [DisplaySetting], existing: [DisplayProfile]) throws -> DisplayProfile {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { throw ProfileError.emptyName }
        guard !existing.contains(where: { $0.name.caseInsensitiveCompare(cleaned) == .orderedSame }) else { throw ProfileError.duplicateName }
        let profile = DisplayProfile(name: cleaned, settings: settings)
        try validate(profile)
        return profile
    }
    public static func validate(_ profile: DisplayProfile) throws {
        guard !profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ProfileError.emptyName }
        guard !profile.settings.isEmpty,
              Set(profile.settings.map(\.displayUUID)).count == profile.settings.count,
              profile.settings.allSatisfy({ setting in
                  !setting.displayUUID.isEmpty && setting.mode.width > 0 && setting.mode.height > 0
                    && setting.mode.pixelWidth > 0 && setting.mode.pixelHeight > 0
                    && setting.mode.refreshRate.isFinite && setting.mode.refreshRate >= 0
                    && setting.dimming.isFinite && (0...0.8).contains(setting.dimming)
                    && (setting.brightness.map { $0.isFinite && (0...1).contains($0) } ?? true)
                    && (setting.hdrBoost.map { $0.isFinite && (1...2).contains($0) && ($0 == 1 || setting.hdrEnabled == true) } ?? true)
                    && (setting.colorProfilePath.map { $0 == "factory" || $0.hasPrefix("/") } ?? true)
                    && (setting.hdrBoostMethod.map { ["metal", "curves"].contains($0) } ?? true)
              }) else { throw ProfileError.invalidSettings }
        if profile.settings.contains(where: { $0.placement != nil }) {
            guard profile.settings.allSatisfy({ $0.placement != nil }) else { throw ProfileError.invalidSettings }
            try DisplayLayout.validate(profile.settings.map {
                LayoutScreen(id: $0.displayUUID, width: $0.mode.width, height: $0.mode.height, placement: $0.placement!)
            })
        }
    }
}

/// Matches persistent display identities, never a transient display index or name.
public enum ProfilePlan {
    public static func resolved(_ profile: DisplayProfile, available: [DisplaySetting], modes: [String: [ModeSpec]]) throws -> [DisplaySetting] {
        try ProfileStore.validate(profile)
        if profile.settings.contains(where: { $0.placement != nil }),
           Set(profile.settings.map(\.displayUUID)) != Set(available.map(\.displayUUID)) {
            throw PlanError.arrangementMismatch
        }
        return try profile.settings.map { saved in
            guard let display = available.first(where: { $0.displayUUID == saved.displayUUID }) else {
                throw PlanError.disconnected(saved.name)
            }
            guard let supported = modes[display.displayUUID]?.first(where: { $0.matches(saved.mode) }) else {
                throw PlanError.unsupported(saved.name)
            }
            var result = saved; result.mode = supported; return result
        }
    }
    public enum PlanError: LocalizedError {
        case disconnected(String), unsupported(String), arrangementMismatch
        public var errorDescription: String? {
            switch self {
            case .arrangementMismatch: return "Connect exactly the displays saved in this layout before applying this profile."
            case .disconnected(let name): return "Connect \(name) before applying this profile."
            case .unsupported(let name): return "The saved resolution/refresh rate is no longer available on \(name)."
            }
        }
    }
}
