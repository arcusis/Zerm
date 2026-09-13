import SwiftUI

/// Model, language and speaker options for the next files added to the queue.
struct FileTranscriptionOptionsView: View {
    @EnvironmentObject private var queue: FileTranscriptionQueue
    @EnvironmentObject private var modelManager: TranscriptionModelManager

    private var usableModels: [any TranscriptionModel] { modelManager.usableModels }

    private var selectedModel: (any TranscriptionModel)? {
        usableModels.first { $0.name == queue.options.modelName }
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                modelPicker
                languageRow

                Toggle("Identify speakers", isOn: Binding(
                    get: { queue.options.identifySpeakers },
                    set: { queue.options.identifySpeakers = $0 }
                ))

                Picker("Speakers", selection: Binding(
                    get: { queue.options.speakerCount },
                    set: { queue.options.speakerCount = $0 }
                )) {
                    Text("Detect automatically").tag(SpeakerCount.automatic)
                    ForEach(SpeakerCount.fixedRange, id: \.self) { count in
                        Text("file_transcription_speakers \(count)").tag(SpeakerCount.fixed(count))
                    }
                }
                .disabled(!queue.options.identifySpeakers)

                Text("These options apply to the files you add next.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(8)
        } label: {
            Text("Options")
                .font(.headline)
        }
    }

    @ViewBuilder
    private var modelPicker: some View {
        let local = usableModels.filter { FileTranscriptionQueue.isOnDevice($0.provider) }
        let cloud = usableModels.filter { !FileTranscriptionQueue.isOnDevice($0.provider) }

        Picker("Model", selection: Binding(
            get: { selectedModel?.name ?? "" },
            set: selectModel
        )) {
            if selectedModel == nil {
                Text("Choose a model").tag("")
            }
            if !local.isEmpty {
                Section("On this Mac") {
                    ForEach(local, id: \.name) { model in
                        Text(verbatim: model.displayName).tag(model.name)
                    }
                }
            }
            if !cloud.isEmpty {
                Section("Cloud") {
                    ForEach(cloud, id: \.name) { model in
                        Text(verbatim: model.displayName).tag(model.name)
                    }
                }
            }
        }

        HStack(spacing: 6) {
            Text("Only downloaded models and cloud models with an API key are listed.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Manage Models") {
                NotificationCenter.default.post(
                    name: .navigateToDestination,
                    object: nil,
                    userInfo: ["route": AppRoute.dictationModels]
                )
            }
            .buttonStyle(.link)
            .font(.caption)
        }
    }

    @ViewBuilder
    private var languageRow: some View {
        if let model = selectedModel {
            if Self.detectsLanguageAutomatically(model) {
                LabeledContent("Language") {
                    Text("Detected automatically")
                }
            } else if !model.isMultilingualModel {
                LabeledContent("Language") {
                    Text("English")
                }
            } else {
                Picker("Language", selection: Binding(
                    get: { queue.options.languageCode },
                    set: { queue.options.languageCode = $0 }
                )) {
                    ForEach(Self.sortedLanguageCodes(for: model), id: \.self) { code in
                        Text(verbatim: Self.languageName(code, for: model)).tag(code)
                    }
                }
            }
        }
    }

    private func selectModel(_ name: String) {
        guard let model = usableModels.first(where: { $0.name == name }) else { return }
        var options = queue.options
        options.modelName = model.name
        options.modelDisplayName = model.displayName
        if !model.isMultilingualModel {
            options.languageCode = "en"
        } else if model.supportedLanguages[options.languageCode] == nil {
            options.languageCode = model.supportedLanguages["auto"] == nil ? "en" : "auto"
        }
        queue.options = options
    }

    /// Models whose provider always detects the language itself, as in Dictation's settings.
    static func detectsLanguageAutomatically(_ model: any TranscriptionModel) -> Bool {
        model.provider == .fluidAudio || model.provider == .gemini
    }

    static func languageName(_ code: String, for model: any TranscriptionModel) -> String {
        if detectsLanguageAutomatically(model) || code == "auto" {
            return String(localized: "Auto-detect")
        }
        return Locale.current.localizedString(forLanguageCode: code)
            ?? model.supportedLanguages[code]
            ?? code
    }

    private static func sortedLanguageCodes(for model: any TranscriptionModel) -> [String] {
        model.supportedLanguages.keys.sorted { lhs, rhs in
            if lhs == "auto" { return rhs != "auto" }
            if rhs == "auto" { return false }
            return languageName(lhs, for: model).localizedStandardCompare(languageName(rhs, for: model)) == .orderedAscending
        }
    }
}
