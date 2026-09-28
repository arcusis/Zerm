import Foundation
import SwiftUI

@MainActor
final class SherpaOnnxModelManager: ObservableObject {
    @Published private(set) var downloadingModels = Set<String>()

    private let storageRoot: URL

    init(storageRoot: URL = AppStoragePaths.root) {
        self.storageRoot = storageRoot
    }

    nonisolated static func modelDirectory(for model: SherpaOnnxModel, under root: URL = AppStoragePaths.root.appendingPathComponent("SherpaOnnxModels", isDirectory: true)) -> URL {
        root.appendingPathComponent(model.name, isDirectory: true)
    }

    func isDownloaded(_ model: SherpaOnnxModel) -> Bool {
        let directory = Self.modelDirectory(for: model, under: storageRoot.appendingPathComponent("SherpaOnnxModels", isDirectory: true))
        return Self.requiredFiles(for: model).allSatisfy {
            FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path)
        }
    }

    func download(_ model: SherpaOnnxModel) async throws {
        guard !downloadingModels.contains(model.name), !isDownloaded(model) else { return }
        downloadingModels.insert(model.name)
        defer { downloadingModels.remove(model.name) }

        let url = URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/\(model.archiveName)")!
        let (archiveURL, _) = try await URLSession.shared.download(from: url)
        defer { try? FileManager.default.removeItem(at: archiveURL) }
        guard ModelIntegrity.verify(fileURL: archiveURL, expectedSHA256: model.sha256) else {
            throw DownloadError.checksumMismatch
        }

        let parent = storageRoot.appendingPathComponent("SherpaOnnxModels", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let temporaryDirectory = parent.appendingPathComponent(".\(model.name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        try Self.extractSafely(archiveURL, to: temporaryDirectory)

        let extracted = temporaryDirectory.appendingPathComponent(Self.archiveDirectory(for: model), isDirectory: true)
        guard Self.requiredFiles(for: model).allSatisfy({ FileManager.default.fileExists(atPath: extracted.appendingPathComponent($0).path) }) else {
            throw DownloadError.invalidArchive
        }

        let destination = Self.modelDirectory(for: model, under: parent)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: extracted, to: destination)
    }

    func delete(_ model: SherpaOnnxModel) throws {
        let directory = Self.modelDirectory(for: model, under: storageRoot.appendingPathComponent("SherpaOnnxModels", isDirectory: true))
        try FileManager.default.removeItem(at: directory)
    }

    static func assertSafeArchivePaths(_ paths: [String]) throws {
        for path in paths where !path.isEmpty {
            guard !path.hasPrefix("/"), !path.contains("\\") else { throw DownloadError.invalidArchive }
            let components = path.split(separator: "/")
            guard !components.contains(".."), !components.contains(".") else { throw DownloadError.invalidArchive }
        }
    }

    static func assertSafeArchiveTypes(_ types: [Character]) throws {
        guard types.allSatisfy({ $0 == "-" || $0 == "d" }) else {
            throw DownloadError.invalidArchive
        }
    }

    private static func extractSafely(_ archive: URL, to destination: URL) throws {
        let names = try runTar(arguments: ["-tjf", archive.path])
            .split(separator: "\n")
            .map(String.init)
        try assertSafeArchivePaths(names)

        let verbose = try runTar(arguments: ["-tvjf", archive.path])
        let entries = verbose.split(separator: "\n")
        try assertSafeArchiveTypes(entries.compactMap(\.first))

        _ = try runTar(arguments: ["-xjf", archive.path, "-C", destination.path, "--no-same-owner", "--no-same-permissions"])
    }

    private static func runTar(arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, let text = String(data: data, encoding: .utf8) else {
            throw DownloadError.invalidArchive
        }
        return text
    }

    private static func requiredFiles(for model: SherpaOnnxModel) -> [String] {
        switch model.family {
        case .moonshine:
            ["tokens.txt", "preprocess.onnx", "encode.int8.onnx", "uncached_decode.int8.onnx", "cached_decode.int8.onnx"]
        case .transducer:
            ["tokens.txt", "bpe.model", "encoder.int8.onnx", "decoder.onnx", "joiner.int8.onnx"]
        }
    }

    private static func archiveDirectory(for model: SherpaOnnxModel) -> String {
        model.archiveName.replacingOccurrences(of: ".tar.bz2", with: "")
    }

    private enum DownloadError: LocalizedError {
        case checksumMismatch
        case invalidArchive

        var errorDescription: String? {
            switch self {
            case .checksumMismatch:
                String(localized: "The downloaded speech model failed its SHA-256 check.")
            case .invalidArchive:
                String(localized: "The downloaded speech model archive is invalid.")
            }
        }
    }
}
