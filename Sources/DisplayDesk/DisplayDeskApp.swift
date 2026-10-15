import SwiftUI
import AppKit

@MainActor
final class DisplayAppDelegate: NSObject, NSApplicationDelegate {
    weak var service: DisplayService?
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
    var body: some Scene {
        Window("Display Desk", id: "dashboard") {
            DisplayDashboard(service: service).onAppear { delegate.service = service }
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
