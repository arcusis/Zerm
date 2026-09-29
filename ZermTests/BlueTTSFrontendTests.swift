import CryptoKit
import Foundation
import Testing
@testable import Zerm

struct BlueTTSFrontendTests {
    @Test func referenceShortHebrewAndEnglishPhonemeIDsRemainStable() throws {
        let vocabulary: [String: Int] = [
            " ": 3, ",": 8, ".": 10, "a": 14, "b": 15, "d": 17, "e": 18, "f": 19,
            "h": 20, "i": 21, "j": 22, "k": 23, "l": 24, "m": 25, "n": 26,
            "o": 27, "p": 28, "s": 31, "t": 32, "v": 34, "w": 35, "æ": 39,
            "ð": 41, "ŋ": 44, "ɐ": 50, "ɔ": 54, "ə": 59, "ɚ": 60, "ɜ": 62,
            "ɪ": 74, "ɹ": 88, "ʁ": 94, "ʃ": 96, "ʊ": 100, "ʌ": 102,
            "ʔ": 109, "ˈ": 120, "ˌ": 121, "ː": 122, "χ": 127, "ᵻ": 128
        ]
        let references: [(String, String, String)] = [
            (
                "he",
                "<he>babˈokeʁ jatsʔˈa noʔˈa mehabˈajit, kantˈa kafˈe bataχanˈa vehemʃˈiχa baʁakˈevet laʔavodˈa.</he>",
                "0d5f4e64bfb358c429e71e013fb847882f71ed8255fdcc37fe4054e9c93b4245"
            ),
            (
                "en",
                "<en>ðə mˈɔːɹnɪŋ tɹˈeɪn ɚɹˈaɪvd ˈɜːli, sˌoʊ mˈaɪə ɹˈiːd ɐnˈʌðɚ tʃˈæptɚ bᵻfˌɔːɹ wˈɜːk.</en>",
                "84d05db5a1e264ef0cbba891f2ed5aec3eed7d9461e5f6556196cdae0a8c9187"
            )
        ]

        for (_, phonemes, expectedHash) in references {
            let ids = BlueTextFrontend.tokenIDs(for: phonemes, vocabulary: vocabulary).map(Int.init)
            let data = try JSONSerialization.data(withJSONObject: ids)
            let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            #expect(actual == expectedHash)
        }
    }

    @Test func pinnedCatalogCoversEveryDownloadedFileAndLicense() {
        #expect(BlueModelCatalog.modelRevision.count == 40)
        #expect(BlueModelCatalog.renikudRevision.count == 40)
        #expect(BlueModelCatalog.files.allSatisfy { $0.sha256.count == 64 })
        #expect(BlueModelCatalog.espeakDataArchive.sha256.count == 64)
        #expect(BlueModelCatalog.espeakDataArchive.url.host == "github.com")
        #expect(BlueModelCatalog.files.allSatisfy { ["huggingface.co", "github.com"].contains($0.url.host ?? "") })
        #expect(BlueModelCatalog.provenance.licenseSPDX == "MIT AND CC-BY-4.0 AND GPL-3.0-or-later")
        #expect(BlueModelCatalog.provenance.attribution.contains("CC-BY-4.0"))
    }

    @Test func mixedTextSplitsIntoHebrewAndEnglishRuns() {
        let runs = BlueTextFrontend.languageRuns(in: "שלום world היום")
        #expect(runs.map { "\($0.language):\($0.text)" } == ["he:שלום ", "en:world ", "he:היום"])
    }

    @Test func speechChunksStartWithSentenceAndStayUnderModelInputLimit() {
        let text = "First sentence. " + String(repeating: "second sentence with several words. ", count: 12)
        let chunks = BlueTextFrontend.sentenceChunks(text)
        #expect(chunks.first == "First sentence. ")
        #expect(chunks.allSatisfy { $0.count <= 100 })
    }

    @MainActor @Test func espeakDataLookupReusesKokoroPackageData() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let kokoroData = root
            .appendingPathComponent(KokoroModelManager.package.name, isDirectory: true)
            .appendingPathComponent(KokoroModelManager.package.dataDirName, isDirectory: true)
        let blueData = root
            .appendingPathComponent(BlueModelManager.packageName, isDirectory: true)
            .appendingPathComponent(EspeakDataSupport.directoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: kokoroData, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: blueData, withIntermediateDirectories: true)
        try Data().write(to: kokoroData.appendingPathComponent("phontab"))
        try Data().write(to: blueData.appendingPathComponent("phontab"))

        #expect(EspeakDataSupport.dataDirectory(in: root) == kokoroData)
    }

    @MainActor @Test func espeakDataLookupFindsBluePackageWhenKokoroDataMissing() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let blueData = root
            .appendingPathComponent(BlueModelManager.packageName, isDirectory: true)
            .appendingPathComponent(EspeakDataSupport.directoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: blueData, withIntermediateDirectories: true)
        try Data().write(to: blueData.appendingPathComponent("phontab"))

        #expect(EspeakDataSupport.dataDirectory(in: root) == blueData)
        #expect(EspeakDataSupport.containsData(in: root))
    }

    @MainActor @Test func espeakArchiveExtractsExpectedFolder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source", isDirectory: true)
        let data = source.appendingPathComponent(EspeakDataSupport.directoryName, isDirectory: true)
        let models = root.appendingPathComponent("models", isDirectory: true)
        let package = models.appendingPathComponent(BlueModelManager.packageName, isDirectory: true)
        let archive = root.appendingPathComponent("fixture.tar.bz2")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        try Data("phoneme data".utf8).write(to: data.appendingPathComponent("phontab"))
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try Self.createEspeakArchive(from: source, at: archive)

        let destination = package.appendingPathComponent(EspeakDataSupport.directoryName, isDirectory: true)
        try EspeakDataSupport.extractTarBz2(at: archive, into: models, destination: destination)

        #expect(try String(contentsOf: destination.appendingPathComponent("phontab"), encoding: .utf8) == "phoneme data")
    }

    @MainActor @Test func espeakArchiveRejectsSymbolicLinks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source", isDirectory: true)
        let data = source.appendingPathComponent(EspeakDataSupport.directoryName, isDirectory: true)
        let archive = root.appendingPathComponent("fixture.tar.bz2")
        let models = root.appendingPathComponent("models", isDirectory: true)
        let package = models.appendingPathComponent(BlueModelManager.packageName, isDirectory: true)
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        try Data("phoneme data".utf8).write(to: data.appendingPathComponent("phontab"))
        try FileManager.default.createSymbolicLink(
            at: data.appendingPathComponent("outside-link"),
            withDestinationURL: URL(fileURLWithPath: "/tmp/espeak-outside-target")
        )
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try Self.createEspeakArchive(from: source, at: archive)

        let destination = package.appendingPathComponent(EspeakDataSupport.directoryName, isDirectory: true)
        #expect(throws: Error.self) {
            try EspeakDataSupport.extractTarBz2(at: archive, into: models, destination: destination)
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @MainActor @Test func espeakArchiveRejectsPathTraversal() {
        #expect(throws: Error.self) {
            try EspeakDataSupport.validateArchiveEntries(
                names: "espeak-ng-data/../outside\n",
                details: "-rw-r--r-- root staff 12 espeak-ng-data/file\n"
            )
        }
    }

    private static func createEspeakArchive(from directory: URL, at archive: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-c", "-j", "-f", archive.path, "-C", directory.path, EspeakDataSupport.directoryName]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }

    @Test func hebrewNumberNormalizationSpellsDatesTimesAndPercentages() {
        let normalized = BlueTextFrontend.normalizeHebrewNumbers("ב־14 באפריל 2026, בשעה 07:35, החליפו 18.6%.")
        #expect(normalized.contains("ארבע עשרה"))
        #expect(normalized.contains("אלפיים עשרים ושש"))
        #expect(normalized.contains("שבע שלושים וחמש"))
        #expect(normalized.contains("שמונה עשרה נקודה שש אחוז"))
        #expect(normalized.range(of: #"\d"#, options: .regularExpression) == nil)
    }

    @MainActor @Test func BlueRoutesHebrewAndEnglishAndKeepsRussianOnApple() throws {
        let provider = BlueTTSProvider()
        let voice = try #require(provider.voices.first)
        let hebrew = try TTSLanguageRouter.resolve(
            provider: provider, voice: voice, text: "צוות המוצר השלים את השינוי החשוב היום", appleVoices: [], blueIsInstalled: true
        )
        #expect(hebrew.provider.kind == .blue)
        let english = try TTSLanguageRouter.resolve(
            provider: provider, voice: voice, text: "The product team shipped the important change today.", appleVoices: [], blueIsInstalled: true
        )
        #expect(english.provider.kind == .blue)
        let russianVoice = TTSVoice(id: "ru", displayName: "Milena", provider: .appleSystem, language: "ru-RU")
        let russian = try TTSLanguageRouter.resolve(
            provider: provider, voice: voice, text: "Команда завершила важное изменение сегодня утром", appleVoices: [russianVoice]
        )
        #expect(russian.provider.kind == .appleSystem)
        #expect(russian.voice == russianVoice)
    }

    @MainActor @Test func blueUsesAppleFallbackWhenModelIsMissing() throws {
        let provider = BlueTTSProvider()
        let voice = try #require(provider.voices.first)
        let hebrewVoice = TTSVoice(id: "he", displayName: "Hebrew", provider: .appleSystem, language: "he-IL")
        let route = try TTSLanguageRouter.resolve(
            provider: provider, voice: voice, text: "צוות המוצר השלים את השינוי החשוב היום",
            appleVoices: [hebrewVoice], blueIsInstalled: false
        )
        #expect(route.provider.kind == .appleSystem)
        #expect(route.voice == hebrewVoice)
        #expect(route.rerouteNotice != nil)
    }

    @MainActor
    @Test func blueIntegrationWritesSixSilentSampleFiles() async throws {
        let marker = URL(fileURLWithPath: "/tmp/ZermRunBlueIntegration")
        guard FileManager.default.fileExists(atPath: marker.path) else { return }
        let manager = BlueModelManager.shared
        if !manager.isInstalled { await manager.download() }
        #expect(manager.isInstalled)
        let cancelled = Task.detached {
            try await manager.synthesize(text: String(repeating: "שלום עולם ", count: 2_000), language: "he", speed: 1)
        }
        cancelled.cancel()
        do {
            _ = try await cancelled.value
            Issue.record("Cancelled Blue synthesis returned audio")
        } catch is CancellationError {
            #expect(Bool(true))
        }
        let outputDirectory = URL(fileURLWithPath: "/tmp/zerm-work/407-samples", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let fixedTexts: [(String, String, String)] = [
            ("he-short", "he", "he_short.txt"),
            ("he-short-niqqud", "he", "he_short_niqqud.txt"),
            ("he-long", "he", "he_long.txt"),
            ("en-short", "en", "en_short.txt"),
            ("en-long", "en", "en_long.txt")
        ]
        for (name, language, filename) in fixedTexts {
            let textFile = URL(fileURLWithPath: "/tmp/tts-research/bench/texts/\(filename)")
            let text = try String(contentsOf: textFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            let audio = try await manager.synthesize(text: text, language: language, speed: 1)
            try Self.writeWAV(audio, to: outputDirectory.appendingPathComponent("\(name).wav"))
        }
        let mixed = try await manager.synthesize(text: "שלום team, we are leaving היום.", language: "he", speed: 1)
        try Self.writeWAV(mixed, to: outputDirectory.appendingPathComponent("mixed-he-en.wav"))
        #expect(fixedTexts.count + 1 == 6)
    }

    private static func writeWAV(_ audio: TTSAudio, to url: URL) throws {
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            var littleEndian = value.littleEndian
            withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: "RIFF".utf8)
        append(UInt32(36 + audio.pcm.count))
        data.append(contentsOf: "WAVEfmt ".utf8)
        append(UInt32(16)); append(UInt16(1)); append(UInt16(audio.channels))
        let sampleRate = UInt32(audio.sampleRate)
        append(sampleRate); append(sampleRate * UInt32(audio.channels) * 2)
        append(UInt16(audio.channels * 2)); append(UInt16(16))
        data.append(contentsOf: "data".utf8)
        append(UInt32(audio.pcm.count)); data.append(audio.pcm)
        try data.write(to: url, options: .atomic)
    }
}
