import Foundation

struct ClipboardHistorySearchIndex: Codable {
    private var documents: [UUID: Document] = [:]
    private var payloadTextVersion: Int? = 2
    var includesFullText: Bool { payloadTextVersion == 2 }

    private struct Document: Codable {
        let text: String
        let kind: ClipboardItemKind

        func matches(_ terms: [String], kind requestedKind: ClipboardItemKind?) -> Bool {
            (requestedKind == nil || requestedKind == kind) && terms.allSatisfy(text.contains)
        }
    }

    mutating func update(id: UUID, kind: ClipboardItemKind, fields: [String]) {
        documents[id] = Document(text: fields.joined(separator: " ").localizedLowercase, kind: kind)
    }

    mutating func remove(_ ids: some Sequence<UUID>) {
        for id in ids { documents.removeValue(forKey: id) }
    }

    func matchingIDs(query: String, kind: ClipboardItemKind?) -> Set<UUID> {
        let terms = query.localizedLowercase.split(whereSeparator: \.isWhitespace).map(String.init)
        return Set(documents.compactMap { id, document in
            document.matches(terms, kind: kind) ? id : nil
        })
    }
}
