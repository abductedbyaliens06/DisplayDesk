import AppKit

@MainActor
final class DisplayAppDelegate: NSObject, NSApplicationDelegate {
    let service = DisplayService()
    let presentation = DashboardPresentation()
    private lazy var windows = DisplayWindows(service: service, presentation: presentation)
    private var statusItem: DisplayStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        presentation.startInMenuBar()
        statusItem = DisplayStatusItem(service: service, windows: windows)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        windows.openDashboard()
        return false
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task {
            let ready = await service.prepareToQuit()
            sender.reply(toApplicationShouldTerminate: ready)
        }
        return .terminateLater
    }
}
