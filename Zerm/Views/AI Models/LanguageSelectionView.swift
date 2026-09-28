import SwiftUI

// Define a display mode for flexible usage
enum LanguageDisplayMode {
    case full // For settings page with descriptions
    case menuItem // For menu bar with compact layout
}

struct LanguageSelectionView: View {
    @ObservedObject var transcriptionModelManager: TranscriptionModelManager
    @AppStorage("SelectedLanguage") private var selectedLanguage: String = "auto"
    // Add display mode parameter with full as the default
    var displayMode: LanguageDisplayMode = .full
    @ObservedObject var whisperPrompt: WhisperPrompt

    private func updateLanguage(_ language: String) {
        // Update UI state - the UserDefaults updating is now automatic with @AppStorage
        selectedLanguage = language

        // Force the prompt to update for the new language
        whisperPrompt.updateTranscriptionPrompt()

        // Post notification for language change
        NotificationCenter.default.post(name: .languageDidChange, object: nil)
        NotificationCenter.default.post(name: .AppSettingsDidChange, object: nil)
    }

    // Function to check if current model is multilingual
    private func isMultilingualModel() -> Bool {
        guard let currentModel = transcriptionModelManager.currentTranscriptionModel else {
            return false
        }
        return currentModel.isMultilingualModel
    }

    // Multilingual models that detect the language themselves. English-only models of the same
    // providers fall through to the English-only presentation instead of "Autodetected".
    private func languageSelectionDisabled() -> Bool {
        guard let model = transcriptionModelManager.currentTranscriptionModel else {
            return false
        }
        return (model.provider == .fluidAudio || model.provider == .gemini) && model.isMultilingualModel
    }

    // Function to get current model's supported languages
    private func getCurrentModelLanguages() -> [String: String] {
        guard let currentModel = transcriptionModelManager.currentTranscriptionModel else {
            return ["en": "English"] // Default to English if no model found
        }
        return currentModel.supportedLanguages
    }

    /// Shown when the language chosen for dictation is not one this model lists: the model is then
    /// left to detect the language, and one that lists Arabic but not Hebrew wrote Hebrew as Arabic.
    @ViewBuilder
    private func unsupportedLanguageWarning(for model: any TranscriptionModel) -> some View {
        if !model.supportsLanguage(selectedLanguage) {
            Label(
                String(localized: "\(model.displayName) does not support \(LanguageDictionary.displayName(for: selectedLanguage)), so it detects the language itself. Choose a model that supports it."),
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.caption)
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    // Get the display name of the current language
    private func currentLanguageDisplayName() -> String {
        guard getCurrentModelLanguages()[selectedLanguage] != nil else { return String(localized: "Unknown") }
        return LanguageDictionary.displayName(for: selectedLanguage)
    }

    var body: some View {
        Group {
            switch displayMode {
            case .full:
                fullView
            case .menuItem:
                menuItemView
            }
        }
        // Lets Apple Speech offer Hebrew once the Speech framework reports it.
        .task { await AppleSpeechLanguageSupport.refresh() }
    }

    // The original full view layout for settings page
    private var fullView: some View {
        VStack(alignment: .leading, spacing: 16) {
            languageSelectionSection
        }
    }
    
    private var languageSelectionSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Transcription Language")
                .font(.headline)

            if let currentModel = transcriptionModelManager.currentTranscriptionModel
            {
                if languageSelectionDisabled() {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Language: Autodetected")
                            .font(.subheadline)
                            .foregroundColor(.primary)

                        Text("Current model: \(currentModel.displayName)")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        Text("The transcription language is automatically detected by the model.")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        unsupportedLanguageWarning(for: currentModel)
                    }
                } else if isMultilingualModel() {
                    VStack(alignment: .leading, spacing: 8) {
                        Picker(selection: $selectedLanguage) {
                            ForEach(
                                currentModel.supportedLanguages.sorted(by: {
                                    if $0.key == "auto" { return true }
                                    if $1.key == "auto" { return false }
                                    return LanguageDictionary.displayName(for: $0.key)
                                        .localizedStandardCompare(LanguageDictionary.displayName(for: $1.key)) == .orderedAscending
                                }), id: \.key
                            ) { key, _ in
                                Text(verbatim: LanguageDictionary.displayName(for: key)).tag(key)
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Text("Select Language")
                                InfoTip(
                                    String(localized: "The language you speak when dictating. Naming it is more accurate than Auto-detect, which can guess wrong on a short phrase or a sentence that mixes languages. Set a different language for particular apps with a Power Mode."),
                                    doc: .models
                                )
                            }
                        }
                        .pickerStyle(MenuPickerStyle())
                        .onChange(of: selectedLanguage) { oldValue, newValue in
                            updateLanguage(newValue)
                        }

                        Text("Current model: \(currentModel.displayName)")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        unsupportedLanguageWarning(for: currentModel)

                        if currentModel.isHebrewOptimized {
                            Text("Tuned for Hebrew: Auto-detect transcribes Hebrew and keeps English words. Choose English only for English-only dictation.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        } else {
                            Text(
                                "This model supports multiple languages. Select a specific language or auto-detect(if available)"
                            )
                            .font(.caption)
                            .foregroundColor(.secondary)
                        }

                        if selectedLanguage == LanguagePreference.autoCode,
                           currentModel.provider == .whisper, !currentModel.isHebrewOptimized {
                            MyLanguagesPicker(model: currentModel)
                        }
                    }
                } else {
                    // For English-only models, force set language to English
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Language: English")
                            .font(.subheadline)
                            .foregroundColor(.primary)

                        Text("Current model: \(currentModel.displayName)")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        Text(
                            "This is an English-optimized model and only supports English transcription."
                        )
                        .font(.caption)
                        .foregroundColor(.secondary)
                    }
                    // Viewing an English-only model must not overwrite the language: switching back
                    // to a multilingual model then forced Hebrew or Russian speech to English (#370).
                }
            } else {
                Text("No model selected")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(10)
    }

    // New compact view for menu bar
    private var menuItemView: some View {
        Group {
            if languageSelectionDisabled() {
                Button {
                    // Do nothing, just showing info
                } label: {
                    Text("Language: Autodetected")
                        .foregroundColor(.secondary)
                }
                .disabled(true)
            } else if isMultilingualModel() {
                Menu {
                    ForEach(
                        getCurrentModelLanguages().sorted(by: {
                            if $0.key == "auto" { return true }
                            if $1.key == "auto" { return false }
                            return LanguageDictionary.displayName(for: $0.key)
                                .localizedStandardCompare(LanguageDictionary.displayName(for: $1.key)) == .orderedAscending
                        }), id: \.key
                    ) { key, _ in
                        Button {
                            updateLanguage(key)
                        } label: {
                            HStack {
                                Text(verbatim: LanguageDictionary.displayName(for: key))
                                if selectedLanguage == key {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    HStack {
                        Text("Language: \(currentLanguageDisplayName())")
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 10))
                    }
                }
            } else {
                // For English-only models
                Button {
                    // Do nothing, just showing info
                } label: {
                    Text("Language: English (only)")
                        .foregroundColor(.secondary)
                }
                .disabled(true)
            }
        }
    }
}

/// "My languages": the languages Auto-detect may choose among with a Whisper model (#371).
private struct MyLanguagesPicker: View {
    let model: any TranscriptionModel
    @AppStorage(DictationLanguages.defaultsKey) private var storedCodes = ""

    private var codes: [String] { DictationLanguages.parse(storedCodes) }

    private var addable: [String] {
        model.supportedLanguages.keys
            .filter { $0 != LanguagePreference.autoCode && !codes.contains($0) }
            .sorted { LanguageDictionary.displayName(for: $0).localizedStandardCompare(LanguageDictionary.displayName(for: $1)) == .orderedAscending }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text("My languages")
                    .font(.subheadline)
                InfoTip(String(localized: "Auto-detect chooses only among these languages, so it cannot guess one you never speak, such as Arabic for a short Hebrew phrase. Leave empty to allow every language."))
            }

            HStack(spacing: 6) {
                ForEach(codes, id: \.self) { code in
                    Button {
                        storedCodes = DictationLanguages.encode(codes.filter { $0 != code })
                    } label: {
                        HStack(spacing: 3) {
                            Text(verbatim: LanguageDictionary.displayName(for: code))
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                    }
                    .buttonStyle(.plain)
                    .help(String(localized: "Remove"))
                }

                Menu {
                    ForEach(addable, id: \.self) { code in
                        Button(LanguageDictionary.displayName(for: code)) {
                            storedCodes = DictationLanguages.encode(codes + [code])
                        }
                    }
                } label: {
                    Label("Add language", systemImage: "plus")
                        .font(.caption)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            if codes.isEmpty {
                Text("Any language can be detected.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.top, 4)
    }
}
