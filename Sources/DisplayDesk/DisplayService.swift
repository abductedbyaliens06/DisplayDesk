import AppKit
import CoreGraphics
import Combine
@preconcurrency import ApplicationServices
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
    var placement = DisplayPlacement(x: 0, y: 0, isMain: true)
    var layoutSupported = true
    var brightnessSupported: Bool { backend == "Apple display" || backend == "DDC/CI" }
    var setting: DisplaySetting {
        DisplaySetting(displayUUID: uuid, name: name, mode: mode, brightness: brightnessSupported ? brightness : nil, dimming: dimming,
                       colorProfilePath: imaging.profileID, hdrEnabled: imaging.hdrEnabled, hdrBoost: imaging.boost, hdrBoostMethod: imaging.boostMethod, placement: layoutSupported ? placement : nil)
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
        try Task.checkCancellation()
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
    @Published private(set) var isRecovering = false
    private(set) var isSleeping = false
    @Published private(set) var automaticProfiles = AutomaticProfileConfiguration()
    let isPreview: Bool
    let keyboard = BrightnessKeyboard()

    private let hardware = BrightnessHardware()
    private let shades = DimmingWindows()
    private let imaging = DisplayImaging()
    private let store: ProfileStore
    private let automaticStore: AutomaticProfileStore
    private var automaticTask: Task<Void, Never>?
    private var lastAutomaticTopology: [String]?
    private var wakeTask: Task<Void, Never>?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var pendingBackup: [DisplaySetting]?
    private var pendingLayoutOnly = false
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
            keyboard.canAdjust = { [weak self] in
                guard let self else { return false }
                return !self.controlsDisabled && !self.isDiscovering && !self.keyboardTargets.isEmpty
            }
            keyboard.adjust = { [weak self] delta in self?.adjustBrightnessFromKeyboard(delta: delta) }
            keyboard.start()
            let center = NSWorkspace.shared.notificationCenter
            for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification] {
                workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    Task { @MainActor in self?.suspendForSleep() }
                })
            }
            for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
                workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    Task { @MainActor in self?.recoverAfterWake() }
                })
            }
            registeredCallback = CGDisplayRegisterReconfigurationCallback(Self.callback, Unmanaged.passUnretained(self).toOpaque()) == .success
            scheduleReload()
            imagingTask = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(2)) } catch { return }
                    guard let self else { return }
                    guard !self.isBusy && !self.imagingBusy && !self.isSleeping && !self.isRecovering else { continue }
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
        imagingTask?.cancel(); automaticTask?.cancel(); wakeTask?.cancel()
        for observer in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        for task in brightnessTasks.values { task.cancel() }
    }

    var selected: Monitor? { monitors.first { $0.uuid == selectedUUID } ?? monitors.first }
    var hasPendingChanges: Bool { pendingBackup != nil }
    var controlsDisabled: Bool { isBusy || imagingBusy || hasPendingChanges || isPreview || isSleeping || isRecovering }
    var screenCaptureAllowed: Bool { !isPreview && CGPreflightScreenCaptureAccess() }

    func suspendForSleep() {
        guard !isPreview, !isSleeping else { return }
        isSleeping = true; isRecovering = false
        wakeTask?.cancel(); reloadTask?.cancel(); automaticTask?.cancel(); rollbackTask?.cancel()
        refreshGeneration = UUID(); isDiscovering = false
        for task in brightnessTasks.values { task.cancel() }; brightnessTasks.removeAll()
        keyboard.stop()
        do { try imaging.stopAllBoosts() } catch { errorMessage = error.localizedDescription }
        shades.clear()
        if var backup = pendingBackup {
            for index in backup.indices { backup[index].hdrBoost = 1 }
            pendingBackup = backup
        }
        statusMessage = "Display controls paused while the screens sleep."
    }

    func recoverAfterWake() {
        guard !isPreview, !isRecovering else { return }
        isSleeping = false; isRecovering = true
        blockedBrightness.removeAll(); lastAutomaticTopology = nil
        wakeTask?.cancel()
        wakeTask = Task { [weak self] in
            for delay in [900, 1500, 2500] {
                do { try await Task.sleep(for: .milliseconds(delay)) } catch { return }
                guard let self, !self.isSleeping else { return }
                await self.reload()
            }
            guard let self, !Task.isCancelled, !self.isSleeping else { return }
            self.isRecovering = false
            if self.hasPendingChanges { await self.revert() }
            self.keyboard.start()
            self.statusMessage = "Displays refreshed after wake. HDR boost remains off."
            self.scheduleAutomaticProfile()
        }
    }

    func diagnosticScreen(_ monitor: Monitor, number: Int) -> DiagnosticScreen {
        let path: DiagnosticControlPath
        switch monitor.backend {
        case "Apple display": path = .apple
        case "DDC/CI": path = .ddc
        case "DDC/CI · read-only": path = .ddcReadOnly
        case "Checking…": path = .checking
        default: path = .softwareOnly
        }
        return DiagnosticScreen(number: number, builtIn: monitor.builtIn, mode: monitor.mode, controlPath: path,
                                brightness: monitor.brightness, hdrSupported: monitor.imaging.hdrSupported,
                                hdrEnabled: monitor.imaging.hdrEnabled, edrHeadroom: monitor.imaging.headroom,
                                boost: monitor.imaging.boost, metalBoost: monitor.imaging.boostMethod == "metal",
                                customColorProfile: monitor.imaging.profileID != ColorProfileChoice.factoryID)
    }

    func diagnosticReport() -> DiagnosticReport {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return DiagnosticReport(appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
                                macOSVersion: "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
                                screenCaptureAllowed: screenCaptureAllowed, accessibilityAllowed: AXIsProcessTrusted(),
                                screens: monitors.enumerated().map { diagnosticScreen($0.element, number: $0.offset + 1) })
    }

    func retryHardware() {
        blockedBrightness.removeAll()
        scheduleReload()
    }

    func scheduleReload() {
        guard !isPreview && !isSleeping else { return }
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self else { return }
            await self.reload()
        }
    }

    func reload() async {
        guard !isPreview && !isSleeping else { return }
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
                           backend: previous?.backend ?? "Checking…", dimming: previous?.dimming ?? 0,
                           placement: DisplayPlacement(x: Int(CGDisplayBounds(id).minX), y: Int(CGDisplayBounds(id).minY), isMain: id == CGMainDisplayID()),
                           layoutSupported: CGDisplayIsInMirrorSet(id) == 0 && Int(CGDisplayBounds(id).width) == spec.width && Int(CGDisplayBounds(id).height) == spec.height)
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

    private var keyboardTargets: [Monitor] {
        switch keyboard.target {
        case "all": return monitors
        case "selected": return selected.map { [$0] } ?? []
        default:
            let point = NSEvent.mouseLocation
            guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }),
                  let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return [] }
            return monitors.filter { $0.id == id }
        }
    }

    func adjustBrightnessFromKeyboard(delta: Double) {
        guard !controlsDisabled && !isDiscovering else { return }
        let targets = keyboardTargets
        for monitor in targets {
            if monitor.brightnessSupported, let current = monitor.brightness,
               let next = BrightnessStep.hardware(current: current, delta: delta) {
                setBrightness(uuid: monitor.uuid, value: next)
            } else if let next = BrightnessStep.dimming(current: monitor.dimming, delta: delta) {
                setDimming(uuid: monitor.uuid, amount: next)
            }
        }
        statusMessage = "Brightness adjusted on \(targets.count) display(s)."
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
            var settings = monitors.map(\.setting)
            // Preserve non-layout profiles for mirrored, rotated, or otherwise unsupported arrangements.
            if !monitors.allSatisfy(\.layoutSupported) || (try? DisplayLayout.validate(layoutScreens)) == nil {
                for index in settings.indices { settings[index].placement = nil }
            }
            let profile = try ProfileStore.makeProfile(name: name, settings: settings, existing: profiles)
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
        var setting = monitor.setting; setting.mode = mode; setting.placement = nil
        await preview(settings: [setting], name: "Display mode")
    }

    var layoutScreens: [LayoutScreen] {
        monitors.map { LayoutScreen(id: $0.uuid, width: $0.mode.width, height: $0.mode.height, placement: $0.placement) }
    }

    func changeArrangement(_ screens: [LayoutScreen]) async {
        guard !controlsDisabled, !isDiscovering else { return }
        do {
            guard monitors.allSatisfy(\.layoutSupported),
                  Set(screens.map(\.id)) == Set(monitors.map(\.uuid)),
                  screens.allSatisfy({ screen in monitors.contains { $0.uuid == screen.id && $0.mode.width == screen.width && $0.mode.height == screen.height } }) else {
                throw DisplayControlError.unavailable("The display setup changed or uses mirroring/rotation. Refresh before arranging displays.")
            }
            try DisplayLayout.validate(screens)
            let settings = monitors.map { monitor in
                var setting = monitor.setting
                setting.placement = screens.first(where: { $0.id == monitor.uuid })?.placement
                return setting
            }
            await preview(settings: settings, name: "Display arrangement", layoutOnly: true)
        } catch { errorMessage = error.localizedDescription }
    }

    private func preview(settings: [DisplaySetting], name: String, layoutOnly: Bool = false) async {
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
        for index in backup.indices where !layoutOnly {
            if let monitor = monitors.first(where: { $0.uuid == backup[index].displayUUID }), monitor.brightnessSupported {
                let (_, value) = await hardware.read(monitor.id)
                guard let value else {
                    errorMessage = "Could not capture brightness for \(monitor.name); nothing was applied."
                    isBusy = false; return
                }
                backup[index].brightness = value
            }
        }
        pendingBackup = backup; pendingName = name; pendingLayoutOnly = layoutOnly
        do {
            try await apply(settings, layoutOnly: layoutOnly)
            guard !isSleeping else { isBusy = false; return }
            isBusy = false
            secondsRemaining = 15
            rollbackTask = Task { [weak self] in
                for remaining in (0..<15).reversed() {
                    do { try await Task.sleep(for: .seconds(1)) } catch { return }
                    guard let self, self.pendingBackup != nil else { return }
                    self.secondsRemaining = remaining
                }
                // The timer has finished. Revert must not cancel its own task,
                // which would leave its subsequent discovery pass incomplete.
                self?.rollbackTask = nil
                await self?.revert()
            }
            await reload()
        } catch {
            let message = error.localizedDescription
            isBusy = false
            guard !isSleeping else { statusMessage = "Pending changes will be reverted after wake."; return }
            await revert()
            errorMessage = "Changes were not kept: \(message)"
        }
    }

    private func apply(_ settings: [DisplaySetting], layoutOnly: Bool = false) async throws {
        guard !isSleeping else { throw DisplayControlError.unavailable("The displays are sleeping.") }
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
            if !layoutOnly && setting.brightness != nil && !monitor.brightnessSupported {
                throw DisplayControlError.unavailable("Hardware brightness is unavailable on \(monitor.name).")
            }
            if !layoutOnly, let path = setting.colorProfilePath, path != ColorProfileChoice.factoryID,
               DisplayImaging.profileChoice(URL(fileURLWithPath: path)) == nil {
                throw DisplayControlError.unavailable("The saved colour profile for \(monitor.name) is missing or invalid.")
            }
            if !layoutOnly && setting.hdrEnabled == true && !imaging.state(monitor.id).hdrSupported {
                throw DisplayControlError.unavailable("HDR is unavailable on \(monitor.name).")
            }
            modeChanges.append((monitor.id, mode))
        }
        let layout = settings.contains(where: { $0.placement != nil }) ? settings : nil
        if let layout {
            guard monitors.allSatisfy(\.layoutSupported), layout.allSatisfy({ $0.placement != nil }),
                  Set(layout.map(\.displayUUID)) == Set(monitors.map(\.uuid)) else {
                throw DisplayControlError.unavailable("The connected displays do not match the saved arrangement.")
            }
            try DisplayLayout.validate(layout.map { LayoutScreen(id: $0.displayUUID, width: $0.mode.width, height: $0.mode.height, placement: $0.placement!) })
        }
        if try configure(modeChanges, layout: layout) { try await Task.sleep(for: .milliseconds(800)) }
        if let layout {
            for setting in layout {
                guard let monitor = monitors.first(where: { $0.uuid == setting.displayUUID }), let p = setting.placement else {
                    throw DisplayControlError.unavailable("A display disconnected while applying the layout.")
                }
                let bounds = CGDisplayBounds(monitor.id)
                guard Int(bounds.minX) == p.x, Int(bounds.minY) == p.y, !p.isMain || CGMainDisplayID() == monitor.id else {
                    throw DisplayControlError.unavailable("macOS adjusted the requested layout. The previous arrangement will be restored.")
                }
            }
        }
        if layoutOnly { return }
        for setting in settings {
            guard let monitor = monitors.first(where: { $0.uuid == setting.displayUUID }) else { continue }
            imaging.remember(monitor.id, uuid: monitor.uuid)
            try imaging.stopBoost(monitor.id)
            if let enabled = setting.hdrEnabled { try await imaging.setHDR(monitor.id, enabled: enabled) }
            guard !isSleeping else { throw DisplayControlError.unavailable("The display went to sleep during configuration.") }
            if let profileID = setting.colorProfilePath {
                try imaging.setProfile(monitor.id, choiceID: profileID)
                try await Task.sleep(for: .milliseconds(300))
            }
            guard !isSleeping else { throw DisplayControlError.unavailable("The display went to sleep during configuration.") }
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
    private func configure(_ requested: [(CGDirectDisplayID, CGDisplayMode)], layout: [DisplaySetting]? = nil) throws -> Bool {
        let needsChange = requested.contains { id, mode in
            CGDisplayCopyDisplayMode(id)?.ioDisplayModeID != mode.ioDisplayModeID
        } || (layout?.contains { setting in
            guard let monitor = monitors.first(where: { $0.uuid == setting.displayUUID }), let p = setting.placement else { return false }
            let bounds = CGDisplayBounds(monitor.id)
            return Int(bounds.minX) != p.x || Int(bounds.minY) != p.y || (p.isMain && CGMainDisplayID() != monitor.id)
        } ?? false)
        // Avoid resetting the monitor's DDC connection for brightness-only or unchanged profiles.
        guard needsChange else { return false }
        // Capture windows cannot keep their old geometry through a mode/layout change.
        try imaging.stopAllBoosts()
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
        if let layout {
            for setting in layout {
                guard let monitor = monitors.first(where: { $0.uuid == setting.displayUUID }), let p = setting.placement,
                      let x = Int32(exactly: p.x), let y = Int32(exactly: p.y) else {
                    CGCancelDisplayConfiguration(configuration)
                    throw DisplayControlError.unavailable("A display disconnected during arrangement.")
                }
                let result = CGConfigureDisplayOrigin(configuration, monitor.id, x, y)
                guard result == .success else {
                    CGCancelDisplayConfiguration(configuration)
                    throw DisplayControlError.configuration(result.rawValue)
                }
            }
        }
        let result = CGCompleteDisplayConfiguration(configuration, .forSession)
        guard result == .success else { throw DisplayControlError.configuration(result.rawValue) }
        return true
    }

    func keepChanges() {
        guard !isBusy, let name = pendingName else { return }
        rollbackTask?.cancel(); rollbackTask = nil
        pendingBackup = nil; pendingName = nil; pendingLayoutOnly = false
        statusMessage = "Kept \(name.lowercased()) changes."
    }

    func revert() async {
        guard let backup = pendingBackup, !isBusy, !isSleeping else { return }
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
            // If topology changed, restore modes without imposing stale display coordinates.
            let previousLayout = Set(connected.map(\.displayUUID)) == Set(monitors.map(\.uuid)) && connected.allSatisfy({ $0.placement != nil }) && monitors.allSatisfy(\.layoutSupported) ? connected : nil
            if try configure(previousModes, layout: previousLayout) { try? await Task.sleep(for: .milliseconds(800)) }
            let skippedLayout = pendingLayoutOnly && previousLayout == nil
            var brightnessFailures: [String] = []
            var imageFailures: [String] = []
            for saved in connected where !pendingLayoutOnly {
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
            if imageFailures.isEmpty { pendingBackup = nil; pendingName = nil; pendingLayoutOnly = false }
            statusMessage = skippedLayout ? "The connected displays changed. Restored available display modes; macOS arranged the remaining screens." : "Restored the previous display settings."
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
        automaticTask?.cancel(); wakeTask?.cancel()
        for task in brightnessTasks.values { task.cancel() }
        do { try imaging.stopAllBoosts() }
        catch { errorMessage = "Could not restore colour curves before quitting: \(error.localizedDescription)"; return false }
        keyboard.stop()
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
                            modes: [fourK, native], brightness: 0.72, backend: "DDC/CI", placement: .init(x: 0, y: 0, isMain: true)),
                    Monitor(id: 1, uuid: "demo-internal", name: "Built-in Retina Display", builtIn: true, mode: retina,
                            modes: [retina], brightness: 0.55, backend: "Apple display", placement: .init(x: -1512, y: 0))]
        selectedUUID = monitors[0].uuid
        profiles = [DisplayProfile(name: "Everyday", settings: monitors.map(\.setting)), DisplayProfile(name: "Evening", settings: monitors.map(\.setting))]
    }
}
