import Foundation
import SwiftData
import Testing
@testable import Zerm

/// Both launch migrations make destructive-sounding promises — one rewrites History rows, the
/// other deletes multi-gigabyte model files. Neither had ever been executed before these tests.
@MainActor
struct LaunchMigrationTests {

    private func inMemoryContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: Transcription.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    /// An isolated suite. Writing the completion flag into the app's real domain would mark a
    /// developer's own install as already repaired and skip the fix on the machine that has the
    /// defect — which is exactly what happened before these tests were isolated.
    private func isolatedDefaults(_ name: String = #function) -> UserDefaults {
        let suite = "com.arcusis.zerm.tests.\(name)"
        UserDefaults().removePersistentDomain(forName: suite)
        return UserDefaults(suiteName: suite)!
    }

    // MARK: - EmptyEnhancementRepair

    @Test func repairClearsEmptyEnhancementsAndLeavesRealOnesAlone() throws {
        let defaults = isolatedDefaults()
        let context = try inMemoryContext()

        let blanked = Transcription(text: "ship the build on friday", duration: 3)
        blanked.enhancedText = ""                       // exactly what 2.8.3 wrote
        let whitespace = Transcription(text: "second transcript", duration: 3)
        whitespace.enhancedText = "\n  \n"
        let real = Transcription(text: "third transcript", duration: 3)
        real.enhancedText = "Third transcript."
        let never = Transcription(text: "fourth transcript", duration: 3)

        for record in [blanked, whitespace, real, never] { context.insert(record) }
        try context.save()

        EmptyEnhancementRepair.run(modelContext: context, defaults: defaults)

        // The blanked rows must show the transcript again.
        #expect(blanked.enhancedText == nil)
        #expect(blanked.displayText == "ship the build on friday")
        #expect(whitespace.enhancedText == nil)
        #expect(whitespace.displayText == "second transcript")
        // A genuine enhancement must survive untouched.
        #expect(real.enhancedText == "Third transcript.")
        #expect(real.displayText == "Third transcript.")
        #expect(never.enhancedText == nil)
    }

    @Test func repairNeverDestroysTheTranscriptItself() throws {
        let defaults = isolatedDefaults()
        let context = try inMemoryContext()
        let record = Transcription(text: "the words the user actually said", duration: 5)
        record.enhancedText = ""
        context.insert(record)
        try context.save()

        EmptyEnhancementRepair.run(modelContext: context, defaults: defaults)

        #expect(record.text == "the words the user actually said")
    }

    @Test func repairRunsOnlyOnce() throws {
        let defaults = isolatedDefaults()
        let context = try inMemoryContext()
        context.insert(Transcription(text: "first", duration: 1))
        try context.save()

        EmptyEnhancementRepair.run(modelContext: context, defaults: defaults)
        #expect(defaults.bool(forKey: EmptyEnhancementRepair.completionKey))

        // A row blanked after the repair ran must not be touched by a second launch.
        let later = Transcription(text: "later transcript", duration: 1)
        later.enhancedText = ""
        context.insert(later)
        try context.save()

        EmptyEnhancementRepair.run(modelContext: context, defaults: defaults)
        #expect(later.enhancedText == "")
    }

    /// The real defaults domain must never be marked by a test run.
    @Test func repairDoesNotTouchTheRealDefaultsDomain() throws {
        let defaults = isolatedDefaults()
        let context = try inMemoryContext()
        UserDefaults.standard.removeObject(forKey: EmptyEnhancementRepair.completionKey)
        EmptyEnhancementRepair.run(modelContext: context, defaults: defaults)
        #expect(!UserDefaults.standard.bool(forKey: EmptyEnhancementRepair.completionKey))
    }

    // MARK: - RetiredLocalLLMMigration

    @Test func retiredListNamesExactFilesOnly() {
        // A prefix or pattern here would be able to sweep up a future catalogue entry.
        for name in RetiredLocalLLMMigration.retiredFileNames {
            #expect(name.hasSuffix(".gguf"), "\(name)")
            #expect(!name.contains("*"))
        }
        #expect(RetiredLocalLLMMigration.retiredFileNames.contains("Qwen3-1.7B-Q4_K_M.gguf"))
        #expect(RetiredLocalLLMMigration.retiredFileNames.contains("gemma-4-E2B-it-Q4_K_M.gguf"))
    }

    /// Runs the real deletion against a temporary directory: retired files go, everything else
    /// stays, and the real defaults domain is untouched.
    @Test func retirementDeletesOnlyRetiredFiles() throws {
        let defaults = isolatedDefaults()
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("zerm-retire-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let retired = directory.appendingPathComponent("Qwen3-1.7B-Q4_K_M.gguf")
        let keep = directory.appendingPathComponent("gemma-4-E2B_q4_0-it.gguf")
        let unrelated = directory.appendingPathComponent("notes.txt")
        for url in [retired, keep, unrelated] {
            try Data("weights".utf8).write(to: url)
        }

        defaults.set("Qwen3-1.7B-Q4_K_M.gguf", forKey: "CurrentLocalLLMModel")
        RetiredLocalLLMMigration.run(defaults: defaults, modelsDirectory: directory)

        #expect(!FileManager.default.fileExists(atPath: retired.path))
        #expect(FileManager.default.fileExists(atPath: keep.path))
        #expect(FileManager.default.fileExists(atPath: unrelated.path))
        // A selection pointing at a retired model is cleared so Settings and the resolver agree.
        #expect(defaults.string(forKey: "CurrentLocalLLMModel") == nil)
    }

    /// The shipped default must never appear in the retired list — deleting it would remove the
    /// model the app depends on and cost the user a 3.35 GB download.
    @Test func theShippedDefaultsAreNeverRetired() {
        for role in [LocalLLMRole.enhancement, .reading] {
            let package = LocalLLMModelManager.package(for: role)
            #expect(!RetiredLocalLLMMigration.retiredFileNames.contains(package.fileName), "\(package.fileName)")
        }
        for package in LocalLLMModelManager.packages {
            #expect(!RetiredLocalLLMMigration.retiredFileNames.contains(package.fileName), "\(package.fileName)")
        }
    }
}
