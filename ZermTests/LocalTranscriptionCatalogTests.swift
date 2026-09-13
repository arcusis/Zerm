import Foundation
import Testing
@testable import Zerm

/// The local speech catalog, its hardware recommendations, and the migration off retired models (#326).
@MainActor
struct LocalTranscriptionCatalogTests {

    private var localModels: [any LocalTranscriptionModel] {
        TranscriptionModelRegistry.models.compactMap { $0 as? any LocalTranscriptionModel }
    }

    private func model(named name: String) throws -> any LocalTranscriptionModel {
        try #require(localModels.first { $0.name == name }, "\(name) is not in the catalog")
    }

    // MARK: - Catalog metadata

    @Test func catalogIsExactlyTheCurrentLocalLineUp() {
        #expect(Set(localModels.map(\.name)) == [
            "apple-speech",
            "parakeet-unified-en-0.6b",
            "parakeet-tdt-ctc-110m",
            "parakeet-tdt-0.6b-v3",
            "ggml-large-v3-turbo",
            "ggml-large-v3-turbo-q5_0",
            "ivrit-large-v3-turbo",
            "ivrit-large-v3"
        ])
    }

    @Test func everyLocalModelHasCompleteMetadata() {
        for model in localModels {
            #expect(model.estimatedRAMGB > 0, "\(model.name)")
            #expect((0...1).contains(model.accuracy) && model.accuracy > 0, "\(model.name)")
            #expect((0...1).contains(model.speed) && model.speed > 0, "\(model.name)")
            #expect(!model.supportedLanguages.isEmpty, "\(model.name)")
            #expect(!model.displayName.isEmpty && !model.description.isEmpty, "\(model.name)")
            switch model.languageGroup {
            case .englishOnly:
                #expect(model.supportedLanguages == ["en": "English"], "\(model.name)")
                #expect(!model.isHebrewOptimized, "\(model.name)")
            case .multilingual:
                #expect(model.isMultilingualModel, "\(model.name)")
            }
        }

        for model in localModels {
            if let whisper = model as? WhisperModel {
                #expect(!whisper.size.isEmpty, "\(model.name)")
            } else if let fluidAudio = model as? FluidAudioModel {
                #expect(!fluidAudio.size.isEmpty, "\(model.name)")
            }
        }
    }

    @Test func languageGroupsAndHebrewFlags() throws {
        #expect(try model(named: "parakeet-unified-en-0.6b").languageGroup == .englishOnly)
        #expect(try model(named: "parakeet-tdt-ctc-110m").languageGroup == .englishOnly)
        #expect(try model(named: "parakeet-tdt-0.6b-v3").languageGroup == .multilingual)
        #expect(try model(named: "ggml-large-v3-turbo").languageGroup == .multilingual)
        #expect(try model(named: "apple-speech").languageGroup == .multilingual)

        let hebrew = localModels.filter(\.isHebrewOptimized).map(\.name)
        #expect(Set(hebrew) == ["ivrit-large-v3-turbo", "ivrit-large-v3"])
        for name in hebrew {
            let ivrit = try model(named: name)
            #expect(ivrit.languageGroup == .multilingual)
            #expect(Set(ivrit.supportedLanguages.keys) == ["auto", "he", "en"])
        }
    }

    @Test func everyWhisperDownloadIsPinnedToACommitAndHash() {
        for model in localModels.compactMap({ $0 as? WhisperModel }) {
            let sha = ModelIntegrity.whisperSHA256[model.name]
            #expect(sha?.count == 64, "\(model.name) has no SHA-256 pin")
            #expect(model.source.commit.count == 40, "\(model.name)")
            #expect(model.downloadURL == "https://huggingface.co/\(model.source.repository)/resolve/\(model.source.commit)/\(model.source.fileName)")
        }
        #expect(ModelIntegrity.ivritLargeV3Turbo.repository == "ivrit-ai/whisper-large-v3-turbo-ggml")
        #expect(ModelIntegrity.ivritLargeV3.repository == "ivrit-ai/whisper-large-v3-ggml")
    }

    /// A fine-tune must never pick up the stock whisper.cpp Core ML encoder or download one.
    @Test func onlyStockWhisperModelsUseCoreMLEncoders() {
        #expect(WhisperModelFile.hasCoreMLEncoder(modelName: "ggml-large-v3-turbo"))
        #expect(!WhisperModelFile.hasCoreMLEncoder(modelName: "ggml-large-v3-turbo-q5_0"))
        #expect(!WhisperModelFile.hasCoreMLEncoder(modelName: "ivrit-large-v3-turbo"))
        #expect(!WhisperModelFile.hasCoreMLEncoder(modelName: "ivrit-large-v3"))
    }

    @Test func fluidAudioModelsResolveToAnEngine() {
        for model in localModels.compactMap({ $0 as? FluidAudioModel }) {
            let known = FluidAudioModelManager.modelVersionMap[model.name] != nil
                || model.name == FluidAudioModelManager.unifiedModelName
            #expect(known, "\(model.name) has no FluidAudio engine")
        }
        #expect(FluidAudioModelManager.modelVersionMap["parakeet-tdt-0.6b-v2"] == nil)
    }

    // MARK: - FluidAudio cache states

    /// A cache folder named like FluidAudio's, holding the given files.
    private func parakeetCache(folderName: String, files: [String]) throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ParakeetCache-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(folderName, isDirectory: true)
        for file in files {
            if file.hasSuffix(".mlmodelc") {
                try FileManager.default.createDirectory(at: folder.appendingPathComponent(file), withIntermediateDirectories: true)
            } else {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                #expect(FileManager.default.createFile(atPath: folder.appendingPathComponent(file).path, contents: Data("{}".utf8)))
            }
        }
        return folder
    }

    private let v3 = "parakeet-tdt-0.6b-v3"
    private let v3Folder = "parakeet-tdt-0.6b-v3"

    /// Exactly what a pre-2.8.6 (FluidAudio before 0.15.7) V3 download left on disk.
    private let preUpdateV3Files = [
        "Preprocessor.mlmodelc", "Encoder.mlmodelc", "Decoder.mlmodelc", "JointDecision.mlmodelc", "parakeet_vocab.json"
    ]

    @Test func preUpdateParakeetV3CacheStillCountsAsInstalled() throws {
        let folder = try parakeetCache(folderName: v3Folder, files: preUpdateV3Files)
        #expect(FluidAudioModelManager.cacheState(forModelNamed: v3, in: folder) == .needsUpdate)
    }

    @Test func currentParakeetV3CacheIsComplete() throws {
        let folder = try parakeetCache(folderName: v3Folder, files: preUpdateV3Files + ["JointDecisionv3.mlmodelc"])
        #expect(FluidAudioModelManager.cacheState(forModelNamed: v3, in: folder) == .complete)
    }

    @Test func missingOrHalfDeletedParakeetV3CacheNeedsADownload() throws {
        let absent = FileManager.default.temporaryDirectory
            .appendingPathComponent("ParakeetCache-\(UUID().uuidString)/\(v3Folder)", isDirectory: true)
        #expect(FluidAudioModelManager.cacheState(forModelNamed: v3, in: absent) == .missing)

        let empty = try parakeetCache(folderName: v3Folder, files: [])
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        #expect(FluidAudioModelManager.cacheState(forModelNamed: v3, in: empty) == .missing)

        let noEncoder = try parakeetCache(
            folderName: v3Folder,
            files: preUpdateV3Files.filter { $0 != "Encoder.mlmodelc" } + ["JointDecisionv3.mlmodelc"]
        )
        #expect(FluidAudioModelManager.cacheState(forModelNamed: v3, in: noEncoder) == .missing)

        let noVocabulary = try parakeetCache(folderName: v3Folder, files: preUpdateV3Files.filter { $0 != "parakeet_vocab.json" })
        #expect(FluidAudioModelManager.cacheState(forModelNamed: v3, in: noVocabulary) == .missing)
    }

    /// 110M and Unified are new in 2.8.6, so only a full download counts.
    @Test func newParakeetModelsNeedTheirFullFileSet() throws {
        let tdtCtcFolder = "parakeet-tdt-ctc-110m"
        let full110M = ["Preprocessor.mlmodelc", "Decoder.mlmodelc", "JointDecision.mlmodelc", "parakeet_vocab.json"]
        let complete = try parakeetCache(folderName: tdtCtcFolder, files: full110M)
        #expect(FluidAudioModelManager.cacheState(forModelNamed: "parakeet-tdt-ctc-110m", in: complete) == .complete)
        let partial = try parakeetCache(folderName: tdtCtcFolder, files: full110M.filter { $0 != "JointDecision.mlmodelc" })
        #expect(FluidAudioModelManager.cacheState(forModelNamed: "parakeet-tdt-ctc-110m", in: partial) == .missing)

        let unified = FluidAudioModelManager.unifiedModelName
        let unifiedComplete = try parakeetCache(folderName: "parakeet-unified-en-0.6b", files: FluidAudioModelManager.unifiedRequiredFiles)
        #expect(FluidAudioModelManager.cacheState(forModelNamed: unified, in: unifiedComplete) == .complete)
        let unifiedPartial = try parakeetCache(
            folderName: "parakeet-unified-en-0.6b",
            files: Array(FluidAudioModelManager.unifiedRequiredFiles.dropFirst())
        )
        #expect(FluidAudioModelManager.cacheState(forModelNamed: unified, in: unifiedPartial) == .missing)
    }

    @Test func updateDownloadErrorSaysWhatIsNeeded() {
        let message = FluidAudioModelError.updateDownloadRequired.errorDescription ?? ""
        #expect(message.contains("one-time update download"))
        #expect(TranscriptionPipeline.describeTranscriptionFailure(FluidAudioModelError.updateDownloadRequired) == message)
    }

    // MARK: - Hebrew fine-tunes force Hebrew

    @Test func ivritModelsForceHebrewUnlessEnglishIsChosen() throws {
        let ivrit = try #require(try model(named: "ivrit-large-v3-turbo") as? WhisperModel)
        #expect(ivrit.transcriptionLanguageCode(forSelected: "auto") == "he")
        #expect(ivrit.transcriptionLanguageCode(forSelected: "he") == "he")
        #expect(ivrit.transcriptionLanguageCode(forSelected: "en") == "en")
        #expect(ivrit.transcriptionLanguageCode(forSelected: "fr") == "he")

        let turbo = try #require(try model(named: "ggml-large-v3-turbo") as? WhisperModel)
        #expect(turbo.transcriptionLanguageCode(forSelected: "auto") == "auto")
        #expect(turbo.transcriptionLanguageCode(forSelected: "fr") == "fr")
    }

    private final class LanguageRecordingService: TranscriptionService {
        var seenLanguage: String?
        func transcribe(audioURL: URL, model: any TranscriptionModel) async throws -> String {
            seenLanguage = LanguagePreference.selectedCode()
            return ""
        }
    }

    @Test func fineTuneServiceRunsTheWhisperEngineInHebrewOnAuto() async throws {
        let ivrit = try #require(try model(named: "ivrit-large-v3") as? WhisperModel)
        let base = LanguageRecordingService()
        let service = HebrewFineTuneTranscriptionService(base: base, model: ivrit)

        try await LanguagePreference.$operationOverrideCode.withValue("auto") {
            _ = try await service.transcribe(audioURL: URL(fileURLWithPath: "/dev/null"), model: ivrit)
        }
        #expect(base.seenLanguage == "he")

        try await LanguagePreference.$operationOverrideCode.withValue("en") {
            _ = try await service.transcribe(audioURL: URL(fileURLWithPath: "/dev/null"), model: ivrit)
        }
        #expect(base.seenLanguage == "en")
    }

    // MARK: - Recommendations

    private typealias Profile = HardwareCapability.Profile

    private func picks(_ profile: Profile) -> [HardwareCapability.RecommendationNeed: String] {
        var result: [HardwareCapability.RecommendationNeed: String] = [:]
        for need in HardwareCapability.RecommendationNeed.allCases {
            result[need] = HardwareCapability.recommendedLocalModel(
                for: need,
                among: TranscriptionModelRegistry.models,
                profile: profile
            )?.name
        }
        return result
    }

    @Test func intel16GBGetsOnlyWhisperCpp() {
        let result = picks(Profile(isAppleSilicon: false, physicalMemoryGB: 16, hasAppleSpeech: true))
        #expect(result == [
            .english: "ggml-large-v3-turbo-q5_0",
            .multilingual: "ggml-large-v3-turbo-q5_0",
            .hebrew: "ivrit-large-v3-turbo"
        ])
    }

    @Test func appleSilicon8GBStaysLight() {
        let result = picks(Profile(isAppleSilicon: true, physicalMemoryGB: 8, hasAppleSpeech: false))
        #expect(result == [
            .english: "parakeet-tdt-ctc-110m",
            .multilingual: "parakeet-tdt-0.6b-v3",
            .hebrew: "ivrit-large-v3-turbo"
        ])
    }

    /// On macOS 26 the system speech model costs Zerm almost no memory, which matters most on 8 GB.
    @Test func appleSilicon8GBOnMacOS26UsesAppleSpeechForManyLanguages() {
        let result = picks(Profile(isAppleSilicon: true, physicalMemoryGB: 8, hasAppleSpeech: true))
        #expect(result == [
            .english: "parakeet-tdt-ctc-110m",
            .multilingual: "apple-speech",
            .hebrew: "ivrit-large-v3-turbo"
        ])
    }

    @Test func appleSilicon16GB() {
        let expected: [HardwareCapability.RecommendationNeed: String] = [
            .english: "parakeet-unified-en-0.6b",
            .multilingual: "ggml-large-v3-turbo",
            .hebrew: "ivrit-large-v3-turbo"
        ]
        #expect(picks(Profile(isAppleSilicon: true, physicalMemoryGB: 16, hasAppleSpeech: false)) == expected)
        #expect(picks(Profile(isAppleSilicon: true, physicalMemoryGB: 16, hasAppleSpeech: true)) == expected)
    }

    @Test func appleSilicon24GBAnd64GBGetTheLargeHebrewModel() {
        let expected: [HardwareCapability.RecommendationNeed: String] = [
            .english: "parakeet-unified-en-0.6b",
            .multilingual: "ggml-large-v3-turbo",
            .hebrew: "ivrit-large-v3"
        ]
        #expect(picks(Profile(isAppleSilicon: true, physicalMemoryGB: 24, hasAppleSpeech: true)) == expected)
        #expect(picks(Profile(isAppleSilicon: true, physicalMemoryGB: 64, hasAppleSpeech: true)) == expected)
        #expect(picks(Profile(isAppleSilicon: true, physicalMemoryGB: 64, hasAppleSpeech: false)) == expected)
    }

    @Test func recommendationsNeverExceedWhatTheMacCanRun() {
        let profiles = [
            Profile(isAppleSilicon: false, physicalMemoryGB: 8, hasAppleSpeech: false),
            Profile(isAppleSilicon: true, physicalMemoryGB: 8, hasAppleSpeech: true),
            Profile(isAppleSilicon: true, physicalMemoryGB: 16, hasAppleSpeech: false),
            Profile(isAppleSilicon: true, physicalMemoryGB: 96, hasAppleSpeech: true)
        ]
        for profile in profiles {
            for need in HardwareCapability.RecommendationNeed.allCases {
                guard let pick = HardwareCapability.recommendedLocalModel(for: need, among: TranscriptionModelRegistry.models, profile: profile) else {
                    continue
                }
                #expect(HardwareCapability.canRun(pick, on: profile), "\(pick.name) on \(profile)")
                if case .good = HardwareCapability.fit(forEstimatedRAMGB: pick.estimatedRAMGB, physicalMemoryGB: profile.physicalMemoryGB) {
                } else {
                    Issue.record("\(pick.name) does not fit \(profile)")
                }
            }
        }
    }

    // MARK: - Retired model migration

    private func isolatedDefaults(_ name: String = #function) -> UserDefaults {
        let suite = "com.arcusis.zerm.tests.localcatalog.\(name)"
        UserDefaults().removePersistentDomain(forName: suite)
        return UserDefaults(suiteName: suite)!
    }

    private func temporaryDirectory(_ name: String = #function) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalTranscriptionCatalogTests-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func runMigration(_ defaults: UserDefaults, isAppleSilicon: Bool = true, whisper: URL, parakeetV2: URL) {
        RetiredLocalTranscriptionModelMigration.run(
            defaults: defaults,
            isAppleSilicon: isAppleSilicon,
            whisperModelsDirectory: whisper,
            parakeetV2CacheDirectory: parakeetV2
        )
    }

    @Test(arguments: [
        ("ggml-tiny.en", true, "parakeet-unified-en-0.6b"),
        ("ggml-base.en", true, "parakeet-unified-en-0.6b"),
        ("ggml-small.en", true, "parakeet-unified-en-0.6b"),
        ("ggml-tiny.en", false, "ggml-large-v3-turbo-q5_0"),
        ("ggml-small.en", false, "ggml-large-v3-turbo-q5_0"),
        ("ggml-tiny", true, "ggml-large-v3-turbo-q5_0"),
        ("ggml-base", false, "ggml-large-v3-turbo-q5_0"),
        ("ggml-small", true, "ggml-large-v3-turbo-q5_0"),
        ("parakeet-tdt-0.6b-v2", true, "parakeet-unified-en-0.6b")
    ])
    func selectionMovesToTheClosestReplacement(retired: String, isAppleSilicon: Bool, replacement: String) throws {
        let defaults = isolatedDefaults("selection-\(retired)-\(isAppleSilicon)")
        let whisper = try temporaryDirectory("selection")
        defaults.set(retired, forKey: "CurrentTranscriptionModel")

        runMigration(defaults, isAppleSilicon: isAppleSilicon, whisper: whisper, parakeetV2: whisper.appendingPathComponent("v2"))

        #expect(defaults.string(forKey: "CurrentTranscriptionModel") == replacement)
        let notice = defaults.dictionary(forKey: RetiredLocalTranscriptionModelMigration.replacementNoticeKey) as? [String: String]
        #expect(notice == ["retired": retired, "replacement": replacement])
        #expect(defaults.bool(forKey: RetiredLocalTranscriptionModelMigration.completionKey))
        #expect(TranscriptionModelRegistry.models.contains { $0.name == replacement })
    }

    @Test func currentModelsAreLeftAloneWithoutANotice() throws {
        let defaults = isolatedDefaults()
        defaults.set("parakeet-tdt-0.6b-v3", forKey: "CurrentTranscriptionModel")

        let whisper = try temporaryDirectory()
        runMigration(defaults, whisper: whisper, parakeetV2: whisper.appendingPathComponent("v2"))

        #expect(defaults.string(forKey: "CurrentTranscriptionModel") == "parakeet-tdt-0.6b-v3")
        #expect(defaults.object(forKey: RetiredLocalTranscriptionModelMigration.replacementNoticeKey) == nil)
    }

    @Test func powerModeConfigurationsAndSessionAreRewritten() throws {
        let defaults = isolatedDefaults()
        let configs: [[String: Any]] = [
            ["id": "A", "name": "Mail", "selectedTranscriptionModelName": "ggml-base.en", "selectedLanguage": "en"],
            ["id": "B", "name": "Chat", "selectedTranscriptionModelName": "ggml-small"],
            ["id": "C", "name": "Code", "selectedTranscriptionModelName": "parakeet-tdt-0.6b-v2"],
            ["id": "D", "name": "Notes", "selectedTranscriptionModelName": "ivrit-large-v3-turbo"],
            ["id": "E", "name": "Default"]
        ]
        defaults.set(try JSONSerialization.data(withJSONObject: configs),
                     forKey: RetiredLocalTranscriptionModelMigration.powerModeConfigurationsKey)
        let session: [String: Any] = [
            "id": "S",
            "originalState": ["isEnhancementEnabled": true, "transcriptionModelName": "ggml-tiny"]
        ]
        defaults.set(try JSONSerialization.data(withJSONObject: session),
                     forKey: RetiredLocalTranscriptionModelMigration.powerModeSessionKey)

        let whisper = try temporaryDirectory()
        runMigration(defaults, whisper: whisper, parakeetV2: whisper.appendingPathComponent("v2"))

        let data = try #require(defaults.data(forKey: RetiredLocalTranscriptionModelMigration.powerModeConfigurationsKey))
        let migrated = try #require(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        #expect(migrated.map { $0["selectedTranscriptionModelName"] as? String } == [
            "parakeet-unified-en-0.6b",
            "ggml-large-v3-turbo-q5_0",
            "parakeet-unified-en-0.6b",
            "ivrit-large-v3-turbo",
            nil
        ])
        #expect(migrated[0]["name"] as? String == "Mail")
        #expect(migrated[0]["selectedLanguage"] as? String == "en")

        let sessionData = try #require(defaults.data(forKey: RetiredLocalTranscriptionModelMigration.powerModeSessionKey))
        let migratedSession = try #require(try JSONSerialization.jsonObject(with: sessionData) as? [String: Any])
        let state = try #require(migratedSession["originalState"] as? [String: Any])
        #expect(state["transcriptionModelName"] as? String == "ggml-large-v3-turbo-q5_0")
        #expect(state["isEnhancementEnabled"] as? Bool == true)
        // Power Mode replacements alone do not produce the default-model notice.
        #expect(defaults.object(forKey: RetiredLocalTranscriptionModelMigration.replacementNoticeKey) == nil)
    }

    @Test func retiredFilesAreDeletedAndCurrentOnesKept() throws {
        let defaults = isolatedDefaults()
        defaults.set("ggml-base.en", forKey: "CurrentTranscriptionModel")
        defaults.set(true, forKey: "ParakeetModelDownloaded_parakeet-tdt-0.6b-v2")
        let whisper = try temporaryDirectory()
        let fileManager = FileManager.default

        let retiredFiles = ["ggml-base.en.bin", "ggml-tiny.bin", "ggml-small.en.bin"]
        let keptFiles = ["ggml-large-v3-turbo.bin", "ivrit-large-v3-turbo.bin", "my-imported-model.bin"]
        for name in retiredFiles + keptFiles {
            #expect(fileManager.createFile(atPath: whisper.appendingPathComponent(name).path, contents: Data("x".utf8)))
        }
        let retiredEncoder = whisper.appendingPathComponent("ggml-base.en-encoder.mlmodelc", isDirectory: true)
        let keptEncoder = whisper.appendingPathComponent("ggml-large-v3-turbo-encoder.mlmodelc", isDirectory: true)
        let parakeetV2 = whisper.appendingPathComponent("parakeet-tdt-0.6b-v2-coreml", isDirectory: true)
        for directory in [retiredEncoder, keptEncoder, parakeetV2] {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        runMigration(defaults, whisper: whisper, parakeetV2: parakeetV2)

        for name in retiredFiles {
            #expect(!fileManager.fileExists(atPath: whisper.appendingPathComponent(name).path), "\(name)")
        }
        for name in keptFiles {
            #expect(fileManager.fileExists(atPath: whisper.appendingPathComponent(name).path), "\(name)")
        }
        #expect(!fileManager.fileExists(atPath: retiredEncoder.path))
        #expect(fileManager.fileExists(atPath: keptEncoder.path))
        #expect(!fileManager.fileExists(atPath: parakeetV2.path))
        #expect(defaults.object(forKey: "ParakeetModelDownloaded_parakeet-tdt-0.6b-v2") == nil)
        #expect(defaults.string(forKey: "CurrentTranscriptionModel") == "parakeet-unified-en-0.6b")
    }

    @Test func migrationRunsOnlyOnce() throws {
        let defaults = isolatedDefaults()
        let whisper = try temporaryDirectory()
        runMigration(defaults, whisper: whisper, parakeetV2: whisper.appendingPathComponent("v2"))

        defaults.set("ggml-tiny", forKey: "CurrentTranscriptionModel")
        runMigration(defaults, whisper: whisper, parakeetV2: whisper.appendingPathComponent("v2"))

        #expect(defaults.string(forKey: "CurrentTranscriptionModel") == "ggml-tiny")
    }

    @Test func noRetiredModelIsStillInTheCatalog() {
        for name in RetiredLocalTranscriptionModelMigration.retiredModelNames {
            #expect(!TranscriptionModelRegistry.models.contains { $0.name == name }, "\(name)")
            #expect(ModelIntegrity.whisperSHA256[name] == nil, "\(name)")
            #expect(RetiredLocalTranscriptionModelMigration.retiredDisplayNames[name] != nil, "\(name)")
        }
    }
}
