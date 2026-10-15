import AppKit
@preconcurrency import ApplicationServices
import DisplayDeskCore
import SwiftUI
import UniformTypeIdentifiers

private struct DiagnosticDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

struct DiagnosticsView: View {
    @ObservedObject var service: DisplayService
    @Environment(\.dismiss) private var dismiss
    @State private var exporting = false
    @State private var exportDocument = DiagnosticDocument(data: Data())
    @State private var message: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Display diagnostics").font(.title2.bold())
                    Text("Current readings and practical next steps").foregroundStyle(.secondary).font(.caption)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(22)
            Form {
                ForEach(Array(service.monitors.enumerated()), id: \.element.uuid) { index, monitor in
                    let diagnostic = service.diagnosticScreen(monitor, number: index + 1)
                    Section(monitor.name) {
                        LabeledContent("Display", value: monitor.builtIn ? "Built-in" : "External")
                        LabeledContent("Mode", value: "\(monitor.mode.resolutionLabel) · \(monitor.mode.refreshLabel)")
                        LabeledContent("Control path", value: diagnostic.controlPath.label)
                        LabeledContent("Hardware brightness", value: monitor.brightness.map { "\(Int(($0 * 100).rounded()))%" } ?? "Unavailable")
                        LabeledContent("HDR", value: monitor.imaging.hdrEnabled ? "On" : "Off")
                        LabeledContent("EDR headroom", value: String(format: "%.2f×", diagnostic.edrHeadroom))
                        ForEach(diagnostic.observations, id: \.self) { text in Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                    }
                }
                Section("Permissions") {
                    LabeledContent("Screen Recording", value: service.screenCaptureAllowed ? "Allowed" : "Not allowed; only needed for Metal boost")
                    LabeledContent("Accessibility", value: AXIsProcessTrusted() ? "Allowed" : "Not allowed; only needed for native brightness keys")
                }
            }.formStyle(.grouped)
            VStack(alignment: .leading, spacing: 10) {
                Text("Export replaces display names with numbered screens and omits device identifiers, profile paths, and raw logs. No report is sent automatically.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Refresh readings") { service.retryHardware() }.disabled(service.controlsDisabled || service.isDiscovering)
                    Spacer()
                    Button("Copy report") {
                        do {
                            let data = try service.diagnosticReport().data()
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(String(decoding: data, as: UTF8.self), forType: .string)
                            message = "Report copied."
                        } catch { message = error.localizedDescription }
                    }
                    Button("Export report…") {
                        do { exportDocument = DiagnosticDocument(data: try service.diagnosticReport().data()); exporting = true }
                        catch { message = error.localizedDescription }
                    }.buttonStyle(.borderedProminent)
                }
                if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
            }.padding(20)
        }.frame(width: 670, height: 640)
        .fileExporter(isPresented: $exporting, document: exportDocument, contentType: .json, defaultFilename: "DisplayDesk-diagnostics") { result in
            if case .failure(let error) = result { message = error.localizedDescription }
        }
    }
}
