import AppKit
import SwiftData
import SwiftUI
import Testing

@testable import Zerm

@Suite(.serialized)
struct HistoryScanabilityTests {
    @Test func readAloudHistoryFiltersAndSortsByVisibleContent() {
        let older = item(
            createdAt: Date(timeIntervalSince1970: 100),
            sourceText: "Older source",
            spokenText: "Older spoken text",
            mode: .exact
        )
        let newer = item(
            createdAt: Date(timeIntervalSince1970: 200),
            sourceText: "Newer source",
            spokenText: "Natural spoken words",
            mode: .retell
        )

        let newestFirst = ReadAloudHistoryPresentation.visibleItems(
            from: [older, newer], query: "", mode: nil, sortOrder: .newestFirst
        )
        #expect(newestFirst.map(\.id) == [newer.id, older.id])

        let matchingMode = ReadAloudHistoryPresentation.visibleItems(
            from: [older, newer], query: "natural", mode: .retell, sortOrder: .oldestFirst
        )
        #expect(matchingMode.map(\.id) == [newer.id])

        let noMatches = ReadAloudHistoryPresentation.visibleItems(
            from: [older, newer], query: "absent", mode: nil, sortOrder: .newestFirst
        )
        #expect(noMatches.isEmpty)
    }

    @MainActor
    @Test(.enabled(if: RenderSnapshots.isEnabled)) func rendersHistoryViewsOffscreenToPNG() async throws {
        let container = try ModelContainer(
            for: Transcription.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let transcription = Transcription(
            text: "A short dictation sample for history scanability.",
            duration: 18,
            enhancedText: "A short, clear dictation sample for history scanability.",
            transcriptionStatus: .completed
        )
        transcription.timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        container.mainContext.insert(transcription)
        try container.mainContext.save()

        let dictationView = InlineHistoryView().modelContainer(container)
        try await capture(dictationView, named: "dictation-history-after.png")
        try await capture(
            dictationView.environment(\.locale, Locale(identifier: "he"))
                .environment(\.layoutDirection, .rightToLeft),
            named: "dictation-history-after-he.png"
        )

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zerm-history-scanability-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ReadAloudHistoryStore(fileURL: directory.appendingPathComponent("history.json"))
        store.record(
            sourceText: "The original selected passage.",
            spokenText: "A natural version of the selected passage.",
            mode: .retell,
            providerName: "Apple System Voices",
            voiceName: "Carmit",
            localModelName: nil
        )
        let readAloudView = ReadAloudHistoryView(store: store)
        try await capture(readAloudView, named: "read-aloud-history-after.png")
        try await capture(
            readAloudView.environment(\.locale, Locale(identifier: "he"))
                .environment(\.layoutDirection, .rightToLeft),
            named: "read-aloud-history-after-he.png"
        )
    }

    private func item(
        createdAt: Date,
        sourceText: String,
        spokenText: String,
        mode: ReadAloudMode
    ) -> ReadAloudHistoryItem {
        ReadAloudHistoryItem(
            id: UUID(),
            createdAt: createdAt,
            sourceText: sourceText,
            spokenText: spokenText,
            mode: mode,
            providerName: "Test Provider",
            voiceName: "Test Voice",
            localModelName: nil
        )
    }

    @MainActor
    private func capture<Content: View>(_ view: Content, named name: String) async throws {
        let window = NSWindow(
            contentRect: NSRect(x: -3200, y: -2200, width: 820, height: 580),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view)
        window.contentView?.frame = NSRect(x: 0, y: 0, width: 820, height: 580)
        window.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 600_000_000)
        window.displayIfNeeded()

        let contentView = try #require(window.contentView)
        let bounds = contentView.bounds
        let bitmap = try #require(contentView.bitmapImageRepForCachingDisplay(in: bounds))
        contentView.cacheDisplay(in: bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        let directory = URL(fileURLWithPath: "/tmp/zerm-work/392-shots", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try png.write(to: directory.appendingPathComponent(name))
        window.close()
    }
}
