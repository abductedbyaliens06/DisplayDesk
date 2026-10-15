import Foundation

public struct AutomaticProfileRule: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var profileID: UUID
    public var externalDisplayUUIDs: [String]
    public var enabled: Bool
    public init(id: UUID = UUID(), profileID: UUID, externalDisplayUUIDs: [String], enabled: Bool = true) {
        self.id = id; self.profileID = profileID
        self.externalDisplayUUIDs = Array(Set(externalDisplayUUIDs)).sorted(); self.enabled = enabled
    }
}

public struct AutomaticProfileConfiguration: Codable, Equatable, Sendable {
    public var enabled = false
    public var rules: [AutomaticProfileRule] = []
    public init() {}
    public func matchingProfile(externalDisplayUUIDs: [String], availableProfileIDs: Set<UUID>) -> UUID? {
        let connected = Set(externalDisplayUUIDs)
        guard enabled, !connected.isEmpty else { return nil }
        let matching = rules.filter {
            $0.enabled && availableProfileIDs.contains($0.profileID) && Set($0.externalDisplayUUIDs) == connected
        }
        // Ambiguous rules do not silently pick a profile based on file order.
        let ids = Set(matching.map(\.profileID))
        return ids.count == 1 ? ids.first : nil
    }
}

public struct AutomaticProfileStore {
    public let fileURL: URL
    public init(fileURL: URL) { self.fileURL = fileURL }
    public func load() throws -> AutomaticProfileConfiguration {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return AutomaticProfileConfiguration() }
        let configuration = try JSONDecoder().decode(AutomaticProfileConfiguration.self, from: Data(contentsOf: fileURL))
        try Self.validate(configuration)
        return configuration
    }
    public func save(_ configuration: AutomaticProfileConfiguration) throws {
        try Self.validate(configuration)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(configuration).write(to: fileURL, options: .atomic)
    }
    private static func validate(_ configuration: AutomaticProfileConfiguration) throws {
        guard Set(configuration.rules.map(\.id)).count == configuration.rules.count,
              configuration.rules.allSatisfy({ !$0.externalDisplayUUIDs.isEmpty && $0.externalDisplayUUIDs.allSatisfy { !$0.isEmpty } }) else {
            throw CocoaError(.fileReadCorruptFile)
        }
    }
}
