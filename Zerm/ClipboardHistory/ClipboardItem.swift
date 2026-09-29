import AppKit
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct ClipboardRepresentation: Codable, Equatable, Sendable {
    let itemIndex: Int
    let type: String
    let data: Data

    init(itemIndex: Int = 0, type: String, data: Data) {
        self.itemIndex = itemIndex
        self.type = type
        self.data = data
    }
}

enum ClipboardItemKind: String, Codable, CaseIterable, Sendable {
    case plainText
    case richText
    case image
    case fileURLs
    case url
    case email
    case color
    case code
    case other
}

struct ClipboardSourceApp: Codable, Equatable, Sendable {
    let bundleIdentifier: String?
    let name: String?
}

/// One captured clipboard payload, including original pasteboard representations for faithful paste.
struct ClipboardItem: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let contentHash: String
    let kind: ClipboardItemKind
    let representations: [ClipboardRepresentation]
    let thumbnailData: Data?
    let payloadSize: Int?
    let preview: String
    let createdAt: Date
    var lastCopiedAt: Date
    var lastUsedAt: Date
    var useCount: Int
    var isPinned: Bool
    var isFavorite: Bool
    var collectionID: UUID?
    var title: String?
    var tagIDs: [UUID]
    var tagDefinitions: [ClipboardTag]?
    var recognizedText: String
    var barcodePayloads: [String]
    let sourceApp: ClipboardSourceApp

    var thumbnail: NSImage? {
        guard kind == .image else { return nil }
        let candidates = [thumbnailData] + representations.filter {
            ["public.tiff", "public.png", "public.jpeg", "public.gif", "public.bmp"].contains($0.type)
        }.map(\.data)
        for data in candidates.compactMap({ $0 }) {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { continue }
            return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        }
        return nil
    }

    init(
        id: UUID = UUID(),
        contentHash: String,
        kind: ClipboardItemKind,
        representations: [ClipboardRepresentation],
        thumbnailData: Data? = nil,
        payloadSize: Int? = nil,
        preview: String,
        createdAt: Date = Date(),
        lastCopiedAt: Date? = nil,
        lastUsedAt: Date = Date(),
        useCount: Int = 1,
        isPinned: Bool = false,
        isFavorite: Bool = false,
        collectionID: UUID? = nil,
        title: String? = nil,
        tagIDs: [UUID] = [],
        tagDefinitions: [ClipboardTag]? = nil,
        recognizedText: String = "",
        barcodePayloads: [String] = [],
        sourceApp: ClipboardSourceApp
    ) {
        self.id = id
        self.contentHash = contentHash
        self.kind = kind
        self.representations = representations
        self.thumbnailData = thumbnailData
        self.payloadSize = payloadSize
        self.preview = preview
        self.createdAt = createdAt
        self.lastCopiedAt = lastCopiedAt ?? createdAt
        self.lastUsedAt = lastUsedAt
        self.useCount = useCount
        self.isPinned = isPinned
        self.isFavorite = isFavorite
        self.collectionID = collectionID
        self.title = title
        self.tagIDs = tagIDs
        self.tagDefinitions = tagDefinitions
        self.recognizedText = recognizedText
        self.barcodePayloads = barcodePayloads
        self.sourceApp = sourceApp
    }

    static func capture(
        representations: [ClipboardRepresentation],
        sourceApp: ClipboardSourceApp,
        createdAt: Date = Date(),
        maximumSize: Int = ClipboardHistorySettings.maximumItemSize
    ) -> ClipboardItem? {
        let pasteableRepresentations = representations.filter { $0.type != "org.nspasteboard.source" }
        guard !pasteableRepresentations.isEmpty,
              pasteableRepresentations.reduce(0, { $0 + $1.data.count }) <= maximumSize else { return nil }
        let sorted = pasteableRepresentations.sorted { ($0.itemIndex, $0.type) < ($1.itemIndex, $1.type) }
        var hashInput = Data()
        for representation in sorted {
            hashInput.append(Data(representation.type.utf8))
            hashInput.append(0)
            hashInput.append(Data(String(representation.itemIndex).utf8))
            hashInput.append(0)
            hashInput.append(representation.data)
            hashInput.append(0)
        }
        let hash = SHA256.hash(data: hashInput).map { String(format: "%02x", $0) }.joined()
        let kind = Self.detectKind(in: sorted)
        let preview = Self.makePreview(from: pasteableRepresentations, kind: kind)
        if [.plainText, .richText, .url, .email, .color].contains(kind),
           preview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return nil
        }
        return ClipboardItem(
            contentHash: hash,
            kind: kind,
            representations: pasteableRepresentations,
            thumbnailData: Self.makeThumbnail(from: pasteableRepresentations, kind: kind),
            preview: preview,
            createdAt: createdAt,
            lastUsedAt: createdAt,
            sourceApp: sourceApp
        )
    }

    private static func makeThumbnail(from representations: [ClipboardRepresentation], kind: ClipboardItemKind) -> Data? {
        guard kind == .image,
              let data = representations.first(where: { ["public.tiff", "public.png", "public.jpeg"].contains($0.type) })?.data,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: 320,
                  kCGImageSourceCreateThumbnailWithTransform: true
              ] as CFDictionary) else { return nil }
        let destinationData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(destinationData, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return destinationData as Data
    }

    static func detectKind(in representations: [ClipboardRepresentation]) -> ClipboardItemKind {
        let types = Set(representations.map(\.type))
        if types.contains("public.file-url") { return .fileURLs }
        if types.contains("public.tiff") || types.contains("public.png") || types.contains("public.jpeg") { return .image }
        if types.contains("public.color") || types.contains(where: { $0.localizedCaseInsensitiveContains("color") }) { return .color }
        if let text = representations.first(where: { $0.type == NSPasteboard.PasteboardType.string.rawValue })
            .flatMap({ String(data: $0.data, encoding: .utf8) }) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.contains(where: \.isNewline), ClipboardDetection.isURL(trimmed) { return .url }
        }
        if types.contains("public.rtf") || types.contains("public.html") || types.contains("com.apple.rtfd") { return .richText }
        if types.contains("public.url") { return .url }
        if let text = representations.first(where: { $0.type == NSPasteboard.PasteboardType.string.rawValue })
            .flatMap({ String(data: $0.data, encoding: .utf8) }) {
            if ClipboardDetection.isEmail(text.trimmingCharacters(in: .whitespacesAndNewlines)) { return .email }
            if ClipboardDetection.isURL(text.trimmingCharacters(in: .whitespacesAndNewlines)) { return .url }
            if ClipboardDetection.colorToken(in: text) != nil { return .color }
            if ClipboardCodeDetection.language(in: text) != nil { return .code }
        }
        if types.contains("public.utf8-plain-text") || types.contains("NSStringPboardType") { return .plainText }
        return .other
    }

    static func migratedKind(from legacyKind: ClipboardItemKind, representations: [ClipboardRepresentation]) -> ClipboardItemKind? {
        let detectedKind = detectKind(in: representations)
        if legacyKind == .richText && detectedKind == .url { return .url }
        guard legacyKind == .plainText, detectedKind == .plainText,
              let text = representations.first(where: {
                  [NSPasteboard.PasteboardType.string.rawValue, "public.utf8-plain-text", "NSStringPboardType"].contains($0.type)
              }).flatMap({ String(data: $0.data, encoding: .utf8) }),
              ClipboardCodeDetection.language(in: text) != nil else { return nil }
        return .code
    }

    private static func makePreview(from representations: [ClipboardRepresentation], kind: ClipboardItemKind) -> String {
        let byType = Dictionary(representations.map { ($0.type, $0.data) }, uniquingKeysWith: { first, _ in first })
        if kind == .richText,
           let rtf = byType["public.rtf"],
           let attributed = try? NSAttributedString(data: rtf, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil) {
            return String(attributed.string.prefix(500))
        }
        if kind == .richText,
           let html = byType["public.html"],
           let attributed = try? NSAttributedString(data: html, options: [.documentType: NSAttributedString.DocumentType.html], documentAttributes: nil) {
            return String(attributed.string.prefix(500))
        }
        if let text = byType[NSPasteboard.PasteboardType.string.rawValue].flatMap({ String(data: $0, encoding: .utf8) }) {
            return String(text.prefix(500))
        }
        if let urlData = byType["public.url"], let text = String(data: urlData, encoding: .utf8) {
            return String(text.prefix(500))
        }
        if let rtf = byType["public.rtf"],
           let attributed = try? NSAttributedString(data: rtf, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil) {
            return String(attributed.string.prefix(500))
        }
        if let html = byType["public.html"],
           let attributed = try? NSAttributedString(data: html, options: [.documentType: NSAttributedString.DocumentType.html], documentAttributes: nil) {
            return String(attributed.string.prefix(500))
        }
        if let fileURL = byType["public.file-url"].flatMap({ URL(dataRepresentation: $0, relativeTo: nil) }) {
            return fileURL.lastPathComponent
        }
        switch kind {
        case .image: return String(localized: "Image")
        case .fileURLs: return String(localized: "File")
        case .color: return String(localized: "Color")
        case .richText: return String(localized: "Rich text")
        case .url: return String(localized: "Link")
        case .email: return String(localized: "Email")
        case .code: return String(localized: "Code")
        case .plainText, .other: return ""
        }
    }
}
