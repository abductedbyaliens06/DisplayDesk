import AppKit
import ServiceManagement
import SwiftUI

@MainActor
final class LoginItemController: ObservableObject {
    @Published private(set) var enabled = false
    @Published private(set) var needsApproval = false
    @Published private(set) var busy = false
    @Published private(set) var message: String?
    var available: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    init() { refresh() }
    func refresh() {
        let status = SMAppService.mainApp.status
        enabled = status == .enabled || status == .requiresApproval
        needsApproval = status == .requiresApproval
    }
    func setEnabled(_ requested: Bool) async {
        guard available, !busy else { return }
        busy = true; message = nil
        defer { busy = false; refresh() }
        do {
            if requested { try SMAppService.mainApp.register() }
            else { try await SMAppService.mainApp.unregister() }
        } catch { message = error.localizedDescription }
    }
}

struct DisplaySettings: View {
    @ObservedObject var service: DisplayService
    @StateObject private var login = LoginItemController()

    var body: some View {
        Form {
            Section("Startup") {
                Toggle("Launch Display Desk at login", isOn: Binding(get: { login.enabled }, set: { requested in
                    Task { await login.setEnabled(requested) }
                })).disabled(login.busy || !login.available || service.isPreview)
                Text("Keep the app in a permanent location such as Applications before enabling this.")
                    .font(.caption).foregroundStyle(.secondary)
                if !login.available { Text("Launch the built .app to register a login item.").font(.caption).foregroundStyle(.secondary) }
                if login.needsApproval {
                    Text("Registration is waiting for approval in macOS Login Items.").font(.caption)
                    Button("Open Login Items…") { SMAppService.openSystemSettingsLoginItems() }
                }
                if let message = login.message { Text(message).font(.caption).foregroundStyle(.red) }
            }
        }
        .formStyle(.grouped).padding(12).frame(width: 560, height: 240)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in login.refresh() }
    }
}
