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

    static let distilLargeV3 = PinnedFile(
        repository: "distil-whisper/distil-large-v3-ggml",
        commit: "0d78dd96ed9fc152325f63b53788fec3b43de031",
        fileName: "ggml-distil-large-v3.bin"
    )

    static let fluidAudioCommits: [String: String] = [
        "parakeet-tdt-0.6b-v2": "ee09c569f73759e6d44c9bd16766f477b2b36d39",
        "parakeet-tdt-0.6b-redux": "8c5ef97a29cd120dc76b354b3f22b7fec3b486f9",
        "parakeet-tdt-0.6b-v3": "7dd20fe6b1797d35f5e3307e8b1732d9a178edfe",
        "parakeet-tdt-0.6b-ultra": "95eaa59a39d4394f047a4dc5cce480388a60d1b6",
        "parakeet-unified-en-0.6b": "d32e972dd4315f1dc3f6be28fb2aab0ab3e80358",
        "parakeet-tdt-ctc-110m": "9bc92ead6e8f17eca92a869fd578ae76842b82ba"
    ]

    /// HF LFS SHA-256 pins for primary FluidAudio encoder weights, queried from the repo tree API.
    static let fluidAudioSHA256: [String: String] = [
        "parakeet-tdt-0.6b-v2": "4adc7ad44f9d05e1bffeb2b06d3bb02861a5c7602dff63a6b494aed3bf8a6c3e",
        "parakeet-tdt-0.6b-redux": "adbb5550dc6488717d3a1407b53122fbdb1af5e99c330ee20f8d8cfd9ec49252"
    ]

    /// HF LFS SHA-256 values for every binary file in the newly catalogued FluidAudio packages.
    static let fluidAudioLFSFileSHA256: [String: [String: String]] = [
        "parakeet-tdt-0.6b-v2": [
            "Decoder.mlmodelc/analytics/coremldata.bin": "46de1a6fe2e49d19a2125bc91acf020df7f2aea84ba821532aade8427a440b05",
            "Decoder.mlmodelc/coremldata.bin": "d200ca07694a347f6d02a3886a062ae839831e094e443222f2e48a14945966a8",
            "Decoder.mlmodelc/weights/weight.bin": "27d26890221d82322c1092fd99d7b40578e435d5cf4b83c887c42603caf97aba",
            "Encoder.mlmodelc/analytics/coremldata.bin": "42e638870d73f26b332918a3496ce36793fbb413a81cbd3d16ba01328637a105",
            "Encoder.mlmodelc/coremldata.bin": "4def7aa848599ad0e17a8b9a982edcdbf33cf92e1f4b798de32e2ca0bc74b030",
            "Encoder.mlmodelc/weights/weight.bin": "4adc7ad44f9d05e1bffeb2b06d3bb02861a5c7602dff63a6b494aed3bf8a6c3e",
            "JointDecision.mlmodelc/analytics/coremldata.bin": "f1183ba213bb94a918c8d2cad19ab045320618f97f6ca662245b3936d7b090f7",
            "JointDecision.mlmodelc/coremldata.bin": "e2c6752f1c8cf2d3f6f26ec93195c9bfa759ad59edf9f806696a138154f96f11",
            "JointDecision.mlmodelc/weights/weight.bin": "ca22a65903a05e64137677da608077578a8606090a598abf4875fa6199aaa19d",
            "Melspectogram.mlmodelc/analytics/coremldata.bin": "6271a1b89644607c3ab203f79b33c86a286c041c75cb9c203332322223a398d3"
        ],
        "parakeet-tdt-0.6b-redux": [
            "Decoder.mlmodelc/analytics/coremldata.bin": "7f24e7248d57024c6f1c5a2ea306f4a6a89db45a363218523bb6410c4b1aecf0",
            "Decoder.mlmodelc/coremldata.bin": "422da51d983e93a3e48cd6d46a17d6c32844452414c8e242fb0caaca2b8af5ed",
            "Decoder.mlmodelc/weights/weight.bin": "6c6c88c23ee5492a6b229e8cc636ddadb2b01ae0dd559d9cb63123bebf507d77",
            "Encoder.mlmodelc/analytics/coremldata.bin": "7862e972e09315df099d4bfd320743bf106acbf7fe4343317f9de45b0635d7b7",
            "Encoder.mlmodelc/coremldata.bin": "ca0b212fe3c06c3ccd35e508fa61e4dfaad19dd0c55b82e4f5bf8711e7758fd9",
            "Encoder.mlmodelc/weights/weight.bin": "adbb5550dc6488717d3a1407b53122fbdb1af5e99c330ee20f8d8cfd9ec49252",
            "JointDecisionv3.mlmodelc/analytics/coremldata.bin": "fc857a756b8c9c9f31aa9e1062766cc0a82ac035ef369d6e1cbe97184921479c",
            "JointDecisionv3.mlmodelc/coremldata.bin": "611ea653e2adede7cc1cfe70da36296844f97e95e2c7dd961d45230e5599389d",
            "JointDecisionv3.mlmodelc/weights/weight.bin": "73b0288acd115fc4c36038f66b6cbf49233182488febf5d8c787bea4009535f7",
            "Preprocessor.mlmodelc/analytics/coremldata.bin": "c9beeb989c8d66f8be11df59bc6df277ec76cee404f6865b46243835ef562f6d",
            "Preprocessor.mlmodelc/coremldata.bin": "dbde3f2300842c1fd51ef3ff948a0bcffe65ffd2dca10707f2509f32c1d65b1d",
            "Preprocessor.mlmodelc/weights/weight.bin": "129b76e3aeafa8afa3ea76d995b964b145fe83700d579f6ff42c4c38fa0968ea"
        ]
    ]

    /// SHA-256 of each pinned `<name>.bin`, keyed by model name.
    static let whisperSHA256: [String: String] = [
        "ggml-tiny": "be07e048e1e599ad46341c8d2a135645097a538221678b7acdd1b1919c6e1b21",
        "ggml-tiny.en": "921e4cf8686fdd993dcd081a5da5b6c365bfde1162e72b08d75ac75289920b1f",
        "ggml-base": "60ed5bc3dd14eea856493d334349b405782ddcaf0028d4b5df4088345fba2efe",
        "ggml-base.en": "a03779c86df3323075f5e796cb2ce5029f00ec8869eee3fdfb897afe36c6d002",
        "ggml-small": "1be3a9b2063867b937e64e2ec7483364a79917e157fa98c5d94b5c1fffea987b",
        "ggml-small.en": "c6138d6d58ecc8322097e0f987c32f1be8bb0a18532a3f88f734d1bbf9c41e5d",
        "ggml-medium": "6c14d5adee5f86394037b4e4e8b59f1673b6cee10e3cf0b11bbdbee79c156208",
        "ggml-medium.en": "cc37e93478338ec7700281a7ac30a10128929eb8f427dda2e865faa8f6da4356",
        "ggml-large-v2": "9a423fe4d40c82774b6af34115b8b935f34152246eb19e80e376071d3f999487",
        "ggml-large-v2-q5_0": "3a214837221e4530dbc1fe8d734f302af393eb30bd0ed046042ebf4baf70f6f2",
        "ggml-large-v2-q8_0": "fef54e6d898246a65c8285bfa83bd1807e27fadf54d5d4e81754c47634737e8c",
        "ggml-large-v3": "64d182b440b98d5203c4f9bd541544d84c605196c4f7b845dfa11fb23594d1e2",
        "ggml-large-v3-q5_0": "d75795ecff3f83b5faa89d1900604ad8c780abd5739fae406de19f23ecd98ad1",
        "ggml-large-v3-turbo-q8_0": "317eb69c11673c9de1e1f0d459b253999804ec71ac4c23c17ecf5fbe24e259a1",
        "ggml-medium-q5_0": "19fea4b380c3a618ec4723c3eef2eb785ffba0d0538cf43f8f235e7b3b34220f",
        "ggml-medium-q8_0": "42a1ffcbe4167d224232443396968db4d02d4e8e87e213d3ee2e03095dea6502",
        "ggml-medium.en-q5_0": "76733e26ad8fe1c7a5bf7531a9d41917b2adc0f20f2e4f5531688a8c6cd88eb0",
        "ggml-medium.en-q8_0": "43fa2cd084de5a04399a896a9a7a786064e221365c01700cea4666005218f11c",
        "ggml-tiny-q8_0": "c2085835d3f50733e2ff6e4b41ae8a2b8d8110461e18821b09a15c40c42d1cca",
        "ggml-tiny.en-q8_0": "5bc2b3860aa151a4c6e7bb095e1fcce7cf12c7b020ca08dcec0c6d018bb7dd94",
        "ggml-base-q8_0": "c577b9a86e7e048a0b7eada054f4dd79a56bbfa911fbdacf900ac5b567cbb7d9",
        "ggml-base.en-q8_0": "a4d4a0768075e13cfd7e19df3ae2dbc4a68d37d36a7dad45e8410c9a34f8c87e",
        "ggml-small-q8_0": "49c8fb02b65e6049d5fa6c04f81f53b867b5ec9540406812c643f177317f779f",
        "ggml-small.en-q8_0": "67a179f608ea6114bd3fdb9060e762b588a3fb3bd00c4387971be4d177958067",
        "ggml-large-v3-turbo": "1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69",
        "ggml-large-v3-turbo-q5_0": "394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2",
        "ggml-distil-large-v3": "2883a11b90fb10ed592d826edeaee7d2929bf1ab985109fe9e1e7b4d2b69a298",
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
