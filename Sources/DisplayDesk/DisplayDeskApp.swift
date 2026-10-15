import SwiftUI
import AppKit

@main
struct DisplayDeskApp: App {
    @NSApplicationDelegateAdaptor(DisplayAppDelegate.self) private var delegate
    var body: some Scene { DisplayDeskScenes(delegate: delegate) }
}

private struct DisplayDeskScenes: Scene {
    @ObservedObject var delegate: DisplayAppDelegate
    @Environment(\.openWindow) private var openWindow
    var body: some Scene {
        Window("Display Desk", id: "dashboard") {
            DisplayDashboard(service: delegate.service)
                .background(DashboardWindowProbe(presentation: delegate.presentation))
        }
        .defaultSize(width: 960, height: 760)
        .windowResizability(.contentMinSize)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
        .onChange(of: delegate.dashboardRequest) { _, _ in
            delegate.presentation.present { openWindow(id: "dashboard") }
        }
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
        MenuBarExtra(isInserted: $delegate.menuBarVisible) {
            QuickControls(service: delegate.service, presentation: delegate.presentation)
        } label: {
            DisplayMenuBarLabel(service: delegate.service)
        }.menuBarExtraStyle(.window)
    }
}

private struct DisplayMenuBarLabel: View {
    @ObservedObject var service: DisplayService
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: service.hasPendingChanges ? "display.trianglebadge.exclamationmark" : "display.2")
            if service.hasPendingChanges { Text("\(service.secondsRemaining)s").monospacedDigit() }
        }
        .accessibilityLabel(service.hasPendingChanges ? "Display Desk, confirm changes within \(service.secondsRemaining) seconds" : "Display Desk")
        .help(service.hasPendingChanges ? "Open to keep or revert display changes" : "Display controls")
    }
}
