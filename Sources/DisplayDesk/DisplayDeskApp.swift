import SwiftUI
import AppKit

extension Notification.Name {
    static let displayDeskShowDashboard = Notification.Name("DisplayDesk.showDashboard")
}

@MainActor
final class DisplayAppDelegate: NSObject, NSApplicationDelegate {
    // The service must exist even when the dashboard has never been opened.
    let service = DisplayService()
    let presentation = DashboardPresentation()

    func applicationDidFinishLaunching(_ notification: Notification) { presentation.startInMenuBar() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        NotificationCenter.default.post(name: .displayDeskShowDashboard, object: nil)
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

@main
struct DisplayDeskApp: App {
    @NSApplicationDelegateAdaptor(DisplayAppDelegate.self) private var delegate
    var body: some Scene {
        Window("Display Desk", id: "dashboard") {
            DisplayDashboard(service: delegate.service)
                .background(DashboardWindowProbe(presentation: delegate.presentation))
        }
        .defaultSize(width: 960, height: 760)
        .windowResizability(.contentMinSize)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
        .commands {
            CommandGroup(replacing: .appTermination) {
                Button("Quit Display Desk") { NSApplication.shared.terminate(nil) }.keyboardShortcut("q")
            }
        }
        Window("Arrange displays", id: "arrangement") { ArrangementView(service: delegate.service) }
            .windowResizability(.contentSize).defaultLaunchBehavior(.suppressed).restorationBehavior(.disabled)
        Window("Display diagnostics", id: "diagnostics") { DiagnosticsView(service: delegate.service) }
            .windowResizability(.contentSize).defaultLaunchBehavior(.suppressed).restorationBehavior(.disabled)
        Settings { DisplaySettings(service: delegate.service) }
        MenuBarExtra {
            QuickControls(service: delegate.service, presentation: delegate.presentation)
        } label: {
            DisplayMenuBarLabel(service: delegate.service, presentation: delegate.presentation)
        }.menuBarExtraStyle(.window)
    }
}

private struct DisplayMenuBarLabel: View {
    @ObservedObject var service: DisplayService
    let presentation: DashboardPresentation
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: service.hasPendingChanges ? "display.trianglebadge.exclamationmark" : "display.2")
            if service.hasPendingChanges { Text("\(service.secondsRemaining)s").monospacedDigit() }
        }
        .accessibilityLabel(service.hasPendingChanges ? "Display Desk, confirm changes within \(service.secondsRemaining) seconds" : "Display Desk")
        .help(service.hasPendingChanges ? "Open to keep or revert display changes" : "Display controls")
        .onReceive(NotificationCenter.default.publisher(for: .displayDeskShowDashboard)) { _ in
            presentation.present { openWindow(id: "dashboard") }
        }
    }
}
