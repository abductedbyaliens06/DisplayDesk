import SwiftUI
import AppKit

@main
struct DisplayDeskApp: App {
    @NSApplicationDelegateAdaptor(DisplayAppDelegate.self) private var delegate
    var body: some Scene {
        // The status item and explicit dashboard windows are owned by AppKit.
        // Do not observe display discovery at the application/scene root: doing
        // so can repeatedly rebuild the app's main-menu graph on macOS.
        Settings { DisplaySettings(service: delegate.service) }
            .commands {
                CommandGroup(replacing: .appTermination) {
                    Button("Quit Display Desk") { NSApplication.shared.terminate(nil) }.keyboardShortcut("q")
                }
            }
    }
}
