import SwiftUI
import KeyboardShortcuts

/// Settings for the Read Aloud (text-to-speech) feature — the mirror of the dictation settings.
struct TextToSpeechSettingsView: View {
    @AppStorage(TTSSettings.Keys.enabled) private var enabled = true
    @AppStorage(TTSSettings.Keys.provider) private var providerRaw = TTSProviderKind.deepgram.rawValue
    @AppStorage(TTSSettings.Keys.speed) private var speed = 1.0
    @AppStorage(TTSSettings.Keys.smartCleanup) private var smartCleanup = true
    @AppStorage(TTSSettings.Keys.naturalReadingAI) private var naturalReadingAI = false

    @State private var voiceID: String = ""
    @State private var apiKey: String = ""
    @State private var verifyState: VerifyState = .idle
    @State private var isPreviewing = false

    /// The app-level controller (wired to the recorder widget), so Preview shows the same
    /// "Speaking" widget a real trigger does — a reliable way to see Read Aloud working.
    @EnvironmentObject private var ttsController: TTSController

    @ObservedObject private var kokoro = KokoroModelManager.shared
    @ObservedObject private var localLLM = LocalLLMModelManager.shared
    @EnvironmentObject private var hotkeyManager: HotkeyManager

    private enum VerifyState: Equatable {
        case idle, verifying, valid, invalid(String)
    }

    private var providerKind: TTSProviderKind {
        TTSProviderKind(rawValue: providerRaw) ?? .deepgram
    }

    private var provider: any TTSProvider {
        TTSProviderRegistry.provider(for: providerKind) ?? DeepgramTTSProvider()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header

                GroupBox {
                    VStack(alignment: .leading, spacing: 16) {
                        Toggle(isOn: $enabled) {
                            HStack(spacing: 4) {
                                Text("Enable Read Aloud")
                                InfoTip(
                                    String(localized: "Turns on the shortcut that speaks whatever text you have selected, in any app. Useful for proofreading your own writing or getting through a long article without staring at it. Off means the shortcut does nothing."),
                                    doc: .readAloud
                                )
                            }
                        }
                        .font(.headline)

                        Divider()

                        shortcutRow
                        Divider()
                        providerRow
                        Divider()
                        voiceRow
                        Divider()
                        speedRow
                    }
                    .padding(8)
                }

                AnalogHeadphoneConfirmationControl()

                smartReadingSection

                if provider.requiresAPIKey {
                    apiKeySection
                }

                if providerKind.isLocal {
                    kokoroDownloadCard
                }

                previewSection
            }
            .padding(24)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .onAppear(perform: reloadForProvider)
        .onChange(of: providerRaw) { _, _ in reloadForProvider() }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Read Aloud")
                .font(.largeTitle.bold())
            Text("Select text anywhere, press your shortcut, and Zerm reads it aloud — local or cloud voices.")
                .foregroundStyle(.secondary)
        }
    }

    private var shortcutRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Trigger key", systemImage: "command")
                InfoTip(
                    String(localized: "Press this key with text selected and Zerm reads it out; press it again to stop. Pick a key you do not use for dictation — if the two clash, one press would try to do both."),
                    doc: .readAloud
                )
                Spacer()
                Picker("Read Aloud trigger key", selection: $hotkeyManager.readAloudHotkey) {
                    ForEach(HotkeyManager.HotkeyOption.allCases, id: \.self) { option in
                        Text(LocalizedStringKey(option.displayName)).tag(option)
                    }
                }
                .labelsHidden()
                .accessibilityLabel("Read Aloud trigger key")
                .accessibilityValue(Text(LocalizedStringKey(hotkeyManager.readAloudHotkey.displayName)))
                .frame(width: 240)
            }

            if hotkeyManager.readAloudHotkey == .custom {
                HStack {
                    Text("Custom shortcut").foregroundStyle(.secondary)
                    InfoTip(String(localized: "Click the field and press the key combination you want. Include a modifier such as Control or Option so it does not fire while you are typing."))
                    Spacer()
                    KeyboardShortcuts.Recorder(for: .readSelectedTextAloud)
                }
            }

            if readAloudHotkeyConflictsWithDictation {
                Label("This key is also your dictation hotkey — pick a different one to avoid both firing.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var readAloudHotkeyConflictsWithDictation: Bool {
        let key = hotkeyManager.readAloudHotkey
        guard key != .none, key != .custom else { return false }
        return key == hotkeyManager.selectedHotkey1 || key == hotkeyManager.selectedHotkey2
    }

    private var providerRow: some View {
        HStack {
            Label("Voice provider", systemImage: "waveform")
            InfoTip(
                String(localized: "Who synthesises the speech. Kokoro runs entirely on your Mac — nothing leaves the machine and it works offline, after a one-off model download. The cloud providers sound more natural but send the selected text to their servers and need an API key."),
                doc: .readAloud
            )
            Spacer()
            Picker("Read Aloud voice provider", selection: $providerRaw) {
                ForEach(TTSProviderKind.allCases, id: \.self) { kind in
                    Text(displayName(for: kind)).tag(kind.rawValue)
                }
            }
            .labelsHidden()
            .accessibilityLabel("Read Aloud voice provider")
            .accessibilityValue(Text(provider.displayName))
            .frame(width: 240)
        }
    }

    private var voiceRow: some View {
        HStack {
            Label("Voice", systemImage: "person.wave.2")
            InfoTip(String(localized: "The voice used by the provider above. Each provider has its own set, so this list changes when you switch provider. Use Preview voice at the bottom to hear one before settling on it."))
            Spacer()
            Picker("Read Aloud voice", selection: $voiceID) {
                ForEach(provider.voices) { voice in
                    Text(voice.displayName).tag(voice.id)
                }
            }
            .labelsHidden()
            .accessibilityLabel("Read Aloud voice")
            .accessibilityValue(Text(selectedVoiceName))
            .frame(width: 240)
            .onChange(of: voiceID) { _, newValue in
                TTSSettings.setVoiceID(newValue, for: providerKind)
            }
        }
    }

    private var speedRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label("Speed", systemImage: "speedometer")
                InfoTip(String(localized: "Playback rate, from half speed to double. Around 1.3× is a common choice for skimming long text; drop below 1× for dense material or an unfamiliar language."))
                Spacer()
                Text(formattedSpeed)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: $speed, in: 0.5...2.0, step: 0.05)
                .accessibilityLabel("Reading speed")
                .accessibilityValue(Text(readingSpeedAccessibilityValue))
        }
    }

    /// Smart reading: instant rules (always available) + the on-device LLM rewrite.
    private var smartReadingSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 16) {
                Text("Smart reading")
                    .font(.headline)

                VStack(alignment: .leading, spacing: 4) {
                    Toggle(isOn: $smartCleanup) {
                        HStack(spacing: 4) {
                            Text("Smart text cleanup")
                            InfoTip(
                                String(localized: "Rewrites the awkward parts before speaking: \"https://example.com/a\" becomes a spoken address rather than a string of slashes, \"~/Library\" is read as a path, and acronyms are spelled out. Turn it off if you want the text read literally, character for character."),
                                doc: .readAloud
                            )
                        }
                    }
                    Text("Instantly reads acronyms, URLs, file paths, code, and symbols the way a person would — offline, no delay.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Divider()

                VStack(alignment: .leading, spacing: 4) {
                    Toggle(isOn: $naturalReadingAI) {
                        HStack(spacing: 4) {
                            Text("Natural reading (AI)")
                            InfoTip(
                                String(localized: "Goes further than cleanup: the on-device model rewrites the passage into something a person would actually say aloud, smoothing lists, tables and dense punctuation. It needs Zerm's local language model downloaded — the toggle stays dimmed until it is — and it adds a pause before the first word."),
                                doc: .readAloud
                            )
                        }
                    }
                    .disabled(!localLLM.isInstalled)
                    Text("Rewrites text into natural spoken language using Zerm's on-device model before reading. Fully offline; adds a moment before the first word.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                LocalLLMModelListView()
            }
            .padding(8)
        }
        .onChange(of: naturalReadingAI) { _, on in
            if on { Task { await localLLM.prewarmIfNeeded() } }
        }
    }

    private var apiKeySection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 4) {
                    Text(apiKeyHeading)
                        .font(.headline)
                    InfoTip(
                        String(localized: "Required for this provider — Read Aloud will not speak without it. Save & Verify checks the key against the provider before storing it in your macOS Keychain. Switch to Kokoro if you would rather not use an account at all."),
                        doc: .readAloud
                    )
                }
                HStack {
                    SecureField("Paste API key", text: $apiKey)
                        .textFieldStyle(.roundedBorder)
                    Button("Save & Verify") { Task { await saveAndVerify() } }
                        .disabled(apiKey.isEmpty || verifyState == .verifying)
                }
                verifyStatusView
            }
            .padding(8)
        }
    }

    @ViewBuilder
    private var verifyStatusView: some View {
        switch verifyState {
        case .idle:
            EmptyView()
        case .verifying:
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Verifying…").foregroundStyle(.secondary) }
        case .valid:
            Label("Key verified", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
        case .invalid(let msg):
            Label(msg, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
        }
    }

    private var previewSection: some View {
        HStack {
            Button {
                Task { await preview() }
            } label: {
                Label(
                    isPreviewing ? String(localized: "Speaking…") : String(localized: "Preview voice"),
                    systemImage: "play.circle.fill"
                )
            }
            .disabled(isPreviewing || (providerKind.isLocal && !kokoro.isInstalled))
            InfoTip(String(localized: "Speaks a sample sentence with the current provider, voice and speed, using the same recorder widget a real trigger uses. A quick way to check your key and settings work before relying on them."))
            Spacer()
        }
    }

    /// On-device model download card — the TTS mirror of the Whisper model card.
    @ViewBuilder
    private var kokoroDownloadCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: "cpu")
                    Text(KokoroModelManager.package.displayName).font(.headline)
                    InfoTip(
                        String(localized: "The offline voice model. Download it once and Read Aloud works with no account, no API key and no text ever leaving your Mac — including on a plane. Deleting it frees the disk space; you can download it again later."),
                        doc: .readAloud
                    )
                    Spacer()
                    Text(KokoroModelManager.package.approxSize)
                        .font(.caption).foregroundStyle(.secondary)
                }

                if kokoro.isInstalled {
                    HStack {
                        Label("Downloaded — runs fully offline", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Spacer()
                        Button(role: .destructive) { kokoro.delete() } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                } else if kokoro.isDownloading {
                    VStack(alignment: .leading, spacing: 6) {
                        ProgressView(value: kokoro.downloadProgress ?? 0)
                        HStack {
                            Text(kokoro.statusText ?? String(localized: "Downloading…"))
                                .font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            if let p = kokoro.downloadProgress {
                                Text(p, format: .percent.precision(.fractionLength(0)))
                                    .font(.caption.monospacedDigit())
                            }
                            Button("Cancel") { kokoro.cancelDownload() }
                        }
                    }
                } else {
                    HStack {
                        Text("Download once to use Kokoro offline. No API key needed.")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button { Task { await kokoro.download() } } label: {
                            Label("Download model", systemImage: "arrow.down.circle")
                        }
                    }
                    if let status = kokoro.statusText {
                        Text(status).font(.caption).foregroundStyle(.red)
                    }
                }
            }
            .padding(8)
        }
    }

    // MARK: - Actions

    private func displayName(for kind: TTSProviderKind) -> String {
        TTSProviderRegistry.provider(for: kind)?.displayName ?? kind.rawValue
    }

    private var selectedVoiceName: String {
        provider.voices.first(where: { $0.id == voiceID })?.displayName
            ?? String(localized: "No voice selected")
    }

    private var formattedSpeed: String {
        let value = formattedSpeedValue
        let format = String(localized: "%@×")
        return String.localizedStringWithFormat(format, value)
    }

    private var readingSpeedAccessibilityValue: String {
        let format = String(localized: "Reading speed: %@ times normal")
        return String.localizedStringWithFormat(format, formattedSpeedValue)
    }

    private var formattedSpeedValue: String {
        speed.formatted(.number.precision(.fractionLength(2)))
    }

    private var apiKeyHeading: String {
        let format = String(localized: "%@ API key")
        return String.localizedStringWithFormat(format, provider.displayName)
    }

    private func reloadForProvider() {
        voiceID = TTSSettings.voiceID(for: providerKind) ?? provider.voices.first?.id ?? ""
        if let providerID = providerKind.apiKeyProvider {
            apiKey = APIKeyManager.shared.getAPIKey(forProvider: providerID) ?? ""
        } else {
            apiKey = ""
        }
        verifyState = .idle
        // Warm up the on-device model when Kokoro is selected so the first read is instant.
        Task { await kokoro.prewarmIfNeeded() }
    }

    private func saveAndVerify() async {
        guard let providerID = providerKind.apiKeyProvider else { return }
        APIKeyManager.shared.saveAPIKey(apiKey, forProvider: providerID)
        verifyState = .verifying
        let result = await provider.verifyAPIKey(apiKey)
        verifyState = result.isValid
            ? .valid
            : .invalid(result.errorMessage ?? String(localized: "Invalid key"))
    }

    private func preview() async {
        isPreviewing = true
        defer { isPreviewing = false }
        await ttsController.speak(String(localized: "This is how the selected voice sounds in Zerm."))
        // brief settle so synthesis can start before the button re-enables
        try? await Task.sleep(nanoseconds: 1_200_000_000)
    }
}

/// Fail-closed confirmation for the built-in analog jack, which CoreAudio cannot distinguish
/// from powered speakers. It is intentionally visible in both Audio settings and Read Aloud.
struct AnalogHeadphoneConfirmationControl: View {
    @ObservedObject private var routeMonitor = AudioOutputRouteMonitor.shared

    @ViewBuilder
    var body: some View {
        if routeMonitor.isAmbiguousAnalogOutput {
            GroupBox("Analog Headphone Safety") {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("I Am Using Wired Headphones", isOn: Binding(
                        get: { routeMonitor.confirmsAmbiguousAnalogHeadphones },
                        set: { routeMonitor.setConfirmsAmbiguousAnalogHeadphones($0) }
                    ))
                    .accessibilityIdentifier("confirm-analog-wired-headphones")

                    Text("The analog jack is treated as speakers until you confirm wired headphones for this attempt. Zerm asks again for every meeting and Read Aloud attempt, and whenever the output changes.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
            }
        }
    }
}
