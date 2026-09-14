import Foundation
import SwiftData
import Testing
@testable import Zerm

/// Streaming provider whose commit behaviour is scripted per test, so the service's commit
/// handshake can be exercised without a model or a network connection.
private final class ScriptedStreamingProvider: StreamingTranscriptionProvider {
    let transcriptionEvents: AsyncStream<StreamingTranscriptionEvent>
    let continuation: AsyncStream<StreamingTranscriptionEvent>.Continuation
    let finishesEventsOnCommit: Bool
    private let onCommit: (ScriptedStreamingProvider) async -> Void

    init(finishesEventsOnCommit: Bool, onCommit: @escaping (ScriptedStreamingProvider) async -> Void) {
        (transcriptionEvents, continuation) = AsyncStream.makeStream(of: StreamingTranscriptionEvent.self)
        self.finishesEventsOnCommit = finishesEventsOnCommit
        self.onCommit = onCommit
    }

    func connect(model: any TranscriptionModel, language: String?) async throws {}
    func sendAudioChunk(_ data: Data) async throws {}
    func commit() async throws { await onCommit(self) }
    func disconnect() async { continuation.finish() }
}

@MainActor
struct StreamingTranscriptionTests {

    private let model = CloudModel(
        name: "scripted",
        displayName: "Scripted",
        description: "",
        provider: .deepgram,
        speed: 1,
        accuracy: 1,
        isMultilingual: true,
        supportedLanguages: [:]
    )

    private func makeService() throws -> StreamingTranscriptionService {
        let container = try ModelContainer(
            for: Transcription.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return StreamingTranscriptionService(modelContext: ModelContext(container))
    }

    /// The race from #316: a pass that was already running when the user stopped confirms words
    /// while the service is committing, and the final pass lands after `commit()` returned. The
    /// first `.committed` must not be taken as the end of the transcript.
    @Test func finalTextWaitsForTheLastPassAfterAnInFlightCommit() async throws {
        let provider = ScriptedStreamingProvider(finishesEventsOnCommit: true) { provider in
            provider.continuation.yield(.committed(text: "hello there"))
            let continuation = provider.continuation
            Task.detached {
                try? await Task.sleep(nanoseconds: 200_000_000)
                continuation.yield(.committed(text: "general Kenobi"))
                continuation.finish()
            }
        }
        let service = try makeService()
        try await service.startStreaming(with: provider, model: model)

        let text = try await service.stopAndGetFinalText()

        #expect(text == "hello there general Kenobi")
    }

    @Test func finalTextIncludesEverySegmentEmittedDuringCommit() async throws {
        let provider = ScriptedStreamingProvider(finishesEventsOnCommit: true) { provider in
            provider.continuation.yield(.committed(text: "the quick brown fox"))
            await Task.yield()
            provider.continuation.yield(.committed(text: "jumps over the lazy dog"))
            provider.continuation.finish()
        }
        let service = try makeService()
        try await service.startStreaming(with: provider, model: model)

        let text = try await service.stopAndGetFinalText()

        #expect(text == "the quick brown fox jumps over the lazy dog")
    }

    /// Server-acknowledged providers keep the stream open; their first `.committed` after the
    /// commit request is the acknowledgment.
    @Test func acknowledgedProvidersReturnOnTheCommitAcknowledgment() async throws {
        let provider = ScriptedStreamingProvider(finishesEventsOnCommit: false) { provider in
            let continuation = provider.continuation
            Task.detached {
                continuation.yield(.committed(text: "acknowledged"))
            }
        }
        let service = try makeService()
        try await service.startStreaming(with: provider, model: model)

        let text = try await service.stopAndGetFinalText()

        #expect(text == "acknowledged")
    }

    /// An error while committing must hand over to the batch fallback at once, not after the
    /// 30 s acknowledgment timeout.
    @Test func errorWhileCommittingFailsWithoutWaitingForTheTimeout() async throws {
        let provider = ScriptedStreamingProvider(finishesEventsOnCommit: true) { provider in
            provider.continuation.yield(.error(CancellationError()))
        }
        let service = try makeService()
        try await service.startStreaming(with: provider, model: model)

        let start = Date()
        await #expect(throws: StreamingTranscriptionError.self) {
            try await service.stopAndGetFinalText()
        }
        #expect(Date().timeIntervalSince(start) < 10)
    }
}

struct WordAgreementEngineTests {

    private func words(_ text: String) -> [TimedWord] {
        text.split(separator: " ").enumerated().map { index, word in
            TimedWord(text: String(word), startTime: Double(index) * 0.4, endTime: Double(index) * 0.4 + 0.3)
        }
    }

    /// VoiceInk e72fad5: words agree lexically, but a sentence ender inside the confirmation
    /// range changed between passes, so nothing may be confirmed until the boundary is stable.
    @Test func doesNotConfirmWhileSentenceBoundaryPunctuationChanges() {
        let engine = WordAgreementEngine()
        let stable = words("Alpha beta gamma. Delta epsilon zeta. Eta theta iota. Kappa lambda")
        for _ in 0..<3 {
            #expect(engine.processTranscriptionResult(words: stable).newlyConfirmedText.isEmpty)
        }

        let changedBoundary = words("Alpha beta gamma. Delta epsilon zeta? Eta theta iota. Kappa lambda.")
        #expect(engine.processTranscriptionResult(words: changedBoundary).newlyConfirmedText.isEmpty)

        let confirmed = engine.processTranscriptionResult(words: changedBoundary)
        #expect(confirmed.newlyConfirmedText == "Alpha beta gamma. Delta epsilon zeta?")
    }
}
