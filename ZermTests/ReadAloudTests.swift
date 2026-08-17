import Foundation
import Testing
@testable import Zerm

struct ReadAloudTests {
    @Test func appleSystemVoicesAreRegisteredAsAnOptionalLocalProvider() throws {
        let provider = try #require(TTSProviderRegistry.provider(for: .appleSystem))
        #expect(provider.kind == .appleSystem)
        #expect(!provider.requiresAPIKey)
        #expect(provider.kind.isLocal)
    }

    @Test func aiReadingModesHaveExplicitSemantics() {
        #expect(!ReadAloudMode.exact.usesLocalAI)
        #expect(ReadAloudMode.retell.usesLocalAI)
        #expect(ReadAloudMode.summarize.usesLocalAI)
        #expect(ReadAloudMode.explain.usesLocalAI)
        #expect(ReadAloudMode.simplify.usesLocalAI)
    }

    @Test @MainActor func hebrewMajoritySourceTakesTheHebrewInstructionPath() {
        #expect(TTSNaturalizer.isPredominantlyHebrew("צוות המוצר השלים את השינוי החשוב היום"))
    }

    @Test @MainActor func mixedHebrewAndEnglishDoesNotTakeTheHebrewOnlyPath() {
        #expect(!TTSNaturalizer.isPredominantlyHebrew(
            "Let's meet tomorrow בבוקר and then send the report"
        ))
    }

    @Test @MainActor func hebrewMajorityWithAnEnglishSpanDoesNotTakeTheHebrewOnlyPath() {
        #expect(!TTSNaturalizer.isPredominantlyHebrew(
            "צריך לשלוח the report היום לצוות המוצר"
        ))
    }

    @Test @MainActor func englishSourceIsNotTreatedAsHebrew() {
        #expect(!TTSNaturalizer.isPredominantlyHebrew("Please send the report today."))
    }

    @Test @MainActor func completedReadingsRoundTripThroughTheLocalHistoryStore() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("zerm-read-aloud-tests-\(UUID().uuidString)", isDirectory: true)
        let file = root.appendingPathComponent("history.json")
        defer { try? FileManager.default.removeItem(at: root) }

        let store = ReadAloudHistoryStore(fileURL: file)
        store.record(
            sourceText: "זהו הטקסט המקורי",
            spokenText: "זהו ניסוח טבעי של הטקסט המקורי",
            mode: .retell,
            providerName: "Apple System Voices",
            voiceName: "Carmit",
            localModelName: "Gemma 4 E2B"
        )

        let reloaded = ReadAloudHistoryStore(fileURL: file)
        let item = try #require(reloaded.items.first)
        #expect(item.sourceText == "זהו הטקסט המקורי")
        #expect(item.spokenText == "זהו ניסוח טבעי של הטקסט המקורי")
        #expect(item.mode == .retell)
        #expect(item.localModelName == "Gemma 4 E2B")
    }

    /// Opt-in runtime coverage for the Office Mac. The ordinary unit suite stays hermetic; the
    /// dedicated verification run creates a temporary marker so this exercises Apple's real
    /// Hebrew voice and whisper.cpp end to end. XCTest does not reliably inherit ad-hoc shell
    /// environment variables from xcodebuild on macOS, hence the explicit marker.
    @Test @MainActor func officeMacHebrewSpeechRoundTrip() async throws {
        let marker = URL(fileURLWithPath: "/tmp/ZermRunSpeechIntegration")
        guard FileManager.default.fileExists(atPath: marker.path) else {
            return
        }

        let apple = try #require(TTSProviderRegistry.provider(for: .appleSystem))
        let hebrewVoice = try #require(apple.voices.first(where: {
            Locale(identifier: $0.language).language.languageCode?.identifier == "he"
        }))
        let phrase = "שלום, זהו מבחן של זיהוי דיבור אוטומטי בעברית. "
        let source = Array(repeating: phrase, count: 10).joined()
        let rendered = try await apple.synthesize(
            text: source,
            voice: hebrewVoice,
            speed: 0.75,
            apiKey: ""
        )
        #expect(!rendered.pcm.isEmpty)
        #expect(rendered.sampleRate > 0)

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("zerm-hebrew-speech-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let wav = root.appendingPathComponent("hebrew.wav")
        try Self.writeWAV(rendered, to: wav)

        let modelDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.arcusis.zerm/WhisperModels", isDirectory: true)
        _ = try #require(
            FileManager.default.fileExists(atPath: modelDirectory.path)
        )
        let modelName = "ggml-large-v3-turbo-q5_0"
        let model = try #require(
            TranscriptionModelRegistry.models.first(where: { $0.name == modelName })
        )
        let manager = WhisperModelManager(modelsDirectory: modelDirectory)
        manager.loadAvailableModels()
        #expect(manager.availableModels.contains(where: { $0.name == modelName }))

        let previousLanguage = UserDefaults.standard.object(forKey: LanguagePreference.defaultsKey)
        UserDefaults.standard.set(LanguagePreference.autoCode, forKey: LanguagePreference.defaultsKey)
        defer {
            if let previousLanguage {
                UserDefaults.standard.set(previousLanguage, forKey: LanguagePreference.defaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: LanguagePreference.defaultsKey)
            }
        }

        let service = WhisperTranscriptionService(
            modelsDirectory: modelDirectory,
            modelProvider: manager
        )
        let transcript = try await service.transcribe(audioURL: wav, model: model)
        print("Office Hebrew auto transcript: \(transcript)")
        let letters = transcript.unicodeScalars.filter(CharacterSet.letters.contains)
        let hebrewLetters = letters.filter { (0x0590...0x05FF).contains($0.value) }
        #expect(letters.count >= 20)
        #expect(Double(hebrewLetters.count) / Double(max(1, letters.count)) >= 0.65)
    }

    private static func writeWAV(_ audio: TTSAudio, to url: URL) throws {
        let sampleRate = UInt32(audio.sampleRate.rounded())
        let channels = UInt16(audio.channels)
        let bitsPerSample: UInt16 = 16
        let byteRate = sampleRate * UInt32(channels) * UInt32(bitsPerSample / 8)
        let blockAlign = channels * (bitsPerSample / 8)
        var data = Data()

        func append<T: FixedWidthInteger>(_ value: T) {
            var littleEndian = value.littleEndian
            withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
        }

        data.append(contentsOf: "RIFF".utf8)
        append(UInt32(36 + audio.pcm.count))
        data.append(contentsOf: "WAVEfmt ".utf8)
        append(UInt32(16))
        append(UInt16(1))
        append(channels)
        append(sampleRate)
        append(byteRate)
        append(blockAlign)
        append(bitsPerSample)
        data.append(contentsOf: "data".utf8)
        append(UInt32(audio.pcm.count))
        data.append(audio.pcm)
        try data.write(to: url, options: .atomic)
    }
}

struct OfficeLocalReadAloudIntegrationTests {
    /// Reproduces the 2026-08-14 production crash: a prompt larger than llama.cpp's logical
    /// decode batch and a response budget that together exceed the 4K KV context. This is
    /// opt-in because it loads the multi-gigabyte local model, but it must complete without a
    /// process-level ggml_abort before a feedback build is installed.
    @Test @MainActor func longLocalEnhancementStaysInsideBatchAndContextLimits() async throws {
        let marker = URL(fileURLWithPath: "/tmp/ZermRunLocalLLMLongContextIntegration")
        guard FileManager.default.fileExists(atPath: marker.path) else { return }

        let manager = LocalLLMModelManager.shared
        let package = LocalLLMModelManager.defaultPackage
        manager.select(package)
        if !manager.isDownloaded(package) {
            await manager.download(package)
        }
        #expect(manager.isDownloaded(package))

        let paragraph = "The product team reviewed the meeting transcript, preserved every decision, and corrected the wording without changing the meaning. "
        let source = String(repeating: paragraph, count: 180)
        let result = try await manager.generate(
            system: "Rewrite the transcript clearly. Return only the rewritten text.",
            user: "<TRANSCRIPT>\(source)</TRANSCRIPT>",
            maxNewTokens: 512
        )

        #expect(!result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    /// Downloads/verifies the current shipped local LLM when necessary, runs the real Retell
    /// transformation in Hebrew, and then synthesizes the transformed text with an installed
    /// local voice. This is deliberately opt-in because the default model is several gigabytes.
    @Test @MainActor func latestLocalModelRetellsAndSynthesizesHebrew() async throws {
        let marker = URL(fileURLWithPath: "/tmp/ZermRunLocalReadAloudIntegration")
        guard FileManager.default.fileExists(atPath: marker.path) else { return }

        let manager = LocalLLMModelManager.shared
        let package = LocalLLMModelManager.defaultPackage
        manager.select(package)
        if !manager.isDownloaded(package) {
            await manager.download(package)
        }
        #expect(manager.isDownloaded(package))
        #expect(manager.currentPackage == package)

        let source = """
        צוות המוצר השלים את השינוי החשוב. מעכשיו המערכת מנתחת את הטקסט הנבחר במלואו,
        שומרת על המשמעות ועל הפרטים, ורק לאחר מכן מקריאה אותו בניסוח טבעי וברור.
        """
        let spoken = try await TTSNaturalizer(llm: manager).transform(source, mode: .retell)
        print("Office local Hebrew retell: \(spoken)")
        let letters = spoken.unicodeScalars.filter(CharacterSet.letters.contains)
        let hebrewLetters = letters.filter { (0x0590...0x05FF).contains($0.value) }
        #expect(spoken != source)
        #expect(letters.count >= 20)
        #expect(Double(hebrewLetters.count) / Double(max(1, letters.count)) >= 0.65)

        let apple = try #require(TTSProviderRegistry.provider(for: .appleSystem))
        let hebrewVoice = try #require(apple.voices.first(where: {
            Locale(identifier: $0.language).language.languageCode?.identifier == "he"
        }))
        let audio = try await apple.synthesize(text: spoken, voice: hebrewVoice, speed: 1, apiKey: "")
        #expect(!audio.pcm.isEmpty)
        #expect(audio.sampleRate > 0)

        let enhancementSystem = String(
            format: AIPrompts.customPromptTemplate,
            "Remove filler words and correct grammar without changing the meaning."
        )
        let enhanced = try await manager.generate(
            system: enhancementSystem,
            user: "<TRANSCRIPT>אממ אני רוצה לקבוע את פגישת המוצר ביום שני בשעה שלוש.</TRANSCRIPT>",
            maxNewTokens: 160
        )
        print("Office local Hebrew enhancement: \(enhanced)")
        let enhancedLetters = enhanced.unicodeScalars.filter(CharacterSet.letters.contains)
        let enhancedHebrew = enhancedLetters.filter { (0x0590...0x05FF).contains($0.value) }
        #expect(enhanced.contains("פגיש"))
        #expect(Double(enhancedHebrew.count) / Double(max(1, enhancedLetters.count)) >= 0.65)
    }
}

struct OfficeKokoroRuntimeIntegrationTests {
    /// Exercises the local voice model plus the real streaming player. Opt-in because first use
    /// downloads/extracts the Kokoro package and produces audible Office-Mac output.
    @Test @MainActor func kokoroSynthesizesAndCompletesStreamingPlayback() async throws {
        let marker = URL(fileURLWithPath: "/tmp/ZermRunKokoroIntegration")
        guard FileManager.default.fileExists(atPath: marker.path) else { return }

        let manager = KokoroModelManager.shared
        if !manager.isInstalled { await manager.download() }
        #expect(manager.isInstalled)

        let provider = try #require(TTSProviderRegistry.provider(for: .kokoro))
        let voice = try #require(provider.voices.first)
        let audio = try await provider.synthesize(
            text: "Zerm now analyzes the complete selection before retelling it clearly.",
            voice: voice,
            speed: 1,
            apiKey: ""
        )
        #expect(audio.pcm.count > Int(audio.sampleRate))

        let player = TTSPlayer()
        var completed = false
        player.startStreaming { completed = true }
        try await player.enqueue(audio)
        player.finishEnqueueing()

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(12))
        while !completed, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(completed)
        #expect(!player.isPlaying)
        player.stop()
    }
}
