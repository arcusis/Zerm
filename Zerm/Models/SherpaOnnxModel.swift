import Foundation

enum SherpaOnnxModelFamily: Equatable {
    case moonshine
    case transducer
}

struct SherpaOnnxModel: LocalTranscriptionModel {
    let id = UUID()
    let name: String
    let displayName: String
    let description: String
    let provider: ModelProvider = .sherpaOnnx
    let size: String
    let speed: Double
    let accuracy: Double
    let estimatedRAMGB: Double
    let isMultilingualModel: Bool
    let supportedLanguages: [String: String]
    let family: SherpaOnnxModelFamily
    let archiveName: String
    let sha256: String
    let provenance: ModelProvenance?

    var runtime: LocalModelRuntime { .sherpaOnnx }
}
