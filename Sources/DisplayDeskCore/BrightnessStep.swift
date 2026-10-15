import Foundation

public enum BrightnessStep {
    public static func hardware(current: Double, delta: Double) -> Double? {
        guard current.isFinite, delta.isFinite else { return nil }
        return min(1, max(0, current + delta))
    }
    /// Software-only screens have 0–80% dimming, corresponding to 100–20%
    /// visible image. Increasing brightness removes dimming; it never starts HDR.
    public static func dimming(current: Double, delta: Double) -> Double? {
        guard current.isFinite, delta.isFinite else { return nil }
        return min(0.8, max(0, current - delta))
    }
}
