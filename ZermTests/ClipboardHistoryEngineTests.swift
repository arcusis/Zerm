import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import Testing
@testable import Zerm

@Suite(.serialized)
struct ClipboardHistoryEngineTests {
    @Test func detectionRecognizesEmailsURLsColorsAndRejectsInvalidForms() {
        #expect(ClipboardDetection.isEmail("person@example.org"))
        #expect(ClipboardDetection.isEmail("mailto:person@example.org"))
        #expect(!ClipboardDetection.isEmail("person@localhost"))
        #expect(ClipboardDetection.isURL("https://example.org/path"))
        #expect(ClipboardDetection.isURL("custom://host/item"))
        #expect(ClipboardItem.capture(representations: [Self.text("mailto:person@example.org")], sourceApp: Self.source)?.kind == .email)
        #expect(!ClipboardDetection.isURL("example.org"))
        for color in ["#abc", "#abcd", "#aabbcc", "#aabbccdd", "rgb(1, 2, 3)", "rgb(1 2 3 / 50%)", "rgba(1,2,3,0.5)", "hsl(120 50% 40%)", "hsla(120,50%,40%,.5)", "hwb(120 10% 20%)", "lab(50% 10 20)", "lch(50% 30 20)", "oklab(50% .1 .2)", "oklch(50% .1 20)", "red"] {
            #expect(ClipboardDetection.colorToken(in: color) != nil)
        }
        #expect(ClipboardDetection.colorToken(in: "#xyz") == nil)
        #expect(ClipboardDetection.colorToken(in: "rgb(nope)") == nil)
        #expect(ClipboardRetentionPeriod.choices.contains(.days(365)))
        #expect(ClipboardRetentionPeriod.choices.contains(.unlimited))
        #expect(ClipboardRetentionPeriod.days(900).dayCount == 365)
    }

    @Test func clipboardKindDetectionSkipsWhitespaceAndDistinguishesTextKinds() throws {
        #expect(ClipboardItem.capture(representations: [Self.text(" \n\t")], sourceApp: Self.source) == nil)
        #expect(ClipboardItem.capture(representations: [Self.text("reader@example.org")], sourceApp: Self.source)?.kind == .email)
        #expect(ClipboardItem.capture(representations: [Self.text("https://example.org")], sourceApp: Self.source)?.kind == .url)
        #expect(ClipboardItem.capture(representations: [Self.text("oklch(40% .2 10)")], sourceApp: Self.source)?.kind == .color)
    }

    @Test func transformsHaveStableUniqueIDsAndDeterministicResults() {
        let input = "Hello, World!\nhello world"
        let ids = ClipboardTextTransform.allCases.map(\.id)
        #expect(Set(ids).count == ids.count)
        for transform in ClipboardTextTransform.allCases {
            #expect(transform.apply(to: input) == transform.apply(to: input))
            #expect(!transform.localizedName.isEmpty)
        }
        #expect(ClipboardTextTransform.camelCase.apply(to: "Hello world") == "helloWorld")
        #expect(ClipboardTextTransform.snakeCase.apply(to: "Hello world") == "hello_world")
        #expect(ClipboardTextTransform.kebabCase.apply(to: "Hello world") == "hello-world")
        #expect(ClipboardTextTransform.pascalCase.apply(to: "hello world") == "HelloWorld")
        #expect(ClipboardTextTransform.removeDuplicateLines.apply(to: "a\nb\na") == "a\nb")
        #expect(ClipboardTextTransform.reverseLines.apply(to: "a\nb") == "b\na")
        #expect(ClipboardTextTransform.urlDecode.apply(to: "%E0%A4%A") == nil)
        #expect(ClipboardTextTransform.base64Decode.apply(to: "%%%") == nil)
        #expect(ClipboardTextTransform.jsonPrettyPrint.apply(to: "not json") == nil)
        #expect(ClipboardTextTransform.jsonMinify.apply(to: "not json") == nil)
        #expect(ClipboardTextTransform.countCharacters.apply(to: "שלום 🙂") == "6")
    }

    @Test func imageAnalyzerExtractsTextAndQRPayload() async throws {
        let textData = try #require(Self.textImage("CLIPBOARD VISION TEST"))
        let textResult = await ClipboardImageAnalyzer.analyze(textData)
        #expect(textResult.recognizedText.localizedCaseInsensitiveContains("clipboard"))

        let qrData = try #require(Self.qrImage("https://example.org/qr"))
        let qrResult = await ClipboardImageAnalyzer.analyze(qrData)
        #expect(qrResult.barcodePayloads.contains("https://example.org/qr"))
    }

    @Test func imageTextIndexIsEncryptedSearchableAndSurvivesReload() async throws {
        try await Self.withStore { store, context in
            let image = try #require(Self.textImage("Zerm searchable image text"))
            let item = try #require(ClipboardItem.capture(
                representations: [ClipboardRepresentation(type: "public.png", data: image)], sourceApp: Self.source
            ))
            let saved = try await store.capture(item)
            await store.indexImageText(saved.id)
            #expect(try await store.search(text: "searchable image", kind: .image).first?.id == saved.id)
            let reloaded = try ClipboardHistoryStore(directoryURL: context.1, keyData: context.2)
            #expect(try await reloaded.search(text: "searchable image", kind: .image).first?.id == saved.id)
            let blob = try Data(contentsOf: context.1.appendingPathComponent("\(saved.id.uuidString).blob.enc"))
            #expect(String(data: blob, encoding: .utf8)?.contains("Zerm searchable image text") != true)
        }
    }

    @Test func imageAnalyzerHandlesInvalidImageData() async {
        let result = await ClipboardImageAnalyzer.analyze(Data("not an image".utf8))
        #expect(result.recognizedText.isEmpty)
        #expect(result.barcodePayloads.isEmpty)
    }

    @Test func tagsAreManyToManySearchableAndDeleteUntags() async throws {
        try await Self.withStore { store, context in
            let item = try #require(ClipboardItem.capture(representations: [Self.text("tagged content")], sourceApp: Self.source))
            let saved = try await store.capture(item)
            let one = try await store.createTag(name: "Work", colorHex: "#123456")
            let two = try await store.createTag(name: "Later")
            try await store.attachTag(one.id, to: saved.id)
            try await store.attachTag(two.id, to: saved.id)
            try await store.renameTag(one.id, name: "Project")
            try await store.recolorTag(one.id, colorHex: "#abcdef")
            #expect(try await store.search(tagID: one.id).first?.tagIDs.count == 2)
            #expect(try await store.search(text: "project").first?.id == saved.id)
            #expect(try await store.allTags().first(where: { $0.id == one.id })?.colorHex == "#abcdef")
            try await store.detachTag(two.id, from: saved.id)
            #expect(try await store.search(tagID: two.id).isEmpty)
            try await store.attachTag(two.id, to: saved.id)
            try await store.deleteTag(one.id)
            #expect(try await store.search(tagID: one.id).isEmpty)
            #expect(try await store.recent().first?.tagIDs == [two.id])
            let reloaded = try ClipboardHistoryStore(directoryURL: context.1, keyData: context.2)
            #expect(try await reloaded.allTags().map(\.id) == [two.id])
        }
    }

    @Test func kindRetentionProtectsFavoriteAndTaggedItems() async throws {
        try await Self.withStore { store, _ in
            let kind = ClipboardItemKind.plainText
            let defaults = UserDefaults.standard
            let priorRetention = defaults.dictionary(forKey: ClipboardHistorySettings.Keys.retentionByKind)
            let priorKeepFavorites = defaults.object(forKey: ClipboardHistorySettings.Keys.keepFavoritesOnClear)
            let priorKeepTagged = defaults.object(forKey: ClipboardHistorySettings.Keys.keepTaggedOnClear)
            defer {
                if let priorRetention { defaults.set(priorRetention, forKey: ClipboardHistorySettings.Keys.retentionByKind) }
                else { defaults.removeObject(forKey: ClipboardHistorySettings.Keys.retentionByKind) }
                if let priorKeepFavorites { defaults.set(priorKeepFavorites, forKey: ClipboardHistorySettings.Keys.keepFavoritesOnClear) }
                else { defaults.removeObject(forKey: ClipboardHistorySettings.Keys.keepFavoritesOnClear) }
                if let priorKeepTagged { defaults.set(priorKeepTagged, forKey: ClipboardHistorySettings.Keys.keepTaggedOnClear) }
                else { defaults.removeObject(forKey: ClipboardHistorySettings.Keys.keepTaggedOnClear) }
            }
            ClipboardHistoryEngineSettings.setRetentionPeriod(.days(1), for: kind)
            defaults.set(true, forKey: ClipboardHistorySettings.Keys.keepFavoritesOnClear)
            defaults.set(true, forKey: ClipboardHistorySettings.Keys.keepTaggedOnClear)
            let old = Date(timeIntervalSince1970: 1_000)
            let plain = try #require(ClipboardItem.capture(representations: [Self.text("old")], sourceApp: Self.source, createdAt: old))
            let favorite = try #require(ClipboardItem.capture(representations: [Self.text("fav")], sourceApp: Self.source, createdAt: old))
            let tagged = try #require(ClipboardItem.capture(representations: [Self.text("tag")], sourceApp: Self.source, createdAt: old))
            let tag = try await store.createTag(name: "Hold")
            let a = try await store.capture(plain, now: old)
            let b = try await store.capture(favorite, now: old)
            let c = try await store.capture(tagged, now: old)
            try await store.favorite(b.id)
            try await store.attachTag(tag.id, to: c.id)
            try await store.cleanupExpired(now: old.addingTimeInterval(2 * 86_400))
            #expect(try await store.recent().map(\.id).contains(a.id) == false)
            #expect(try await store.recent().map(\.id).contains(b.id))
            #expect(try await store.recent().map(\.id).contains(c.id))
        }
    }

    @Test func retentionSettingRoundTripsThroughSinglePerKindModel() {
        let defaults = UserDefaults.standard
        let previous = defaults.dictionary(forKey: ClipboardHistorySettings.Keys.retentionByKind)
        defer {
            if let previous { defaults.set(previous, forKey: ClipboardHistorySettings.Keys.retentionByKind) }
            else { defaults.removeObject(forKey: ClipboardHistorySettings.Keys.retentionByKind) }
        }

        ClipboardHistoryEngineSettings.setRetentionPeriod(.days(123), for: .plainText)

        #expect(ClipboardHistoryEngineSettings.retentionPeriod(for: .plainText) == .days(123))
        #expect((defaults.dictionary(forKey: ClipboardHistorySettings.Keys.retentionByKind) as? [String: String])?[ClipboardItemKind.plainText.rawValue] == "days:123")
    }

    @Test func sortOrdersAndFavoriteReorderPersist() async throws {
        try await Self.withStore { store, context in
            let first = try #require(ClipboardItem.capture(representations: [Self.text("a")], sourceApp: Self.source, createdAt: Date(timeIntervalSince1970: 1)))
            let second = try #require(ClipboardItem.capture(representations: [Self.text("longer")], sourceApp: Self.source, createdAt: Date(timeIntervalSince1970: 2)))
            let a = try await store.capture(first, now: first.createdAt)
            let b = try await store.capture(second, now: second.createdAt)
            try await store.favorite(a.id)
            try await store.favorite(b.id)
            try await store.reorderFavorites([b.id, a.id])
            #expect(try await store.favorites().map(\.id) == [b.id, a.id])
            #expect(try await store.sorted(.firstCopy, ascending: true).map(\.id) == [a.id, b.id])
            #expect(try await store.sorted(.size).first?.id == b.id)
            let reloaded = try ClipboardHistoryStore(directoryURL: context.1, keyData: context.2)
            #expect(try await reloaded.favorites().map(\.id) == [b.id, a.id])
        }
    }

    @Test func mergeSplitEditAndCopyMergeOperateOnEncryptedItems() async throws {
        try await Self.withStore { store, _ in
            let first = try #require(ClipboardItem.capture(representations: [Self.text("one")], sourceApp: Self.source))
            let second = try #require(ClipboardItem.capture(representations: [Self.text("two")], sourceApp: Self.source))
            let a = try await store.capture(first)
            let b = try await store.capture(second)
            let merged = try #require(try await store.merge([a.id, b.id]))
            #expect(merged.preview == "one\ntwo")
            #expect(try await store.search(text: "one").first?.id == merged.id)
            let split = try await store.split(merged.id)
            #expect(split.map(\.preview) == ["one", "two"])
            let edited = try #require(try await store.editText(merged.id, text: "changed", richText: true))
            #expect(edited.kind == .richText)
            #expect(edited.preview == "changed")
            let appended = try #require(try await store.appendCopyToPreviousText("next", separator: " "))
            #expect(appended.preview == "two next")
        }
    }

    @Test func pasteSequenceUsesCopyOrderSkipsFavoritesWrapsAndResets() async throws {
        try await Self.withStore { store, _ in
            let first = try #require(ClipboardItem.capture(representations: [Self.text("first")], sourceApp: Self.source, createdAt: Date(timeIntervalSince1970: 1)))
            let favorite = try #require(ClipboardItem.capture(representations: [Self.text("favorite")], sourceApp: Self.source, createdAt: Date(timeIntervalSince1970: 2)))
            let second = try #require(ClipboardItem.capture(representations: [Self.text("second")], sourceApp: Self.source, createdAt: Date(timeIntervalSince1970: 3)))
            let a = try await store.capture(first, now: first.createdAt)
            let b = try await store.capture(favorite, now: favorite.createdAt)
            let c = try await store.capture(second, now: second.createdAt)
            try await store.favorite(b.id)
            #expect(try await store.nextPasteCandidate()?.id == a.id)
            try await store.recordPasteSequenceSuccess(a.id)
            #expect(try await store.nextPasteCandidate()?.id == c.id)
            try await store.recordPasteSequenceSuccess(c.id)
            #expect(try await store.nextPasteCandidate()?.id == a.id)
            await store.resetPasteSequence()
            #expect(try await store.nextPasteCandidate()?.id == a.id)
        }
    }

    @Test func copyMergeAppendsOnlyToNonFavoritePlainTextAndNeverIsCaptureGate() async throws {
        try await Self.withStore { store, _ in
            let defaults = UserDefaults.standard
            let previous = defaults.dictionary(forKey: ClipboardHistorySettings.Keys.retentionByKind)
            defer {
                if let previous { defaults.set(previous, forKey: ClipboardHistorySettings.Keys.retentionByKind) }
                else { defaults.removeObject(forKey: ClipboardHistorySettings.Keys.retentionByKind) }
            }
            let prior = try #require(ClipboardItem.capture(representations: [Self.text("prior")], sourceApp: Self.source))
            let saved = try await store.capture(prior)
            try await store.favorite(saved.id)
            #expect(try await store.appendCopyToPreviousText("next") == nil)
            let next = try #require(ClipboardItem.capture(representations: [Self.text("next")], sourceApp: Self.source))
            let savedNext = try await store.capture(next)
            let merged = try #require(try await store.appendCopyToPreviousText("last", separator: " "))
            #expect(merged.id == savedNext.id)
            #expect(merged.preview == "next last")
            ClipboardHistoryEngineSettings.setRetentionPeriod(.never, for: .plainText)
            #expect(await store.shouldCapture(.plainText) == false)
            #expect(await store.shouldCapture(.image))
            let rejected = try #require(ClipboardItem.capture(representations: [Self.text("blocked")], sourceApp: Self.source))
            var captureWasRejected = false
            do { _ = try await store.capture(rejected) }
            catch ClipboardHistoryCaptureError.retentionDisabled { captureWasRejected = true }
            #expect(captureWasRejected)
        }
    }

    @Test func identityKeepsDifferentRichFormattingSeparate() async throws {
        try await Self.withStore { store, _ in
            let plain = try #require(ClipboardItem.capture(representations: [Self.text("same")], sourceApp: Self.source))
            let attributed = NSAttributedString(string: "same", attributes: [.font: NSFont.boldSystemFont(ofSize: 12)])
            let rtf = try attributed.data(from: NSRange(location: 0, length: 4), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
            let rich = try #require(ClipboardItem.capture(representations: [ClipboardRepresentation(type: "public.rtf", data: rtf)], sourceApp: Self.source))
            #expect(plain.contentHash != rich.contentHash)
            _ = try await store.capture(plain)
            _ = try await store.capture(rich)
            #expect(try await store.recent().count == 2)
        }
    }

    @Test func transformPropertiesHoldAcrossGeneratedInputs() throws {
        for seed in 0..<64 {
            let value = "Word \(seed) / שלום 🙂\nline-\(63 - seed)"
            let encoded = try #require(ClipboardTextTransform.urlEncode.apply(to: value))
            #expect(ClipboardTextTransform.urlDecode.apply(to: encoded) == value)
            let base64 = try #require(ClipboardTextTransform.base64Encode.apply(to: value))
            #expect(ClipboardTextTransform.base64Decode.apply(to: base64) == value)
            let reverseTwice = ClipboardTextTransform.reverseLines.apply(to: ClipboardTextTransform.reverseLines.apply(to: value) ?? "")
            #expect(reverseTwice == value)
            let trimmed = ClipboardTextTransform.trim.apply(to: "  \(value) \n")
            #expect(ClipboardTextTransform.trim.apply(to: trimmed ?? "") == trimmed)
            let unique = ClipboardTextTransform.removeDuplicateLines.apply(to: "\(value)\n\(value)")
            #expect(ClipboardTextTransform.removeDuplicateLines.apply(to: unique ?? "") == unique)
        }
    }

    private static let source = ClipboardSourceApp(bundleIdentifier: "com.apple.TextEdit", name: "TextEdit")

    private static func text(_ value: String) -> ClipboardRepresentation {
        ClipboardRepresentation(type: NSPasteboard.PasteboardType.string.rawValue, data: Data(value.utf8))
    }

    private static func textImage(_ value: String) -> Data? {
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 900,
            pixelsHigh: 180,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 900, height: 180).fill()
        (value as NSString).draw(at: NSPoint(x: 24, y: 52), withAttributes: [
            .font: NSFont.systemFont(ofSize: 58), .foregroundColor: NSColor.black
        ])
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.representation(using: .png, properties: [:])
    }

    private static func qrImage(_ value: String) -> Data? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(value.utf8)
        filter.correctionLevel = "M"
        guard let image = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 12, y: 12)),
              let cgImage = CIContext().createCGImage(image, from: image.extent) else { return nil }
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        return bitmap.representation(using: .png, properties: [:])
    }

    private static func withStore(_ body: (ClipboardHistoryStore, (UserDefaults, URL, Data)) async throws -> Void) async throws {
        let suite = "ClipboardHistoryEngineTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        let key = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        try await body(ClipboardHistoryStore(directoryURL: directory, keyData: key), (defaults, directory, key))
    }
}
