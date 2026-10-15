import AppKit
import ServiceManagement
import SwiftUI
import DisplayDeskCore

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
    @State private var selectedProfile: UUID?

    var body: some View {
        Form {
            KeyboardSettings(keyboard: service.keyboard, isPreview: service.isPreview)
            Section("Automatic profiles") {
                Toggle("Apply a profile when monitors connect", isOn: Binding(get: { service.automaticProfiles.enabled }, set: { service.setAutomaticProfilesEnabled($0) }))
                    .disabled(service.isPreview)
                Text("Matches the exact set of external monitors. Open the menu bar and choose Keep changes within 15 seconds; otherwise the previous setup returns.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Profile for this monitor setup", selection: $selectedProfile) {
                    Text("Choose a saved profile").tag(nil as UUID?)
                    ForEach(service.profiles) { profile in Text(profile.name).tag(Optional(profile.id)) }
                }
                Button("Use for this setup") { if let selectedProfile { service.addAutomaticProfile(profileID: selectedProfile) } }
                    .disabled(selectedProfile == nil || service.externalTopology.isEmpty || service.isPreview)
                if service.externalTopology.isEmpty { Text("Connect an external monitor to create a rule.").font(.caption).foregroundStyle(.secondary) }
                ForEach(service.automaticProfiles.rules) { rule in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(service.profiles.first { $0.id == rule.profileID }?.name ?? "Missing profile")
                            Text("\(rule.externalDisplayUUIDs.count) external monitor(s)").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Remove", role: .destructive) { service.removeAutomaticProfile(id: rule.id) }
                    }
                }
            }
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
        .formStyle(.grouped).padding(12).frame(width: 560, height: 680)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in login.refresh() }
    }
}

private struct KeyboardSettings: View {
    @ObservedObject var keyboard: BrightnessKeyboard
    let isPreview: Bool
    var body: some View {
        Section("Brightness keys") {
            Toggle("Use ⌃⌥↑ / ⌃⌥↓ shortcuts", isOn: Binding(get: { keyboard.shortcutsEnabled }, set: { keyboard.setShortcutsEnabled($0) }))
            Toggle("Use native brightness keys", isOn: Binding(get: { keyboard.nativeKeysEnabled }, set: { keyboard.setNativeKeysEnabled($0) }))
            Picker("Adjust", selection: $keyboard.target) {
                Text("Monitor under pointer").tag("pointer")
                Text("Selected monitor").tag("selected")
                Text("All connected monitors").tag("all")
            }
            Text("5% steps; hold Shift with native keys for 1% steps. Screens without hardware control use software dimming. Keys never enable HDR boost.")
                .font(.caption).foregroundStyle(.secondary)
            if keyboard.nativeKeysEnabled && !keyboard.nativeKeysActive {
                Button("Allow Accessibility…") { keyboard.requestAccessibility() }
            }
            if let message = keyboard.message { Text(message).font(.caption).foregroundStyle(.secondary) }
        }
        .disabled(isPreview)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in keyboard.refreshNativeKeys() }
    }
}
