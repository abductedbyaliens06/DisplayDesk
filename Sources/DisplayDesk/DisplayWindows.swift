import AppKit
import SwiftUI

/// Window ownership is independent of status-item visibility and scene updates.
@MainActor
final class DisplayWindows {
    private let service: DisplayService
    private let presentation: DashboardPresentation
    private var dashboard: NSWindow?
    private var settings: NSWindow?
    private var arrangement: NSWindow?
    private var diagnostics: NSWindow?

    init(service: DisplayService, presentation: DashboardPresentation) {
        self.service = service; self.presentation = presentation
    }
    func openDashboard() {
        if dashboard == nil {
            let view = DisplayDashboard(service: service, openSettings: { [weak self] in self?.openSettings() })
            let window = makeWindow(title: "Display Desk", size: NSSize(width: 960, height: 760), resizable: true, content: view)
            presentation.track(window)
            dashboard = window
        }
        presentation.present { dashboard?.makeKeyAndOrderFront(nil) }
    }
    func openSettings() {
        if settings == nil { settings = makeWindow(title: "Display Desk Settings", size: NSSize(width: 560, height: 680), content: DisplaySettings(service: service)) }
        reveal(settings)
    }
    func openUtility(_ id: String) {
        switch id {
        case "arrangement":
            // Build a new editor so its draft always starts with the current topology.
            arrangement?.close()
            let view = ArrangementView(service: service, onDone: { [weak self] in self?.arrangement?.close() })
            arrangement = makeWindow(title: "Arrange displays", size: NSSize(width: 760, height: 660), content: view)
            reveal(arrangement)
        case "diagnostics":
            if diagnostics == nil {
                let view = DiagnosticsView(service: service, onDone: { [weak self] in self?.diagnostics?.close() })
                diagnostics = makeWindow(title: "Display diagnostics", size: NSSize(width: 670, height: 640), content: view)
            }
            reveal(diagnostics)
        default: break
        }
    }
    private func reveal(_ window: NSWindow?) {
        window?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
    private func makeWindow<Content: View>(title: String, size: NSSize, resizable: Bool = false, content: Content) -> NSWindow {
        var style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable]
        if resizable { style.insert(.resizable) }
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: style, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.title = title
        window.contentViewController = NSHostingController(rootView: content)
        if resizable { window.contentMinSize = NSSize(width: 920, height: 680) }
        window.center()
        return window
    }
}
