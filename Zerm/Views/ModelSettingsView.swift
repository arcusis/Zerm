import SwiftUI

/// Which model settings have an effect for the selected model. A setting that the model or its
/// active (batch or real-time) path ignores is hidden rather than shown as a no-op.
struct ModelSettingsVisibility: Equatable {
    let showsOutputFormat: Bool
    let showsVoiceActivityDetection: Bool
    let showsPrewarm: Bool
    let showsLiveTextPreview: Bool
    let showsCloudTimeout: Bool

    init(model: (any TranscriptionModel)?, defaults: UserDefaults = .standard) {
        guard let model else {
            self.init(outputFormat: false, voiceActivityDetection: false, prewarm: false, liveTextPreview: false, cloudTimeout: false)
            return
        }
        let capabilities = model.activeCapabilities(defaults: defaults)
        let isLocal = model.provider == .whisper || model.provider == .fluidAudio
        let isCloud = model.provider == .custom || CloudProviderRegistry.provider(for: model.provider) != nil
        self.init(
            outputFormat: capabilities.contains(.prompt),
            voiceActivityDetection: isLocal,
            prewarm: isLocal,
            liveTextPreview: capabilities.contains(.streaming),
            cloudTimeout: isCloud
        )
    }

    private init(outputFormat: Bool, voiceActivityDetection: Bool, prewarm: Bool, liveTextPreview: Bool, cloudTimeout: Bool) {
        showsOutputFormat = outputFormat
        showsVoiceActivityDetection = voiceActivityDetection
        showsPrewarm = prewarm
        showsLiveTextPreview = liveTextPreview
        showsCloudTimeout = cloudTimeout
    }
}

struct ModelSettingsView: View {
    @ObservedObject var whisperPrompt: WhisperPrompt
    @EnvironmentObject private var transcriptionModelManager: TranscriptionModelManager
    @AppStorage("SelectedLanguage") private var selectedLanguage: String = "auto"
    @AppStorage("IsTextFormattingEnabled") private var isTextFormattingEnabled = true
    @AppStorage("IsVADEnabled") private var isVADEnabled = true
    @AppStorage("AppendTrailingSpace") private var appendTrailingSpace = true
    @AppStorage("PrewarmModelOnWake") private var prewarmModelOnWake = true
    @AppStorage("showLiveTextPreview") private var showLiveTextPreview = true
    @AppStorage(CloudTranscriptionSettings.timeoutKey) private var cloudTimeout = Int(CloudTranscriptionSettings.defaultTimeout)
    @State private var customPrompt: String = ""
    @State private var isEditing: Bool = false

    private var visibility: ModelSettingsVisibility {
        ModelSettingsVisibility(model: transcriptionModelManager.currentTranscriptionModel)
    }

    var body: some View {
        Form {
            if visibility.showsOutputFormat {
                outputFormatSection
            }

            Section {
                Toggle(isOn: $appendTrailingSpace) {
                    HStack(spacing: 4) {
                        Text("Add Space After Paste")
                        InfoTip("Puts a single space at the end of every pasted transcript, so you can dictate one sentence after another without the words running together. Turn it off when you dictate into fields where a trailing space matters, such as a search box or a file name.")
                    }
                }
                .toggleStyle(.switch)

                Toggle(isOn: $isTextFormattingEnabled) {
                    HStack(spacing: 4) {
                        Text("Automatic text formatting")
                        InfoTip("Apply intelligent text formatting to break large block of text into paragraphs.")
                    }
                }
                .toggleStyle(.switch)

                if visibility.showsVoiceActivityDetection {
                    Toggle(isOn: $isVADEnabled) {
                        HStack(spacing: 4) {
                            Text("Voice Activity Detection (VAD)")
                            InfoTip("Detect speech segments and filter out silence to improve accuracy of local models.")
                        }
                    }
                    .toggleStyle(.switch)
                }

                if visibility.showsPrewarm {
                    Toggle(isOn: $prewarmModelOnWake) {
                        HStack(spacing: 4) {
                            Text("Prewarm model (Experimental)")
                            InfoTip("Turn this on if transcriptions with local models are taking longer than expected. Runs silent background transcription on app launch and wake to trigger optimization.")
                        }
                    }
                    .toggleStyle(.switch)
                }

                if visibility.showsLiveTextPreview {
                    Toggle(isOn: $showLiveTextPreview) {
                        HStack(spacing: 4) {
                            Text("Show Live Text Preview")
                            InfoTip("Displays the live transcript preview in the recorder while speaking. Only applies when using real-time streaming models.")
                        }
                    }
                    .toggleStyle(.switch)
                }

                if visibility.showsCloudTimeout {
                    Picker(selection: $cloudTimeout) {
                        ForEach(CloudTranscriptionSettings.timeoutOptions, id: \.self) { seconds in
                            Text(Duration.seconds(seconds).formatted(.units(allowed: [.minutes, .seconds], width: .wide)))
                                .tag(seconds)
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text("Cloud timeout")
                            InfoTip(String(localized: "How long to wait for a cloud model to return a transcript before giving up. Long recordings and files automatically get more time. Does not affect local models or live streaming."))
                        }
                    }
                    .pickerStyle(.menu)
                }
            } header: {
                Text("Transcription")
            }

            Section {
                FillerWordsSettingsView()
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .onChange(of: selectedLanguage) { oldValue, newValue in
            if isEditing {
                customPrompt = whisperPrompt.getLanguagePrompt(for: selectedLanguage)
            }
        }
    }

    private var outputFormatSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                if isEditing {
                    TextEditor(text: $customPrompt)
                        .font(.system(size: 12))
                        .frame(minHeight: 40, maxHeight: 80)
                        .fixedSize(horizontal: false, vertical: true)
                        .scrollContentBackground(.hidden)

                    Button("Save") {
                        whisperPrompt.setCustomPrompt(customPrompt, for: selectedLanguage)
                        isEditing = false
                    }
                } else {
                    Text(whisperPrompt.getLanguagePrompt(for: selectedLanguage))
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Button("Edit") {
                        customPrompt = whisperPrompt.getLanguagePrompt(for: selectedLanguage)
                        isEditing = true
                    }
                }
            }
        } header: {
            HStack(spacing: 4) {
                Text("Output Format")
                InfoTip(
                    String(localized: "Example text that shows the spelling, punctuation and style you want. The selected model receives it with every transcription in the current language, and each language keeps its own text. Models imitate examples and ignore instructions, so write sample output, not commands. Rewriting and cleanup belong in Enhancement."),
                    learnMoreURL: "https://cookbook.openai.com/examples/whisper_prompting_guide#comparison-with-gpt-prompting"
                )
            }
        }
    }
}
