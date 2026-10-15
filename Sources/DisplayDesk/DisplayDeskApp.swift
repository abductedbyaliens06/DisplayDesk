import SwiftUI
import AppKit

extension Notification.Name {
    static let displayDeskShowDashboard = Notification.Name("DisplayDesk.showDashboard")
}

@MainActor
final class DisplayAppDelegate: NSObject, NSApplicationDelegate {
    weak var service: DisplayService?
    var openDashboard: (() -> Void)?
    private var dashboardObserver: NSObjectProtocol?
    func applicationDidFinishLaunching(_ notification: Notification) {
        dashboardObserver = NotificationCenter.default.addObserver(forName: .displayDeskShowDashboard, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.openDashboard?()
                NSApplication.shared.activate(ignoringOtherApps: true)
            }
        }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let service else { return .terminateNow }
        Task {
            let ready = await service.prepareToQuit()
            sender.reply(toApplicationShouldTerminate: ready)
        }
        return .terminateLater
    }
}

@main
struct DisplayDeskApp: App {
    @NSApplicationDelegateAdaptor(DisplayAppDelegate.self) private var delegate
    @StateObject private var service = DisplayService()
    @Environment(\.openWindow) private var openWindow
    var body: some Scene {
        Window("Display Desk", id: "dashboard") {
            DisplayDashboard(service: service).onAppear {
                delegate.service = service
                delegate.openDashboard = { openWindow(id: "dashboard") }
            }
        }
        .defaultSize(width: 960, height: 760)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .appTermination) {
                Button("Quit Display Desk") {
                    Task { if await service.prepareToQuit() { NSApplication.shared.terminate(nil) } }
                }.keyboardShortcut("q")
            }
        }
        Settings { DisplaySettings(service: service) }
        MenuBarExtra("Display Desk", systemImage: "display.2") { QuickControls(service: service) }
            .menuBarExtraStyle(.window)
    }
}
