import AppKit
import Darwin
import Foundation
import ImageIO
import Testing

@testable import Zerm

@Suite(.serialized)
struct ClipboardHistoryScaleTests {
    @Test func tenThousandItemsCaptureAndSearchStayWithinBounds() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("clipboard-scale-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ClipboardHistoryStore(directoryURL: directory, keyData: Data(repeating: 9, count: 32))
        let defaults = UserDefaults.standard
        let previousRetention = defaults.object(forKey: ClipboardHistorySettings.Keys.retentionCount)
        defaults.set(12_000, forKey: ClipboardHistorySettings.Keys.retentionCount)
        defer {
            if let previousRetention { defaults.set(previousRetention, forKey: ClipboardHistorySettings.Keys.retentionCount) }
            else { defaults.removeObject(forKey: ClipboardHistorySettings.Keys.retentionCount) }
        }
        let source = ClipboardSourceApp(bundleIdentifier: "test.scale", name: "Scale Test")
        let now = Date()
        let items = (0..<10_000).map { index in
            ClipboardItem(
                contentHash: "scale-\(index)", kind: .plainText,
                representations: [ClipboardRepresentation(type: NSPasteboard.PasteboardType.string.rawValue, data: Data("scale row \(index)".utf8))],
                preview: "scale row \(index)", createdAt: now.addingTimeInterval(Double(index)),
                lastUsedAt: now.addingTimeInterval(Double(index)), sourceApp: source
            )
        }
        let memoryBefore = Self.residentMemory()
        let captureStart = ProcessInfo.processInfo.systemUptime
        _ = try await store.captureBatch(items, now: now)
        try await store.flushPendingWrites()
        let captureMilliseconds = (ProcessInfo.processInfo.systemUptime - captureStart) * 1_000

        let searchStart = ProcessInfo.processInfo.systemUptime
        let results = try await store.search(text: "scale row 9999")
        let searchMilliseconds = (ProcessInfo.processInfo.systemUptime - searchStart) * 1_000

        let reloaded = try ClipboardHistoryStore(directoryURL: directory, keyData: Data(repeating: 9, count: 32))
        let pageStart = ProcessInfo.processInfo.systemUptime
        let firstPage = try await reloaded.sortedPage(.lastCopy, offset: 0, limit: 100)
        let firstPageMilliseconds = (ProcessInfo.processInfo.systemUptime - pageStart) * 1_000
        let memoryDelta = max(0, Self.residentMemory() - memoryBefore)

        let measurements = "capture_10000_ms=\(Int(captureMilliseconds))\nsearch_ms=\(String(format: "%.2f", searchMilliseconds))\nfirst_page_ms=\(String(format: "%.2f", firstPageMilliseconds))\nresident_delta_mib=\(memoryDelta / 1_048_576)\n"
        try? FileManager.default.createDirectory(atPath: "/tmp/zerm-work", withIntermediateDirectories: true)
        try? measurements.write(toFile: "/tmp/zerm-work/386-scale-metrics.txt", atomically: true, encoding: .utf8)
        print("Clipboard scale: \(measurements.replacingOccurrences(of: "\n", with: "; "))")
        #expect(results.first?.preview == "scale row 9999")
        #expect(firstPage.count == 100)
        #expect(firstPageMilliseconds < 1_500, "10,000-item first page took \(firstPageMilliseconds) ms")
        #expect(searchMilliseconds < 150, "10,000-item search took \(searchMilliseconds) ms")
        #expect(memoryDelta < 512 * 1_048_576, "10,000-item resident growth was \(memoryDelta) bytes")
    }

    @Test func captureCreatesThumbnailNoLargerThan320Pixels() throws {
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 1_600, pixelsHigh: 1_200,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        bitmap.size = NSSize(width: 1_600, height: 1_200)
        let sourceData = try #require(bitmap.representation(using: .png, properties: [:]))
        let item = try #require(ClipboardItem.capture(
            representations: [ClipboardRepresentation(type: "public.png", data: sourceData)],
            sourceApp: ClipboardSourceApp(bundleIdentifier: "test.scale", name: "Scale Test")
        ))
        let thumbnailData = try #require(item.thumbnailData)
        let source = try #require(CGImageSourceCreateWithData(thumbnailData as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(max(image.width, image.height) <= 320)
    }

    @Test func thumbnailIsEncryptedAndLoadedForHistoryPage() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("clipboard-thumbnail-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = Data(repeating: 3, count: 32)
        let source = ClipboardSourceApp(bundleIdentifier: "test.scale", name: "Scale Test")
        let sourceData = try Self.largePNG()
        let item = try #require(ClipboardItem.capture(
            representations: [ClipboardRepresentation(type: "public.png", data: sourceData)], sourceApp: source
        ))
        let store = try ClipboardHistoryStore(directoryURL: directory, keyData: key)
        let saved = try await store.capture(item)
        try await store.flushPendingWrites()

        let encryptedThumbnail = try Data(contentsOf: directory.appendingPathComponent("\(saved.id.uuidString).thumb.enc"))
        let thumbnailData = try #require(item.thumbnailData)
        #expect(encryptedThumbnail.range(of: thumbnailData) == nil)
        let reloaded = try ClipboardHistoryStore(directoryURL: directory, keyData: key)
        let page = try await reloaded.recentPage(limit: 10)
        let thumbnail = try #require(page.first?.thumbnailData)
        #expect(thumbnail.count < sourceData.count)
    }

    @Test func storeSkipsItemsAboveConfiguredMaximum() async throws {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: ClipboardHistorySettings.Keys.maximumItemSize)
        defer {
            if let previous { defaults.set(previous, forKey: ClipboardHistorySettings.Keys.maximumItemSize) }
            else { defaults.removeObject(forKey: ClipboardHistorySettings.Keys.maximumItemSize) }
        }
        defaults.set(10, forKey: ClipboardHistorySettings.Keys.maximumItemSize)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("clipboard-size-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ClipboardHistoryStore(directoryURL: directory, keyData: Data(repeating: 4, count: 32))
        let item = try #require(ClipboardItem.capture(
            representations: [ClipboardRepresentation(type: NSPasteboard.PasteboardType.string.rawValue, data: Data(repeating: 65, count: 11))],
            sourceApp: ClipboardSourceApp(bundleIdentifier: "test.scale", name: "Scale Test"),
            maximumSize: 100
        ))
        do {
            _ = try await store.capture(item)
            Issue.record("Oversized item was captured")
        } catch ClipboardHistoryStoreCaptureError.itemTooLarge {
            #expect(try await store.totalCount() == 0)
        }
    }

    private static func residentMemory() -> Int64 {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Int64(usage.ru_maxrss)
    }

    private static func largePNG() throws -> Data {
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 1_600, pixelsHigh: 1_200,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        bitmap.size = NSSize(width: 1_600, height: 1_200)
        let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor.systemPurple.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: 1_600, height: 1_200)).fill()
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        return try #require(bitmap.representation(using: .png, properties: [:]))
    }
}
