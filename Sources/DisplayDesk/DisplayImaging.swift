import AppKit
@preconcurrency import ColorSync
import CoreGraphics
import Metal
import QuartzCore
import DisplayDeskCore

struct ColorProfileChoice: Identifiable, Equatable {
    static let factoryID = "factory"
    let id: String
    let name: String
    let url: URL?
}

struct ImagingState {
    var profileID = ColorProfileChoice.factoryID
    var profileName = "Display default"
    var hdrSupported = false
    var hdrEnabled = false
    var headroom = 1.0
    var boost = 1.0
    var boostMethod = "curves"
}

struct ImagingBackup {
    let profileID: String
    let hdrEnabled: Bool
    let boost: Double
    let boostMethod: String
}

/// HDR switching is private Apple SPI. Resolve it dynamically and verify state
/// instead of assuming that a successful call changed the physical display.
@MainActor
final class DisplayImaging {
    private typealias HDRRead = @convention(c) (CGDirectDisplayID) -> Bool
    private typealias HDRWrite = @convention(c) (CGDirectDisplayID, Bool) -> Void
    private let handle: UnsafeMutableRawPointer?
    private let supportsHDR: HDRRead?
    private let readsHDR: HDRRead?
    private let writesHDR: HDRWrite?
    private var boosts: [CGDirectDisplayID: BoostSession] = [:]
    private var metalBoosts: [CGDirectDisplayID: MetalDesktopBoost] = [:]
    private var generation = UUID()
    private var originals: [String: ImagingBackup] = [:]

    init() {
        let handle = dlopen("/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay", RTLD_LAZY)
        self.handle = handle
        supportsHDR = handle.flatMap { dlsym($0, "CoreDisplay_Display_SupportsHDRMode") }.map { unsafeBitCast($0, to: HDRRead.self) }
        readsHDR = handle.flatMap { dlsym($0, "CoreDisplay_Display_IsHDRModeEnabled") }.map { unsafeBitCast($0, to: HDRRead.self) }
        writesHDR = handle.flatMap { dlsym($0, "CoreDisplay_Display_SetHDRModeEnabled") }.map { unsafeBitCast($0, to: HDRWrite.self) }
    }
    isolated deinit { if let handle { dlclose(handle) } }

    private func screen(_ id: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == id }
    }
    func state(_ id: CGDirectDisplayID) -> ImagingState {
        let profile = currentProfile(id)
        return ImagingState(profileID: profile.id, profileName: profile.name,
                            hdrSupported: supportsHDR?(id) == true && writesHDR != nil,
                            hdrEnabled: readsHDR?(id) == true,
                            headroom: Double(screen(id)?.maximumExtendedDynamicRangeColorComponentValue ?? 1),
                            boost: metalBoosts[id]?.factor ?? boosts[id]?.factor ?? 1,
                            boostMethod: metalBoosts[id] != nil ? "metal" : "curves")
    }
    func backup(_ id: CGDirectDisplayID) -> ImagingBackup {
        let current = state(id)
        return ImagingBackup(profileID: current.profileID, hdrEnabled: current.hdrEnabled, boost: current.boost, boostMethod: current.boostMethod)
    }
    func remember(_ id: CGDirectDisplayID, uuid: String) {
        if originals[uuid] == nil { originals[uuid] = backup(id) }
    }
    func original(_ uuid: String) -> ImagingBackup? { originals[uuid] }

    private func customProfile(_ id: CGDirectDisplayID) -> URL? {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue(),
              let info = ColorSyncDeviceCopyDeviceInfo(kColorSyncDisplayDeviceClass.takeUnretainedValue(), uuid)?.takeRetainedValue() as? [String: Any],
              let custom = info[kColorSyncCustomProfiles.takeUnretainedValue() as String] as? [String: Any] else { return nil }
        let defaultKey = kColorSyncDeviceDefaultProfileID.takeUnretainedValue() as String
        if let url = custom[defaultKey] as? URL { return url }
        let factory = info[kColorSyncFactoryProfiles.takeUnretainedValue() as String] as? [String: Any]
        if let profileID = factory?[defaultKey] as? String { return custom[profileID] as? URL }
        return nil
    }
    private func currentProfile(_ id: CGDirectDisplayID) -> ColorProfileChoice {
        let assigned = customProfile(id)
        let profile = ColorSyncProfileCreateWithDisplayID(id)?.takeRetainedValue()
        let name = profile.flatMap { ColorSyncProfileCopyDescriptionString($0)?.takeRetainedValue() as String? } ?? "Display default"
        return ColorProfileChoice(id: assigned?.path ?? ColorProfileChoice.factoryID, name: name, url: assigned)
    }
    static func profileChoice(_ url: URL) -> ColorProfileChoice? {
        guard url.isFileURL, let data = try? Data(contentsOf: url), data.count >= 128,
              String(data: data[12..<16], encoding: .ascii) == "mntr",
              String(data: data[16..<20], encoding: .ascii) == "RGB ",
              let profile = ColorSyncProfileCreateWithURL(url as CFURL, nil)?.takeRetainedValue(),
              ColorSyncProfileVerify(profile, nil, nil) else { return nil }
        let name = ColorSyncProfileCopyDescriptionString(profile)?.takeRetainedValue() as String? ?? url.deletingPathExtension().lastPathComponent
        return ColorProfileChoice(id: url.path, name: name, url: url)
    }
    func profiles(_ id: CGDirectDisplayID) -> [ColorProfileChoice] {
        var choices = [ColorProfileChoice(id: ColorProfileChoice.factoryID, name: "Display default (EDID)", url: nil)]
        let roots = [URL(fileURLWithPath: "/System/Library/ColorSync/Profiles"), URL(fileURLWithPath: "/Library/ColorSync/Profiles"),
                     FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/ColorSync/Profiles"),
                     FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("DisplayDesk/ColorProfiles")]
        var seen = Set<String>()
        let current = currentProfile(id)
        if current.url != nil { choices.append(current); seen.insert(current.id) }
        for root in roots {
            guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in files where ["icc", "icm"].contains(url.pathExtension.lowercased()) {
                if seen.insert(url.path).inserted, let choice = Self.profileChoice(url) { choices.append(choice) }
            }
        }
        return [choices[0]] + choices.dropFirst().sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    func importProfile(_ url: URL) throws -> ColorProfileChoice {
        guard Self.profileChoice(url) != nil else { throw DisplayControlError.unavailable("Choose a valid RGB display ICC/ICM profile, not a printer or abstract effects profile.") }
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("DisplayDesk/ColorProfiles")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent("\(UUID().uuidString).icc")
        try FileManager.default.copyItem(at: url, to: destination)
        guard let choice = Self.profileChoice(destination) else { throw DisplayControlError.unavailable("The imported profile could not be read.") }
        return choice
    }
    func setProfile(_ id: CGDirectDisplayID, choiceID: String) throws {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { throw DisplayControlError.unavailable("This display has no ColorSync identity.") }
        let value: Any
        if choiceID == ColorProfileChoice.factoryID { value = kCFNull! }
        else {
            let url = URL(fileURLWithPath: choiceID)
            guard Self.profileChoice(url) != nil else { throw DisplayControlError.unavailable("The saved display colour profile is missing or invalid. Import it again.") }
            value = url
        }
        let dictionary = [kColorSyncDeviceDefaultProfileID.takeUnretainedValue() as String: value,
                          kColorSyncProfileUserScope.takeUnretainedValue() as String: kCFPreferencesCurrentUser] as CFDictionary
        guard ColorSyncDeviceSetCustomProfiles(kColorSyncDisplayDeviceClass.takeUnretainedValue(), uuid, dictionary) else {
            throw DisplayControlError.unavailable("macOS did not accept the colour profile for this display.")
        }
    }
    func setHDR(_ id: CGDirectDisplayID, enabled: Bool) async throws {
        guard state(id).hdrEnabled != enabled else { return }
        guard supportsHDR?(id) == true, let writesHDR else { throw DisplayControlError.unavailable("HDR switching is unavailable for this display or macOS version.") }
        try stopBoost(id)
        writesHDR(id, enabled)
        try await Task.sleep(for: .milliseconds(900))
        guard readsHDR?(id) == enabled else { throw DisplayControlError.unavailable("macOS did not switch HDR. Check the monitor's HDR setting and active display mode.") }
    }
    func setBoost(_ id: CGDirectDisplayID, factor: Double, useMetal: Bool = false) async throws {
        let requestGeneration = generation
        guard factor.isFinite, (1...2).contains(factor) else { throw DisplayControlError.unavailable("HDR boost must be between 100% and 200%.") }
        if factor <= 1.001 { try stopBoost(id); return }
        guard readsHDR?(id) == true, let screen = screen(id) else { throw DisplayControlError.unavailable("Enable HDR first. SDR gamma brightening cannot unlock the panel's HDR brightness.") }
        if useMetal || metalBoosts[id] != nil {
            guard CGPreflightScreenCaptureAccess() else { throw DisplayControlError.unavailable("Metal boost needs Screen Recording permission. Click Allow Screen Recording, approve Display Desk in System Settings, and restart it if requested.") }
            if let active = metalBoosts[id] {
                let headroom = Double(screen.maximumExtendedDynamicRangeColorComponentValue)
                guard headroom > 1.02 else { try stopBoost(id); throw DisplayControlError.unavailable("No HDR brightness headroom is currently available.") }
                active.factor = min(factor, headroom); return
            }
            try stopBoost(id)
            let session = try MetalDesktopBoost(screen: screen)
            session.factor = factor
            metalBoosts[id] = session
            do {
                try await session.start(displayID: id, excludedWindowIDs: Set(metalBoosts.values.map(\.windowID)))
                guard generation == requestGeneration else { throw CancellationError() }
                let headroom = Double(self.screen(id)?.maximumExtendedDynamicRangeColorComponentValue ?? 1)
                guard headroom > 1.02 else { throw DisplayControlError.unavailable("The display has no active HDR headroom for Metal boost.") }
                session.factor = min(factor, headroom)
            } catch { session.close(); metalBoosts[id] = nil; throw error }
            return
        }
        let session: BoostSession
        if let existing = boosts[id] { session = existing }
        else {
            session = try BoostSession(screen: screen)
            boosts[id] = session
        }
        do {
            try await Task.sleep(for: .milliseconds(350))
            guard generation == requestGeneration else { throw CancellationError() }
            let headroom = Double(self.screen(id)?.maximumExtendedDynamicRangeColorComponentValue ?? 1)
            guard headroom > 1.02 else { throw DisplayControlError.unavailable("No active HDR brightness headroom is reported. Boost was not applied.") }
            try session.apply(id, factor: min(factor, headroom))
        } catch { try? stopBoost(id); throw error }
    }
    func stopBoost(_ id: CGDirectDisplayID) throws {
        if let session = metalBoosts.removeValue(forKey: id) { session.close() }
        guard let session = boosts[id] else { return }
        try session.restore(id)
        session.close(); boosts[id] = nil
    }
    /// No continuous rewriting: another app or a system profile change owns its
    /// new table. Yield control rather than fighting it with a timer.
    func reconcile(connected: Set<CGDirectDisplayID>) -> Bool {
        var changed = false
        for (id, session) in metalBoosts where !connected.contains(id) || readsHDR?(id) != true || session.failed || !session.matches(screen: screen(id)) {
            session.close(); metalBoosts[id] = nil; changed = true
        }
        for (id, session) in boosts {
            if !connected.contains(id) { session.close(); boosts[id] = nil; changed = true }
            else if readsHDR?(id) != true || !session.isCurrent(id) {
                try? stopBoost(id); changed = true
            }
        }
        return changed
    }
    func stopAllBoosts() throws {
        generation = UUID()
        for id in Set(boosts.keys).union(metalBoosts.keys) { try stopBoost(id) }
    }
}

@MainActor
private final class BoostSession {
    private let window: NSWindow
    private let baseline: GammaTable
    private var applied: GammaTable?
    var factor = 1.0

    init(screen: NSScreen) throws {
        guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
              let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw DisplayControlError.unavailable("Metal is unavailable for HDR brightness activation.")
        }
        baseline = try GammaTable.read(id)
        guard baseline.channels.flatMap({ $0 }).allSatisfy({ $0 <= 1.01 }) else {
            throw DisplayControlError.unavailable("Another colour adjustment already extends this display's colour curves. Disable it before starting HDR boost.")
        }
        let layer = CAMetalLayer()
        layer.device = device; layer.pixelFormat = .rgba16Float
        layer.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
        layer.wantsExtendedDynamicRangeContent = true
        layer.drawableSize = CGSize(width: 2, height: 2)
        let frame = NSRect(x: screen.frame.minX, y: screen.frame.minY, width: 1, height: 1)
        window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.isOpaque = false; window.backgroundColor = .clear
        window.ignoresMouseEvents = true
        window.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue - 2)
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let view = NSView(frame: NSRect(origin: .zero, size: frame.size))
        view.wantsLayer = true; view.layer = layer; window.contentView = view
        window.orderFrontRegardless()
        guard let drawable = layer.nextDrawable(), let command = queue.makeCommandBuffer() else {
            window.close(); throw DisplayControlError.unavailable("Could not create the HDR activation surface.")
        }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear; pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 2, green: 2, blue: 2, alpha: 1)
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else {
            window.close(); throw DisplayControlError.unavailable("Could not draw the HDR activation surface.")
        }
        encoder.endEncoding(); command.present(drawable); command.commit()
    }
    func apply(_ id: CGDirectDisplayID, factor: Double) throws {
        guard isCurrent(id) else { throw DisplayControlError.unavailable("Another app changed the colour curves. HDR boost yielded control; disable its adjustments before retrying.") }
        // This >1 gamma path is experimental OS-dependent EDR behaviour, not a
        // documented guarantee of luminance or colour accuracy.
        let table = try GammaCurve.scaled(baseline.channels, factor: factor)
        let next = GammaTable(channels: table)
        do {
            try next.write(id)
            guard let readback = try? GammaTable.read(id), next.matches(readback) else {
                throw DisplayControlError.unavailable("macOS did not retain the HDR boost table. Original colours were restored. Try Metal boost as an alternative.")
            }
            applied = next; self.factor = factor
        } catch { try? baseline.write(id); throw error }
    }
    func isCurrent(_ id: CGDirectDisplayID) -> Bool {
        guard let applied else { return true }
        return (try? GammaTable.read(id)).map { applied.matches($0) } ?? false
    }
    func restore(_ id: CGDirectDisplayID) throws {
        if applied != nil && isCurrent(id) { try baseline.write(id) }
        applied = nil; factor = 1
    }
    func close() { window.orderOut(nil); window.close() }
}

private struct GammaTable {
    let channels: [[Float]]
    static func read(_ id: CGDirectDisplayID) throws -> GammaTable {
        let capacity = CGDisplayGammaTableCapacity(id)
        guard capacity >= 2, capacity <= 65536 else { throw DisplayControlError.unavailable("Display colour tables are unavailable.") }
        var red = [Float](repeating: 0, count: Int(capacity)), green = red, blue = red
        var count: UInt32 = 0
        let result = CGGetDisplayTransferByTable(id, capacity, &red, &green, &blue, &count)
        guard result == .success, count >= 2, count <= capacity else { throw DisplayControlError.configuration(result.rawValue) }
        return GammaTable(channels: [red, green, blue].map { Array($0.prefix(Int(count))) })
    }
    func write(_ id: CGDirectDisplayID) throws {
        let result = CGSetDisplayTransferByTable(id, UInt32(channels[0].count), channels[0], channels[1], channels[2])
        guard result == .success else { throw DisplayControlError.configuration(result.rawValue) }
    }
    func matches(_ other: GammaTable) -> Bool {
        channels.count == other.channels.count && zip(channels, other.channels).allSatisfy { lhs, rhs in
            lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { abs($0 - $1) < 0.015 }
        }
    }
}
