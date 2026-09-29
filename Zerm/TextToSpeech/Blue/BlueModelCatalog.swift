import Foundation

struct BlueModelFile: Sendable {
    let path: String
    let url: URL
    let sha256: String
    let revision: String
}

enum BlueModelCatalog {
    static let modelRevision = "45dc85f1ac045ea62458a7492c5ae387610ac0af"
    static let renikudRevision = "a59c632c8cbac0f8c63f298cad77ef3a3a2547c9"
    static let espeakRevision = "f6fed6c58b5e0998b8e68c6610125e2d07d595a7"
    private static let espeakHost = "https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/"
    private static let codeRevision = "0e38dbf08ed53f85863d1eab092bd9572c53a503"
    private static let modelHost = "https://huggingface.co/notmax123/blue-onnx-v2/resolve/\(modelRevision)/"
    private static let codeHost = "https://raw.githubusercontent.com/maxmelichov/BlueTTS/\(codeRevision)/"
    private static let g2pHost = "https://huggingface.co/renikud/renikud/resolve/\(renikudRevision)/"

    static let files: [BlueModelFile] = [
        file("duration_predictor.onnx", "1fb897a3f1c5f4132ffba3e56c5792f8c03783e2f478d825774514da668af161", modelHost),
        file("text_encoder.onnx", "9f80f87093067ee2300343133b0456e36d705eea31f523f9d3dc9f4c5e212db1", modelHost),
        file("vector_estimator.onnx", "8c333ef2eb0c075136384eaa9608a374230f1b26e8181097467b803078095a5a", modelHost),
        file("vocoder.onnx", "f4fbb6f60dec035cd8071883e021ac2cd3eee62630e42174492fd2d1f39976db", modelHost),
        file("tts.json", "9afc8622ee9a40adff8befdc6bdfcb3c008f8caed9750febe870e53f47a73a0a", modelHost),
        file("vocab.json", "9c5ce360977b8b70423a782519bc067681863aae54768105e5aa0fed9f02520d", modelHost),
        file("voices/female1.json", "22e6c98210ca014cfd40bd485152a58c49bfff32265faff8c1c47cb4d60e1872", modelHost),
        file("renikud/model.onnx", "8b881a3a8f00283d86c6d1feea44d37e09c1ea6609a4de7d820d937e7f3dbbca", g2pHost, source: "model.onnx"),
    ]

    static let espeakDataArchive = BlueModelFile(
        path: "espeak-ng-data.tar.bz2",
        url: URL(string: espeakHost + "espeak-ng-data.tar.bz2")!,
        sha256: "4135ccf82e1f40613491c0874d4945ae9e9c7840933d8e25a6f9e003d9ebf533",
        revision: espeakRevision
    )

    static let provenance = ModelProvenance(
        creator: String(localized: "BlueTTS, Renikud, and eSpeak NG contributors"),
        sourceURL: URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/tag/tts-models")!,
        downloadHost: "github.com",
        licenseName: String(localized: "MIT, CC-BY-4.0, and GPL-3.0-or-later"),
        licenseSPDX: "MIT AND CC-BY-4.0 AND GPL-3.0-or-later",
        licenseURL: URL(string: "https://github.com/csukuangfj/espeak-ng/blob/f6fed6c58b5e0998b8e68c6610125e2d07d595a7/COPYING")!,
        attribution: "Blue v2 ONNX weights and BlueTTS code © BlueTTS contributors, MIT. Hebrew G2P model © Renikud contributors, CC-BY-4.0. eSpeak NG pronunciation data built from csukuangfj/espeak-ng commit f6fed6c58b5e0998b8e68c6610125e2d07d595a7; © eSpeak NG contributors, GPL-3.0-or-later.",
        conversionCredit: "BlueTTS",
        checksumSHA256: nil
    )

    private static func file(_ path: String, _ sha: String, _ base: String, source: String? = nil) -> BlueModelFile {
        let remotePath = source ?? path
        return BlueModelFile(
            path: path,
            url: URL(string: base + remotePath)!,
            sha256: sha,
            revision: base == codeHost ? codeRevision : (base == g2pHost ? renikudRevision : modelRevision)
        )
    }
}
