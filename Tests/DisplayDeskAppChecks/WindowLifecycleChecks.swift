import AppKit
import Foundation

@main struct WindowLifecycleChecks {
    @MainActor static func main() {
        let app = NSApplication.shared
        let presentation = DashboardPresentation()
        presentation.startInMenuBar()
        precondition(app.activationPolicy() == .accessory, "Startup must have no Dock icon")
        let dashboard = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        dashboard.isReleasedWhenClosed = false
        presentation.track(dashboard)
        precondition(app.activationPolicy() == .accessory, "Creating hidden dashboard content must not add a Dock icon")
        var didOpen = false
        presentation.present { didOpen = true; dashboard.orderFront(nil) }
        precondition(didOpen && app.activationPolicy() == .regular, "Explicit dashboard invocation must show the Dock")
        let settings = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        settings.isReleasedWhenClosed = false
        settings.close()
        precondition(app.activationPolicy() == .regular, "Closing a utility window must not remove an open dashboard from the Dock")
        dashboard.close()
        precondition(app.activationPolicy() == .accessory, "Closing the dashboard must return to menu bar operation")
        presentation.present { dashboard.orderFront(nil) }
        precondition(app.activationPolicy() == .regular, "Reopening must restore the Dock")
        dashboard.close()
        precondition(app.activationPolicy() == .accessory, "Repeated dashboard closure must hide the Dock")
        print("PASS: accessory startup, hidden dashboard, explicit opening, utility close, dashboard close, and repeated reopening.")
    }
}
