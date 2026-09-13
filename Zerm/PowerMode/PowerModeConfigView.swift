import SwiftUI
import KeyboardShortcuts

struct ConfigurationView: View {
    let mode: ConfigurationMode
    let powerModeManager: PowerModeManager
    var onDismiss: () -> Void
    @EnvironmentObject var enhancementService: AIEnhancementService
    @EnvironmentObject var aiService: AIService
    @EnvironmentObject private var transcriptionModelManager: TranscriptionModelManager
    @FocusState private var isNameFieldFocused: Bool

    @State private var configName: String = "New Power Mode"
    @State private var selectedEmoji: String = "💼"
    @State private var isShowingEmojiPicker = false
    @State private var isShowingAppPicker = false
    @State private var outputMode: DictationOutputMode?
    @State private var selectedPromptId: UUID?
    @State private var selectedTranscriptionModelName: String?
    @State private var selectedLanguage: String?
    @State private var installedApps: [(url: URL, name: String, bundleId: String, icon: NSImage)] = []
    @State private var searchText = ""
    @State private var validationErrors: [PowerModeValidationError] = []
    @State private var showValidationAlert = false
    @State private var selectedAIProvider: String?
    @State private var selectedAIModel: String?
    @State private var selectedAppConfigs: [AppConfig] = []
    @State private var websiteConfigs: [URLConfig] = []
    @State private var newWebsiteURL: String = ""
    @State private var contextAwareness: Bool?
    @State private var isTextFormattingEnabled: Bool?
    @State private var punctuationCleanupMode: PunctuationCleanupMode?
    @State private var lowercaseTranscription: Bool?
    @State private var autoSendKey: AutoSendKey = .none
    @State private var isDefault = false
    @State private var isShowingDeleteConfirmation = false
    @State private var powerModeConfigId: UUID = UUID()

    private var effectiveModelName: String? {
        selectedTranscriptionModelName ?? transcriptionModelManager.currentTranscriptionModel?.name
    }

    private var effectiveModel: (any TranscriptionModel)? {
        transcriptionModelManager.allAvailableModels.first { $0.name == effectiveModelName }
    }

    /// Usable models, plus a saved override that is no longer usable so the picker still shows it.
    private var modelChoices: [any TranscriptionModel] {
        var models = transcriptionModelManager.usableModels
        if let name = selectedTranscriptionModelName,
           !models.contains(where: { $0.name == name }),
           let saved = transcriptionModelManager.allAvailableModels.first(where: { $0.name == name }) {
            models.append(saved)
        }
        return models
    }

    private var providerChoices: [AIProvider] {
        var providers = aiService.connectedEnhancementProviders
        if let saved = selectedAIProvider.flatMap({ AIProvider(rawValue: $0) }), !providers.contains(saved) {
            providers.append(saved)
        }
        return providers
    }

    private var filteredApps: [(url: URL, name: String, bundleId: String, icon: NSImage)] {
        if searchText.isEmpty { return installedApps }
        return installedApps.filter { app in
            app.name.localizedCaseInsensitiveContains(searchText) ||
            app.bundleId.localizedCaseInsensitiveContains(searchText)
        }
    }

    private var canSave: Bool { !configName.isEmpty }

    /// Multilingual models that detect the language themselves. English-only models of the same
    /// providers get the English-only presentation instead of "Autodetected".
    private func languageSelectionDisabled() -> Bool {
        guard let model = effectiveModel else { return false }
        return (model.provider == .fluidAudio || model.provider == .gemini) && model.isMultilingualModel
    }

    init(mode: ConfigurationMode, powerModeManager: PowerModeManager, onDismiss: @escaping () -> Void) {
        self.mode = mode
        self.powerModeManager = powerModeManager
        self.onDismiss = onDismiss

        switch mode {
        case .add:
            // A new Power Mode starts out overriding nothing.
            _powerModeConfigId = State(initialValue: UUID())
            _configName = State(initialValue: "")
            _selectedEmoji = State(initialValue: "✏️")
        case .edit(let config):
            // Fetch latest version in case config was modified elsewhere
            let latestConfig = powerModeManager.getConfiguration(with: config.id) ?? config
            _powerModeConfigId = State(initialValue: latestConfig.id)
            _outputMode = State(initialValue: latestConfig.outputMode)
            _selectedPromptId = State(initialValue: latestConfig.selectedPrompt.flatMap { UUID(uuidString: $0) })
            _selectedTranscriptionModelName = State(initialValue: latestConfig.selectedTranscriptionModelName)
            _selectedLanguage = State(initialValue: latestConfig.selectedLanguage)
            _configName = State(initialValue: latestConfig.name)
            _selectedEmoji = State(initialValue: latestConfig.emoji)
            _selectedAppConfigs = State(initialValue: latestConfig.appConfigs ?? [])
            _websiteConfigs = State(initialValue: latestConfig.urlConfigs ?? [])
            _contextAwareness = State(initialValue: latestConfig.contextAwareness)
            _isTextFormattingEnabled = State(initialValue: latestConfig.isTextFormattingEnabled)
            _punctuationCleanupMode = State(initialValue: latestConfig.punctuationCleanupMode)
            _lowercaseTranscription = State(initialValue: latestConfig.lowercaseTranscription)
            _autoSendKey = State(initialValue: latestConfig.autoSendKey)
            _isDefault = State(initialValue: latestConfig.isDefault)
            _selectedAIProvider = State(initialValue: latestConfig.selectedAIProvider)
            _selectedAIModel = State(initialValue: latestConfig.selectedAIModel)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 12) {
                Text(mode.title)
                    .font(.headline)
                    .fontWeight(.semibold)
                    .foregroundColor(.primary)

                Spacer()

                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.secondary)
                        .padding(6)
                        .background(Color.secondary.opacity(0.1))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Close")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .background(Color(NSColor.windowBackgroundColor))
            .overlay(Divider().opacity(0.5), alignment: .bottom)

            Form {
                Section("General") {
                    HStack(spacing: 12) {
                        Button {
                            isShowingEmojiPicker.toggle()
                        } label: {
                            Text(verbatim: selectedEmoji)
                                .font(.system(size: 22))
                                .frame(width: 32, height: 32)
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(Color(NSColor.controlBackgroundColor))
                                )
                        }
                        .buttonStyle(.plain)
                        .popover(isPresented: $isShowingEmojiPicker, arrowEdge: .bottom) {
                            EmojiPickerView(
                                selectedEmoji: $selectedEmoji,
                                isPresented: $isShowingEmojiPicker
                            )
                        }

                        TextField("Name", text: $configName)
                            .textFieldStyle(.roundedBorder)
                            .focused($isNameFieldFocused)
                    }
                }

                Section("Trigger Scenarios") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Applications")
                            InfoTip(
                                String(localized: "This mode switches on whenever one of these apps is the one you are working in. Apps are matched exactly, so adding Mail here has no effect while you are in a browser reading webmail — use a website trigger for that."),
                                doc: .powerMode
                            )
                            Spacer()
                            AddIconButton(helpText: "Add application") {
                                loadInstalledApps()
                                isShowingAppPicker = true
                            }
                            .popover(isPresented: $isShowingAppPicker, arrowEdge: .bottom) {
                                AppPickerPopover(
                                    installedApps: filteredApps,
                                    selectedAppConfigs: $selectedAppConfigs,
                                    searchText: $searchText
                                )
                            }
                        }

                        if selectedAppConfigs.isEmpty {
                            Text("No applications added")
                                .foregroundColor(.secondary)
                                .font(.subheadline)
                        } else {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 44, maximum: 50), spacing: 10)], spacing: 10) {
                                ForEach(selectedAppConfigs) { appConfig in
                                    ZStack(alignment: .topTrailing) {
                                        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: appConfig.bundleIdentifier) {
                                            Image(nsImage: NSWorkspace.shared.icon(forFile: appURL.path))
                                                .resizable()
                                                .aspectRatio(contentMode: .fill)
                                                .frame(width: 44, height: 44)
                                                .clipShape(RoundedRectangle(cornerRadius: 10))
                                        } else {
                                            Image(systemName: "app.fill")
                                                .resizable()
                                                .aspectRatio(contentMode: .fit)
                                                .frame(width: 26, height: 26)
                                                .frame(width: 44, height: 44)
                                                .background(
                                                    RoundedRectangle(cornerRadius: 10)
                                                        .fill(Color(NSColor.controlBackgroundColor))
                                                )
                                        }

                                        Button {
                                            selectedAppConfigs.removeAll(where: { $0.id == appConfig.id })
                                        } label: {
                                            Image(systemName: "xmark.circle.fill")
                                                .font(.system(size: 14))
                                                .foregroundColor(.secondary)
                                        }
                                        .buttonStyle(.plain)
                                        .offset(x: 6, y: -6)
                                    }
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                    .padding(.vertical, 2)

                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Websites")
                            InfoTip(
                                String(localized: "Matching is a substring test, not an exact one. Both the address you are on and the entry you type here are lowercased and stripped of \"https://\", \"http://\" and \"www.\" first, then Zerm checks whether the address contains your entry. So \"github.com\" matches every page on the site, and \"github.com/arcusis\" narrows it to one account. The first time this runs, macOS asks to let Zerm control your browser — that is how it reads the current address."),
                                doc: .powerMode
                            )
                        }

                        HStack {
                            TextField("Enter website URL", text: $newWebsiteURL)
                                .textFieldStyle(.roundedBorder)
                                .onSubmit { addWebsite() }

                            AddIconButton(helpText: "Add website", isDisabled: newWebsiteURL.isEmpty) {
                                addWebsite()
                            }
                        }

                        if websiteConfigs.isEmpty {
                            Text("No websites added")
                                .foregroundColor(.secondary)
                                .font(.subheadline)
                        } else {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140, maximum: 220), spacing: 10)], spacing: 10) {
                                ForEach(websiteConfigs) { urlConfig in
                                    HStack(spacing: 6) {
                                        Image(systemName: "globe")
                                            .foregroundColor(.secondary)
                                        Text(verbatim: urlConfig.url)
                                            .lineLimit(1)
                                        Spacer(minLength: 0)
                                        Button {
                                            websiteConfigs.removeAll(where: { $0.id == urlConfig.id })
                                        } label: {
                                            Image(systemName: "xmark.circle.fill")
                                                .foregroundColor(.secondary)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 6)
                                    .background(
                                        RoundedRectangle(cornerRadius: 8)
                                            .fill(Color(NSColor.controlBackgroundColor))
                                    )
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                    .padding(.vertical, 2)
                }

                Section {
                    if transcriptionModelManager.usableModels.isEmpty {
                        Text("No transcription models available. Please connect to a cloud service or download a local model in the AI Models tab.")
                            .foregroundColor(.secondary)
                    } else {
                        Picker(selection: $selectedTranscriptionModelName) {
                            Text("Use global setting").tag(String?.none)
                            ForEach(modelChoices, id: \.name) { model in
                                Text(verbatim: model.displayName).tag(model.name as String?)
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Text("Model")
                                InfoTip(String(localized: "The transcription model used while this mode is active. \"Use global setting\" always follows the model selected in Dictation Models."))
                            }
                        }
                    }

                    if languageSelectionDisabled() {
                        LabeledContent {
                            Text("Autodetected")
                                .foregroundColor(.secondary)
                        } label: {
                            HStack(spacing: 4) {
                                Text("Language")
                                InfoTip(String(localized: "The model above works out the language on its own, so there is nothing to choose here. Switch to a different model if you need to pin one language."))
                            }
                        }
                    } else if let modelInfo = effectiveModel, !modelInfo.isMultilingualModel {
                        LabeledContent {
                            Text("English")
                                .foregroundColor(.secondary)
                        } label: {
                            Text("Language")
                        }
                    } else if let modelInfo = effectiveModel, modelInfo.isMultilingualModel {
                        Picker(selection: $selectedLanguage) {
                            Text("Use global setting").tag(String?.none)
                            ForEach(modelInfo.supportedLanguages.sorted(by: {
                                if $0.key == "auto" { return true }
                                if $1.key == "auto" { return false }
                                return $0.value < $1.value
                            }), id: \.key) { key, value in
                                Text(verbatim: FileTranscriptionOptionsView.languageName(key, for: modelInfo)).tag(key as String?)
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Text("Language")
                                InfoTip(String(localized: "The language you speak while this mode is active. \"Use global setting\" follows the language chosen in Dictation Models."))
                            }
                        }
                    }
                } header: {
                    Text("Transcription")
                }

                Section {
                    OptionalBoolPicker(selection: $isTextFormattingEnabled) {
                        Text("Text Formatting")
                    }

                    Picker(selection: $punctuationCleanupMode) {
                        Text("Use global setting").tag(PunctuationCleanupMode?.none)
                        Text("Keep punctuation").tag(PunctuationCleanupMode?.some(.keep))
                        Text("Remove all punctuation").tag(PunctuationCleanupMode?.some(.removeAll))
                        Text("Remove trailing period").tag(PunctuationCleanupMode?.some(.removeTrailingPeriod))
                    } label: {
                        Text("Punctuation")
                    }

                    OptionalBoolPicker(selection: $lowercaseTranscription) {
                        Text("Lowercase")
                    }
                } header: {
                    Text("Text")
                }

                Section {
                    Picker(selection: $outputMode) {
                        Text("Use global setting").tag(DictationOutputMode?.none)
                        ForEach(DictationOutputMode.allCases) { mode in
                            Text(verbatim: mode.title).tag(DictationOutputMode?.some(mode))
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text("Output")
                            InfoTip(
                                String(localized: "Whether this Power Mode pastes instantly or uses AI enhancement. \"Use global setting\" follows the Output setting in Enhancement."),
                                learnMoreURL: Links.docString(.powerMode)
                            )
                        }
                    }
                    .pickerStyle(.menu)

                    if outputMode != .instant {
                        Picker(selection: $selectedAIProvider) {
                            Text("Use global setting").tag(String?.none)
                            ForEach(providerChoices, id: \.self) { provider in
                                Text(LocalizedStringKey(provider.rawValue)).tag(provider.rawValue as String?)
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Text("AI Provider")
                                InfoTip(String(localized: "Which connected service enhances transcripts in this mode. Handy for keeping work text on a local provider while using a cloud one elsewhere. Only providers you have already connected appear here."))
                            }
                        }
                        .onChange(of: selectedAIProvider) { _, _ in
                            selectedAIModel = nil
                        }

                        if let provider = selectedAIProvider.flatMap({ AIProvider(rawValue: $0) }),
                           provider != .custom {
                            let models = aiService.availableModels(for: provider)
                            if models.isEmpty {
                                LabeledContent("AI Model") {
                                    Text(provider == .openRouter ? "No models loaded" : "No models available")
                                        .foregroundColor(.secondary)
                                        .italic()
                                }
                            } else {
                                Picker(selection: $selectedAIModel) {
                                    Text("Use global setting").tag(String?.none)
                                    ForEach(models, id: \.self) { model in
                                        Text(verbatim: model).tag(model as String?)
                                    }
                                } label: {
                                    HStack(spacing: 4) {
                                        Text("AI Model")
                                        InfoTip(String(localized: "The specific model from that provider. Smaller models return faster and cost less, which suits quick messages; larger ones handle long or carefully worded text better."))
                                    }
                                }

                                if provider == .openRouter {
                                    Button("Refresh Models") {
                                        Task { await aiService.fetchOpenRouterModels() }
                                    }
                                    .help("Refresh models")
                                }
                            }
                        }

                        Picker(selection: $selectedPromptId) {
                            Text("Use global setting").tag(UUID?.none)
                            ForEach(enhancementService.allPrompts) { prompt in
                                Text(verbatim: prompt.displayTitle).tag(prompt.id as UUID?)
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Text("Enhancement Prompt")
                                InfoTip(
                                    String(localized: "The instructions the AI follows in this mode — this is what makes a Power Mode feel tailored. Pick your email prompt for the mail app, a terse one for chat, a note-taking one for your editor."),
                                    doc: .enhancement
                                )
                            }
                        }

                        OptionalBoolPicker(selection: $contextAwareness) {
                            HStack(spacing: 4) {
                                Text("Context Awareness")
                                InfoTip(
                                    String(localized: "Reads the text visible on screen and passes it to the AI along with your transcript. Used in Enhanced output only. Needs Screen Recording permission, and means on-screen text is sent to your enhancement provider."),
                                    doc: .contextualAwareness
                                )
                            }
                        }
                    }
                } header: {
                    Text("AI Enhancement")
                }

                Section("Advanced") {
                    Toggle(isOn: $isDefault) {
                        HStack(spacing: 6) {
                            Text("Set as default")
                            InfoTip(String(localized: "Default power mode is used when no specific app or website matches are found."))
                        }
                    }

                    Picker(selection: $autoSendKey) {
                        ForEach(AutoSendKey.allCases, id: \.self) { key in
                            Text(LocalizedStringKey(key.displayName)).tag(key)
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Text("Auto Send")
                            InfoTip(String(localized: "Automatically presses a key combination after pasting text. Useful for chat applications or forms that use different send shortcuts."))
                        }
                    }

                    HStack {
                        Text("Keyboard Shortcut")
                        InfoTip(String(localized: "Assign a unique keyboard shortcut to instantly activate this Power Mode and start recording."))

                        Spacer()

                        KeyboardShortcuts.Recorder(for: .powerMode(id: powerModeConfigId))
                            .controlSize(.regular)
                            .frame(minHeight: 28)
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .background(Color(NSColor.controlBackgroundColor))
            .confirmationDialog(
                "Delete Power Mode?",
                isPresented: $isShowingDeleteConfirmation,
                titleVisibility: .visible
            ) {
                if case .edit(let config) = mode {
                    Button("Delete", role: .destructive) {
                        powerModeManager.removeConfiguration(with: config.id)
                        onDismiss()
                    }
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                if case .edit(let config) = mode {
                    Text("Are you sure you want to delete the '\(config.name)' power mode? This action cannot be undone.")
                }
            }
            .powerModeValidationAlert(errors: validationErrors, isPresented: $showValidationAlert)
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    isNameFieldFocused = true
                }
            }

            // Footer
            VStack(spacing: 0) {
                HStack {
                    if case .edit = mode {
                        Button("Delete", role: .destructive) {
                            isShowingDeleteConfirmation = true
                        }
                        .buttonStyle(.bordered)
                    } else {
                        Button("Cancel") { onDismiss() }
                            .keyboardShortcut(.escape, modifiers: [])
                            .buttonStyle(.plain)
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    Button {
                        saveConfiguration()
                    } label: {
                        Text("Save Changes")
                            .frame(minWidth: 100)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSave)
                    .keyboardShortcut(.return, modifiers: .command)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .background(Color(NSColor.windowBackgroundColor))
            }
        }
    }

    // MARK: - Actions

    private func addWebsite() {
        guard !newWebsiteURL.isEmpty else { return }
        let cleanedURL = powerModeManager.cleanURL(newWebsiteURL)
        websiteConfigs.append(URLConfig(url: cleanedURL))
        newWebsiteURL = ""
    }

    private func getConfigForForm() -> PowerModeConfig {
        let shortcut = KeyboardShortcuts.getShortcut(for: .powerMode(id: powerModeConfigId))
        let hotkeyString = shortcut != nil ? "configured" : nil

        var config: PowerModeConfig
        switch mode {
        case .add:
            config = PowerModeConfig(id: powerModeConfigId, name: configName, emoji: selectedEmoji)
        case .edit(let existing):
            config = existing
        }
        config.name = configName
        config.emoji = selectedEmoji
        config.appConfigs = selectedAppConfigs.isEmpty ? nil : selectedAppConfigs
        config.urlConfigs = websiteConfigs.isEmpty ? nil : websiteConfigs
        config.selectedTranscriptionModelName = selectedTranscriptionModelName
        config.selectedLanguage = selectedLanguage
        config.isTextFormattingEnabled = isTextFormattingEnabled
        config.punctuationCleanupMode = punctuationCleanupMode
        config.lowercaseTranscription = lowercaseTranscription
        config.outputMode = outputMode
        config.selectedPrompt = selectedPromptId?.uuidString
        config.selectedAIProvider = selectedAIProvider
        // A model belongs to the provider it was picked for.
        config.selectedAIModel = selectedAIProvider == nil ? nil : selectedAIModel
        config.contextAwareness = contextAwareness
        config.autoSendKey = autoSendKey
        config.isDefault = isDefault
        config.hotkeyShortcut = hotkeyString
        return config
    }

    private func loadInstalledApps() {
        let userAppURLs = FileManager.default.urls(for: .applicationDirectory, in: .userDomainMask)
        let localAppURLs = FileManager.default.urls(for: .applicationDirectory, in: .localDomainMask)
        let systemAppURLs = FileManager.default.urls(for: .applicationDirectory, in: .systemDomainMask)
        let allAppURLs = userAppURLs + localAppURLs + systemAppURLs

        let allApps = Self.applicationURLs(in: allAppURLs)

        installedApps = allApps.compactMap { url in
            guard let bundle = Bundle(url: url),
                  let bundleId = bundle.bundleIdentifier,
                  let name = (bundle.infoDictionary?["CFBundleName"] as? String) ??
                            (bundle.infoDictionary?["CFBundleDisplayName"] as? String) else {
                return nil
            }
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            return (url: url, name: name, bundleId: bundleId, icon: icon)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Collects every `.app` under the given directories without ever descending through a
    /// symlink.
    ///
    /// The previous version resolved symlinks and recursed into whatever they pointed at,
    /// guarded only by a depth limit. A link into a large or remote tree — a network mount, or
    /// anything pointing back up the hierarchy — turned opening the app picker into a long
    /// filesystem walk, and the same bundle could be collected several times by different
    /// paths. Ported from upstream VoiceInk.
    static func applicationURLs(
        in appDirectories: [URL],
        fileManager: FileManager = .default
    ) -> [URL] {
        var appURLs: [URL] = []
        var seenPaths = Set<String>()

        for appDirectory in appDirectories {
            guard let enumerator = fileManager.enumerator(
                at: appDirectory,
                includingPropertiesForKeys: [.isApplicationKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }

            for item in enumerator {
                guard let url = item as? URL else { continue }
                let values = try? url.resourceValues(forKeys: [.isApplicationKey, .isSymbolicLinkKey])

                if values?.isSymbolicLink == true {
                    // A linked app still counts, but nothing behind the link is walked.
                    enumerator.skipDescendants()

                    let resolvedURL = url.resolvingSymlinksInPath()
                    guard resolvedURL.pathExtension.caseInsensitiveCompare("app") == .orderedSame else {
                        continue
                    }
                    if seenPaths.insert(resolvedURL.standardizedFileURL.path).inserted {
                        appURLs.append(resolvedURL)
                    }
                    continue
                }

                guard values?.isApplication == true
                        || url.pathExtension.caseInsensitiveCompare("app") == .orderedSame else {
                    continue
                }

                enumerator.skipDescendants()
                if seenPaths.insert(url.standardizedFileURL.path).inserted {
                    appURLs.append(url)
                }
            }
        }

        return appURLs
    }

    private func saveConfiguration() {
        let config = getConfigForForm()
        let validator = PowerModeValidator(powerModeManager: powerModeManager)
        validationErrors = validator.validateForSave(config: config, mode: mode)

        if !validationErrors.isEmpty {
            showValidationAlert = true
            return
        }

        if isDefault {
            powerModeManager.setAsDefault(configId: config.id, skipSave: true)
        }

        switch mode {
        case .add:
            powerModeManager.addConfiguration(config)
        case .edit:
            powerModeManager.updateConfiguration(config)
        }

        onDismiss()
    }
}

/// A Power Mode switch that can also leave the global setting alone.
private struct OptionalBoolPicker<Label: View>: View {
    @Binding var selection: Bool?
    @ViewBuilder let label: () -> Label

    var body: some View {
        Picker(selection: $selection) {
            Text("Use global setting").tag(Bool?.none)
            Text("On").tag(Bool?.some(true))
            Text("Off").tag(Bool?.some(false))
        } label: {
            label()
        }
    }
}
