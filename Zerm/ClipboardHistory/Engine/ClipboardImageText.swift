import Foundation
import Vision

struct ClipboardImageText: Sendable {
    let recognizedText: String
    let barcodePayloads: [String]
}

enum ClipboardImageAnalyzer {
    /// Vision's `perform` blocks its thread until analysis finishes, so it runs on its own queue
    /// instead of a Swift concurrency thread; blocking those can starve the cooperative pool on
    /// Macs with few cores.
    private static let queue = DispatchQueue(label: "com.arcusis.zerm.clipboard-image-text", qos: .utility)

    static func analyze(_ imageData: Data) async -> ClipboardImageText {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: recognize(imageData))
            }
        }
    }

    private static func recognize(_ imageData: Data) -> ClipboardImageText {
        let textRequest = VNRecognizeTextRequest()
        textRequest.recognitionLevel = .accurate
        textRequest.usesLanguageCorrection = false
        let barcodeRequest = VNDetectBarcodesRequest()
        let handler = VNImageRequestHandler(data: imageData)
        guard (try? handler.perform([textRequest, barcodeRequest])) != nil else {
            return ClipboardImageText(recognizedText: "", barcodePayloads: [])
        }
        let recognized = (textRequest.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        let barcodes = (barcodeRequest.results ?? []).compactMap(\.payloadStringValue)
        return ClipboardImageText(recognizedText: recognized.joined(separator: "\n"), barcodePayloads: barcodes)
    }
}
