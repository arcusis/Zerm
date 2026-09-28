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
            "parakeet-tdt-0.6b-v2",
            "parakeet-tdt-0.6b-ultra",
            "parakeet-tdt-0.6b-redux",
            "parakeet-tdt-0.6b-v3",
            "sherpa-moonshine-tiny-en",
            "sherpa-moonshine-base-en",
            "sherpa-zipformer-ru-vosk-int8",
            "ggml-tiny", "ggml-tiny.en", "ggml-base", "ggml-base.en",
            "ggml-small", "ggml-small.en", "ggml-medium", "ggml-medium.en",
            "ggml-large-v2", "ggml-large-v2-q5_0", "ggml-large-v2-q8_0",
            "ggml-large-v3", "ggml-large-v3-q5_0",
            "ggml-large-v3-turbo",
            "ggml-large-v3-turbo-q5_0",
            "ggml-large-v3-turbo-q8_0",
            "ggml-medium-q5_0", "ggml-medium-q8_0",
            "ggml-medium.en-q5_0", "ggml-medium.en-q8_0",
            "ggml-tiny-q8_0", "ggml-tiny.en-q8_0",
            "ggml-base-q8_0", "ggml-base.en-q8_0",
            "ggml-small-q8_0", "ggml-small.en-q8_0",
            "ggml-distil-large-v3",
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
            let provenance = model.provenance
            #expect(provenance != nil, "\(model.name) has no provenance")
            #expect(!(provenance?.creator.isEmpty ?? true), "\(model.name)")
            #expect(!(provenance?.licenseName.isEmpty ?? true), "\(model.name)")
            #expect(!(provenance?.attribution.isEmpty ?? true), "\(model.name)")
            #expect(!(provenance?.conversionCredit?.isEmpty ?? true), "\(model.name)")
            switch model.languageGroup {
            case .englishOnly:
                #expect(model.supportedLanguages == ["en": "English"], "\(model.name)")
                #expect(!model.isHebrewOptimized, "\(model.name)")
            case .multilingual:
                #expect(model.isMultilingualModel, "\(model.name)")
            case .singleLanguage:
                #expect(model.name == "sherpa-zipformer-ru-vosk-int8")
                #expect(model.supportedLanguages["ru"] == "Russian")
            }
        }

        for model in localModels {
            if let whisper = model as? WhisperModel {
                #expect(!whisper.size.isEmpty, "\(model.name)")
            } else if let fluidAudio = model as? FluidAudioModel {
                #expect(!fluidAudio.size.isEmpty, "\(model.name)")
            } else if let sherpa = model as? SherpaOnnxModel {
                #expect(!sherpa.size.isEmpty, "\(model.name)")
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
            #expect(model.provenance?.checksumSHA256 == sha, "\(model.name) provenance checksum")
        }
        #expect(ModelIntegrity.ivritLargeV3Turbo.repository == "ivrit-ai/whisper-large-v3-turbo-ggml")
        #expect(ModelIntegrity.ivritLargeV3.repository == "ivrit-ai/whisper-large-v3-ggml")
    }

    @Test func localProvenanceLinksUseOfficialHostsAndNewModelsHaveChecksums() throws {
        let allowedHosts: Set<String> = ["huggingface.co", "github.com", "developer.apple.com", "opensource.org", "www.apache.org", "creativecommons.org", "www.apple.com"]
        for model in localModels {
            let provenance = try #require(model.provenance, "\(model.name)")
            #expect(allowedHosts.contains(provenance.sourceURL.host ?? ""), "\(model.name) source host")
            #expect(allowedHosts.contains(provenance.downloadHost), "\(model.name) download host")
            #expect(allowedHosts.contains(provenance.licenseURL.host ?? ""), "\(model.name) license host")
        }
        #expect(try model(named: "parakeet-tdt-ctc-110m").provenance?.licenseSPDX == "CC-BY-4.0")
        #expect(try model(named: "parakeet-tdt-0.6b-ultra").provenance?.creator == "Moondream")
        #expect(try model(named: "parakeet-tdt-0.6b-ultra").provenance?.licenseSPDX == "CC-BY-4.0")
        for name in ["parakeet-tdt-0.6b-v2", "parakeet-tdt-0.6b-redux"] {
            #expect(ModelIntegrity.fluidAudioSHA256[name]?.count == 64, "\(name) HF SHA-256")
            #expect(try model(named: name).provenance?.checksumSHA256?.count == 64, "\(name) provenance SHA-256")
            let fileHashes = try #require(ModelIntegrity.fluidAudioLFSFileSHA256[name], "\(name) component hashes")
            #expect(fileHashes.count == (name.hasSuffix("-v2") ? 10 : 12), "\(name) LFS file count")
            #expect(fileHashes.values.allSatisfy { $0.count == 64 }, "\(name) component SHA-256")
            #expect(fileHashes["Encoder.mlmodelc/weights/weight.bin"] == ModelIntegrity.fluidAudioSHA256[name], "\(name) primary encoder pin")
        }
        #expect(try model(named: "ggml-distil-large-v3").provenance?.checksumSHA256?.count == 64)
    }

    @Test func englishOnlyWhisperModelsListOnlyEnglish() {
        let englishOnly = localModels.compactMap { $0 as? WhisperModel }.filter { $0.languageGroup == .englishOnly }
        #expect(!englishOnly.isEmpty)
        for model in englishOnly {
            #expect(model.supportedLanguages == ["en": "English"], "\(model.name)")
        }
    }

    @Test func reduxRequiresMacOS15() throws {
        #expect(FluidAudioModelManager.modelVersionMap[FluidAudioModelManager.reduxModelName] == .redux)
        #expect(!FluidAudioModelManager.supportsModel(FluidAudioModelManager.reduxModelName, macOSMajorVersion: 14))
        #expect(FluidAudioModelManager.supportsModel(FluidAudioModelManager.reduxModelName, macOSMajorVersion: 15))
        #expect(FluidAudioModelManager.supportsModel("parakeet-tdt-0.6b-v3", macOSMajorVersion: 14))
        #expect(try model(named: FluidAudioModelManager.reduxModelName).description.contains("macOS 15"))
    }

    /// A fine-tune must never pick up the stock whisper.cpp Core ML encoder or download one.
    @Test func onlyStockWhisperModelsUseCoreMLEncoders() {
        #expect(WhisperModelFile.hasCoreMLEncoder(modelName: "ggml-large-v3-turbo"))
        #expect(!WhisperModelFile.hasCoreMLEncoder(modelName: "ggml-large-v3-turbo-q5_0"))
        #expect(!WhisperModelFile.hasCoreMLEncoder(modelName: "ggml-distil-large-v3"))
        #expect(!WhisperModelFile.hasCoreMLEncoder(modelName: "ivrit-large-v3-turbo"))
        #expect(!WhisperModelFile.hasCoreMLEncoder(modelName: "ivrit-large-v3"))
    }

    @Test func fluidAudioModelsResolveToAnEngine() {
        for model in localModels.compactMap({ $0 as? FluidAudioModel }) {
            let known = FluidAudioModelManager.modelVersionMap[model.name] != nil
                || model.name == FluidAudioModelManager.unifiedModelName
            #expect(known, "\(model.name) has no FluidAudio engine")
        }
        #expect(FluidAudioModelManager.modelVersionMap["parakeet-tdt-0.6b-v2"] == .v2)
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
            .english: "ggml-base.en",
            .multilingual: "ggml-base",
            .hebrew: "ivrit-large-v3-turbo"
        ])
    }

    @Test func appleSilicon8GBStaysLight() {
        let result = picks(Profile(isAppleSilicon: true, physicalMemoryGB: 8, hasAppleSpeech: false))
        #expect(result == [
            .english: "parakeet-tdt-ctc-110m",
            .multilingual: "parakeet-tdt-0.6b-redux",
            .hebrew: "ivrit-large-v3-turbo"
        ])
    }

    /// Redux's smaller memory footprint wins for multilingual use on 8 GB Macs, including macOS 26.
    @Test func appleSilicon8GBOnMacOS26CanRecommendReduxForManyLanguages() {
        let result = picks(Profile(isAppleSilicon: true, physicalMemoryGB: 8, hasAppleSpeech: true))
        #expect(result == [
            .english: "parakeet-tdt-ctc-110m",
            .multilingual: "parakeet-tdt-0.6b-redux",
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

    // MARK: - Restored catalog models

    @Test func restoredCatalogModelsAreNotRetiredOrDeleted() throws {
        let restored = [
            "ggml-tiny", "ggml-tiny.en", "ggml-base", "ggml-base.en", "ggml-small", "ggml-small.en",
            "parakeet-tdt-0.6b-v2"
        ]
        #expect(RetiredLocalTranscriptionModelMigration.retiredModelNames.isEmpty)
        for name in restored {
            #expect(localModels.contains { $0.name == name }, "\(name) is missing")
        }
        #expect(ModelIntegrity.fluidAudioSHA256["parakeet-tdt-0.6b-v2"]?.count == 64)

        let suite = "com.arcusis.zerm.tests.localcatalog.\(#function)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defaults.set("ggml-tiny", forKey: "CurrentTranscriptionModel")
        defaults.set(true, forKey: "ParakeetModelDownloaded_parakeet-tdt-0.6b-v2")
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalTranscriptionCatalogTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let tinyFile = directory.appendingPathComponent("ggml-tiny.bin")
        #expect(FileManager.default.createFile(atPath: tinyFile.path, contents: Data("model".utf8)))

        RetiredLocalTranscriptionModelMigration.run(
            defaults: defaults,
            whisperModelsDirectory: directory,
            parakeetV2CacheDirectory: directory.appendingPathComponent("parakeet-v2")
        )

        #expect(defaults.string(forKey: "CurrentTranscriptionModel") == "ggml-tiny")
        #expect(defaults.bool(forKey: "ParakeetModelDownloaded_parakeet-tdt-0.6b-v2"))
        #expect(FileManager.default.fileExists(atPath: tinyFile.path))
        #expect(defaults.bool(forKey: RetiredLocalTranscriptionModelMigration.completionKey))
    }
}
