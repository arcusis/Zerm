import SwiftUI
import KeyboardShortcuts

/// Settings for the Read Aloud (text-to-speech) feature — the mirror of the dictation settings.
struct TextToSpeechSettingsView: View {
    @AppStorage(TTSSettings.Keys.enabled) private var enabled = true
    @AppStorage(TTSSettings.Keys.provider) private var providerRaw = TTSProviderKind.deepgram.rawValue
    @AppStorage(TTSSettings.Keys.speed) private var speed = 1.0

    @State private var voiceID: String = ""
    @State private var apiKey: String = ""
    @State private var verifyState: VerifyState = .idle
    @State private var isPreviewing = false

    /// Retained so preview playback isn't cut off when the action returns.
    /// Does not call `registerHotkey()`, so it never double-binds the global shortcut.
    @StateObject private var previewController = TTSController()

    @ObservedObject private var kokoro = KokoroModelManager.shared
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
                        Toggle("Enable Read Aloud", isOn: $enabled)
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
                Spacer()
                Picker("", selection: $hotkeyManager.readAloudHotkey) {
                    ForEach(HotkeyManager.HotkeyOption.allCases, id: \.self) { option in
                        Text(option.displayName).tag(option)
                    }
                }
                .labelsHidden()
                .frame(width: 240)
            }

            if hotkeyManager.readAloudHotkey == .custom {
                HStack {
                    Text("Custom shortcut").foregroundStyle(.secondary)
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
            Spacer()
            Picker("", selection: $providerRaw) {
                ForEach(TTSProviderKind.allCases, id: \.self) { kind in
                    Text(displayName(for: kind)).tag(kind.rawValue)
                }
            }
            .labelsHidden()
            .frame(width: 240)
        }
    }

    private var voiceRow: some View {
        HStack {
            Label("Voice", systemImage: "person.wave.2")
            Spacer()
            Picker("", selection: $voiceID) {
                ForEach(provider.voices) { voice in
                    Text(voice.displayName).tag(voice.id)
                }
            }
            .labelsHidden()
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
                Spacer()
                Text(String(format: "%.2f×", speed))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: $speed, in: 0.5...2.0, step: 0.05)
        }
    }

    private var apiKeySection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Text("\(provider.displayName) API key")
                    .font(.headline)
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
                Label(isPreviewing ? "Speaking…" : "Preview voice", systemImage: "play.circle.fill")
            }
            .disabled(isPreviewing || (providerKind.isLocal && !kokoro.isInstalled))
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
                            Text(kokoro.statusText ?? "Downloading…")
                                .font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            if let p = kokoro.downloadProgress {
                                Text("\(Int(p * 100))%").font(.caption.monospacedDigit())
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

    private func reloadForProvider() {
        voiceID = TTSSettings.voiceID(for: providerKind) ?? provider.voices.first?.id ?? ""
        if let providerID = providerKind.apiKeyProvider {
            apiKey = APIKeyManager.shared.getAPIKey(forProvider: providerID) ?? ""
        } else {
            apiKey = ""
        }
        verifyState = .idle
    }

    private func saveAndVerify() async {
        guard let providerID = providerKind.apiKeyProvider else { return }
        APIKeyManager.shared.saveAPIKey(apiKey, forProvider: providerID)
        verifyState = .verifying
        let result = await provider.verifyAPIKey(apiKey)
        verifyState = result.isValid ? .valid : .invalid(result.errorMessage ?? "Invalid key")
    }

    private func preview() async {
        isPreviewing = true
        defer { isPreviewing = false }
        await previewController.speak("This is how the selected voice sounds in Zerm.")
        // brief settle so synthesis can start before the button re-enables
        try? await Task.sleep(nanoseconds: 1_200_000_000)
    }
}
