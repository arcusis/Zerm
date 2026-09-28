import Foundation

/// Compatibility no-op for the migration that retired models restored in #375.
enum RetiredLocalTranscriptionModelMigration {
    static let completionKey = "retired-local-transcription-models-migration-v1"
    static let replacementNoticeKey = "retired-local-transcription-model-replacement"
    static let noticeRetiredNameKey = "retired"
    static let noticeReplacementNameKey = "replacement"
    static let retiredDisplayNames: [String: String] = [:]
    static let retiredModelNames: Set<String> = []

    static func run(
        defaults: UserDefaults = .standard,
        isAppleSilicon _: Bool = SystemArchitecture.isAppleSilicon,
        whisperModelsDirectory _: URL,
        parakeetV2CacheDirectory _: URL? = nil,
        fileManager _: FileManager = .default
    ) {
        defaults.set(true, forKey: completionKey)
    }
}
