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

    /// A file at an immutable Hugging Face revision.
    struct PinnedFile: Hashable {
        let repository: String
        let commit: String
        let fileName: String

        var downloadURL: String {
            "https://huggingface.co/\(repository)/resolve/\(commit)/\(fileName)"
        }

        static func whisperCpp(fileName: String) -> PinnedFile {
            PinnedFile(repository: "ggerganov/whisper.cpp", commit: whisperRepoCommit, fileName: fileName)
        }
    }

    // MARK: - Whisper (ggerganov/whisper.cpp)

    /// Repo revision the whisper hashes below correspond to. Also used to build download URLs.
    static let whisperRepoCommit = "5359861c739e955e79d9a303bcbc70fb988958b1"

    // MARK: - ivrit.ai Hebrew fine-tunes (whisper.cpp ggml conversions by ivrit.ai)

    static let ivritLargeV3Turbo = PinnedFile(
        repository: "ivrit-ai/whisper-large-v3-turbo-ggml",
        commit: "2130c78e4a9cb4914cc4df91a1c3031407789705",
        fileName: "ggml-model.bin"
    )

    static let ivritLargeV3 = PinnedFile(
        repository: "ivrit-ai/whisper-large-v3-ggml",
        commit: "9ead614052ce13dfe5f8d0f6cd3e36787a9cf60c",
        fileName: "ggml-model.bin"
    )

    /// SHA-256 of each pinned `<name>.bin`, keyed by model name.
    static let whisperSHA256: [String: String] = [
        "ggml-large-v3-turbo": "1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69",
        "ggml-large-v3-turbo-q5_0": "394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2",
        "ivrit-large-v3-turbo": "c8090411113357097bfafc2b8e228ec1639fa7f5fe4ecb5d054ac0ccef8641b1",
        "ivrit-large-v3": "09e66ec67b2e00c6933afab6684cbf78fe023e8ad153c1848f62000e4335a07f"
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
