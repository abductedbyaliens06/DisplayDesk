import AppKit
@preconcurrency import ApplicationServices
import Carbon
import Combine

@MainActor
final class BrightnessKeyboard: ObservableObject {
    @Published private(set) var shortcutsEnabled: Bool
    @Published private(set) var nativeKeysEnabled: Bool
    @Published private(set) var nativeKeysActive = false
    @Published private(set) var message: String?
    @Published var target: String { didSet { UserDefaults.standard.set(target, forKey: "brightnessKeyboardTarget") } }
    var canAdjust: (() -> Bool)?
    var adjust: ((Double) -> Void)?
    private var hotKeys: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?
    private var localMonitor: Any?
    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var swallowedNativeKeys = Set<Int>()
    private let signature: OSType = 0x4444534b // DDSK

    init() {
        let defaults = UserDefaults.standard
        shortcutsEnabled = defaults.bool(forKey: "brightnessKeyboardShortcuts")
        nativeKeysEnabled = defaults.bool(forKey: "brightnessNativeKeys")
        target = defaults.string(forKey: "brightnessKeyboardTarget") ?? "pointer"
    }
    func start() { configureShortcuts(); refreshNativeKeys() }
    func setShortcutsEnabled(_ enabled: Bool) {
        shortcutsEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "brightnessKeyboardShortcuts")
        configureShortcuts()
    }
    func setNativeKeysEnabled(_ enabled: Bool) {
        nativeKeysEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "brightnessNativeKeys")
        refreshNativeKeys()
    }
    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        refreshNativeKeys()
    }
    private func configureShortcuts() {
        if let localMonitor { NSEvent.removeMonitor(localMonitor); self.localMonitor = nil }
        for key in hotKeys { UnregisterEventHotKey(key) }; hotKeys.removeAll()
        if let handler { RemoveEventHandler(handler); self.handler = nil }
        message = nil
        guard shortcutsEnabled else { return }
        var specification = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var key = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                    MemoryLayout<EventHotKeyID>.size, nil, &key) == noErr else { return OSStatus(eventNotHandledErr) }
            let controller = Unmanaged<BrightnessKeyboard>.fromOpaque(context).takeUnretainedValue()
            return MainActor.assumeIsolated {
                guard key.signature == controller.signature, controller.canAdjust?() == true else { return OSStatus(eventNotHandledErr) }
                controller.adjust?(key.id == 1 ? -0.05 : 0.05)
                return noErr
            }
        }, 1, &specification, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard installed == noErr else { message = "Could not install the keyboard shortcut handler."; return }
        for (id, code) in [(UInt32(1), UInt32(kVK_UpArrow)), (UInt32(2), UInt32(kVK_DownArrow))] {
            // Up increases; Down decreases.
            let identifier = EventHotKeyID(signature: signature, id: id == 1 ? 2 : 1)
            var key: EventHotKeyRef?
            let result = RegisterEventHotKey(code, UInt32(controlKey | optionKey), identifier, GetApplicationEventTarget(), 0, &key)
            guard result == noErr, let key else {
                for registered in hotKeys { UnregisterEventHotKey(registered) }; hotKeys.removeAll()
                if let handler { RemoveEventHandler(handler); self.handler = nil }
                message = "⌃⌥↑/↓ is already in use or could not be registered. Disable the conflicting shortcut and try again."
                return
            }
            hotKeys.append(key)
        }
        // Registered global shortcuts normally arrive as Carbon hot-key events.
        // App-local keyDown events (including menu/window routing) are handled
        // here as well; consumed global hot keys do not also deliver keyDown.
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.shortcutsEnabled, self.canAdjust?() == true,
                  event.modifierFlags.intersection([.control, .option, .command, .shift]) == [.control, .option],
                  event.keyCode == UInt16(kVK_UpArrow) || event.keyCode == UInt16(kVK_DownArrow) else { return event }
            self.adjust?(event.keyCode == UInt16(kVK_UpArrow) ? 0.05 : -0.05)
            return nil
        }
    }
    func refreshNativeKeys() {
        guard nativeKeysEnabled, AXIsProcessTrusted() else {
            stopNativeKeys()
            if nativeKeysEnabled { message = "Native brightness keys need Accessibility permission for Display Desk. The ⌃⌥↑/↓ shortcuts do not." }
            return
        }
        guard tap == nil else { return }
        let eventMask = CGEventMask(1) << CGEventType(rawValue: UInt32(NSEvent.EventType.systemDefined.rawValue))!.rawValue
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: eventMask,
                               callback: { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            let controller = Unmanaged<BrightnessKeyboard>.fromOpaque(context).takeUnretainedValue()
            let swallowed = MainActor.assumeIsolated {
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let tap = controller.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                    return false
                }
                guard let native = NSEvent(cgEvent: event), native.type == .systemDefined, native.subtype.rawValue == 8 else {
                    return false
                }
                let key = (native.data1 & 0xffff0000) >> 16
                let state = (native.data1 & 0xff00) >> 8
                guard key == 2 || key == 3 else { return false }
                if state == 0x0b, controller.swallowedNativeKeys.remove(key) != nil { return true }
                guard state == 0x0a, controller.canAdjust?() == true else { return false }
                controller.swallowedNativeKeys.insert(key)
                let step = native.modifierFlags.contains(.shift) ? 0.01 : 0.05
                controller.adjust?(key == 2 ? step : -step)
                return true
            }
            return swallowed ? nil : Unmanaged.passUnretained(event)
        }, userInfo: Unmanaged.passUnretained(self).toOpaque())
        guard let tap else { message = "macOS did not allow native brightness-key interception. Check Accessibility access and reopen the app."; return }
        tapSource = CFMachPortCreateRunLoopSource(nil, tap, 0)
        if let tapSource { CFRunLoopAddSource(CFRunLoopGetMain(), tapSource, .commonModes) }
        CGEvent.tapEnable(tap: tap, enable: true)
        nativeKeysActive = true; message = nil
    }
    private func stopNativeKeys() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes) }
        tap = nil; tapSource = nil; nativeKeysActive = false; swallowedNativeKeys.removeAll()
    }
    func stop() {
        if let localMonitor { NSEvent.removeMonitor(localMonitor); self.localMonitor = nil }
        for key in hotKeys { UnregisterEventHotKey(key) }; hotKeys.removeAll()
        if let handler { RemoveEventHandler(handler); self.handler = nil }
        stopNativeKeys()
    }
    isolated deinit { stop() }
}
