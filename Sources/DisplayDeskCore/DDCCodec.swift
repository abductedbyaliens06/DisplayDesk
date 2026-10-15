import Foundation

public struct DDCIdentity: Equatable, Sendable {
    public let vendor: UInt32
    public let model: UInt32
    public let serial: UInt32
    public init(vendor: UInt32, model: UInt32, serial: UInt32) {
        self.vendor = vendor; self.model = model; self.serial = serial
    }
    public static func decodeEDID(_ data: Data) -> DDCIdentity? {
        let bytes = Array(data)
        guard bytes.count >= 128,
              Array(bytes.prefix(8)) == [0, 255, 255, 255, 255, 255, 255, 0],
              bytes.prefix(128).reduce(UInt32(0), { $0 + UInt32($1) }) % 256 == 0 else { return nil }
        let serial = bytes[12..<16].enumerated().reduce(UInt32(0)) { $0 | (UInt32($1.element) << ($1.offset * 8)) }
        return DDCIdentity(vendor: UInt32(bytes[8]) << 8 | UInt32(bytes[9]),
                           model: UInt32(bytes[11]) << 8 | UInt32(bytes[10]), serial: serial)
    }
}

public enum DDCCodec {
    public static func queryBrightness() -> [UInt8] { packet([0x82, 0x01, 0x10]) }
    public static func setBrightness(_ value: UInt16) -> [UInt8] {
        packet([0x84, 0x03, 0x10, UInt8(value >> 8), UInt8(value & 0xff)])
    }
    private static func packet(_ payload: [UInt8]) -> [UInt8] {
        payload + [payload.reduce(UInt8(0x6e ^ 0x51), ^)]
    }
    public static func decodeBrightnessReply(_ bytes: [UInt8]) -> (current: UInt16, maximum: UInt16)? {
        guard bytes.count == 11, bytes[0] == 0x6e, bytes[1] == 0x88, bytes[2] == 0x02,
              bytes[3] == 0, bytes[4] == 0x10, bytes.reduce(UInt8(0x50), ^) == 0 else { return nil }
        let maximum = UInt16(bytes[6]) << 8 | UInt16(bytes[7])
        let current = UInt16(bytes[8]) << 8 | UInt16(bytes[9])
        guard maximum > 0, current <= maximum else { return nil }
        return (current, maximum)
    }
    /// Never choose the first vendor/model match when two identical monitors are attached.
    public static func serviceIndex(target: DDCIdentity, candidates: [DDCIdentity], activeSameModelCount: Int) -> Int? {
        let matching = candidates.indices.filter { candidates[$0].vendor == target.vendor && candidates[$0].model == target.model }
        if target.serial != 0 {
            let serialMatches = matching.filter { candidates[$0].serial == target.serial }
            return serialMatches.count == 1 ? serialMatches[0] : nil
        }
        return activeSameModelCount == 1 && matching.count == 1 ? matching[0] : nil
    }
}
