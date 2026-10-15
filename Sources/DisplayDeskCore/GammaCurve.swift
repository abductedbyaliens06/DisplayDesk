import Foundation

public enum GammaCurve {
    public enum Error: Swift.Error { case invalidTable, invalidFactor }
    /// Scale the captured channel curves; do not replace the display's existing
    /// channel calibration with an assumed linear ramp or accumulate prior boosts.
    public static func scaled(_ channels: [[Float]], factor: Double) throws -> [[Float]] {
        guard factor.isFinite, (1...2).contains(factor) else { throw Error.invalidFactor }
        guard channels.count == 3, let count = channels.first?.count, count >= 2,
              channels.allSatisfy({ $0.count == count && $0.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 4 } }) else { throw Error.invalidTable }
        return channels.map { $0.map { $0 * Float(factor) } }
    }
}
