import SwiftUI
import DisplayDeskCore

struct ArrangementView: View {
    @ObservedObject var service: DisplayService
    @Environment(\.dismiss) private var dismiss
    @State private var screens: [LayoutScreen] = []
    @State private var original: [LayoutScreen] = []
    @State private var selectedID: String?
    @State private var dragOrigin: DisplayPlacement?
    @State private var dragViewport: [LayoutScreen]?
    @State private var message: String?
    private let screenColor = Color(red: 0.16, green: 0.36, blue: 0.67)

    private var selectedIndex: Int? { screens.firstIndex { $0.id == selectedID } }
    private var topologyChanged: Bool {
        Set(service.layoutScreens.map { "\($0.id):\($0.width):\($0.height)" }) != Set(original.map { "\($0.id):\($0.width):\($0.height)" })
            || service.layoutScreens != original
    }
    private var issue: String? {
        if topologyChanged { return "The display setup changed. Reset to load its current arrangement." }
        if service.monitors.contains(where: { !$0.layoutSupported }) { return "Arrangement editing requires extended displays without rotation. Turn off mirroring in macOS Displays settings first." }
        if screens.count < 2 { return "Connect another display to arrange your workspace." }
        do { try DisplayLayout.validate(screens); return nil } catch { return error.localizedDescription }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Arrange your workspace").font(.title2.bold())
                    Text("Drag screens until their edges meet. The white bar marks your main display.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            canvas.frame(height: 290)
                .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 16))
                .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(Color.primary.opacity(0.08)) }
                .clipped()
            HStack {
                Button("Side by side") { preset(vertical: false) }
                Button("Stack vertically") { preset(vertical: true) }
                Spacer()
                Button("Reset") { reset() }
            }.disabled(service.controlsDisabled || service.isDiscovering)
            if let index = selectedIndex {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text(name(screens[index].id)).font(.headline)
                        Spacer()
                        Button(screens[index].placement.isMain ? "Main display" : "Make main display") {
                            normalize(main: screens[index].id)
                        }.disabled(screens[index].placement.isMain)
                    }
                    HStack(spacing: 14) {
                        Text("Position").foregroundStyle(.secondary)
                        coordinate("X", index: index, horizontal: true).disabled(screens[index].placement.isMain)
                        coordinate("Y", index: index, horizontal: false).disabled(screens[index].placement.isMain)
                        Spacer()
                        Text("\(screens[index].width) × \(screens[index].height) pt")
                            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                    Text(screens[index].placement.isMain ? "The main display defines position 0, 0. Drag it to move the other screens relative to it." : "Positive Y moves a screen down. Coordinates are relative to the main display.")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(16).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
            }
            Text(message ?? issue ?? "Ready to preview. Save a profile afterward to remember this arrangement.")
                .font(.caption).foregroundStyle(issue == nil && message == nil ? Color.secondary : Color.orange)
                .frame(minHeight: 28, alignment: .topLeading)
            HStack(alignment: .center) {
                Text("Changes revert after 15 seconds unless kept. Layout changes stop HDR boost; you can enable it again afterward.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 30)
                Button("Preview layout") {
                    Task {
                        message = nil
                        await service.changeArrangement(screens)
                        if service.hasPendingChanges { dismiss() }
                        else { message = service.errorMessage ?? "The layout could not be applied." }
                    }
                }.buttonStyle(.borderedProminent)
                    .disabled(issue != nil || screens == original || service.controlsDisabled || service.isDiscovering || dragOrigin != nil)
            }
        }.padding(24).frame(width: 760)
            .onAppear { reset() }
    }
    private func coordinate(_ title: String, index: Int, horizontal: Bool) -> some View {
        HStack(spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            TextField(title, value: Binding(get: {
                horizontal ? screens[index].placement.x : screens[index].placement.y
            }, set: { value in
                if horizontal { screens[index].placement.x = min(50_000, max(-50_000, value)) }
                else { screens[index].placement.y = min(50_000, max(-50_000, value)) }
                normalize(main: screens.first(where: { $0.placement.isMain })?.id)
            }), format: .number.grouping(.never))
            .textFieldStyle(.roundedBorder).frame(width: 85).accessibilityLabel("Display position \(title)")
        }
    }
    private var canvas: some View {
        GeometryReader { geometry in
            let viewport = dragViewport ?? screens
            let minX = viewport.map { $0.placement.x }.min() ?? 0
            let minY = viewport.map { $0.placement.y }.min() ?? 0
            let maxX = viewport.map { $0.placement.x + $0.width }.max() ?? 1
            let maxY = viewport.map { $0.placement.y + $0.height }.max() ?? 1
            let scale = min((geometry.size.width - 90) / Double(max(1, maxX - minX)), (geometry.size.height - 80) / Double(max(1, maxY - minY)))
            let offsetX = (geometry.size.width - Double(maxX - minX) * scale) / 2
            let offsetY = (geometry.size.height - Double(maxY - minY) * scale) / 2
            ForEach(screens) { screen in
                VStack(spacing: 7) {
                    if screen.placement.isMain {
                        Capsule().fill(.white.opacity(0.95)).frame(height: 4).padding(.horizontal, 10)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "display").font(.title3)
                    Text(name(screen.id)).font(.system(size: 11, weight: .medium)).lineLimit(2).multilineTextAlignment(.center)
                    Spacer(minLength: 0)
                }
                .padding(8)
                .frame(width: Double(screen.width) * scale, height: Double(screen.height) * scale)
                .foregroundStyle(.white)
                .background(selectedID == screen.id ? screenColor : screenColor.opacity(0.75), in: RoundedRectangle(cornerRadius: 8))
                .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(selectedID == screen.id ? 0.85 : 0.2), lineWidth: 2) }
                .position(x: offsetX + Double(screen.placement.x - minX) * scale + Double(screen.width) * scale / 2,
                          y: offsetY + Double(screen.placement.y - minY) * scale + Double(screen.height) * scale / 2)
                .onTapGesture { selectedID = screen.id }
                .gesture(DragGesture(minimumDistance: 2).onChanged { value in
                    guard let index = screens.firstIndex(where: { $0.id == screen.id }), !service.controlsDisabled else { return }
                    selectedID = screen.id
                    if dragOrigin == nil { dragOrigin = screens[index].placement; dragViewport = screens }
                    guard let start = dragOrigin else { return }
                    screens[index].placement.x = min(50_000, max(-50_000, start.x + Int((value.translation.width / scale).rounded())))
                    screens[index].placement.y = min(50_000, max(-50_000, start.y + Int((value.translation.height / scale).rounded())))
                }.onEnded { _ in
                    if let index = screens.firstIndex(where: { $0.id == screen.id }) {
                        screens[index].placement = DisplayLayout.snapped(screens[index], among: screens, distance: min(1000, Int(12 / scale)))
                        normalize(main: screens.first(where: { $0.placement.isMain })?.id)
                    }
                    dragOrigin = nil; dragViewport = nil
                })
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(name(screen.id))\(screen.placement.isMain ? ", main display" : ""), X \(screen.placement.x), Y \(screen.placement.y)")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { selectedID = screen.id }
            }
        }
    }
    private func name(_ id: String) -> String { service.monitors.first(where: { $0.uuid == id })?.name ?? "Display" }
    private func reset() {
        original = service.layoutScreens; screens = original
        selectedID = screens.first(where: { $0.placement.isMain })?.id ?? screens.first?.id
        message = nil; dragOrigin = nil; dragViewport = nil
    }
    private func normalize(main: String?) {
        guard let main else { return }
        do { screens = try DisplayLayout.normalized(screens, mainID: main); message = nil }
        catch { message = error.localizedDescription }
    }
    private func preset(vertical: Bool) {
        let main = screens.first(where: { $0.placement.isMain })?.id
        var offset = 0
        for index in screens.indices {
            screens[index].placement.x = vertical ? 0 : offset
            screens[index].placement.y = vertical ? offset : 0
            offset += vertical ? screens[index].height : screens[index].width
        }
        normalize(main: main)
    }
}
