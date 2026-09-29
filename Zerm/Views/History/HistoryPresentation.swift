import Foundation
import SwiftUI

enum HistorySortOrder: String, CaseIterable, Identifiable {
    case newestFirst
    case oldestFirst

    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .newestFirst: "Newest First"
        case .oldestFirst: "Oldest First"
        }
    }
}

enum DictationHistoryFilter: String, CaseIterable, Identifiable {
    case all
    case withAudio

    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .all: "All Dictations"
        case .withAudio: "With Audio"
        }
    }
}

enum ReadAloudHistoryPresentation {
    static func visibleItems(
        from items: [ReadAloudHistoryItem],
        query: String,
        mode: ReadAloudMode?,
        sortOrder: HistorySortOrder
    ) -> [ReadAloudHistoryItem] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return items
            .filter { item in
                guard let mode else { return true }
                return item.mode == mode
            }
            .filter { item in
                guard !normalizedQuery.isEmpty else { return true }
                return item.sourceText.localizedCaseInsensitiveContains(normalizedQuery)
                    || item.spokenText.localizedCaseInsensitiveContains(normalizedQuery)
                    || item.mode.title.localizedCaseInsensitiveContains(normalizedQuery)
            }
            .sorted {
                switch sortOrder {
                case .newestFirst: $0.createdAt > $1.createdAt
                case .oldestFirst: $0.createdAt < $1.createdAt
                }
            }
    }
}
