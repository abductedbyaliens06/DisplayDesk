import AppKit
import SwiftUI

/// Only the dashboard opts into a Dock presence. Settings and utility windows
/// remain usable while the application continues as a menu bar accessory.
@MainActor
final class DashboardPresentation {
    private weak var dashboard: NSWindow?
    private var observers: [NSObjectProtocol] = []
    private let changePolicy: (NSApplication.ActivationPolicy) -> Void
    private let activate: () -> Void

    init(changePolicy: @escaping (NSApplication.ActivationPolicy) -> Void = { _ = NSApplication.shared.setActivationPolicy($0) },
         activate: @escaping () -> Void = { NSApplication.shared.activate(ignoringOtherApps: true) }) {
        self.changePolicy = changePolicy
        self.activate = activate
    }

    func startInMenuBar() { changePolicy(.accessory) }

    func present(open: () -> Void) {
        changePolicy(.regular)
        open()
        activate()
    }

    func track(_ window: NSWindow) {
        guard dashboard !== window else { return }
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        dashboard = window
        window.isRestorable = false
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.changePolicy(.regular) }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.startInMenuBar() }
        })
        if window.isVisible { changePolicy(.regular) }
    }

    isolated deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }
}

struct DashboardWindowProbe: NSViewRepresentable {
    let presentation: DashboardPresentation
    func makeNSView(context: Context) -> Probe { Probe(presentation: presentation) }
    func updateNSView(_ nsView: Probe, context: Context) {
        if let window = nsView.window { presentation.track(window) }
    }
    final class Probe: NSView {
        let presentation: DashboardPresentation
        init(presentation: DashboardPresentation) {
            self.presentation = presentation
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { presentation.track(window) }
        }
    }
}
