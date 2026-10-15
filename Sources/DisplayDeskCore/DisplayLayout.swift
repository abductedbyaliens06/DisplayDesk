import Foundation

public struct DisplayPlacement: Codable, Equatable, Sendable {
    public var x: Int
    public var y: Int
    public var isMain: Bool
    public init(x: Int, y: Int, isMain: Bool = false) { self.x = x; self.y = y; self.isMain = isMain }
}

public struct LayoutScreen: Identifiable, Equatable, Sendable {
    public var id: String
    public var width: Int
    public var height: Int
    public var placement: DisplayPlacement
    public init(id: String, width: Int, height: Int, placement: DisplayPlacement) {
        self.id = id; self.width = width; self.height = height; self.placement = placement
    }
}

public enum DisplayLayout {
    public enum LayoutError: LocalizedError {
        case invalid, main, overlap, disconnected
        public var errorDescription: String? {
            switch self {
            case .invalid: return "The layout contains invalid display coordinates or dimensions."
            case .main: return "Choose one main display at the layout origin."
            case .overlap: return "Displays cannot overlap. Move them until their edges meet."
            case .disconnected: return "Every display must share an edge with another display so the pointer can travel between them."
            }
        }
    }
    private static func bounded(_ screens: [LayoutScreen]) -> Bool {
        !screens.isEmpty && Set(screens.map(\.id)).count == screens.count && screens.allSatisfy {
            !$0.id.isEmpty && (1...100_000).contains($0.width) && (1...100_000).contains($0.height)
                && (-100_000...100_000).contains($0.placement.x) && (-100_000...100_000).contains($0.placement.y)
        }
    }
    public static func normalized(_ screens: [LayoutScreen], mainID: String) throws -> [LayoutScreen] {
        guard bounded(screens), let main = screens.first(where: { $0.id == mainID }) else { throw LayoutError.invalid }
        return screens.map {
            var screen = $0
            screen.placement = DisplayPlacement(x: $0.placement.x - main.placement.x, y: $0.placement.y - main.placement.y, isMain: $0.id == mainID)
            return screen
        }
    }
    public static func validate(_ screens: [LayoutScreen]) throws {
        guard bounded(screens) else { throw LayoutError.invalid }
        let main = screens.filter { $0.placement.isMain }
        guard main.count == 1, main[0].placement.x == 0, main[0].placement.y == 0 else { throw LayoutError.main }
        var neighbors = [String: Set<String>]()
        for (index, a) in screens.enumerated() {
            for b in screens.dropFirst(index + 1) {
                let xOverlap = min(a.placement.x + a.width, b.placement.x + b.width) - max(a.placement.x, b.placement.x)
                let yOverlap = min(a.placement.y + a.height, b.placement.y + b.height) - max(a.placement.y, b.placement.y)
                if xOverlap > 0 && yOverlap > 0 { throw LayoutError.overlap }
                if (xOverlap == 0 && yOverlap > 0) || (yOverlap == 0 && xOverlap > 0) {
                    neighbors[a.id, default: []].insert(b.id); neighbors[b.id, default: []].insert(a.id)
                }
            }
        }
        var visited: Set<String> = []; var queue = [main[0].id]
        while let id = queue.popLast() {
            if visited.insert(id).inserted { queue.append(contentsOf: neighbors[id, default: []]) }
        }
        guard visited.count == screens.count else { throw LayoutError.disconnected }
    }
    /// Snap to a nearby edge, then align perpendicular edges when they are close.
    public static func snapped(_ moving: LayoutScreen, among screens: [LayoutScreen], distance: Int = 50) -> DisplayPlacement {
        guard bounded([moving]), bounded(screens), (0...1000).contains(distance) else { return moving.placement }
        let p = moving.placement
        var candidates: [(Int, DisplayPlacement)] = []
        for other in screens where other.id != moving.id {
            let q = other.placement
            for x in [q.x - moving.width, q.x + other.width] where abs(x - p.x) <= distance {
                let y = [q.y, q.y + other.height - moving.height].min(by: { abs($0 - p.y) < abs($1 - p.y) })!
                let alignedY = abs(y - p.y) <= distance ? y : p.y
                if min(alignedY + moving.height, q.y + other.height) > max(alignedY, q.y) {
                    candidates.append((abs(x - p.x) + abs(alignedY - p.y), .init(x: x, y: alignedY, isMain: p.isMain)))
                }
            }
            for y in [q.y - moving.height, q.y + other.height] where abs(y - p.y) <= distance {
                let x = [q.x, q.x + other.width - moving.width].min(by: { abs($0 - p.x) < abs($1 - p.x) })!
                let alignedX = abs(x - p.x) <= distance ? x : p.x
                if min(alignedX + moving.width, q.x + other.width) > max(alignedX, q.x) {
                    candidates.append((abs(y - p.y) + abs(alignedX - p.x), .init(x: alignedX, y: y, isMain: p.isMain)))
                }
            }
        }
        return candidates.min(by: { $0.0 < $1.0 })?.1 ?? p
    }
}
