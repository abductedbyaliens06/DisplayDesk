import SwiftUI
import UniformTypeIdentifiers
import AppKit
import DisplayDeskCore

private let accent = Color(red: 0.25, green: 0.51, blue: 0.95)

private struct Panel<Content: View>: View {
    @ViewBuilder var content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) { content }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.65), in: RoundedRectangle(cornerRadius: 18))
            .overlay { RoundedRectangle(cornerRadius: 18).strokeBorder(Color.primary.opacity(0.07)) }
    }
}

struct DisplayDashboard: View {
    @ObservedObject var service: DisplayService
    @State private var showingSave = false
    @State private var showingDiagnostics = false
    @State private var showingArrangement = false
    @State private var profileName = ""
    @State private var deletingProfile: DisplayProfile?

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            VStack(spacing: 0) {
                header
                if service.isPreview {
                    Label("Illustrative preview · Controls are disabled", systemImage: "eye")
                        .font(.caption).foregroundStyle(.secondary).padding(.bottom, 12)
                }
                ScrollView {
                    if let monitor = service.selected {
                        DisplayDetail(service: service, monitor: monitor).id(monitor.uuid)
                            .padding(.horizontal, 28).padding(.bottom, 24)
                    } else {
                        ContentUnavailableView("No displays found", systemImage: "display.2",
                                               description: Text("Connect a monitor, then refresh the display list."))
                            .padding(40)
                    }
                }
                if service.hasPendingChanges { confirmationBanner }
                Divider()
                footer
            }
        }
        .frame(minWidth: 920, minHeight: 680)
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(accent)
        .sheet(isPresented: $showingSave) { saveSheet }
        .sheet(isPresented: $showingDiagnostics) { DiagnosticsView(service: service) }
        .sheet(isPresented: $showingArrangement) { ArrangementView(service: service) }
        .alert("Display Desk", isPresented: Binding(get: { service.errorMessage != nil }, set: { if !$0 { service.errorMessage = nil } })) {
            Button("OK") { service.errorMessage = nil }
        } message: { Text(service.errorMessage ?? "") }
        .confirmationDialog("Delete \(deletingProfile?.name ?? "profile")?", isPresented: Binding(get: { deletingProfile != nil }, set: { if !$0 { deletingProfile = nil } })) {
            Button("Delete profile", role: .destructive) {
                if let profile = deletingProfile { service.deleteProfile(profile) }
                deletingProfile = nil
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if !service.hasPendingChanges && !service.isBusy { service.scheduleReload() }
        }
        .onChange(of: service.selectedUUID) { _, _ in service.refreshColorProfiles() }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "display.2").font(.system(size: 20, weight: .semibold)).foregroundStyle(accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Display Desk").font(.system(size: 15, weight: .semibold))
                    Text("Make every screen yours").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }.padding(.horizontal, 20).padding(.top, 25).padding(.bottom, 30)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    sectionLabel("DISPLAYS")
                    ForEach(service.monitors) { monitor in
                        Button { service.selectedUUID = monitor.uuid } label: {
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: monitor.builtIn ? "laptopcomputer" : "display")
                                    .font(.system(size: 15)).frame(width: 24).padding(.top, 3)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(monitor.name).font(.system(size: 12, weight: .medium)).lineLimit(2)
                                    Text(monitor.builtIn ? "Built-in" : "External monitor").font(.system(size: 10)).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                            .background(service.selected?.uuid == monitor.uuid ? accent.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 12))
                            .foregroundStyle(service.selected?.uuid == monitor.uuid ? accent : Color.primary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(service.selected?.uuid == monitor.uuid ? .isSelected : [])
                    }
                    sectionLabel("PROFILES").padding(.top, 28)
                    if service.profiles.isEmpty {
                        Text("Save a setup to switch between your favorite display settings.")
                            .font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.vertical, 6)
                    }
                    ForEach(service.profiles) { profile in
                        HStack(spacing: 4) {
                            Button { Task { await service.applyProfile(profile) } } label: {
                                HStack(spacing: 9) {
                                    Image(systemName: "square.stack.3d.up").foregroundStyle(.secondary)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(profile.name).font(.system(size: 12, weight: .medium))
                                        Text("\(profile.settings.count) display\(profile.settings.count == 1 ? "" : "s")").font(.system(size: 10)).foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 0)
                                }.padding(.vertical, 9).padding(.leading, 12)
                            }.buttonStyle(.plain)
                            Button { deletingProfile = profile } label: { Image(systemName: "trash").font(.system(size: 10)).padding(8) }
                                .buttonStyle(.plain).foregroundStyle(.tertiary).help("Delete \(profile.name)")
                                .accessibilityLabel("Delete \(profile.name)")
                        }.disabled(service.controlsDisabled || service.isDiscovering)
                    }
                }.padding(.horizontal, 12)
            }
            Spacer(minLength: 10)
            Button { profileName = ""; showingSave = true } label: {
                Label("Save current setup", systemImage: "plus").font(.system(size: 12, weight: .medium))
                    .frame(maxWidth: .infinity).padding(.vertical, 10)
            }
            .buttonStyle(.bordered).disabled(service.controlsDisabled || service.isDiscovering || service.monitors.isEmpty)
            .padding(16)
        }
        .frame(width: 230)
        .background(Color.primary.opacity(0.025))
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title).font(.system(size: 9, weight: .semibold)).tracking(1.2).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.bottom, 7)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 5) {
                Text(service.selected?.name ?? "Your displays").font(.system(size: 23, weight: .semibold, design: .rounded))
                Text("Brightness, clarity, and your preferred setup.").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            Button { showingArrangement = true } label: { Image(systemName: "rectangle.3.group").frame(width: 28, height: 28) }
                .buttonStyle(.bordered).help("Arrange displays").accessibilityLabel("Arrange displays")
                .disabled(service.controlsDisabled || service.monitors.isEmpty)
            Button { showingDiagnostics = true } label: { Image(systemName: "stethoscope").frame(width: 28, height: 28) }
                .buttonStyle(.bordered).help("Display diagnostics").accessibilityLabel("Diagnostics")
            SettingsLink { Image(systemName: "gearshape").frame(width: 28, height: 28) }
                .buttonStyle(.bordered).help("Display Desk settings").accessibilityLabel("Settings")
            if service.isDiscovering || service.isBusy || service.isRecovering { ProgressView().controlSize(.small) }
            Button { service.retryHardware() } label: { Image(systemName: "arrow.clockwise").frame(width: 28, height: 28) }
                .buttonStyle(.bordered).help("Refresh displays and brightness").accessibilityLabel("Refresh displays")
                .disabled(service.isBusy || service.hasPendingChanges || service.isPreview)
        }.padding(28)
    }

    private var confirmationBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "timer").font(.title3).foregroundStyle(accent)
            VStack(alignment: .leading, spacing: 4) {
                Text("Does everything look right?").font(.system(size: 13, weight: .semibold))
                Text("Reverting in \(service.secondsRemaining)s unless you keep these changes.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer()
            Button("Revert") { Task { await service.revert() } }.keyboardShortcut(.cancelAction)
            Button("Keep changes") { service.keepChanges() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
        }
        .padding(18).background(accent.opacity(0.09)).disabled(service.isBusy)
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Circle().fill(service.monitors.isEmpty ? Color.secondary : .green).frame(width: 6, height: 6)
            Text(service.statusMessage ?? "\(service.monitors.count) display\(service.monitors.count == 1 ? "" : "s") connected")
                .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            Button("Reset boost & dimming") { service.resetImageAdjustments() }
                .font(.system(size: 10)).buttonStyle(.link).disabled(service.isPreview || service.isBusy)
                .keyboardShortcut("0", modifiers: [.command, .option])
        }.padding(.horizontal, 28).padding(.vertical, 13)
    }

    private var saveSheet: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Save your display setup").font(.system(size: 21, weight: .semibold, design: .rounded))
            Text("Capture resolution, refresh rate, brightness, colour profile, HDR mode, boost, and dimming for all connected displays.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            TextField("Profile name", text: $profileName).textFieldStyle(.roundedBorder).accessibilityLabel("Profile name")
            HStack {
                Spacer()
                Button("Cancel") { showingSave = false }.keyboardShortcut(.cancelAction)
                Button("Save profile") {
                    let previousCount = service.profiles.count
                    service.saveProfile(name: profileName)
                    if service.profiles.count > previousCount { showingSave = false }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(profileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(28).frame(width: 400)
    }
}

private struct DisplayDetail: View {
    @ObservedObject var service: DisplayService
    let monitor: Monitor
    @State private var modeID: String

    init(service: DisplayService, monitor: Monitor) {
        self.service = service; self.monitor = monitor
        _modeID = State(initialValue: monitor.mode.id)
    }
    private var chosen: ModeSpec { monitor.modes.first { $0.id == modeID } ?? monitor.mode }
    private var resolution: Binding<String> {
        Binding(get: { chosen.resolutionID }, set: { value in
            let matches = monitor.modes.filter { $0.resolutionID == value }
            if let best = matches.min(by: { abs($0.refreshRate - chosen.refreshRate) < abs($1.refreshRate - chosen.refreshRate) }) { modeID = best.id }
        })
    }

    var body: some View {
        VStack(spacing: 18) {
            Panel {
                HStack(spacing: 22) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12).fill(LinearGradient(colors: [accent.opacity(0.20), accent.opacity(0.03)], startPoint: .topLeading, endPoint: .bottomTrailing))
                        Image(systemName: monitor.builtIn ? "laptopcomputer" : "display").font(.system(size: 54, weight: .ultraLight)).foregroundStyle(accent)
                    }.frame(width: 140, height: 96)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(monitor.mode.resolutionLabel).font(.system(size: 19, weight: .semibold, design: .rounded)).monospacedDigit()
                        Text(monitor.mode.refreshLabel).font(.system(size: 12)).foregroundStyle(.secondary)
                        HStack(spacing: 5) {
                            Image(systemName: monitor.brightnessSupported ? "checkmark.circle.fill" : "circle.dashed")
                            Text(monitor.backend)
                        }.font(.system(size: 10, weight: .medium)).foregroundStyle(monitor.brightnessSupported ? accent : .secondary)
                    }
                    Spacer(minLength: 0)
                }
            }
            Panel {
                HStack {
                    Label("Brightness", systemImage: "sun.max").font(.system(size: 14, weight: .semibold))
                    Spacer()
                    Text(monitor.brightness.map { "\(Int(($0 * 100).rounded()))%" } ?? "Unavailable")
                        .font(.system(size: 19, weight: .semibold, design: .rounded)).monospacedDigit()
                }
                HStack(spacing: 12) {
                    Image(systemName: "sun.min").foregroundStyle(.secondary)
                    Slider(value: Binding(get: { monitor.brightness ?? 0.5 }, set: { service.setBrightness(uuid: monitor.uuid, value: $0) }), in: 0...1)
                        .accessibilityLabel("Hardware brightness for \(monitor.name)")
                    Image(systemName: "sun.max.fill").foregroundStyle(accent)
                }.disabled(service.controlsDisabled || !monitor.brightnessSupported || monitor.brightness == nil || service.isDiscovering)
                Text(monitor.brightnessSupported ? "Adjusts the display's actual backlight using \(monitor.backend)." : (monitor.backend.contains("read-only") ? "The monitor did not apply the backlight change. Use software dimming, or check HDR/monitor settings and Refresh to retry." : "Hardware brightness is unavailable. Enable DDC/CI in your monitor's menu; some adapters block it."))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Divider().opacity(0.5)
                HStack {
                    Text("Software dimming").font(.system(size: 12, weight: .medium))
                    Spacer()
                    Text("\(Int((monitor.dimming * 100).rounded()))%").font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary)
                }
                Slider(value: Binding(get: { monitor.dimming }, set: { service.setDimming(uuid: monitor.uuid, amount: $0) }), in: 0...0.8)
                    .accessibilityLabel("Software dimming for \(monitor.name)").disabled(service.controlsDisabled)
                Text("Darkens the image without changing backlight power. Resets when Display Desk quits.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            ImagingControls(service: service, monitor: monitor)
            Panel {
                Label("Resolution & refresh rate", systemImage: "viewfinder").font(.system(size: 14, weight: .semibold))
                HStack(alignment: .top, spacing: 20) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Looks like").font(.system(size: 11)).foregroundStyle(.secondary)
                        Picker("Resolution", selection: resolution) {
                            ForEach(monitor.resolutions, id: \.resolutionID) { mode in Text(mode.resolutionLabel).tag(mode.resolutionID) }
                        }.labelsHidden().frame(maxWidth: .infinity)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Refresh rate").font(.system(size: 11)).foregroundStyle(.secondary)
                        Picker("Refresh rate", selection: $modeID) {
                            ForEach(monitor.modes.filter { $0.resolutionID == chosen.resolutionID }) { mode in Text(mode.refreshLabel).tag(mode.id) }
                        }.labelsHidden().frame(maxWidth: .infinity)
                    }
                }.disabled(service.controlsDisabled)
                HStack {
                    Text("Available modes supplied by macOS. Changes revert after 15 seconds unless confirmed.")
                        .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 12)
                    Button("Apply mode") { Task { await service.changeMode(uuid: monitor.uuid, mode: chosen) } }
                        .buttonStyle(.borderedProminent).disabled(service.controlsDisabled || chosen.matches(monitor.mode))
                }
            }
        }
        .onChange(of: monitor.mode.id) { _, value in modeID = value }
    }
}

private struct ImagingControls: View {
    @ObservedObject var service: DisplayService
    let monitor: Monitor
    @State private var importing = false
    @State private var boost = 1.0
    @State private var editingBoost = false
    @State private var hdrChoice = false
    @State private var changingHDR = false

    var body: some View {
        Panel {
            Label("Colour & HDR", systemImage: "paintpalette").font(.system(size: 14, weight: .semibold))
            Text("Keep hardware brightness adjustable using an unlocked monitor preset. Match its colours with a display ICC profile.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            HStack(alignment: .bottom, spacing: 12) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Colour profile").font(.system(size: 11)).foregroundStyle(.secondary)
                    Picker("Colour profile", selection: Binding(get: { monitor.imaging.profileID }, set: { id in
                        Task { await service.changeColorProfile(uuid: monitor.uuid, profileID: id) }
                    })) {
                        ForEach(service.colorProfiles) { profile in Text(profile.name).tag(profile.id) }
                    }.labelsHidden().frame(maxWidth: .infinity)
                }
                Button("Import ICC…") { importing = true }
            }.disabled(service.controlsDisabled || service.isDiscovering)
            Text("Active: \(monitor.imaging.profileName)").font(.system(size: 10)).foregroundStyle(.secondary)
            Text("Use a measured profile made for this monitor and preset. Generic Display P3 is a colour-space description, not a calibration or the monitor's DCI-P3 gamut clamp.")
                .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Divider().opacity(0.5)
            Toggle(isOn: Binding(get: { hdrChoice }, set: { enabled in
                guard !changingHDR && !service.controlsDisabled else { return }
                hdrChoice = enabled
                changingHDR = true
                let uuid = monitor.uuid
                Task {
                    await service.changeHDR(uuid: uuid, enabled: enabled)
                    hdrChoice = service.monitors.first(where: { $0.uuid == uuid })?.imaging.hdrEnabled ?? false
                    changingHDR = false
                }
            })) {
                HStack {
                    Text("HDR mode").font(.system(size: 12, weight: .medium))
                    Spacer()
                    Text(changingHDR ? "Switching…" : (monitor.imaging.hdrEnabled ? "HDR" : "SDR")).font(.caption).foregroundStyle(.secondary)
                }
            }.toggleStyle(.switch).disabled(changingHDR || service.controlsDisabled || !monitor.imaging.hdrSupported)
                .accessibilityLabel("HDR mode for \(monitor.name)")
            Text(monitor.imaging.hdrSupported ? "HDR and colour-profile changes have a 15-second keep/revert preview. Your monitor controls its HDR colour rendering." : "macOS does not expose HDR switching for this display.")
                .font(.system(size: 10)).foregroundStyle(.secondary)
            Divider().opacity(0.5)
            HStack {
                Label("HDR desktop boost", systemImage: "sun.max.trianglebadge.exclamationmark").font(.system(size: 12, weight: .medium))
                Text("Experimental").font(.system(size: 9, weight: .medium)).padding(.horizontal, 6).padding(.vertical, 3)
                    .background(accent.opacity(0.10), in: Capsule())
                Spacer()
                Text("\(Int((monitor.imaging.boost * 100).rounded()))%").font(.system(size: 16, weight: .semibold, design: .rounded)).monospacedDigit()
            }
            Slider(value: $boost, in: 1...2, step: 0.05, onEditingChanged: { editing in
                editingBoost = editing
                if !editing { Task { await service.setHDRBoost(uuid: monitor.uuid, factor: boost) } }
            }).accessibilityLabel("HDR desktop brightness boost for \(monitor.name)")
                .disabled(service.controlsDisabled || !monitor.imaging.hdrEnabled || monitor.dimming > 0)
            HStack {
                Text("100% · Neutral").font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "Available EDR headroom: %.2f×", monitor.imaging.headroom)).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Text(monitor.imaging.hdrEnabled ? "Uses available HDR headroom, capped at 200%. May clip HDR highlights or alter colour; output is not measured nits. Disable other apps' colour adjustments. Set dimming to 0% first. Boost resets on quit." : "Enable HDR to use real brightness headroom. This does not bypass the locked DCI-P3 monitor preset.")
                .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Text("Method: \(monitor.imaging.boostMethod == "metal" ? "Metal desktop rendering" : "Colour curves")")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                Button("Try Metal boost") {
                    Task { await service.setHDRBoost(uuid: monitor.uuid, factor: max(1.1, boost), useMetal: true) }
                }.font(.system(size: 11)).disabled(service.controlsDisabled || !monitor.imaging.hdrEnabled || monitor.dimming > 0)
            }
            Text("Metal is an alternative when macOS clamps colour curves. It processes this screen locally at up to 60 fps, adds GPU work and latency, and tone-maps captured HDR content. No audio, recordings, or uploads.")
                .font(.system(size: 10)).foregroundStyle(.secondary)
            if !service.screenCaptureAllowed {
                Button("Allow Screen Recording…") { CGRequestScreenCaptureAccess() }
                    .font(.system(size: 11)).disabled(service.isPreview)
            }
            HStack {
                Button("Reset boost") { boost = 1; Task { await service.setHDRBoost(uuid: monitor.uuid, factor: 1) } }
                    .disabled(service.controlsDisabled || monitor.imaging.boost <= 1)
                Spacer()
                Button("Restore original colour & HDR") { Task { await service.restoreOriginalImaging(uuid: monitor.uuid) } }
                    .disabled(service.controlsDisabled || !service.hasOriginalImaging(uuid: monitor.uuid))
            }.font(.system(size: 11))
        }
        .onAppear { boost = monitor.imaging.boost; hdrChoice = monitor.imaging.hdrEnabled }
        .onChange(of: monitor.imaging.hdrEnabled) { _, value in if !changingHDR { hdrChoice = value } }
        .onChange(of: monitor.imaging.boost) { _, value in if !editingBoost { boost = value } }
        .fileImporter(isPresented: $importing, allowedContentTypes: [UTType(filenameExtension: "icc") ?? .data, UTType(filenameExtension: "icm") ?? .data]) { result in
            switch result {
            case .success(let url):
                Task {
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    await service.importColorProfile(uuid: monitor.uuid, url: url)
                }
            case .failure(let error): service.errorMessage = error.localizedDescription
            }
        }
    }
}

struct QuickControls: View {
    @ObservedObject var service: DisplayService
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("Display Desk", systemImage: "display.2").font(.system(size: 14, weight: .semibold))
                Spacer()
                Text("\(service.monitors.count) connected").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(service.monitors) { monitor in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(monitor.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                        Spacer()
                        Text(monitor.brightness.map { "\(Int(($0 * 100).rounded()))%" } ?? "Software only").font(.caption).foregroundStyle(.secondary)
                    }
                    if monitor.brightnessSupported && monitor.brightness != nil {
                        Slider(value: Binding(get: { monitor.brightness ?? 0.5 }, set: { service.setBrightness(uuid: monitor.uuid, value: $0) }), in: 0...1)
                            .accessibilityLabel("Brightness for \(monitor.name)").disabled(service.controlsDisabled || service.isDiscovering)
                    } else {
                        Slider(value: Binding(get: { monitor.dimming }, set: { service.setDimming(uuid: monitor.uuid, amount: $0) }), in: 0...0.8)
                            .accessibilityLabel("Software dimming for \(monitor.name)").disabled(service.controlsDisabled)
                        Text("Software dimming").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            if service.hasPendingChanges {
                Text("Confirm changes in the dashboard · \(service.secondsRemaining)s").font(.caption).foregroundStyle(accent)
            }
            Divider()
            Button("Open display dashboard") { openWindow(id: "dashboard"); NSApplication.shared.activate(ignoringOtherApps: true) }
                .buttonStyle(.borderedProminent).frame(maxWidth: .infinity)
            SettingsLink { Text("Settings…") }
            Button("Reset boost & dimming") { service.resetImageAdjustments() }.buttonStyle(.link)
            Button("Quit Display Desk") { Task { if await service.prepareToQuit() { NSApplication.shared.terminate(nil) } } }.buttonStyle(.link)
        }.padding(18).frame(width: 340).tint(accent)
    }
}
