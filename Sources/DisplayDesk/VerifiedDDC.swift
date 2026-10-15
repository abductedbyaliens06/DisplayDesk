import CoreGraphics
import Foundation
import IOKit
import DisplayDeskCore

/// Apple Silicon DDC brightness with validated EDID identity and protocol replies.
/// Unsupported or ambiguous routes fail closed instead of addressing another screen.
final class VerifiedDDC {
    private typealias Create = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
    private typealias Read = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn
    private typealias Write = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn
    private struct Route {
        let service: CFTypeRef
        let chip: UInt32
    }
    private typealias DisplayInfo = @convention(c) (CGDirectDisplayID) -> Unmanaged<CFDictionary>?
    private let coreDisplayHandle: UnsafeMutableRawPointer?
    private let displayInfo: DisplayInfo?
    private let handle: UnsafeMutableRawPointer?
    private let create: Create?
    private let readI2C: Read?
    private let writeI2C: Write?

    init() {
        let core = dlopen("/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay", RTLD_LAZY)
        coreDisplayHandle = core
        displayInfo = core.flatMap { dlsym($0, "CoreDisplay_DisplayCreateInfoDictionary") }.map { unsafeBitCast($0, to: DisplayInfo.self) }
        let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY)
        self.handle = handle
        create = handle.flatMap { dlsym($0, "IOAVServiceCreateWithService") }.map { unsafeBitCast($0, to: Create.self) }
        readI2C = handle.flatMap { dlsym($0, "IOAVServiceReadI2C") }.map { unsafeBitCast($0, to: Read.self) }
        writeI2C = handle.flatMap { dlsym($0, "IOAVServiceWriteI2C") }.map { unsafeBitCast($0, to: Write.self) }
    }
    deinit { if let handle { dlclose(handle) }; if let coreDisplayHandle { dlclose(coreDisplayHandle) } }

    func readBrightness(_ id: CGDirectDisplayID) -> Double? {
        for _ in 0..<2 {
            if let service = service(for: id), let reply = query(service) {
                return Double(reply.current) / Double(reply.maximum)
            }
            usleep(150_000)
        }
        return nil
    }
    func setBrightness(_ id: CGDirectDisplayID, value: Double) throws -> Double {
        guard let service = service(for: id), let reply = query(service),
              value.isFinite, let writeI2C else {
            throw DisplayControlError.unavailable("DDC/CI brightness could not be verified for this display. Check its connection and DDC/CI setting.")
        }
        let raw = UInt16((min(1, max(0, value)) * Double(reply.maximum)).rounded())
        // Use the same transport checksum compatibility as queries. Successful I2C
        // delivery alone does not mean the monitor accepted the DDC packet.
        for transportSuppliesSource in [false, true] {
            try Task.checkCancellation()
            var bytes = DDCCodec.setBrightness(raw)
            if transportSuppliesSource { bytes[bytes.count - 1] ^= 0x51 }
            for _ in 0..<3 {
                try Task.checkCancellation()
                usleep(60_000)
                let result = bytes.withUnsafeMutableBytes { writeI2C(service.service, service.chip, 0x51, $0.baseAddress!, UInt32($0.count)) }
                guard result == KERN_SUCCESS else { throw DisplayControlError.unavailable("The monitor rejected the DDC/CI brightness command.") }
            }
            // Some monitors acknowledge before applying their backlight setting.
            // Allow readback to settle before trying the other packet variant.
            var receivedReply = false
            for _ in 0..<3 {
                usleep(200_000)
                if let observed = query(service) {
                    receivedReply = true
                    if observed.current != reply.current || raw == reply.current {
                        return Double(observed.current) / Double(observed.maximum)
                    }
                }
            }
            if !receivedReply {
                throw DisplayControlError.unavailable("The brightness command was sent, but the monitor did not return a verification reading.")
            }
        }
        throw DisplayControlError.brightnessIgnored
    }
    private func query(_ route: Route) -> (current: UInt16, maximum: UInt16)? {
        guard let readI2C, let writeI2C else { return nil }
        // Some IOAV transports account for the 0x51 sub-address in the query checksum.
        for transportSuppliesSource in [false, true, false, true, false, true] {
            var command = DDCCodec.queryBrightness()
            if transportSuppliesSource { command[3] ^= 0x51 }
            usleep(60_000)
            guard command.withUnsafeMutableBytes({ writeI2C(route.service, route.chip, 0x51, $0.baseAddress!, UInt32($0.count)) }) == KERN_SUCCESS else { continue }
            usleep(route.chip == 0xb7 ? 150_000 : 100_000)
            var reply = [UInt8](repeating: 0, count: 12)
            guard reply.withUnsafeMutableBytes({ readI2C(route.service, route.chip, 0x51, $0.baseAddress!, UInt32($0.count)) }) == KERN_SUCCESS else { continue }
            if let decoded = DDCCodec.decodeBrightnessReply(Array(reply.prefix(11))) { return decoded }
        }
        return nil
    }
    /// Resolve the exact OS-provided framebuffer, including modern proxies without EDID properties.
    private func framebufferRoute(_ id: CGDirectDisplayID) -> Route? {
        guard let create, let info = displayInfo?(id)?.takeRetainedValue() as? [String: Any],
              let path = info["IODisplayLocation"] as? String else { return nil }
        let framebuffer = path.withCString { IORegistryEntryFromPath(kIOMainPortDefault, $0) }
        guard framebuffer != 0 else { return nil }
        defer { IOObjectRelease(framebuffer) }
        var targetID: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(framebuffer, &targetID) == KERN_SUCCESS else { return nil }
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        guard root != 0 else { return nil }
        defer { IOObjectRelease(root) }
        var iterator: io_iterator_t = 0
        guard IORegistryEntryCreateIterator(root, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var belongsToTarget = false
        var routes: [Route] = []
        var entry = IOIteratorNext(iterator)
        while entry != 0 {
            defer { IOObjectRelease(entry); entry = IOIteratorNext(iterator) }
            if IOObjectConformsTo(entry, "IOMobileFramebuffer") != 0 {
                var currentID: UInt64 = 0
                belongsToTarget = IORegistryEntryGetRegistryEntryID(entry, &currentID) == KERN_SUCCESS && currentID == targetID
                continue
            }
            guard belongsToTarget, IOObjectConformsTo(entry, "DCPAVServiceProxy") != 0,
                  let location = IORegistryEntryCreateCFProperty(entry, "Location" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String,
                  location == "External", let service = create(kCFAllocatorDefault, entry)?.takeRetainedValue() else { continue }
            var parent: io_registry_entry_t = 0
            var chip: UInt32 = 0x37
            if IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent) == KERN_SUCCESS {
                if let provider = IORegistryEntryCreateCFProperty(parent, "EPICProviderClass" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String,
                   provider == "AppleDCPMCDP29XX" { chip = 0xb7 }
                IOObjectRelease(parent)
            }
            routes.append(Route(service: service, chip: chip))
        }
        return routes.count == 1 ? routes[0] : nil
    }

    private func service(for id: CGDirectDisplayID) -> Route? {
        #if arch(arm64)
        guard CGDisplayIsBuiltin(id) == 0, let create else { return nil }
        if let direct = framebufferRoute(id) { return direct }
        let target = DDCIdentity(vendor: CGDisplayVendorNumber(id), model: CGDisplayModelNumber(id), serial: CGDisplaySerialNumber(id))
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"), &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var candidates: [(DDCIdentity, CFTypeRef)] = []
        var entry = IOIteratorNext(iterator)
        while entry != 0 {
            defer { IOObjectRelease(entry); entry = IOIteratorNext(iterator) }
            var properties: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(entry, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let dictionary = properties?.takeRetainedValue() as? [String: Any],
                  let edid = dictionary["EDID"] as? Data, let identity = DDCIdentity.decodeEDID(edid) else { continue }
            let location = (dictionary["Location"] as? String ?? "").lowercased()
            guard !location.contains("embedded"), !location.contains("internal"),
                  identity.vendor == target.vendor, identity.model == target.model,
                  let service = create(kCFAllocatorDefault, entry)?.takeRetainedValue() else { continue }
            candidates.append((identity, service))
        }
        var ids = [CGDirectDisplayID](repeating: 0, count: 32); var count: UInt32 = 0
        guard CGGetOnlineDisplayList(32, &ids, &count) == .success else { return nil }
        let sameModel = ids.prefix(Int(count)).filter {
            CGDisplayIsBuiltin($0) == 0 && CGDisplayVendorNumber($0) == target.vendor && CGDisplayModelNumber($0) == target.model
        }.count
        guard let index = DDCCodec.serviceIndex(target: target, candidates: candidates.map(\.0), activeSameModelCount: sameModel) else { return nil }
        return Route(service: candidates[index].1, chip: 0x37)
        #else
        return nil
        #endif
    }
}
