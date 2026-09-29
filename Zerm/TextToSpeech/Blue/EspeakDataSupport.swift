import Foundation

@MainActor
enum EspeakDataSupport {
    static let directoryName = "espeak-ng-data"

    static func dataDirectory(in modelsDirectory: URL) -> URL {
        let candidates = [
            modelsDirectory
                .appendingPathComponent(KokoroModelManager.package.name, isDirectory: true)
                .appendingPathComponent(KokoroModelManager.package.dataDirName, isDirectory: true),
            modelsDirectory
                .appendingPathComponent(BlueModelManager.packageName, isDirectory: true)
                .appendingPathComponent(directoryName, isDirectory: true)
        ]
        return candidates.first(where: containsPhonemeTable)
            ?? candidates[0]
    }

    static func containsData(in modelsDirectory: URL) -> Bool {
        containsPhonemeTable(dataDirectory(in: modelsDirectory))
    }

    static func extractTarBz2(at archiveURL: URL, into modelsDirectory: URL, destination: URL) throws {
        try validateArchive(at: archiveURL)
        let staging = modelsDirectory.appendingPathComponent(".espeak-extract-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        try runTar(arguments: ["-x", "-j", "-f", archiveURL.path, "-C", staging.path])
        let extracted = staging.appendingPathComponent(directoryName, isDirectory: true)
        guard containsPhonemeTable(extracted), try containsNoSymbolicLinks(extracted) else {
            throw TTSError.notAvailable(String(localized: "Failed to extract English pronunciation data."))
        }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: extracted, to: destination)
    }

    private static func containsPhonemeTable(_ directory: URL) -> Bool {
        let table = directory.appendingPathComponent("phontab")
        guard let values = try? table.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return false }
        return values.isRegularFile == true && values.isSymbolicLink != true
    }

    private static func validateArchive(at archiveURL: URL) throws {
        let names = try runTar(arguments: ["-t", "-j", "-f", archiveURL.path])
        let details = try runTar(arguments: ["-t", "-j", "-v", "-f", archiveURL.path])
        try validateArchiveEntries(names: names, details: details)
    }

    static func validateArchiveEntries(names: String, details: String) throws {
        for rawName in names.split(separator: "\n").map(String.init) {
            let name = rawName.hasPrefix("./") ? String(rawName.dropFirst(2)) : rawName
            let components = name.split(separator: "/", omittingEmptySubsequences: true)
            guard !name.hasPrefix("/"), !name.contains("\\"),
                  components.first == Substring(directoryName),
                  !components.contains("..") else {
                throw TTSError.notAvailable(String(localized: "Failed to extract English pronunciation data."))
            }
        }

        for line in details.split(separator: "\n") {
            guard let type = line.first, type == "-" || type == "d" else {
                throw TTSError.notAvailable(String(localized: "Failed to extract English pronunciation data."))
            }
        }
    }

    private static func containsNoSymbolicLinks(_ directory: URL) throws -> Bool {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isSymbolicLinkKey],
            options: []
        ) else { return false }
        for case let url as URL in enumerator {
            if try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true { return false }
        }
        return true
    }

    @discardableResult
    private static func runTar(arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = arguments
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        try process.run()
        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = error.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(data: errorData, encoding: .utf8) ?? ""
            throw TTSError.notAvailable(detail.isEmpty
                ? String(localized: "Failed to extract English pronunciation data.")
                : detail)
        }
        return String(decoding: outputData, as: UTF8.self)
    }
}
