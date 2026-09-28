import AppKit
import KeyboardShortcuts
import SwiftUI

struct ClipboardHistorySettingsView: View {
    @AppStorage(ClipboardHistorySettings.Keys.enabled) private var enabled = true
    @AppStorage(ClipboardHistorySettings.Keys.windowPosition) private var windowPosition = "lastLocation"
    @AppStorage(ClipboardHistorySettings.Keys.saveDictations) private var saveDictations = false
    @AppStorage(ClipboardHistorySettings.Keys.pasteOnClick) private var pasteOnClick = true
    @AppStorage(ClipboardHistorySettings.Keys.doubleClickPaste) private var doubleClickPaste = true
    @AppStorage(ClipboardHistorySettings.Keys.showBadges) private var showBadges = true
    @AppStorage(ClipboardHistorySettings.Keys.updateAfterPaste) private var updateAfterPaste = true
    @AppStorage(ClipboardHistorySettings.Keys.favoritesOnTop) private var favoritesOnTop = true
    @AppStorage(ClipboardHistorySettings.Keys.warnBeforeClear) private var warnBeforeClear = true
    @AppStorage(ClipboardHistorySettings.Keys.clearOnQuit) private var clearOnQuit = false
    @AppStorage(ClipboardHistorySettings.Keys.clearOnRestart) private var clearOnRestart = false
    @AppStorage(ClipboardHistorySettings.Keys.keepFavoritesOnClear) private var keepFavorites = true
    @AppStorage(ClipboardHistorySettings.Keys.keepTaggedOnClear) private var keepTagged = true
    @AppStorage(ClipboardHistorySettings.Keys.ignoreConfidential) private var ignoreConfidential = true
    @AppStorage(ClipboardHistorySettings.Keys.ignoreTransient) private var ignoreTransient = true
    @AppStorage(ClipboardHistorySettings.Keys.paused) private var paused = false
    @AppStorage(ClipboardHistorySettings.Keys.copySound) private var copySound = false
    @AppStorage(ClipboardHistorySettings.Keys.pasteSound) private var pasteSound = false
    @AppStorage(ClipboardHistorySettings.Keys.deleteSound) private var deleteSound = false
    @AppStorage(ClipboardHistorySettings.Keys.selectionSound) private var selectionSound = false
    @AppStorage(ClipboardHistorySettings.Keys.retentionCount) private var retentionCount = 500
    @AppStorage(ClipboardHistorySettings.Keys.sort) private var sort = ClipboardHistorySort.lastCopy.rawValue
    @AppStorage(ClipboardHistorySettings.Keys.copyMergeEnabled) private var copyMergeEnabled = false
    @AppStorage(ClipboardHistorySettings.Keys.copyMergeSeparator) private var copyMergeSeparator = "\n"
    @AppStorage(ClipboardHistorySettings.Keys.copyMergeUpdatesClipboard) private var copyMergeUpdatesClipboard = false
    @State private var installedApps: [(url: URL, name: String, bundleId: String, icon: NSImage)] = []
    @State private var selectedApps: [AppConfig] = []
    @State private var appSearch = ""
    @State private var showingAppPicker = false
    @State private var pendingAppDeletion: AppConfig?
    @State private var showingClearConfirmation = false
    @State private var showingDeleteAppConfirmation = false
    @State private var storageSize: Int64 = 0
    @State private var archivePassword = ""
    @State private var showingArchivePassword = false
    @State private var archiveAction: ArchiveAction = .export
    @State private var showingArchiveError = false
    @State private var archiveError = ""

    private enum ArchiveAction { case export, `import` }
    private let retentionChoices: [ClipboardRetentionPeriod] = [
        .days(1), .days(3), .days(7), .days(14), .days(30), .days(90), .days(180), .days(365), .unlimited, .never
    ]

    var body: some View {
        Form {
            Section("General") {
                Toggle("Enable Clipboard History", isOn: $enabled)
                Picker("Panel window position", selection: $windowPosition) {
                    Text("Last location").tag(ClipboardPanelPosition.lastLocation.rawValue)
                    Text("Center of screen").tag(ClipboardPanelPosition.centerScreen.rawValue)
                    Text("Pointer location").tag(ClipboardPanelPosition.pointer.rawValue)
                }
                Toggle("Save dictations to history", isOn: $saveDictations)
            }

            Section("History") {
                Toggle("Paste on click", isOn: $pasteOnClick)
                Toggle("Paste on double-click", isOn: $doubleClickPaste)
                Toggle("Always show ⌘1–9 badges", isOn: $showBadges)
                Toggle("Update history after paste", isOn: $updateAfterPaste)
                Toggle("Show favourites on top", isOn: $favoritesOnTop)
                Toggle("Warn before clearing history", isOn: $warnBeforeClear)
                Toggle("Clear history on quit", isOn: $clearOnQuit)
                Toggle("Clear history on restart", isOn: $clearOnRestart)
                Toggle("Keep favourites when clearing", isOn: $keepFavorites)
                Toggle("Keep tagged items when clearing", isOn: $keepTagged)
                Picker("Sort order", selection: $sort) {
                    Text("Most recently copied").tag(ClipboardHistorySort.lastCopy.rawValue)
                    Text("First copied").tag(ClipboardHistorySort.firstCopy.rawValue)
                    Text("Copy count").tag(ClipboardHistorySort.copyCount.rawValue)
                    Text("Size").tag(ClipboardHistorySort.size.rawValue)
                    Text("Copy sequence").tag(ClipboardHistorySort.copySequence.rawValue)
                }
                Toggle("Copy & Merge on double ⌘C", isOn: $copyMergeEnabled)
                Picker("Copy & Merge separator", selection: $copyMergeSeparator) {
                    Text("New line").tag("\n")
                    Text("Space").tag(" ")
                }
                Toggle("Update clipboard after Copy & Merge", isOn: $copyMergeUpdatesClipboard)
            }

            Section("Shortcuts") {
                LabeledContent("Open") { KeyboardShortcuts.Recorder(for: .openClipboardHistory) }
                LabeledContent("Pause / Resume") { KeyboardShortcuts.Recorder(for: .pauseClipboardHistory) }
                LabeledContent("Paste next") { KeyboardShortcuts.Recorder(for: .pasteNextClipboardItem) }
                LabeledContent("Paste next as formatted") { KeyboardShortcuts.Recorder(for: .pasteNextClipboardItemFormatted) }
            }

            Section("Sounds") {
                Toggle("Copy sound", isOn: $copySound)
                Toggle("Paste sound", isOn: $pasteSound)
                Toggle("Delete sound", isOn: $deleteSound)
                Toggle("Selection sound", isOn: $selectionSound)
            }

            Section("Privacy") {
                Toggle("Pause Clipboard History", isOn: $paused)
                    .onChange(of: paused) { _, value in ClipboardHistoryRuntime.shared.pause(value) }
                Toggle("Ignore confidential content", isOn: $ignoreConfidential)
                Toggle("Ignore transient content", isOn: $ignoreTransient)
                ForEach(selectedApps) { app in
                    HStack {
                        Text(verbatim: app.appName)
                        Spacer()
                        Button("Remove") { removeApp(app) }
                            .buttonStyle(.borderless)
                    }
                }
                Button("Add excluded app…") { showingAppPicker.toggle() }
                    .popover(isPresented: $showingAppPicker) {
                        AppPickerPopover(installedApps: filteredApps, selectedAppConfigs: $selectedApps, searchText: $appSearch)
                            .onChange(of: selectedApps) { oldValue, newValue in
                                ClipboardHistorySettings.excludedApps = Set(newValue.map(\.bundleIdentifier))
                                if let added = newValue.first(where: { candidate in !oldValue.contains(where: { $0.bundleIdentifier == candidate.bundleIdentifier }) }) {
                                    pendingAppDeletion = added
                                    showingDeleteAppConfirmation = true
                                }
                            }
                    }
            }

            Section("Storage") {
                ForEach(ClipboardItemKind.allCases, id: \.self) { kind in
                    Picker(LocalizedStringKey(kindTitle(kind)), selection: retentionBinding(for: kind)) {
                        ForEach(retentionChoicesIncludingCurrent(for: kind), id: \.storageValue) { period in
                            retentionTitle(for: period).tag(period.storageValue)
                        }
                    }
                }
                Stepper(value: $retentionCount, in: 1...10_000, step: 100) {
                    LabeledContent("Maximum items") { Text(verbatim: retentionCount.formatted()) }
                }
                LabeledContent("Current storage") { Text(verbatim: ByteCountFormatter.string(fromByteCount: storageSize, countStyle: .file)) }
                HStack {
                    Button("Export History…", action: exportArchive)
                    Button("Import History…", action: importArchive)
                    Spacer()
                    Button("Clear history…", role: .destructive) {
                        if warnBeforeClear { showingClearConfirmation = true }
                        else { clearHistory() }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .onAppear(perform: loadSettings)
        .alert("Clear Clipboard History?", isPresented: $showingClearConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Clear", role: .destructive) {
                clearHistory()
            }
        } message: {
            Text("This removes stored items. Pinned items and items protected by your settings stay in history.")
        }
        .alert("Delete Existing Items?", isPresented: $showingDeleteAppConfirmation) {
            Button("Keep Existing Items", role: .cancel) { pendingAppDeletion = nil }
            Button("Delete Items", role: .destructive) {
                if let app = pendingAppDeletion { Task { await ClipboardHistoryRuntime.shared.deleteItems(from: app.bundleIdentifier) } }
                pendingAppDeletion = nil
            }
        } message: {
            Text("Delete items already copied from this app?")
        }
        .alert("Clipboard History Error", isPresented: $showingArchiveError) {
            Button("OK", role: .cancel) {}
        } message: { Text(verbatim: archiveError) }
        .sheet(isPresented: $showingArchivePassword) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Archive Password").font(.headline)
                SecureField("Password", text: $archivePassword)
                HStack {
                    Button("Cancel") { showingArchivePassword = false }
                    Spacer()
                    Button("Continue", action: continueArchiveAction)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(24)
            .frame(width: 340)
        }
    }

    private var filteredApps: [(url: URL, name: String, bundleId: String, icon: NSImage)] {
        guard !appSearch.isEmpty else { return installedApps }
        return installedApps.filter { $0.name.localizedCaseInsensitiveContains(appSearch) || $0.bundleId.localizedCaseInsensitiveContains(appSearch) }
    }

    private func loadSettings() {
        let apps = ClipboardHistorySettings.excludedApps
        selectedApps = apps.sorted().map { id in
            let name = installedApps.first(where: { $0.bundleId == id })?.name ?? id
            return AppConfig(bundleIdentifier: id, appName: name)
        }
        let appDirectories = FileManager.default.urls(for: .applicationDirectory, in: .userDomainMask)
            + FileManager.default.urls(for: .applicationDirectory, in: .localDomainMask)
            + FileManager.default.urls(for: .applicationDirectory, in: .systemDomainMask)
        let appURLs = appDirectories.flatMap { directory -> [URL] in
            guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else { return [] }
            return enumerator.compactMap { item in
                guard let url = item as? URL, url.pathExtension == "app" else { return nil }
                enumerator.skipDescendants()
                return url
            }
        }
        installedApps = appURLs.compactMap { url in
            guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { return nil }
            return (url, bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String ?? url.deletingPathExtension().lastPathComponent, id, NSWorkspace.shared.icon(forFile: url.path))
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        selectedApps = apps.sorted().map { id in AppConfig(bundleIdentifier: id, appName: installedApps.first(where: { $0.bundleId == id })?.name ?? id) }
        Task { await refreshStorageSize() }
    }

    private func removeApp(_ app: AppConfig) {
        selectedApps.removeAll { $0.bundleIdentifier == app.bundleIdentifier }
        ClipboardHistorySettings.excludedApps = Set(selectedApps.map(\.bundleIdentifier))
    }

    private func retentionBinding(for kind: ClipboardItemKind) -> Binding<String> {
        Binding(
            get: { ClipboardHistoryEngineSettings.retentionPeriod(for: kind).storageValue },
            set: { value in
                guard let period = ClipboardRetentionPeriod(storageValue: value) else { return }
                ClipboardHistoryEngineSettings.setRetentionPeriod(period, for: kind)
            }
        )
    }

    private func kindTitle(_ kind: ClipboardItemKind) -> String {
        switch kind {
        case .plainText: "Plain text"
        case .richText: "Rich text"
        case .image: "Images"
        case .fileURLs: "Files and folders"
        case .url: "Links"
        case .color: "Colours"
        case .email: "Email"
        case .other: "Other"
        }
    }

    private func retentionChoicesIncludingCurrent(for kind: ClipboardItemKind) -> [ClipboardRetentionPeriod] {
        let current = ClipboardHistoryEngineSettings.retentionPeriod(for: kind)
        guard case .days = current, !retentionChoices.contains(current) else { return retentionChoices }
        return [current] + retentionChoices
    }

    private func retentionTitle(for period: ClipboardRetentionPeriod) -> Text {
        switch period {
        case .days(1): Text("1 day")
        case .days(3): Text("3 days")
        case .days(7): Text("7 days")
        case .days(14): Text("14 days")
        case .days(30): Text("30 days")
        case .days(90): Text("90 days")
        case .days(180): Text("6 months")
        case .days(365): Text("1 year")
        case .days(let days): Text("\(days) days")
        case .unlimited: Text("Unlimited")
        case .never: Text("Never")
        }
    }

    private func refreshStorageSize() async { storageSize = await ClipboardHistoryRuntime.shared.storageSize() }

    private func clearHistory() {
        Task {
            try? await ClipboardHistoryRuntime.shared.store?.clear(
                includingPinned: false,
                keepingFavorites: keepFavorites,
                keepingTagged: keepTagged
            )
            await refreshStorageSize()
        }
    }

    private func exportArchive() {
        archiveAction = .export
        chooseArchivePasswordAndContinue()
    }

    private func importArchive() {
        archiveAction = .import
        chooseArchivePasswordAndContinue()
    }

    private func chooseArchivePasswordAndContinue() {
        archivePassword = ""
        showingArchivePassword = true
    }

    private func continueArchiveAction() {
        showingArchivePassword = false
        if archiveAction == .export { performExport() } else { performImport() }
    }

    private func performExport() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = String(localized: "Zerm Clipboard History.zermclip")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let password = archivePassword
        Task {
            do { try await ClipboardHistoryRuntime.shared.exportArchive(to: url, password: password.isEmpty ? nil : password) }
            catch { archiveError = error.localizedDescription; showingArchiveError = true }
        }
    }

    private func performImport() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let password = archivePassword
        Task {
            do { try await ClipboardHistoryRuntime.shared.importArchive(from: url, password: password.isEmpty ? nil : password); await refreshStorageSize() }
            catch { archiveError = error.localizedDescription; showingArchiveError = true }
        }
    }
}
