import AppKit
import Foundation
import SwiftUI
import Testing

@testable import Zerm

@Suite(.serialized)
struct ClipboardPreviewTests {
    @Test func classifiesEverySupportedMediaURLShape() throws {
        let cases: [(String, ClipboardPreviewLinkKind)] = [
            ("https://open.spotify.com/track/123", .spotify("track")),
            ("https://open.spotify.com/album/123", .spotify("album")),
            ("https://open.spotify.com/playlist/123", .spotify("playlist")),
            ("https://open.spotify.com/episode/123", .spotify("episode")),
            ("https://open.spotify.com/show/123", .spotify("show")),
            ("https://open.spotify.com/artist/123", .spotify("artist")),
            ("https://open.spotify.com/intl-de/track/123", .spotify("track")),
            ("https://youtube.com/watch?v=123", .youtube("video")),
            ("https://www.youtube.com/shorts/123", .youtube("shorts")),
            ("https://youtu.be/123", .youtube("video")),
            ("https://music.youtube.com/watch?v=123", .youtubeMusic("watch")),
            ("https://music.apple.com/us/song/title/123", .appleMusic("song")),
            ("https://music.apple.com/us/album/title/123", .appleMusic("album")),
            ("https://music.apple.com/us/playlist/title/123", .appleMusic("playlist")),
            ("https://music.apple.com/us/artist/name/123", .appleMusic("artist")),
            ("https://music.apple.com/album/title/123", .appleMusic("album")),
            ("https://soundcloud.com/artist/track", .soundCloud),
            ("https://on.soundcloud.com/abcd", .soundCloud),
            ("https://example.test/path", .website),
        ]
        for (value, expected) in cases {
            #expect(ClipboardPreviewClassifier.linkKind(for: try #require(URL(string: value))) == expected, "\(value)")
        }
    }

    @Test func parsesOEmbedJSON() throws {
        let json = Data(#"{"title":"Song title","author_name":"Artist","provider_name":"Spotify","thumbnail_url":"https://img.example.test/art.jpg"}"#.utf8)
        let response = try JSONDecoder().decode(ClipboardOEmbed.self, from: json)
        #expect(response.title == "Song title")
        #expect(response.authorName == "Artist")
        #expect(response.providerName == "Spotify")
        #expect(response.thumbnailURL?.host == "img.example.test")
        #expect(response.metadata().author == "Artist")
    }

    @Test func encryptedCacheHitsMissesAndEvictsOldest() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("clipboard-preview-cache-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = try ClipboardLinkPreviewCache(directory: directory, keyData: Data(repeating: 9, count: 32), maximumBytes: 140)
        let firstURL = try #require(URL(string: "https://first.example.test"))
        let secondURL = try #require(URL(string: "https://second.example.test"))
        #expect(await cache.metadata(for: firstURL) == nil)
        let metadata = ClipboardLinkMetadata(title: "First title", siteName: "Example")
        await cache.store(metadata, for: firstURL)
        #expect(await cache.metadata(for: firstURL) == metadata)
        await cache.store(ClipboardLinkMetadata(title: String(repeating: "x", count: 200)), for: secondURL)
        #expect(await cache.count() == 0)
    }

    @Test func linkServiceFetchesOnMissAndUsesEncryptedCacheOnHit() async throws {
        let key = "clipboardHistoryLinkPreviewsEnabled"
        let previous = UserDefaults.standard.object(forKey: key)
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        UserDefaults.standard.set(true, forKey: key)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("clipboard-preview-service-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try #require(URL(string: "https://cache.example.test"))
        let fetcher = PreviewFixtureFetcher(metadata: ClipboardLinkMetadata(title: "Cached title"))
        let cache = try ClipboardLinkPreviewCache(directory: directory, keyData: Data(repeating: 3, count: 32))
        let service = LinkPreviewService(fetcher: fetcher, cache: cache)
        #expect(await service.preview(for: url)?.title == "Cached title")
        #expect(await service.preview(for: url)?.title == "Cached title")
        #expect(await fetcher.calls == 1)
    }

    @Test func disabledAndOfflineLinksReturnCleanFallbackMetadata() async throws {
        let key = "clipboardHistoryLinkPreviewsEnabled"
        let previous = UserDefaults.standard.object(forKey: key)
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        let url = try #require(URL(string: "https://offline.example.test/path"))
        let disabledFetcher = PreviewFixtureFetcher(metadata: ClipboardLinkMetadata(title: "Should not fetch"))
        let disabledService = LinkPreviewService(fetcher: disabledFetcher, cache: nil)
        UserDefaults.standard.set(false, forKey: key)
        #expect(await disabledService.preview(for: url) == nil)
        #expect(await disabledFetcher.calls == 0)

        UserDefaults.standard.set(true, forKey: key)
        let offline = LinkPreviewService(fetcher: PreviewFixtureFetcher(fails: true), cache: nil)
        #expect(await offline.preview(for: url) == nil)
        #expect(url.host == "offline.example.test")

        UserDefaults.standard.removeObject(forKey: key)
        let defaultEnabledFetcher = PreviewFixtureFetcher(metadata: ClipboardLinkMetadata(title: "Default enabled"))
        let defaultEnabled = LinkPreviewService(fetcher: defaultEnabledFetcher, cache: nil)
        #expect(await defaultEnabled.preview(for: url)?.title == "Default enabled")
    }

    @Test func colorParsingFormatsHexRGBHSLAndContrast() throws {
        let white = try #require(ClipboardColorDetails.parse("#fff"))
        #expect(white.hex == "#FFFFFF")
        #expect(white.rgb == "RGB 255, 255, 255")
        #expect(white.hsl == "HSL 0°, 0%, 100%")
        #expect(white.contrast == "Dark text")
        let red = try #require(ClipboardColorDetails.parse("#ff0000"))
        #expect(red.hex == "#FF0000")
        #expect(red.rgb == "RGB 255, 0, 0")
        #expect(red.hsl == "HSL 0°, 100%, 50%")
        #expect(red.contrast == "Dark text")
        #expect(ClipboardColorDetails.parse("rgb(255, 0, 0)")?.hex == "#FF0000")
        #expect(ClipboardColorDetails.parse("hsl(0, 100%, 50%)")?.hex == "#FF0000")
        #expect(ClipboardColorDetails.parse("#f008")?.hex == "#FF0000")
        #expect(ClipboardColorDetails.parse("#ff000080")?.hex == "#FF0000")
        #expect(ClipboardColorDetails.parse("not a color") == nil)
    }

    @MainActor
    @Test func rendersEachPreviewKindToPNG() async throws {
        let directory = URL(fileURLWithPath: "/tmp/zerm-work/387-previews", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let folderURL = FileManager.default.temporaryDirectory.appendingPathComponent("clipboard-preview-folder-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        try Data("sample".utf8).write(to: folderURL.appendingPathComponent("inside.txt"))
        defer { try? FileManager.default.removeItem(at: folderURL) }
        let fixture = PreviewFixtureFetcher(metadata: ClipboardLinkMetadata(title: "Preview title", siteName: "Fixture", author: "Creator"))
        let service = LinkPreviewService(fetcher: fixture, cache: nil)
        let items: [(String, ClipboardItem)] = [
            ("text", item(.plainText, "Clipboard notes", representations: [representation("Clipboard notes")])),
            ("rich-text", item(.richText, "Rich preview", representations: [representation("Rich preview", type: "public.rtf")])),
            ("image", item(.image, "Image", representations: [try pngRepresentation()])),
            ("files", item(.fileURLs, "missing-file.txt", representations: [ClipboardRepresentation(type: "public.file-url", data: URL(fileURLWithPath: "/tmp/zerm-work/no-such-file.txt").dataRepresentation)])),
            ("folder", item(.fileURLs, folderURL.lastPathComponent, representations: [ClipboardRepresentation(type: "public.file-url", data: folderURL.dataRepresentation)])),
            ("link", item(.url, "https://example.test", representations: [representation("https://example.test", type: "public.url")])),
            ("email", item(.email, "person@example.test", representations: [representation("person@example.test")])),
            ("color", item(.color, "#336699", representations: [representation("#336699")])),
            ("other", item(.other, "Other clipboard data", representations: [])),
        ]
        for (name, item) in items {
            let window = NSWindow(contentRect: NSRect(x: -3200, y: -2200, width: 520, height: 360), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.setFrameOrigin(NSPoint(x: -3200, y: -2200))
            window.contentView = NSHostingView(rootView: ClipboardRichPreview(item: item, linkService: service))
            window.contentView?.frame = NSRect(x: 0, y: 0, width: 520, height: 360)
            window.contentView?.layoutSubtreeIfNeeded()
            window.orderFrontRegardless()
            if item.kind == .url {
                for _ in 0..<40 {
                    if await fixture.calls > 0 { break }
                    try await Task.sleep(nanoseconds: 25_000_000)
                }
            }
            try await Task.sleep(nanoseconds: 1_000_000_000)
            window.displayIfNeeded()
            let content = try #require(window.contentView)
            let bounds = content.bounds
            let bitmap = try #require(content.bitmapImageRepForCachingDisplay(in: bounds))
            content.cacheDisplay(in: bounds, to: bitmap)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: directory.appendingPathComponent("\(name).png"))
            window.close()
        }
    }

    private func item(_ kind: ClipboardItemKind, _ preview: String, representations: [ClipboardRepresentation]) -> ClipboardItem {
        ClipboardItem(contentHash: UUID().uuidString, kind: kind, representations: representations, preview: preview, sourceApp: ClipboardSourceApp(bundleIdentifier: "test.preview", name: "Preview Test"))
    }

    private func representation(_ value: String, type: String = NSPasteboard.PasteboardType.string.rawValue) -> ClipboardRepresentation {
        ClipboardRepresentation(type: type, data: Data(value.utf8))
    }

    private func pngRepresentation() throws -> ClipboardRepresentation {
        let image = NSImage(size: NSSize(width: 80, height: 48))
        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: 80, height: 48)).fill()
        image.unlockFocus()
        let bitmap = try #require(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        return ClipboardRepresentation(type: "public.png", data: try #require(bitmap.representation(using: .png, properties: [:])))
    }
}

private actor PreviewFixtureFetcher: ClipboardLinkMetadataFetching {
    private(set) var calls = 0
    let metadata: ClipboardLinkMetadata
    let fails: Bool

    init(metadata: ClipboardLinkMetadata = ClipboardLinkMetadata(), fails: Bool = false) { self.metadata = metadata; self.fails = fails }

    func fetch(_ url: URL, kind: ClipboardPreviewLinkKind) async throws -> ClipboardLinkMetadata {
        calls += 1
        if fails { throw URLError(.notConnectedToInternet) }
        return metadata
    }
}
