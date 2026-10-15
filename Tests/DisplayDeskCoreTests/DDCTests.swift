import XCTest
@testable import DisplayDeskCore

final class DDCTests: XCTestCase {
    func testBrightnessReplyValidatesCommandResultChecksumAndRange() {
        var reply: [UInt8] = [0x6e, 0x88, 2, 0, 0x10, 0, 0, 150, 0, 75]
        reply.append(reply.reduce(0x50, ^))
        let result = DDCCodec.decodeBrightnessReply(reply)
        XCTAssertEqual(result?.current, 75)
        XCTAssertEqual(result?.maximum, 150)
        reply[3] = 1
        reply[10] = Array(reply.prefix(10)).reduce(0x50, ^)
        XCTAssertNil(DDCCodec.decodeBrightnessReply(reply))
        reply[3] = 0; reply[4] = 0x12
        reply[10] = Array(reply.prefix(10)).reduce(0x50, ^)
        XCTAssertNil(DDCCodec.decodeBrightnessReply(reply))
        reply[4] = 0x10; reply[9] = 200
        reply[10] = Array(reply.prefix(10)).reduce(0x50, ^)
        XCTAssertNil(DDCCodec.decodeBrightnessReply(reply))
        reply[9] = 75; reply[10] = 0
        XCTAssertNil(DDCCodec.decodeBrightnessReply(reply))
    }
    func testOutgoingPacketChecksumsAndBrightnessEncoding() {
        let query = DDCCodec.queryBrightness()
        XCTAssertEqual(Array(query.prefix(3)), [0x82, 1, 0x10])
        XCTAssertEqual(query.reduce(UInt8(0x6e ^ 0x51), ^), 0)
        let write = DDCCodec.setBrightness(200)
        XCTAssertEqual(Array(write.prefix(5)), [0x84, 3, 0x10, 0, 200])
        XCTAssertEqual(write.reduce(UInt8(0x6e ^ 0x51), ^), 0)
    }
    func testIdenticalMonitorsRequireUniqueSerialMatching() {
        let first = DDCIdentity(vendor: 10, model: 20, serial: 123)
        let second = DDCIdentity(vendor: 10, model: 20, serial: 456)
        XCTAssertEqual(DDCCodec.serviceIndex(target: second, candidates: [first, second], activeSameModelCount: 2), 1)
        let noSerial = DDCIdentity(vendor: 10, model: 20, serial: 0)
        XCTAssertNil(DDCCodec.serviceIndex(target: noSerial, candidates: [first, second], activeSameModelCount: 2))
        XCTAssertNil(DDCCodec.serviceIndex(target: noSerial, candidates: [first], activeSameModelCount: 2))
        XCTAssertNil(DDCCodec.serviceIndex(target: first, candidates: [first, first], activeSameModelCount: 1))
        XCTAssertEqual(DDCCodec.serviceIndex(target: noSerial, candidates: [first], activeSameModelCount: 1), 0)
    }
    func testEDIDRequiresValidHeaderAndBaseBlockChecksum() {
        var edid = [UInt8](repeating: 0, count: 128)
        edid.replaceSubrange(0..<8, with: [0, 255, 255, 255, 255, 255, 255, 0])
        edid[8] = 0x06; edid[9] = 0x10; edid[10] = 0x34; edid[11] = 0x12
        edid[12] = 0x78; edid[13] = 0x56; edid[14] = 0x34; edid[15] = 0x12
        edid[127] = UInt8(truncatingIfNeeded: 256 - edid.prefix(127).reduce(0, { $0 + Int($1) }) % 256)
        XCTAssertEqual(DDCIdentity.decodeEDID(Data(edid)), DDCIdentity(vendor: 0x0610, model: 0x1234, serial: 0x12345678))
        edid[20] = 1
        XCTAssertNil(DDCIdentity.decodeEDID(Data(edid)))
        XCTAssertNil(DDCIdentity.decodeEDID(Data([0, 1, 2])))
    }
}
