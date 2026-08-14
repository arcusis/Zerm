import Foundation

struct ReadAloudHistoryItem: Codable, Identifiable, Equatable {
    let id: UUID
    let createdAt: Date
    let sourceText: String
    let spokenText: String
    let mode: ReadAloudMode
    let providerName: String
    let voiceName: String
    let localModelName: String?
}

/// Local-only history for completed Read Aloud sessions.
///
/// Selected text can be sensitive, so this store never syncs or leaves Application Support. It
/// uses one atomic JSON file rather than adding another SwiftData configuration/migration solely
/// for an append-only feature log.
@MainActor
final class ReadAloudHistoryStore: ObservableObject {
    static let shared = ReadAloudHistoryStore()

    @Published private(set) var items: [ReadAloudHistoryItem] = []

    private let fileURL: URL
    private let maximumItems = 500

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("com.arcusis.zerm", isDirectory: true)
            self.fileURL = directory.appendingPathComponent("ReadAloudHistory.json")
        }
        load()
    }

    func record(
        sourceText: String,
        spokenText: String,
        mode: ReadAloudMode,
        providerName: String,
        voiceName: String,
        localModelName: String?
    ) {
        let item = ReadAloudHistoryItem(
            id: UUID(),
            createdAt: Date(),
            sourceText: sourceText,
            spokenText: spokenText,
            mode: mode,
            providerName: providerName,
            voiceName: voiceName,
            localModelName: localModelName
        )
        items.insert(item, at: 0)
        if items.count > maximumItems {
            items.removeLast(items.count - maximumItems)
        }
        save()
    }

    func delete(_ item: ReadAloudHistoryItem) {
        items.removeAll { $0.id == item.id }
        save()
    }

    func clear() {
        items = []
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([ReadAloudHistoryItem].self, from: data) else {
            items = []
            return
        }
        items = decoded.sorted { $0.createdAt > $1.createdAt }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(items).write(to: fileURL, options: .atomic)
        } catch {
            // History is supplementary. Playback completion must never be reported as failed
            // merely because the optional local history file could not be updated.
        }
    }
}
