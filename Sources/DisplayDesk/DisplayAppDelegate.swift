import AppKit
import Combine

@MainActor
final class DisplayAppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    // Discovery belongs to the app, not the status item, so hot-plug detection
    // continues even when there is no external display and no menu bar icon.
    let service: DisplayService
    let presentation = DashboardPresentation()
    @Published var menuBarVisible = false
    @Published private(set) var dashboardRequest = 0
    private var monitorObserver: AnyCancellable?

    override convenience init() { self.init(service: DisplayService()) }

    init(service: DisplayService) {
        self.service = service
        super.init()
        monitorObserver = service.$monitors
            .map { $0.contains(where: { !$0.builtIn }) }
            .removeDuplicates()
            .sink { [weak self] visible in self?.menuBarVisible = visible }
    }

    func applicationDidFinishLaunching(_ notification: Notification) { presentation.startInMenuBar() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // This request is observed by the scene, which remains alive with the
        // status item removed. Reopening cannot depend on the menu label's view.
        dashboardRequest += 1
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
