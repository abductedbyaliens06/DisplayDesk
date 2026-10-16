import AppKit
import Combine
import SwiftUI
import OSLog

/// Insert/remove an AppKit status item without rebuilding SwiftUI's scene graph.
@MainActor
final class DisplayStatusItem: NSObject {
    private let service: DisplayService
    private let windows: DisplayWindows
    private var item: NSStatusItem?
    private let popover = NSPopover()
    private var subscriptions: Set<AnyCancellable> = []
    var isInserted: Bool { item != nil }
    private let logger = Logger(subsystem: "local.displaydesk.app", category: "StatusItem")

    init(service: DisplayService, windows: DisplayWindows) {
        self.service = service; self.windows = windows
        super.init()
        popover.behavior = .transient
        popover.animates = false
        service.$monitors
            .map { $0.contains(where: { !$0.builtIn }) }
            .removeDuplicates()
            .sink { [weak self] visible in self?.setVisible(visible) }
            .store(in: &subscriptions)
        service.$pendingName.combineLatest(service.$secondsRemaining)
            .sink { [weak self] name, seconds in self?.updateLabel(pending: name != nil, seconds: seconds) }
            .store(in: &subscriptions)
    }
    private func setVisible(_ visible: Bool) {
        if visible {
            guard item == nil else { return }
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.button?.target = self
            item.button?.action = #selector(togglePopover)
            item.button?.setAccessibilityLabel("Display Desk")
            self.item = item
            updateLabel(pending: service.hasPendingChanges, seconds: service.secondsRemaining)
            logger.info("External display available; status item inserted.")
        } else if let item {
            popover.performClose(nil)
            popover.contentViewController = nil
            NSStatusBar.system.removeStatusItem(item)
            self.item = nil
            logger.info("No external display; status item removed.")
        }
    }
    private func updateLabel(pending: Bool, seconds: Int) {
        guard let button = item?.button else { return }
        let image = NSImage(systemSymbolName: "display.2", accessibilityDescription: "Display Desk")
        image?.isTemplate = true
        button.image = image
        button.imagePosition = .imageLeading
        button.title = pending ? " \(seconds)s" : ""
        button.toolTip = pending ? "Open to keep or revert display changes" : "Display Desk"
    }
    @objc private func togglePopover() {
        guard let button = item?.button else { return }
        if popover.isShown { popover.performClose(nil); return }
        if popover.contentViewController == nil {
            popover.contentViewController = NSHostingController(rootView: QuickControls(service: service,
                openDashboard: { [weak self] in self?.popover.performClose(nil); self?.windows.openDashboard() },
                openSettings: { [weak self] in self?.popover.performClose(nil); self?.windows.openSettings() },
                openUtility: { [weak self] id in self?.popover.performClose(nil); self?.windows.openUtility(id) }))
        }
        popover.contentSize = NSSize(width: 440, height: 680)
        NSApplication.shared.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }
    isolated deinit {
        if let item { NSStatusBar.system.removeStatusItem(item) }
    }
}
