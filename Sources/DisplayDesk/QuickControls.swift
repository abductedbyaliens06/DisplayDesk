import AppKit
import SwiftUI
import DisplayDeskCore

private enum QuickTab: String, CaseIterable { case display = "Display", profiles = "Profiles" }

struct QuickControls: View {
    @ObservedObject var service: DisplayService
    let presentation: DashboardPresentation
    @Environment(\.openWindow) private var openWindow
    @State private var tab: QuickTab = .display
    @State private var profileName = ""
    @State private var deleting: DisplayProfile?
    private let accent = Color(red: 0.25, green: 0.51, blue: 0.95)

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "display.2").font(.title3).foregroundStyle(accent)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Display Desk").font(.system(size: 14, weight: .semibold))
                    Text("\(service.monitors.count) display\(service.monitors.count == 1 ? "" : "s") connected")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer()
                if service.isDiscovering || service.isBusy || service.isRecovering { ProgressView().controlSize(.small) }
                Button { service.retryHardware() } label: { Image(systemName: "arrow.clockwise").frame(width: 26, height: 26) }
                    .buttonStyle(.borderless).accessibilityLabel("Refresh displays")
                    .disabled(service.controlsDisabled || service.isDiscovering)
                SettingsLink { Image(systemName: "gearshape").frame(width: 26, height: 26) }
                    .buttonStyle(.borderless).accessibilityLabel("Display Desk settings")
            }.padding(18)
            Picker("Controls", selection: $tab) { ForEach(QuickTab.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.segmented).padding(.horizontal, 18).padding(.bottom, 14)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let error = service.errorMessage {
                        VStack(alignment: .leading, spacing: 6) {
                            Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                            Button("Dismiss message") { service.errorMessage = nil }.font(.caption).buttonStyle(.link)
                        }.padding(12).background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                    }
                    if service.isPreview { Text("Illustrative preview · controls disabled").font(.caption).foregroundStyle(.secondary) }
                    if tab == .display { displayControls } else { profiles }
                    if let message = service.statusMessage { Text(message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                }.padding(.horizontal, 18).padding(.bottom, 16).frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: .infinity)
            if service.hasPendingChanges { confirmation }
            Divider()
            HStack(spacing: 12) {
                Button("Open dashboard") { presentation.present { openWindow(id: "dashboard") } }
                    .buttonStyle(.borderedProminent)
                Spacer(minLength: 0)
                Menu {
                    Button("Arrange displays…") { openUtility("arrangement") }
                    Button("Diagnostics…") { openUtility("diagnostics") }
                    Divider()
                    Button("Reset boost & dimming") { service.resetImageAdjustments() }.disabled(service.controlsDisabled)
                    Divider()
                    Button("Quit Display Desk") { NSApplication.shared.terminate(nil) }
                } label: { Image(systemName: "ellipsis").frame(width: 24, height: 24) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().accessibilityLabel("More display controls")
            }.padding(16)
        }
        .frame(width: 440, height: 680)
        .background(Color(nsColor: .windowBackgroundColor)).tint(accent)
        .onAppear {
            if !service.controlsDisabled && !service.isDiscovering { service.scheduleReload() }
            service.refreshColorProfiles()
        }
        .onChange(of: service.selectedUUID) { _, _ in service.refreshColorProfiles() }
        .confirmationDialog("Delete \(deleting?.name ?? "profile")?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete profile", role: .destructive) { if let deleting { service.deleteProfile(deleting) }; deleting = nil }
        }
    }
    @ViewBuilder private var displayControls: some View {
        if let monitor = service.selected {
            Picker("Display", selection: Binding(get: { service.selected?.uuid ?? "" }, set: { service.selectedUUID = $0 })) {
                ForEach(service.monitors) { Text($0.name).tag($0.uuid) }
            }.disabled(service.isBusy || service.imagingBusy)
            DisplayDetail(service: service, monitor: monitor, compact: true).id(monitor.uuid)
        } else {
            ContentUnavailableView("No displays found", systemImage: "display.2", description: Text("Connect a display, then refresh."))
        }
    }
    private var profiles: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Your saved setups").font(.headline)
            Text("Apply brightness, display modes, colour/HDR, and saved layout together. Keep or revert the preview here.")
                .font(.caption).foregroundStyle(.secondary)
            if service.profiles.isEmpty { Text("Save your current setup to get started.").font(.caption).foregroundStyle(.secondary) }
            ForEach(service.profiles) { profile in
                HStack {
                    Button { Task { await service.applyProfile(profile) } } label: {
                        HStack(spacing: 9) {
                            Image(systemName: "square.stack.3d.up").foregroundStyle(accent)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(profile.name).font(.system(size: 12, weight: .medium))
                                Text("\(profile.settings.count) display(s)").font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary)
                        }.padding(12).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
                    }.buttonStyle(.plain)
                    Button { deleting = profile } label: { Image(systemName: "trash").frame(width: 24, height: 24) }
                        .buttonStyle(.borderless).accessibilityLabel("Delete \(profile.name)")
                }.disabled(service.controlsDisabled || service.isDiscovering)
            }
            Divider()
            Text("Save current setup").font(.system(size: 12, weight: .semibold))
            TextField("Profile name", text: $profileName).textFieldStyle(.roundedBorder).accessibilityLabel("New profile name")
            Button("Save profile") {
                let count = service.profiles.count
                service.saveProfile(name: profileName)
                if service.profiles.count > count { profileName = "" }
            }.buttonStyle(.bordered)
                .disabled(service.controlsDisabled || service.isDiscovering || service.monitors.isEmpty || profileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }
    private var confirmation: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Label("Keep these changes?", systemImage: "timer").font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("\(service.secondsRemaining)s").font(.caption).monospacedDigit()
            }
            HStack {
                Button("Revert") { Task { await service.revert() } }
                Spacer()
                Button("Keep changes") { service.keepChanges() }.buttonStyle(.borderedProminent)
            }.disabled(service.isBusy || service.imagingBusy)
        }.padding(16).background(accent.opacity(0.09))
    }
    private func openUtility(_ id: String) {
        openWindow(id: id)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}
