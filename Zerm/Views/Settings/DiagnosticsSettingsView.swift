import SwiftUI

struct DiagnosticsSettingsView: View {
    @AppStorage(DebugLogger.defaultsKey) private var isDebugLoggingEnabled = false
    @State private var isExportingLogs = false
    @State private var exportedLogURL: URL?
    @State private var showLogExportError = false
    @State private var logExportError: String = ""

    var body: some View {
        Toggle(isOn: $isDebugLoggingEnabled) {
            HStack(spacing: 4) {
                Text("Debug Logging")
                InfoTip(
                    "Writes a detailed record of what Zerm is doing to a file on this Mac. Turn it on only while reproducing a problem you want to report, then turn it off — the log grows quickly and can contain the text of your transcriptions.",
                    doc: .commonIssues
                )
            }
        }

        if isDebugLoggingEnabled {
            LabeledContent {
                Button("Show in Finder") {
                    revealDebugLog()
                }
            } label: {
                HStack(spacing: 4) {
                    Text("Debug Log File")
                    InfoTip("Opens the folder holding the debug log so you can read it or attach it to a bug report. Have a look through it before sending it on.")
                }
            }
        }

        LabeledContent {
            HStack(spacing: 8) {
                if let url = exportedLogURL {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }

                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                }

                Button("Export") {
                    exportDiagnosticLogs()
                }
                .disabled(isExportingLogs)
            }
        } label: {
            HStack(spacing: 4) {
                if isExportingLogs {
                    ProgressView()
                        .controlSize(.small)
                }
                Text("Export Logs")
                InfoTip(
                    "Gathers Zerm's system log entries into one file you can attach to a bug report. This works whether or not Debug Logging is on, but the file is far more useful with it enabled.",
                    doc: .commonIssues
                )
            }
        }
        .alert("Export Failed", isPresented: $showLogExportError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(logExportError)
        }
    }

    private func revealDebugLog() {
        let fileURL = DebugLogger.shared.logFileURL
        if FileManager.default.fileExists(atPath: fileURL.path) {
            NSWorkspace.shared.activateFileViewerSelecting([fileURL])
        } else {
            try? FileManager.default.createDirectory(at: DebugLogger.shared.logsDirectory, withIntermediateDirectories: true)
            NSWorkspace.shared.activateFileViewerSelecting([DebugLogger.shared.logsDirectory])
        }
    }

    private func exportDiagnosticLogs() {
        isExportingLogs = true
        exportedLogURL = nil

        Task {
            do {
                let url = try await LogExporter.shared.exportLogs()
                await MainActor.run {
                    exportedLogURL = url
                    isExportingLogs = false
                }
            } catch {
                await MainActor.run {
                    logExportError = error.localizedDescription
                    showLogExportError = true
                    isExportingLogs = false
                }
            }
        }
    }
}
