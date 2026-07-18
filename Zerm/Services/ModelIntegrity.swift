import Foundation
import CryptoKit

/// Integrity pinning for downloaded model files.
///
/// Model weights are fetched over HTTPS from third-party hosts (Hugging Face) and then parsed
/// in-process by native C/C++ loaders (ggml / gguf) that have a history of memory-safety bugs.
/// TLS protects transit but not a compromised or swapped file at the source. We therefore pin
/// each catalog file to an immutable repo revision *and* to its SHA-256, and reject any
/// downloaded file whose hash doesn't match before it is loaded or extracted.
///
/// Hashes and the commit are captured at build time from the Hugging Face LFS pointers. Pinning
/// the URL to the same commit as the hash keeps this non-breaking: the bytes at a fixed revision
/// never change, so verification always passes for a genuine download. New model revisions ship
/// via app updates.
enum ModelIntegrity {

    // MARK: - Whisper (ggerganov/whisper.cpp)

    /// Repo revision the whisper hashes below correspond to. Also used to build download URLs.
    static let whisperRepoCommit = "5359861c739e955e79d9a303bcbc70fb988958b1"

    /// SHA-256 of each pinned `<name>.bin`, keyed by model name.
    static let whisperSHA256: [String: String] = [
        "ggml-tiny": "be07e048e1e599ad46341c8d2a135645097a538221678b7acdd1b1919c6e1b21",
        "ggml-tiny.en": "921e4cf8686fdd993dcd081a5da5b6c365bfde1162e72b08d75ac75289920b1f",
        "ggml-base": "60ed5bc3dd14eea856493d334349b405782ddcaf0028d4b5df4088345fba2efe",
        "ggml-base.en": "a03779c86df3323075f5e796cb2ce5029f00ec8869eee3fdfb897afe36c6d002",
        "ggml-small": "1be3a9b2063867b937e64e2ec7483364a79917e157fa98c5d94b5c1fffea987b",
        "ggml-small.en": "c6138d6d58ecc8322097e0f987c32f1be8bb0a18532a3f88f734d1bbf9c41e5d",
        "ggml-large-v3-turbo": "1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69",
        "ggml-large-v3-turbo-q5_0": "394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2"
    ]

    // MARK: - Verification

    /// Streams a file through SHA-256 without loading it (models are up to gigabytes).
    static func sha256(ofFileAt url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            guard let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// True if the file matches the expected hash, or if there is no pinned hash (`expected` is
    /// nil/empty) — so files without a pin keep working unchanged.
    static func verify(fileURL: URL, expectedSHA256 expected: String?) -> Bool {
        guard let expected, !expected.isEmpty else { return true }
        guard let actual = sha256(ofFileAt: fileURL) else { return false }
        return actual.caseInsensitiveCompare(expected) == .orderedSame
    }
}
