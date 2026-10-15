import AppKit
import Foundation

@main struct WindowLifecycleChecks {
    @MainActor static func main() {
        // This process never registers in the Dock or opens a window. Only the
        // policy requests are recorded; real NSWindow close notifications are tested.
        NSApplication.shared.setActivationPolicy(.prohibited)
        var policy: NSApplication.ActivationPolicy = .prohibited
        var activations = 0
        let presentation = DashboardPresentation(changePolicy: { policy = $0 }, activate: { activations += 1 })
        func check(_ condition: Bool, _ message: String) {
            if !condition {
                FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
                exit(1)
            }
        }
        func window() -> NSWindow {
            let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            return window
        }
        presentation.startInMenuBar()
        check(policy == .accessory, "Startup must request accessory policy")
        let dashboard = window()
        presentation.track(dashboard)
        check(policy == .accessory, "Creating hidden content must not request a Dock icon")
        var didOpen = false
        presentation.present { didOpen = true }
        check(didOpen && policy == .regular && activations == 1, "Dashboard invocation must request regular policy and activation")
        let settings = window()
        settings.close()
        check(policy == .regular, "Closing a utility must preserve the dashboard policy")
        dashboard.close()
        check(policy == .accessory, "Dashboard closure must request accessory policy")
        let reopened = window()
        presentation.track(reopened)
        presentation.present { }
        check(policy == .regular && activations == 2, "Reopening must request regular policy")
        reopened.close()
        check(policy == .accessory, "Closing the reopened dashboard must request accessory policy")
        check(NSApplication.shared.activationPolicy() == .prohibited, "The test process must never become a Dock application")
        print("PASS: dashboard policy requests and native close notifications; no Dock registration or visible windows.")
    }
}
