import AppKit
import CoreGraphics
import Combine
import DisplayDeskCore
import MacBrightnessKit

struct Monitor: Identifiable {
    let id: CGDirectDisplayID
    let uuid: String
    let name: String
    let builtIn: Bool
    var mode: ModeSpec
    var modes: [ModeSpec]
    var brightness: Double?
    var backend = "Checking…"
    var dimming: Double = 0
    var imaging = ImagingState()
    var brightnessSupported: Bool { backend == "Apple display" || backend == "DDC/CI" }
    var setting: DisplaySetting {
        DisplaySetting(displayUUID: uuid, name: name, mode: mode, brightness: brightnessSupported ? brightness : nil, dimming: dimming,
                       colorProfilePath: imaging.profileID, hdrEnabled: imaging.hdrEnabled, hdrBoost: imaging.boost, hdrBoostMethod: imaging.boostMethod)
    }
    var resolutions: [ModeSpec] {
        var seen = Set<String>()
        return modes.filter { seen.insert($0.resolutionID).inserted }
    }
}

private actor BrightnessHardware {
    private let backend = SystemDisplayBrightnessBackend()
    private let ddc = VerifiedDDC()
    func read(_ id: CGDirectDisplayID) -> (String, Double?) {
        if backend.capability(displayID: id).backend == .displayServices {
            return ("Apple display", (try? backend.getBrightness(displayID: id)).map(Double.init))
        }
        if let value = ddc.readBrightness(id) { return ("DDC/CI", value) }
        return ("Software only", nil)
    }
    func set(_ id: CGDirectDisplayID, value: Double) throws -> Double {
        if backend.capability(displayID: id).backend == .displayServices {
            try backend.setBrightness(displayID: id, value: Float(value))
            return Double(try backend.getBrightness(displayID: id))
        } else {
            return try ddc.setBrightness(id, value: value)
        }
    }
}

@MainActor
private final class DimmingWindows {
    private var windows: [CGDirectDisplayID: NSWindow] = [:]
    func set(_ id: CGDirectDisplayID, amount: Double) {
        guard amount > 0.001, let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == id
        }) else {
            windows[id]?.orderOut(nil); windows[id]?.close(); windows[id] = nil; return
        }
        let window = windows[id] ?? NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .black
        window.ignoresMouseEvents = true
        window.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue - 1)
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.alphaValue = min(0.8, max(0, amount))
        window.setFrame(screen.frame, display: true)
        window.orderFrontRegardless()
        windows[id] = window
    }
    func synchronize(_ monitors: [Monitor]) {
        for id in Array(windows.keys) where !monitors.contains(where: { $0.id == id }) {
            windows[id]?.orderOut(nil); windows[id]?.close(); windows[id] = nil
        }
        for monitor in monitors { set(monitor.id, amount: monitor.dimming) }
    }
    func clear() { for window in windows.values { window.orderOut(nil); window.close() }; windows.removeAll() }
}

enum DisplayControlError: LocalizedError {
    case unavailable(String), configuration(Int32), preview, brightnessIgnored
    var errorDescription: String? {
        switch self {
        case .unavailable(let message): return message
        case .configuration(let code): return "macOS rejected the display configuration (error \(code))."
        case .preview: return "Controls are disabled in the illustrative preview."
        case .brightnessIgnored: return "DDC/CI is reachable, but brightness readback did not change after the command. The cause may be the connection, monitor settings, or DDC compatibility. Software dimming is available. Click Refresh to retry hardware control."
        }
    }
}

@MainActor
final class DisplayService: ObservableObject {
    @Published var monitors: [Monitor] = []
    @Published var selectedUUID: String?
    @Published var profiles: [DisplayProfile] = []
    @Published var errorMessage: String?
    @Published var statusMessage: String?
    @Published var isBusy = false
    @Published var isDiscovering = false
    @Published var pendingName: String?
    @Published var secondsRemaining = 15
    @Published var colorProfiles: [ColorProfileChoice] = []
    @Published var imagingBusy = false
    @Published private(set) var automaticProfiles = AutomaticProfileConfiguration()
    let isPreview: Bool

    private let hardware = BrightnessHardware()
    private let shades = DimmingWindows()
    private let imaging = DisplayImaging()
    private let store: ProfileStore
    private let automaticStore: AutomaticProfileStore
    private var automaticTask: Task<Void, Never>?
    private var lastAutomaticTopology: [String]?
    private var pendingBackup: [DisplaySetting]?
    private var rollbackTask: Task<Void, Never>?
    private var reloadTask: Task<Void, Never>?
    private var brightnessTasks: [String: Task<Void, Never>] = [:]
    private var refreshGeneration = UUID()
    private var registeredCallback = false
    private var blockedBrightness = Set<String>()
    private var imagingTask: Task<Void, Never>?

    private static let callback: CGDisplayReconfigurationCallBack = { _, flags, context in
        guard !flags.contains(.beginConfigurationFlag), let context else { return }
        let service = Unmanaged<DisplayService>.fromOpaque(context).takeUnretainedValue()
        Task { @MainActor [weak service] in service?.scheduleReload() }
    }

    init(preview: Bool = false) {
        isPreview = preview
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        store = ProfileStore(fileURL: base.appendingPathComponent("DisplayDesk/profiles.json"))
        automaticStore = AutomaticProfileStore(fileURL: base.appendingPathComponent("DisplayDesk/automation.json"))
        if preview {
            loadPreview()
        } else {
            do { automaticProfiles = try automaticStore.load() }
            catch { errorMessage = "Could not read automatic profiles: \(error.localizedDescription)" }
            do { profiles = try store.load() }
            catch { errorMessage = "Could not read saved profiles: \(error.localizedDescription)" }
            registeredCallback = CGDisplayRegisterReconfigurationCallback(Self.callback, Unmanaged.passUnretained(self).toOpaque()) == .success
            scheduleReload()
            imagingTask = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(2)) } catch { return }
                    guard let self else { return }
                    guard !self.isBusy && !self.imagingBusy else { continue }
                    if self.imaging.reconcile(connected: Set(self.monitors.map(\.id))) {
                        self.statusMessage = "HDR boost stopped because the display state or colour table changed."
                    }
                    for index in self.monitors.indices { self.monitors[index].imaging = self.imaging.state(self.monitors[index].id) }
                }
            }
        }
    }

    isolated deinit {
        if registeredCallback { CGDisplayRemoveReconfigurationCallback(Self.callback, Unmanaged.passUnretained(self).toOpaque()) }
        rollbackTask?.cancel(); reloadTask?.cancel()
        imagingTask?.cancel(); automaticTask?.cancel()
        for task in brightnessTasks.values { task.cancel() }
    }

    var selected: Monitor? { monitors.first { $0.uuid == selectedUUID } ?? monitors.first }
    var hasPendingChanges: Bool { pendingBackup != nil }
    var controlsDisabled: Bool { isBusy || imagingBusy || hasPendingChanges || isPreview }
    var screenCaptureAllowed: Bool { !isPreview && CGPreflightScreenCaptureAccess() }

    func retryHardware() {
        blockedBrightness.removeAll()
        scheduleReload()
    }

    func scheduleReload() {
        guard !isPreview else { return }
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self else { return }
            await self.reload()
        }
    }

    func reload() async {
        guard !isPreview else { return }
        let generation = UUID(); refreshGeneration = generation
        isDiscovering = true
        let old = monitors
        var ids = [CGDirectDisplayID](repeating: 0, count: 32)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(32, &ids, &count) == .success else {
            isDiscovering = false; errorMessage = "Could not query the connected displays."; return
        }
        monitors = ids.prefix(Int(count)).compactMap { id in
            guard let current = CGDisplayCopyDisplayMode(id) else { return nil }
            let uuid = Self.uuid(for: id)
            let screen = NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == id }
            let modes = Self.cgModes(id).map(Self.spec).sorted {
                if $0.width != $1.width { return $0.width > $1.width }
                if $0.isHiDPI != $1.isHiDPI { return $0.isHiDPI }
                return $0.refreshRate > $1.refreshRate
            }
            var seen = Set<String>()
            var unique = modes.filter { seen.insert($0.id).inserted }
            let spec = Self.spec(current)
            if !unique.contains(where: { $0.id == spec.id }) { unique.append(spec) }
            let previous = old.first { $0.uuid == uuid }
            return Monitor(id: id, uuid: uuid, name: screen?.localizedName ?? "Display \(id)", builtIn: CGDisplayIsBuiltin(id) != 0,
                           mode: spec, modes: unique, brightness: previous?.brightness,
                           backend: previous?.backend ?? "Checking…", dimming: previous?.dimming ?? 0)
        }.sorted { lhs, rhs in lhs.builtIn != rhs.builtIn ? !lhs.builtIn : lhs.name < rhs.name }
        if !monitors.contains(where: { $0.uuid == selectedUUID }) { selectedUUID = monitors.first?.uuid }
        shades.synchronize(monitors)
        _ = imaging.reconcile(connected: Set(monitors.map(\.id)))
        for index in monitors.indices { monitors[index].imaging = imaging.state(monitors[index].id) }
        refreshColorProfiles()
        let inventory = monitors.map { ($0.id, $0.uuid) }
        for (id, uuid) in inventory {
            let (backend, brightness) = await hardware.read(id)
            guard refreshGeneration == generation, !Task.isCancelled else { return }
            if let index = monitors.firstIndex(where: { $0.uuid == uuid }) {
                monitors[index].backend = blockedBrightness.contains(uuid) && backend == "DDC/CI" ? "DDC/CI · read-only" : backend
                // An in-flight slider write owns the value until it has finished.
                if brightnessTasks[uuid] == nil && !isBusy { monitors[index].brightness = brightness }
            }
        }
        if refreshGeneration == generation {
            isDiscovering = false
            scheduleAutomaticProfile()
        }
    }

    func setBrightness(uuid: String, value: Double) {
        guard !controlsDisabled, let index = monitors.firstIndex(where: { $0.uuid == uuid }), monitors[index].brightnessSupported else { return }
        let clamped = min(1, max(0, value)); let id = monitors[index].id
        monitors[index].brightness = clamped
        brightnessTasks[uuid]?.cancel()
        brightnessTasks[uuid] = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(180))
                guard !Task.isCancelled, let self else { return }
                let actual = try await self.hardware.set(id, value: clamped)
                if !Task.isCancelled {
                    self.brightnessTasks[uuid] = nil
                    if let current = self.monitors.firstIndex(where: { $0.uuid == uuid }) { self.monitors[current].brightness = actual }
                }
            } catch is CancellationError {} catch {
                guard !Task.isCancelled, let self else { return }
                self.brightnessTasks[uuid] = nil
                if let controlError = error as? DisplayControlError, case .brightnessIgnored = controlError {
                    self.blockedBrightness.insert(uuid)
                }
                self.errorMessage = "Brightness could not be changed: \(error.localizedDescription)"
                await self.reload()
            }
        }
    }

    func setDimming(uuid: String, amount: Double) {
        guard !controlsDisabled, let index = monitors.firstIndex(where: { $0.uuid == uuid }) else { return }
        if amount > 0 {
            do { try imaging.stopBoost(monitors[index].id) }
            catch { errorMessage = error.localizedDescription; return }
            monitors[index].imaging = imaging.state(monitors[index].id)
        }
        monitors[index].dimming = min(0.8, max(0, amount))
        shades.set(monitors[index].id, amount: monitors[index].dimming)
    }

    func resetDimming() {
        guard !isBusy else { return }
        for index in monitors.indices { monitors[index].dimming = 0 }
        shades.clear()
    }

    func refreshColorProfiles() {
        guard !isPreview, let selected else { return }
        colorProfiles = imaging.profiles(selected.id)
    }

    func hasOriginalImaging(uuid: String) -> Bool { imaging.original(uuid) != nil }

    func changeColorProfile(uuid: String, profileID: String) async {
        guard let monitor = monitors.first(where: { $0.uuid == uuid }) else { return }
        var setting = monitor.setting; setting.brightness = nil
        setting.colorProfilePath = profileID; setting.hdrBoost = 1
        await preview(settings: [setting], name: "Colour profile")
    }

    func importColorProfile(uuid: String, url: URL) async {
        guard !controlsDisabled else { return }
        do {
            let choice = try imaging.importProfile(url)
            refreshColorProfiles()
            await changeColorProfile(uuid: uuid, profileID: choice.id)
        } catch { errorMessage = error.localizedDescription }
    }

    func changeHDR(uuid: String, enabled: Bool) async {
        guard let monitor = monitors.first(where: { $0.uuid == uuid }) else { return }
        var setting = monitor.setting; setting.brightness = nil
        setting.hdrEnabled = enabled; setting.hdrBoost = 1
        await preview(settings: [setting], name: enabled ? "HDR mode" : "SDR mode")
    }

    func setHDRBoost(uuid: String, factor: Double, useMetal: Bool = false) async {
        guard !controlsDisabled, let monitor = monitors.first(where: { $0.uuid == uuid }) else { return }
        guard factor <= 1 || monitor.dimming == 0 else { errorMessage = "Reset software dimming to 0% before boosting HDR brightness."; return }
        imagingBusy = true
        errorMessage = nil
        defer { imagingBusy = false }
        do {
            imaging.remember(monitor.id, uuid: uuid)
            try await imaging.setBoost(monitor.id, factor: factor, useMetal: useMetal || monitor.imaging.boostMethod == "metal")
            if let index = monitors.firstIndex(where: { $0.uuid == uuid }) { monitors[index].imaging = imaging.state(monitor.id) }
            statusMessage = factor > 1 ? "HDR boost active. Percentage is a curve multiplier, not measured nits." : "Original colour curves restored."
        } catch { errorMessage = error.localizedDescription; await reload() }
    }

    func restoreOriginalImaging(uuid: String) async {
        guard let monitor = monitors.first(where: { $0.uuid == uuid }), let original = imaging.original(uuid) else { return }
        var setting = monitor.setting; setting.brightness = nil
        setting.colorProfilePath = original.profileID; setting.hdrEnabled = original.hdrEnabled; setting.hdrBoost = original.boost
        setting.hdrBoostMethod = original.boostMethod
        await preview(settings: [setting], name: "Original colour and HDR settings")
    }

    func resetImageAdjustments() {
        guard !isBusy && !imagingBusy else { return }
        do {
            try imaging.stopAllBoosts()
            resetDimming()
            for index in monitors.indices { monitors[index].imaging = imaging.state(monitors[index].id) }
        } catch { errorMessage = "Could not restore the colour curves: \(error.localizedDescription)" }
    }

    var externalTopology: [String] { monitors.filter { !$0.builtIn }.map(\.uuid).sorted() }

    func setAutomaticProfilesEnabled(_ enabled: Bool) {
        var next = automaticProfiles; next.enabled = enabled
        saveAutomaticConfiguration(next)
    }

    func addAutomaticProfile(profileID: UUID) {
        guard !externalTopology.isEmpty, profiles.contains(where: { $0.id == profileID }) else { return }
        var next = automaticProfiles
        next.rules.removeAll { Set($0.externalDisplayUUIDs) == Set(externalTopology) }
        next.rules.append(AutomaticProfileRule(profileID: profileID, externalDisplayUUIDs: externalTopology))
        saveAutomaticConfiguration(next)
    }

    func removeAutomaticProfile(id: UUID) {
        var next = automaticProfiles; next.rules.removeAll { $0.id == id }
        saveAutomaticConfiguration(next)
    }

    private func saveAutomaticConfiguration(_ next: AutomaticProfileConfiguration) {
        guard !isPreview else { return }
        do {
            try automaticStore.save(next)
            automaticProfiles = next
            automaticTask?.cancel(); lastAutomaticTopology = nil
            scheduleAutomaticProfile()
        } catch { errorMessage = "Could not save automatic profiles: \(error.localizedDescription)" }
    }

    private func scheduleAutomaticProfile() {
        let topology = externalTopology
        guard automaticProfiles.enabled, topology != lastAutomaticTopology else { return }
        automaticTask?.cancel()
        automaticTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(1500)) } catch { return }
            guard let self, !Task.isCancelled, self.externalTopology == topology,
                  !self.controlsDisabled, !self.isDiscovering else { return }
            self.lastAutomaticTopology = topology
            guard let profileID = self.automaticProfiles.matchingProfile(externalDisplayUUIDs: topology, availableProfileIDs: Set(self.profiles.map(\.id))),
                  let profile = self.profiles.first(where: { $0.id == profileID }) else { return }
            await self.applyProfile(profile)
            guard self.hasPendingChanges else { return }
            self.statusMessage = "Automatic profile: \(profile.name). Keep changes within 15 seconds."
            NotificationCenter.default.post(name: .displayDeskShowDashboard, object: nil)
        }
    }

    func saveProfile(name: String) {
        guard !controlsDisabled, !monitors.isEmpty else { return }
        do {
            let profile = try ProfileStore.makeProfile(name: name, settings: monitors.map(\.setting), existing: profiles)
            let next = profiles + [profile]
            try store.save(next); profiles = next
            statusMessage = "Saved \(profile.name)."
        } catch { errorMessage = error.localizedDescription }
    }

    func deleteProfile(_ profile: DisplayProfile) {
        guard !controlsDisabled else { return }
        do {
            let next = profiles.filter { $0.id != profile.id }
            try store.save(next); profiles = next
        } catch { errorMessage = error.localizedDescription }
    }

    func applyProfile(_ profile: DisplayProfile) async {
        do {
            let modes = Dictionary(uniqueKeysWithValues: monitors.map { ($0.uuid, $0.modes) })
            let settings = try ProfilePlan.resolved(profile, available: monitors.map(\.setting), modes: modes)
            await preview(settings: settings, name: profile.name)
        } catch { errorMessage = error.localizedDescription }
    }

    func changeMode(uuid: String, mode: ModeSpec) async {
        guard let monitor = monitors.first(where: { $0.uuid == uuid }) else { return }
        var setting = monitor.setting; setting.mode = mode
        await preview(settings: [setting], name: "Display mode")
    }

    private func preview(settings: [DisplaySetting], name: String) async {
        guard !controlsDisabled else { return }
        isBusy = true; errorMessage = nil; statusMessage = nil
        for task in brightnessTasks.values { task.cancel() }; brightnessTasks.removeAll()
        var backup = monitors.map(\.setting)
        for index in backup.indices {
            if let monitor = monitors.first(where: { $0.uuid == backup[index].displayUUID }) {
                let actual = imaging.state(monitor.id)
                backup[index].colorProfilePath = actual.profileID
                backup[index].hdrEnabled = actual.hdrEnabled
                backup[index].hdrBoost = actual.boost
                backup[index].hdrBoostMethod = actual.boostMethod
            }
        }
        // Capture hardware brightness at the moment of application, not an old UI sample.
        for index in backup.indices {
            if let monitor = monitors.first(where: { $0.uuid == backup[index].displayUUID }), monitor.brightnessSupported {
                let (_, value) = await hardware.read(monitor.id)
                guard let value else {
                    errorMessage = "Could not capture brightness for \(monitor.name); nothing was applied."
                    isBusy = false; return
                }
                backup[index].brightness = value
            }
        }
        pendingBackup = backup; pendingName = name
        do {
            try await apply(settings)
            isBusy = false
            secondsRemaining = 15
            rollbackTask = Task { [weak self] in
                for remaining in (0..<15).reversed() {
                    do { try await Task.sleep(for: .seconds(1)) } catch { return }
                    guard let self, self.pendingBackup != nil else { return }
                    self.secondsRemaining = remaining
                }
                await self?.revert()
            }
            await reload()
        } catch {
            let message = error.localizedDescription
            isBusy = false
            await revert()
            errorMessage = "Changes were not kept: \(message)"
        }
    }

    private func apply(_ settings: [DisplaySetting]) async throws {
        // Resolve every requested mode before making any change.
        var modeChanges: [(CGDirectDisplayID, CGDisplayMode)] = []
        for setting in settings {
            guard let monitor = monitors.first(where: { $0.uuid == setting.displayUUID }) else {
                throw DisplayControlError.unavailable("\(setting.name) is disconnected.")
            }
            let current = CGDisplayCopyDisplayMode(monitor.id)
            let availableMode = current.flatMap { Self.spec($0).matches(setting.mode) ? $0 : nil }
                ?? Self.cgModes(monitor.id).first(where: { Self.spec($0).matches(setting.mode) })
            guard let mode = availableMode else {
                throw DisplayControlError.unavailable("The requested mode is unavailable on \(monitor.name).")
            }
            if setting.brightness != nil && !monitor.brightnessSupported {
                throw DisplayControlError.unavailable("Hardware brightness is unavailable on \(monitor.name).")
            }
            if let path = setting.colorProfilePath, path != ColorProfileChoice.factoryID,
               DisplayImaging.profileChoice(URL(fileURLWithPath: path)) == nil {
                throw DisplayControlError.unavailable("The saved colour profile for \(monitor.name) is missing or invalid.")
            }
            if setting.hdrEnabled == true && !imaging.state(monitor.id).hdrSupported {
                throw DisplayControlError.unavailable("HDR is unavailable on \(monitor.name).")
            }
            modeChanges.append((monitor.id, mode))
        }
        if try configure(modeChanges) { try await Task.sleep(for: .milliseconds(800)) }
        for setting in settings {
            guard let monitor = monitors.first(where: { $0.uuid == setting.displayUUID }) else { continue }
            imaging.remember(monitor.id, uuid: monitor.uuid)
            try imaging.stopBoost(monitor.id)
            if let enabled = setting.hdrEnabled { try await imaging.setHDR(monitor.id, enabled: enabled) }
            if let profileID = setting.colorProfilePath {
                try imaging.setProfile(monitor.id, choiceID: profileID)
                try await Task.sleep(for: .milliseconds(300))
            }
            if let factor = setting.hdrBoost, factor > 1 { try await imaging.setBoost(monitor.id, factor: factor, useMetal: setting.hdrBoostMethod == "metal") }
            if let value = setting.brightness {
                let actual = try await hardware.set(monitor.id, value: value)
                if let current = monitors.firstIndex(where: { $0.uuid == setting.displayUUID }) { monitors[current].brightness = actual }
            }
            if let current = monitors.firstIndex(where: { $0.uuid == setting.displayUUID }) {
                monitors[current].dimming = setting.dimming
                shades.set(monitors[current].id, amount: setting.dimming)
            }
        }
    }

    @discardableResult
    private func configure(_ requested: [(CGDirectDisplayID, CGDisplayMode)]) throws -> Bool {
        let needsChange = requested.contains { id, mode in
            CGDisplayCopyDisplayMode(id)?.ioDisplayModeID != mode.ioDisplayModeID
        }
        // Avoid resetting the monitor's DDC connection for brightness-only or unchanged profiles.
        guard needsChange else { return false }
        var configuration: CGDisplayConfigRef?
        let begin = CGBeginDisplayConfiguration(&configuration)
        guard begin == .success else { throw DisplayControlError.configuration(begin.rawValue) }
        for monitor in monitors {
            guard let mode = requested.first(where: { $0.0 == monitor.id })?.1 ?? CGDisplayCopyDisplayMode(monitor.id) else { continue }
            let result = CGConfigureDisplayWithDisplayMode(configuration, monitor.id, mode, nil)
            guard result == .success else {
                CGCancelDisplayConfiguration(configuration)
                throw DisplayControlError.configuration(result.rawValue)
            }
        }
        let result = CGCompleteDisplayConfiguration(configuration, .forSession)
        guard result == .success else { throw DisplayControlError.configuration(result.rawValue) }
        return true
    }

    func keepChanges() {
        guard !isBusy, let name = pendingName else { return }
        rollbackTask?.cancel(); rollbackTask = nil
        pendingBackup = nil; pendingName = nil
        statusMessage = "Kept \(name.lowercased()) changes."
    }

    func revert() async {
        guard let backup = pendingBackup, !isBusy else { return }
        rollbackTask?.cancel(); rollbackTask = nil
        isBusy = true
        do {
            // Mode restoration must not depend on a responsive DDC brightness channel.
            let connected = backup.filter { saved in monitors.contains { $0.uuid == saved.displayUUID } }
            var previousModes: [(CGDirectDisplayID, CGDisplayMode)] = []
            for saved in connected {
                guard let monitor = monitors.first(where: { $0.uuid == saved.displayUUID }) else { continue }
                let current = CGDisplayCopyDisplayMode(monitor.id)
                guard let mode = current.flatMap({ Self.spec($0).matches(saved.mode) ? $0 : nil })
                    ?? Self.cgModes(monitor.id).first(where: { Self.spec($0).matches(saved.mode) }) else {
                    throw DisplayControlError.unavailable("The previous mode is no longer available on \(saved.name).")
                }
                previousModes.append((monitor.id, mode))
            }
            if try configure(previousModes) { try? await Task.sleep(for: .milliseconds(800)) }
            var brightnessFailures: [String] = []
            var imageFailures: [String] = []
            for saved in connected {
                guard let index = monitors.firstIndex(where: { $0.uuid == saved.displayUUID }) else { continue }
                monitors[index].dimming = saved.dimming
                shades.set(monitors[index].id, amount: saved.dimming)
                let displayID = monitors[index].id
                do {
                    try imaging.stopBoost(displayID)
                    if let enabled = saved.hdrEnabled { try await imaging.setHDR(displayID, enabled: enabled) }
                    if let profileID = saved.colorProfilePath { try imaging.setProfile(displayID, choiceID: profileID) }
                    if let factor = saved.hdrBoost, factor > 1 { try await imaging.setBoost(displayID, factor: factor, useMetal: saved.hdrBoostMethod == "metal") }
                } catch { imageFailures.append(saved.name) }
                if let value = saved.brightness {
                    do {
                        let id = monitors[index].id
                        let actual = try await hardware.set(id, value: value)
                        if let current = monitors.firstIndex(where: { $0.uuid == saved.displayUUID }) { monitors[current].brightness = actual }
                    } catch { brightnessFailures.append(saved.name) }
                }
            }
            if imageFailures.isEmpty { pendingBackup = nil; pendingName = nil }
            statusMessage = "Restored the previous display settings."
            if !brightnessFailures.isEmpty {
                errorMessage = "Display modes were restored, but hardware brightness could not be restored on: \(brightnessFailures.joined(separator: ", "))."
            }
            if !imageFailures.isEmpty { errorMessage = "Could not restore colour/HDR settings on: \(imageFailures.joined(separator: ", ")). Use Displays settings to check the result." }
        } catch {
            errorMessage = "Could not restore the display mode: \(error.localizedDescription). Try Revert again."
        }
        isBusy = false
        await reload()
    }

    func prepareToQuit() async -> Bool {
        guard !imagingBusy && !isBusy else { errorMessage = "Wait for the display adjustment to finish, then quit again."; return false }
        if hasPendingChanges { await revert() }
        guard !hasPendingChanges else { return false }
        automaticTask?.cancel()
        for task in brightnessTasks.values { task.cancel() }
        do { try imaging.stopAllBoosts() }
        catch { errorMessage = "Could not restore colour curves before quitting: \(error.localizedDescription)"; return false }
        shades.clear()
        return true
    }

    private static func uuid(for id: CGDirectDisplayID) -> String {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return "display-\(id)" }
        return CFUUIDCreateString(nil, uuid) as String
    }
    private static func cgModes(_ id: CGDirectDisplayID) -> [CGDisplayMode] {
        CGDisplayCopyAllDisplayModes(id, [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary) as? [CGDisplayMode] ?? []
    }
    private static func spec(_ mode: CGDisplayMode) -> ModeSpec {
        ModeSpec(width: mode.width, height: mode.height, pixelWidth: mode.pixelWidth, pixelHeight: mode.pixelHeight, refreshRate: mode.refreshRate)
    }

    private func loadPreview() {
        let fourK = ModeSpec(width: 2560, height: 1440, pixelWidth: 5120, pixelHeight: 2880, refreshRate: 60)
        let native = ModeSpec(width: 3840, height: 2160, pixelWidth: 3840, pixelHeight: 2160, refreshRate: 60)
        let retina = ModeSpec(width: 1512, height: 982, pixelWidth: 3024, pixelHeight: 1964, refreshRate: 0)
        monitors = [Monitor(id: 2, uuid: "demo-external", name: "Studio workspace", builtIn: false, mode: fourK,
                            modes: [fourK, native], brightness: 0.72, backend: "DDC/CI"),
                    Monitor(id: 1, uuid: "demo-internal", name: "Built-in Retina Display", builtIn: true, mode: retina,
                            modes: [retina], brightness: 0.55, backend: "Apple display")]
        selectedUUID = monitors[0].uuid
        profiles = [DisplayProfile(name: "Everyday", settings: monitors.map(\.setting)), DisplayProfile(name: "Evening", settings: monitors.map(\.setting))]
    }
}
