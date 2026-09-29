import AppKit
import KeyboardShortcuts
import SwiftUI
import UniformTypeIdentifiers

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
    @AppStorage(ClipboardHistorySettings.Keys.clearOnLock) private var clearOnLock = false
    @AppStorage(ClipboardHistorySettings.Keys.clearOnSleep) private var clearOnSleep = false
    @AppStorage(ClipboardHistorySettings.Keys.clearDaily) private var clearDaily = false
    @AppStorage(ClipboardHistorySettings.Keys.clearDailyTime) private var clearDailyTime = 32_400
    @AppStorage(ClipboardHistorySettings.Keys.keepFavoritesOnClear) private var keepFavorites = true
    @AppStorage(ClipboardHistorySettings.Keys.keepTaggedOnClear) private var keepTagged = true
    @AppStorage(ClipboardHistorySettings.Keys.ignoreConfidential) private var ignoreConfidential = true
    @AppStorage(ClipboardHistorySettings.Keys.ignoreTransient) private var ignoreTransient = true
    @AppStorage(ClipboardHistorySettings.Keys.paused) private var paused = false
    @AppStorage(ClipboardHistorySettings.Keys.linkPreviewsEnabled) private var linkPreviewsEnabled = true
    @AppStorage(ClipboardHistorySettings.Keys.retentionCount) private var retentionCount = 500
    @AppStorage(ClipboardHistorySettings.Keys.maximumItemSize) private var maximumItemSize = 52_428_800
    @AppStorage(ClipboardHistorySettings.Keys.maximumStorageSize) private var maximumStorageSize = 1_073_741_824
    @AppStorage(ClipboardHistorySettings.Keys.sort) private var sort = ClipboardHistorySort.lastCopy.rawValue
    @AppStorage(ClipboardHistorySettings.Keys.copyMergeEnabled) private var copyMergeEnabled = false
    @AppStorage(ClipboardHistorySettings.Keys.copyMergeSeparator) private var copyMergeSeparator = "\n"
    @AppStorage(ClipboardHistorySettings.Keys.copyMergeUpdatesClipboard) private var copyMergeUpdatesClipboard = false
    @State private var installedApps: [(url: URL, name: String, bundleId: String, icon: NSImage)] = []
    @State private var selectedApps: [AppConfig] = []
    @State private var runningApps: [(url: URL, name: String, bundleId: String, icon: NSImage)] = []
    @State private var hoveredAppID: String?
    @State private var showingClearConfirmation = false
    @State private var storageSize: Int64 = 0
    @State private var archivePassword = ""
    @State private var showingArchivePassword = false
    @State private var archiveAction: ArchiveAction = .export
    @State private var showingArchiveError = false
    @State private var archiveError = ""
    @State private var soundChoices: [String: String] = [:]
    @State private var soundVolumes: [String: Double] = [:]

    private enum ArchiveAction { case export, `import` }
    private let retentionChoices: [ClipboardRetentionPeriod] = [
        .days(1), .days(3), .days(7), .days(14), .days(30), .days(90), .days(180), .days(365), .unlimited, .never
    ]
    private let soundActions: [(id: String, title: String, key: String, fallback: String)] = [
        ("copy", "Copy", ClipboardHistorySettings.Keys.copySound, "Pop"),
        ("paste", "Paste", ClipboardHistorySettings.Keys.pasteSound, "Purr"),
        ("delete", "Delete", ClipboardHistorySettings.Keys.deleteSound, "Basso"),
        ("selection", "Selection", ClipboardHistorySettings.Keys.selectionSound, "Tink")
    ]
    private let suggestedBundleIDs = ClipboardHistorySettings.defaultExcludedApps

    var body: some View {
        Form {
            Section(header: Text("General")) {
                sectionDescription("Capture copied items locally and open history where it feels natural.")
                Toggle("Enable Clipboard History", isOn: $enabled)
                Picker("Panel window position", selection: $windowPosition) {
                    Text("Last location").tag(ClipboardPanelPosition.lastLocation.rawValue)
                    Text("Center of screen").tag(ClipboardPanelPosition.centerScreen.rawValue)
                    Text("Pointer location").tag(ClipboardPanelPosition.pointer.rawValue)
                }
                Toggle("Save dictations to history", isOn: $saveDictations)
            }

            Section(header: Text("History")) {
                sectionDescription("Choose how items paste, sort, and combine in history.")
                Toggle("Paste on click", isOn: $pasteOnClick)
                Toggle("Paste on double-click", isOn: $doubleClickPaste)
                Toggle("Always show ⌘1–9 badges", isOn: $showBadges)
                Toggle("Update history after paste", isOn: $updateAfterPaste)
                Toggle("Show favourites on top", isOn: $favoritesOnTop)
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

            Section(header: Text("Shortcuts")) {
                sectionDescription("Change keyboard shortcuts for opening, pausing, and pasting items.")
                LabeledContent("Open history") { KeyboardShortcuts.Recorder(for: .openClipboardHistory) }
                LabeledContent("Pause / Resume") { KeyboardShortcuts.Recorder(for: .pauseClipboardHistory) }
                LabeledContent("Paste next") { KeyboardShortcuts.Recorder(for: .pasteNextClipboardItem) }
                LabeledContent("Paste next as formatted") { KeyboardShortcuts.Recorder(for: .pasteNextClipboardItemFormatted) }
            }

            Section(header: Text("Privacy")) {
                sectionDescription("Choose what history ignores and what gets fetched for link previews.")
                Toggle("Pause Clipboard History", isOn: $paused)
                    .onChange(of: paused) { _, value in ClipboardHistoryRuntime.shared.pause(value) }
                Toggle("Ignore confidential content", isOn: $ignoreConfidential)
                Toggle("Ignore transient content", isOn: $ignoreTransient)
                Toggle("Show link previews", isOn: $linkPreviewsEnabled)
                Text("Link titles and images are fetched from the site.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                appExclusionGrid
                HStack(spacing: 8) {
                    Button("Add app…", action: chooseExcludedApps)
                    Button("Add suggested apps", action: addSuggestedApps)
                    Spacer()
                    Text("Selected apps are never captured.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if !runningApps.isEmpty {
                    Text("Running apps")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), alignment: .leading)], alignment: .leading, spacing: 6) {
                        ForEach(runningApps, id: \.bundleId) { app in
                            Button { addApp(app) } label: {
                                Label {
                                    Text(verbatim: app.name).lineLimit(1)
                                } icon: {
                                    Image(nsImage: app.icon).resizable().frame(width: 18, height: 18)
                                }
                            }
                            .buttonStyle(.borderless)
                            .disabled(selectedApps.contains(where: { $0.bundleIdentifier == app.bundleId }))
                        }
                    }
                }
            }

            Section(header: Text("Storage")) {
                sectionDescription("Set item limits and automatic cleanup. Favorites and tagged items follow protection choices.")
                LabeledContent("Storage used") {
                    Text(verbatim: ByteCountFormatter.string(fromByteCount: storageSize, countStyle: .file))
                        .monospacedDigit()
                }
                Stepper(value: megabyteBinding($maximumStorageSize), in: 1...1_048_576, step: 128) {
                    LabeledContent("Maximum total storage") { Text("\(maximumStorageSize / 1_048_576) MB") }
                }
                Stepper(value: megabyteBinding($maximumItemSize), in: 1...1_024, step: 10) {
                    LabeledContent("Maximum item size") { Text("\(maximumItemSize / 1_048_576) MB") }
                }
                Stepper(value: $retentionCount, in: 1...10_000, step: 100) {
                    LabeledContent("Maximum item count") { Text(verbatim: retentionCount.formatted()) }
                }
                ForEach(ClipboardItemKind.allCases, id: \.self) { kind in
                    HStack(spacing: 12) {
                        Text(kindTitle(kind)).frame(maxWidth: .infinity, alignment: .leading)
                        Picker("Retention for \(kindTitle(kind))", selection: retentionBinding(for: kind)) {
                            ForEach(retentionChoicesIncludingCurrent(for: kind), id: \.storageValue) { period in
                                retentionTitle(for: period).tag(period.storageValue)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 125)
                        Stepper(value: kindSizeBinding(for: kind), in: 0...1_048_576, step: 128) {
                            kindSizeLabel(for: kind)
                                .frame(width: 94, alignment: .trailing)
                        }
                        .help("Per-kind maximum size; 0 means unlimited.")
                    }
                }
                Toggle("Clear history on quit", isOn: $clearOnQuit)
                Toggle("Clear history on restart", isOn: $clearOnRestart)
                Toggle("Clear history on screen lock", isOn: $clearOnLock)
                Toggle("Clear history on sleep", isOn: $clearOnSleep)
                Toggle("Clear history daily", isOn: $clearDaily)
                if clearDaily {
                    DatePicker("Clear at", selection: dailyTimeBinding, displayedComponents: .hourAndMinute)
                }
                Toggle("Keep favourites when clearing", isOn: $keepFavorites)
                Toggle("Keep tagged items when clearing", isOn: $keepTagged)
                Toggle("Warn before clearing history", isOn: $warnBeforeClear)
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

            Section(header: Text("Sounds")) {
                sectionDescription("Choose a system sound or audio file for each action, then preview volume.")
                ForEach(soundActions, id: \.id) { action in
                    soundRow(action)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(Color(nsColor: .controlBackgroundColor))
        .padding(20)
        .onAppear(perform: loadSettings)
        .onChange(of: maximumStorageSize) { _, _ in
            Task { try? await ClipboardHistoryRuntime.shared.store?.cleanupExpired() }
        }
        .onChange(of: maximumItemSize) { _, _ in
            Task { try? await ClipboardHistoryRuntime.shared.store?.cleanupExpired() }
        }
        .onChange(of: retentionCount) { _, _ in
            Task { try? await ClipboardHistoryRuntime.shared.store?.cleanupExpired() }
        }
        .task {
            while !Task.isCancelled {
                await refreshStorageSize()
                try? await Task.sleep(for: .seconds(5))
            }
        }
        .alert("Clear Clipboard History?", isPresented: $showingClearConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Clear", role: .destructive, action: clearHistory)
        } message: {
            Text("This removes stored items. Pinned items and items protected by your settings stay in history.")
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
                    Button("Continue", action: continueArchiveAction).keyboardShortcut(.defaultAction)
                }
            }
            .padding(24)
            .frame(width: 340)
        }
    }

    private var appExclusionGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 175), alignment: .leading)], alignment: .leading, spacing: 8) {
            ForEach(selectedApps) { app in
                HStack(spacing: 8) {
                    if let icon = appIcon(for: app.bundleIdentifier) {
                        Image(nsImage: icon).resizable().frame(width: 24, height: 24).cornerRadius(5)
                    }
                    Text(verbatim: app.appName).lineLimit(1)
                    Spacer(minLength: 0)
                    Button { removeApp(app) } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .opacity(hoveredAppID == app.bundleIdentifier ? 1 : 0)
                    .accessibilityLabel("Remove \(app.appName)")
                }
                .padding(7)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
                .onHover { hoveredAppID = $0 ? app.bundleIdentifier : nil }
            }
        }
    }

    private func soundRow(_ action: (id: String, title: String, key: String, fallback: String)) -> some View {
        HStack(spacing: 10) {
            Text(action.title).frame(width: 75, alignment: .leading)
            Picker(action.title, selection: soundBinding(for: action)) {
                Text("None").tag("none")
                ForEach(systemSounds, id: \.self) { name in Text(verbatim: name).tag("system:\(name)") }
                if soundChoices[action.key]?.hasPrefix("custom:") == true {
                    Text("Custom audio file").tag(soundChoices[action.key]!)
                }
            }
            .labelsHidden()
            .frame(width: 175)
            Button("Choose File…") { chooseSoundFile(for: action) }
            Button { SoundManager.shared.previewClipboardSound(key: action.key, fallback: action.fallback, volume: soundVolumes[action.id] ?? 0.22) } label: {
                Image(systemName: "play.fill")
            }
            .buttonStyle(.borderless)
            .help("Play preview")
            .accessibilityLabel(String(localized: "Play preview"))
            Slider(value: volumeBinding(for: action), in: 0...1)
                .frame(minWidth: 90)
            Text("\(Int((soundVolumes[action.id] ?? 0.22) * 100))%")
                .monospacedDigit()
                .frame(width: 42, alignment: .trailing)
        }
    }

    private var systemSounds: [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: "/System/Library/Sounds"))?
            .filter { ["aiff", "wav", "m4a"] .contains(URL(fileURLWithPath: $0).pathExtension.lowercased()) }
            .map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent }
            .sorted() ?? []
    }

    private var runningAppSuggestions: [(url: URL, name: String, bundleId: String, icon: NSImage)] {
        NSWorkspace.shared.runningApplications.compactMap { app in
            guard let id = app.bundleIdentifier,
                  let url = app.bundleURL,
                  !selectedApps.contains(where: { $0.bundleIdentifier == id }) else { return nil }
            return (url, app.localizedName ?? url.deletingPathExtension().lastPathComponent, id, app.icon ?? NSWorkspace.shared.icon(forFile: url.path))
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func sectionDescription(_ value: LocalizedStringKey) -> some View {
        Text(value).font(.caption).foregroundStyle(.secondary)
    }

    private var dailyTimeBinding: Binding<Date> {
        Binding(
            get: { Calendar.current.startOfDay(for: .now).addingTimeInterval(TimeInterval(clearDailyTime)) },
            set: { date in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                clearDailyTime = (parts.hour ?? 0) * 3_600 + (parts.minute ?? 0) * 60
            }
        )
    }

    private func megabyteBinding(_ value: Binding<Int>) -> Binding<Int> {
        Binding(get: { max(1, value.wrappedValue / 1_048_576) }, set: { value.wrappedValue = $0 * 1_048_576 })
    }

    private func kindSizeBinding(for kind: ClipboardItemKind) -> Binding<Int> {
        Binding(
            get: { (ClipboardHistoryEngineSettings.maximumSize(for: kind) ?? 0) / 1_048_576 },
            set: { megabytes in
                ClipboardHistoryEngineSettings.setMaximumSize(megabytes == 0 ? nil : megabytes * 1_048_576, for: kind)
                Task { try? await ClipboardHistoryRuntime.shared.store?.cleanupExpired() }
            }
        )
    }

    private func kindSizeLabel(for kind: ClipboardItemKind) -> Text {
        guard let size = ClipboardHistoryEngineSettings.maximumSize(for: kind) else { return Text("Unlimited") }
        return Text("\(size / 1_048_576) MB")
    }

    private func soundBinding(for action: (id: String, title: String, key: String, fallback: String)) -> Binding<String> {
        Binding(
            get: { soundChoices[action.key] ?? "none" },
            set: { value in
                soundChoices[action.key] = value
                UserDefaults.standard.set(value, forKey: action.key)
            }
        )
    }

    private func volumeBinding(for action: (id: String, title: String, key: String, fallback: String)) -> Binding<Double> {
        Binding(
            get: { soundVolumes[action.id] ?? 0.22 },
            set: { value in
                soundVolumes[action.id] = value
                UserDefaults.standard.set(value, forKey: action.key + "Volume")
            }
        )
    }

    private func chooseSoundFile(for action: (id: String, title: String, key: String, fallback: String)) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let value = ClipboardHistorySoundChoice.customFile(url).storageValue
        soundChoices[action.key] = value
        UserDefaults.standard.set(value, forKey: action.key)
    }

    private func chooseExcludedApps() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard let bundle = Bundle(url: url), let bundleID = bundle.bundleIdentifier else { continue }
            addApp((url, bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? url.deletingPathExtension().lastPathComponent, bundleID, NSWorkspace.shared.icon(forFile: url.path)))
        }
    }

    private func addSuggestedApps() {
        for bundleID in suggestedBundleIDs {
            let app = installedApps.first(where: { $0.bundleId == bundleID })
            let url = app?.url ?? URL(fileURLWithPath: "/Applications")
            let name = app?.name ?? bundleID
            addApp((url, name, bundleID, app?.icon ?? NSWorkspace.shared.icon(forFile: url.path)))
        }
    }

    private func addApp(_ app: (url: URL, name: String, bundleId: String, icon: NSImage)) {
        guard !selectedApps.contains(where: { $0.bundleIdentifier == app.bundleId }) else { return }
        let config = AppConfig(bundleIdentifier: app.bundleId, appName: app.name)
        selectedApps.append(config)
        ClipboardHistorySettings.excludedApps = Set(selectedApps.map(\.bundleIdentifier))
    }

    private func loadSettings() {
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
            let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
                ?? url.deletingPathExtension().lastPathComponent
            return (url, name, id, NSWorkspace.shared.icon(forFile: url.path))
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        selectedApps = ClipboardHistorySettings.excludedApps.sorted().map { id in
            AppConfig(bundleIdentifier: id, appName: installedApps.first(where: { $0.bundleId == id })?.name ?? id)
        }
        runningApps = runningAppSuggestions
        soundChoices = Dictionary(uniqueKeysWithValues: soundActions.map { action in
            (action.key, ClipboardHistorySettings.soundChoice(for: action.key, fallback: action.fallback).storageValue)
        })
        soundVolumes = Dictionary(uniqueKeysWithValues: soundActions.map { action in
            (action.id, UserDefaults.standard.object(forKey: action.key + "Volume") as? Double ?? 0.22)
        })
        Task { await refreshStorageSize() }
    }

    private func appIcon(for bundleID: String) -> NSImage? {
        installedApps.first(where: { $0.bundleId == bundleID })?.icon
            ?? runningApps.first(where: { $0.bundleId == bundleID })?.icon
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).map { NSWorkspace.shared.icon(forFile: $0.path) }
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
                Task { try? await ClipboardHistoryRuntime.shared.store?.cleanupExpired() }
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

    private func refreshStorageSize() async {
        storageSize = await ClipboardHistoryRuntime.shared.storageSize()
    }

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
            do {
                try await ClipboardHistoryRuntime.shared.importArchive(from: url, password: password.isEmpty ? nil : password)
                await refreshStorageSize()
            } catch {
                archiveError = error.localizedDescription
                showingArchiveError = true
            }
        }
    }
}
