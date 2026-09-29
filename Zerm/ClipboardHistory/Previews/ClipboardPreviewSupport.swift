import AppKit
import CryptoKit
import Foundation
import LinkPresentation
import QuickLookThumbnailing

enum ClipboardPreviewLinkKind: Equatable, Sendable {
    case website
    case spotify(String)
    case youtube(String)
    case youtubeMusic(String)
    case appleMusic(String)
    case soundCloud

    var serviceName: String? {
        switch self {
        case .website: nil
        case .spotify: String(localized: "Spotify")
        case .youtube: String(localized: "YouTube")
        case .youtubeMusic: String(localized: "YouTube Music")
        case .appleMusic: String(localized: "Apple Music")
        case .soundCloud: String(localized: "SoundCloud")
        }
    }
}

enum ClipboardPreviewClassifier {
    static func linkKind(for url: URL) -> ClipboardPreviewLinkKind {
        let host = (url.host ?? "").lowercased().replacingOccurrences(of: "www.", with: "")
        let path = url.path.lowercased().split(separator: "/").map(String.init)
        if host == "open.spotify.com",
           let category = path.first(where: { ["track", "album", "playlist", "episode", "show", "artist"].contains($0) }) {
            return .spotify(category)
        }
        if host == "music.youtube.com" { return .youtubeMusic(path.first ?? "") }
        if ["youtube.com", "m.youtube.com"].contains(host) {
            return .youtube(path.first == "shorts" ? "shorts" : "video")
        }
        if host == "youtu.be" { return .youtube("video") }
        if host == "music.apple.com",
           let category = path.first(where: { ["song", "album", "playlist", "artist"].contains($0) }) {
            return .appleMusic(category)
        }
        if host == "soundcloud.com" || host == "on.soundcloud.com" { return .soundCloud }
        return .website
    }

    static func url(from item: ClipboardItem) -> URL? {
        let data = item.representations.first(where: { $0.type == "public.url" || $0.type == "public.utf8-plain-text" })?.data
        guard let data, let value = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let url = URL(string: value), url.scheme?.lowercased() == "https" || url.scheme?.lowercased() == "http" else { return nil }
        return url
    }
}

struct ClipboardLinkMetadata: Codable, Equatable, Sendable {
    var title: String?
    var siteName: String?
    var author: String?
    var iconData: Data?
    var imageData: Data?

    var isEmpty: Bool { title == nil && siteName == nil && author == nil && iconData == nil && imageData == nil }
}

struct ClipboardOEmbed: Decodable, Equatable, Sendable {
    let title: String?
    let authorName: String?
    let providerName: String?
    let thumbnailURL: URL?

    enum CodingKeys: String, CodingKey {
        case title
        case authorName = "author_name"
        case providerName = "provider_name"
        case thumbnailURL = "thumbnail_url"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        authorName = try container.decodeIfPresent(String.self, forKey: .authorName)
        providerName = try container.decodeIfPresent(String.self, forKey: .providerName)
        thumbnailURL = try container.decodeIfPresent(URL.self, forKey: .thumbnailURL)
    }

    func metadata(thumbnail: Data? = nil) -> ClipboardLinkMetadata {
        ClipboardLinkMetadata(title: title, siteName: providerName, author: authorName, iconData: nil, imageData: thumbnail)
    }
}

protocol ClipboardLinkMetadataFetching: Sendable {
    func fetch(_ url: URL, kind: ClipboardPreviewLinkKind) async throws -> ClipboardLinkMetadata
}

struct ClipboardPreviewHTTPClient: Sendable {
    private let session: URLSession

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            configuration.urlCache = nil
            configuration.timeoutIntervalForRequest = 10
            configuration.timeoutIntervalForResource = 10
            self.session = URLSession(configuration: configuration)
        }
    }

    func data(from url: URL) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpShouldHandleCookies = false
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? false else {
            throw URLError(.badServerResponse)
        }
        return data
    }
}

struct DefaultClipboardLinkMetadataFetcher: ClipboardLinkMetadataFetching {
    let http: ClipboardPreviewHTTPClient

    init(http: ClipboardPreviewHTTPClient = ClipboardPreviewHTTPClient()) { self.http = http }

    func fetch(_ url: URL, kind: ClipboardPreviewLinkKind) async throws -> ClipboardLinkMetadata {
        if let endpoint = oEmbedEndpoint(for: url, kind: kind),
           let data = try? await http.data(from: endpoint),
           let response = try? JSONDecoder().decode(ClipboardOEmbed.self, from: data) {
            var artwork: Data?
            if let thumbnailURL = response.thumbnailURL { artwork = try? await http.data(from: thumbnailURL) }
            return response.metadata(thumbnail: artwork)
        }
        return try await linkPresentationMetadata(for: url)
    }

    private func oEmbedEndpoint(for url: URL, kind: ClipboardPreviewLinkKind) -> URL? {
        let endpoint: URL?
        switch kind {
        case .spotify: endpoint = URL(string: "https://open.spotify.com/oembed")
        case .youtube, .youtubeMusic: endpoint = URL(string: "https://www.youtube.com/oembed")
        case .soundCloud: endpoint = URL(string: "https://soundcloud.com/oembed")
        case .website, .appleMusic: endpoint = nil
        }
        guard let endpoint else { return nil }
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "url", value: url.absoluteString), URLQueryItem(name: "format", value: "json")]
        return components?.url
    }

    private func linkPresentationMetadata(for url: URL) async throws -> ClipboardLinkMetadata {
        let provider = LPMetadataProvider()
        provider.timeout = 10
        let metadata = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<LPLinkMetadata, Error>) in
                provider.startFetchingMetadata(for: url) { metadata, error in
                    if let error { continuation.resume(throwing: error) }
                    else if let metadata { continuation.resume(returning: metadata) }
                    else { continuation.resume(throwing: URLError(.unknown)) }
                }
            }
        } onCancel: {
            provider.cancel()
        }
        async let icon = loadImageData(metadata.iconProvider)
        async let image = loadImageData(metadata.imageProvider)
        return ClipboardLinkMetadata(title: metadata.title, siteName: metadata.url?.host, author: nil, iconData: await icon, imageData: await image)
    }

    private func loadImageData(_ provider: NSItemProvider?) async -> Data? {
        guard let provider else { return nil }
        let cancellation = ClipboardPreviewProgress()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let progress = provider.loadDataRepresentation(forTypeIdentifier: "public.image") { data, _ in continuation.resume(returning: data) }
                cancellation.set(progress)
            }
        } onCancel: {
            cancellation.cancel()
        }
    }
}

actor ClipboardLinkPreviewCache {
    private struct Entry: Codable {
        let metadata: ClipboardLinkMetadata
        let storedAt: Date
    }

    private let directory: URL
    private let encryption: ClipboardHistoryEncryption
    private let maximumBytes: Int

    init(directory: URL = AppStoragePaths.root.appendingPathComponent("ClipboardHistory/Previews", isDirectory: true), keyData: Data? = nil, maximumBytes: Int = 20 * 1_024 * 1_024) throws {
        let resolvedKey: Data
        if let keyData { resolvedKey = keyData }
        else if let existing = KeychainService.shared.getData(forKey: "clipboardHistoryEncryptionKey", syncable: false) { resolvedKey = existing }
        else { throw ClipboardHistoryError.keychainUnavailable }
        self.directory = directory
        encryption = try ClipboardHistoryEncryption(keyData: resolvedKey)
        self.maximumBytes = max(0, maximumBytes)
    }

    private var directoryURL: URL { directory }

    func metadata(for url: URL) -> ClipboardLinkMetadata? {
        let file = cacheURL(for: url)
        guard let bytes = try? Data(contentsOf: file), let clear = try? encryption.open(bytes),
              let entry = try? JSONDecoder().decode(Entry.self, from: clear) else { return nil }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
        return entry.metadata
    }

    func store(_ metadata: ClipboardLinkMetadata, for url: URL) {
        guard !metadata.isEmpty, let data = try? JSONEncoder().encode(Entry(metadata: metadata, storedAt: Date())),
              let sealed = try? encryption.seal(data) else { return }
        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            try sealed.write(to: cacheURL(for: url), options: .atomic)
            evictIfNeeded()
        } catch { return }
    }

    func count() -> Int {
        (try? FileManager.default.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil).count) ?? 0
    }

    private func cacheURL(for url: URL) -> URL {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        return directoryURL.appendingPathComponent(digest).appendingPathExtension("enc")
    }

    private func evictIfNeeded() {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]) else { return }
        var entries = files.compactMap { file -> (URL, Int, Date)? in
            guard let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { return nil }
            return (file, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast)
        }.sorted { $0.2 < $1.2 }
        var total = entries.reduce(0) { $0 + $1.1 }
        while total > maximumBytes, let oldest = entries.first {
            try? FileManager.default.removeItem(at: oldest.0)
            total -= oldest.1
            entries.removeFirst()
        }
    }
}

actor LinkPreviewService {
    static let shared = LinkPreviewService()

    private let fetcher: any ClipboardLinkMetadataFetching
    private let cache: ClipboardLinkPreviewCache?
    private var inFlight: [URL: Task<ClipboardLinkMetadata?, Never>] = [:]

    init(fetcher: any ClipboardLinkMetadataFetching = DefaultClipboardLinkMetadataFetcher(), cache: ClipboardLinkPreviewCache? = try? ClipboardLinkPreviewCache()) {
        self.fetcher = fetcher
        self.cache = cache
    }

    func preview(for url: URL) async -> ClipboardLinkMetadata? {
        guard UserDefaults.standard.object(forKey: "clipboardHistoryLinkPreviewsEnabled") as? Bool ?? true else { return nil }
        if let cached = await cache?.metadata(for: url) { return cached }
        if let inFlight = inFlight[url] { return await inFlight.value }
        let kind = ClipboardPreviewClassifier.linkKind(for: url)
        let fetcher = self.fetcher
        let task = Task<ClipboardLinkMetadata?, Never> {
            await withTaskGroup(of: ClipboardLinkMetadata?.self) { group in
                group.addTask {
                    do { return try await fetcher.fetch(url, kind: kind) }
                    catch { return nil }
                }
                group.addTask {
                    try? await Task.sleep(for: .seconds(10))
                    return nil
                }
                let result = await group.next() ?? nil
                group.cancelAll()
                return result
            }
        }
        inFlight[url] = task
        let metadata = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
            Task { await self.removeInFlight(url) }
        }
        inFlight.removeValue(forKey: url)
        if let metadata { await cache?.store(metadata, for: url) }
        return metadata
    }

    private func removeInFlight(_ url: URL) { inFlight.removeValue(forKey: url) }
}

struct ClipboardColorDetails: Equatable, Sendable {
    let hex: String
    let rgb: String
    let hsl: String
    let contrast: String
    let red: Int
    let green: Int
    let blue: Int

    static func parse(_ value: String) -> ClipboardColorDetails? {
        let token = ClipboardDetection.colorToken(in: value) ?? value.trimmingCharacters(in: .whitespacesAndNewlines)
        let red: Int, green: Int, blue: Int
        let hex = token.hasPrefix("#") ? String(token.dropFirst()) : token
        if [3, 4, 6, 8].contains(hex.count), let number = UInt64(hex, radix: 16) {
            if hex.count == 3 {
                red = Int((number >> 8) & 0xF) * 17; green = Int((number >> 4) & 0xF) * 17; blue = Int(number & 0xF) * 17
            } else if hex.count == 4 {
                red = Int((number >> 12) & 0xF) * 17; green = Int((number >> 8) & 0xF) * 17; blue = Int((number >> 4) & 0xF) * 17
            } else if hex.count == 8 {
                red = Int((number >> 24) & 0xFF); green = Int((number >> 16) & 0xFF); blue = Int((number >> 8) & 0xFF)
            } else {
                red = Int((number >> 16) & 0xFF); green = Int((number >> 8) & 0xFF); blue = Int(number & 0xFF)
            }
        } else if token.lowercased().hasPrefix("rgb"), let components = functionComponents(token), components.count >= 3 {
            func channel(_ component: String) -> Int? {
                let percent = component.hasSuffix("%")
                guard let value = Double(component.replacingOccurrences(of: "%", with: "")), value.isFinite else { return nil }
                return Int((max(0, min(percent ? 100 : 255, value)) * (percent ? 2.55 : 1)).rounded())
            }
            guard let r = channel(components[0]), let g = channel(components[1]), let b = channel(components[2]) else { return nil }
            red = r; green = g; blue = b
        } else if token.lowercased().hasPrefix("hsl"), let components = functionComponents(token), components.count >= 3,
                  let rawHue = Double(components[0].replacingOccurrences(of: "deg", with: "")),
                  let rawSaturation = Double(components[1].replacingOccurrences(of: "%", with: "")),
                  let rawLightness = Double(components[2].replacingOccurrences(of: "%", with: "")),
                  rawHue.isFinite, rawSaturation.isFinite, rawLightness.isFinite {
            let hue = (rawHue.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 60
            let saturation = max(0, min(100, rawSaturation)) / 100
            let lightness = max(0, min(100, rawLightness)) / 100
            let chroma = (1 - abs(2 * lightness - 1)) * saturation
            let secondary = chroma * (1 - abs(hue.truncatingRemainder(dividingBy: 2) - 1))
            let match = lightness - chroma / 2
            let values: (Double, Double, Double)
            switch Int(hue) {
            case 0: values = (chroma, secondary, 0)
            case 1: values = (secondary, chroma, 0)
            case 2: values = (0, chroma, secondary)
            case 3: values = (0, secondary, chroma)
            case 4: values = (secondary, 0, chroma)
            default: values = (chroma, 0, secondary)
            }
            red = Int(((values.0 + match) * 255).rounded()); green = Int(((values.1 + match) * 255).rounded()); blue = Int(((values.2 + match) * 255).rounded())
        } else {
            return nil
        }
        let r = Double(red) / 255, g = Double(green) / 255, b = Double(blue) / 255
        let maxC = max(r, g, b), minC = min(r, g, b), delta = maxC - minC
        var hue = 0.0
        if delta != 0 {
            if maxC == r { hue = 60 * (((g - b) / delta).truncatingRemainder(dividingBy: 6)) }
            else if maxC == g { hue = 60 * ((b - r) / delta + 2) }
            else { hue = 60 * ((r - g) / delta + 4) }
        }
        if hue < 0 { hue += 360 }
        let lightness = (maxC + minC) / 2
        let saturation = delta == 0 ? 0 : delta / (1 - abs(2 * lightness - 1))
        let luminance = [r, g, b].map { $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }.enumerated().reduce(0.0) { $0 + $1.element * [0.2126, 0.7152, 0.0722][$1.offset] }
        let contrast = (1.05 / (luminance + 0.05)) >= 4.5 ? String(localized: "Light text") : String(localized: "Dark text")
        let rgb = String.localizedStringWithFormat(String(localized: "RGB %lld, %lld, %lld"), red, green, blue)
        let hsl = String.localizedStringWithFormat(String(localized: "HSL %lld°, %lld%%, %lld%%"), Int(hue.rounded()), Int((saturation * 100).rounded()), Int((lightness * 100).rounded()))
        return ClipboardColorDetails(hex: String(format: "#%02X%02X%02X", red, green, blue), rgb: rgb, hsl: hsl, contrast: contrast, red: red, green: green, blue: blue)
    }

    private static func functionComponents(_ value: String) -> [String]? {
        guard let open = value.firstIndex(of: "("), value.last == ")" else { return nil }
        return value[value.index(after: open)..<value.index(before: value.endIndex)]
            .split(whereSeparator: { $0 == "," || $0.isWhitespace || $0 == "/" })
            .map(String.init)
    }
}

struct ClipboardFilePreview: @unchecked Sendable {
    let name: String
    let size: String
    let kind: String
    let folderCount: Int?
    let missing: Bool
    let thumbnail: NSImage?

    static func load(_ url: URL, size: CGSize = CGSize(width: 160, height: 120)) async -> ClipboardFilePreview {
        let task = Task.detached(priority: .utility) {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .localizedTypeDescriptionKey, .contentModificationDateKey])
            let exists = FileManager.default.fileExists(atPath: url.path)
            let folderCount = values?.isDirectory == true ? (try? FileManager.default.contentsOfDirectory(atPath: url.path).count) : nil
            var image: NSImage?
            if exists {
                let date = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
                let cacheKey = "\(url.standardizedFileURL.path):\(date):\(Int(size.width))x\(Int(size.height))"
                image = ClipboardPreviewImageCache.cachedImage(for: cacheKey)
                if image == nil {
                    let request = QLThumbnailGenerator.Request(fileAt: url, size: size, scale: 2, representationTypes: .thumbnail)
                    let generator = QLThumbnailGenerator.shared
                    let thumbnail = await withTaskCancellationHandler {
                        try? await generator.generateBestRepresentation(for: request)
                    } onCancel: {
                        generator.cancel(request)
                    }
                    image = thumbnail?.nsImage
                    if let image { ClipboardPreviewImageCache.store(image, for: cacheKey) }
                }
            }
            return ClipboardFilePreview(name: url.lastPathComponent, size: Self.byteString(values?.fileSize, isDirectory: values?.isDirectory == true), kind: values?.localizedTypeDescription ?? String(localized: "File"), folderCount: folderCount, missing: !exists, thumbnail: image)
        }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private static func byteString(_ bytes: Int?, isDirectory: Bool) -> String {
        if isDirectory { return String(localized: "Folder") }
        guard let bytes else { return String(localized: "Unknown size") }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

enum ClipboardPreviewImageCache {
    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.totalCostLimit = 24 * 1_024 * 1_024
        cache.countLimit = 160
        return cache
    }()

    static func image(for key: String, data: Data) -> NSImage? {
        if let image = cachedImage(for: key) { return image }
        guard let image = NSImage(data: data) else { return nil }
        store(image, for: key, cost: data.count)
        return image
    }

    static func cachedImage(for key: String) -> NSImage? { cache.object(forKey: key as NSString) }

    static func store(_ image: NSImage, for key: String, cost: Int? = nil) {
        let estimatedCost = cost ?? Int(image.size.width * image.size.height * 4)
        cache.setObject(image, forKey: key as NSString, cost: estimatedCost)
    }
}

private final class ClipboardPreviewProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var progress: Progress?
    private var isCancelled = false

    func set(_ progress: Progress) {
        lock.lock()
        self.progress = progress
        let shouldCancel = isCancelled
        lock.unlock()
        if shouldCancel { progress.cancel() }
    }

    func cancel() {
        lock.lock()
        isCancelled = true
        let progress = self.progress
        lock.unlock()
        progress?.cancel()
    }
}
