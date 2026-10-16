import AppKit
@main struct NativeItemQA {
    @MainActor static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let service = DisplayService(preview: true)
        let inventory = service.monitors
        let presentation = DashboardPresentation(changePolicy: { _ in }, activate: {})
        let windows = DisplayWindows(service: service, presentation: presentation)
        let status = DisplayStatusItem(service: service, windows: windows)
        func check(_ condition: Bool, _ message: String) {
            if !condition { service.monitors = []; FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8)); exit(1) }
        }
        check(status.isInserted, "External monitor must insert a native status item")
        for _ in 0..<5 {
            service.monitors = inventory.filter(\.builtIn)
            check(!status.isInserted, "Laptop-only state must remove the native item")
            service.monitors = inventory
            check(status.isInserted, "Reconnect must recreate the native item")
        }
        service.monitors = []
        check(!status.isInserted, "Discovery with no displays must leave no status item")
        check(NSApplication.shared.activationPolicy() == .prohibited, "QA must never register in the Dock")
        print("PASS: actual native status-item insertion/removal across five reconnect cycles; no Dock registration, windows, or hardware changes.")
    }
}
