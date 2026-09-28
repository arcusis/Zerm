import Foundation
import Vision

struct ClipboardImageText: Sendable {
    let recognizedText: String
    let barcodePayloads: [String]
}

enum ClipboardImageAnalyzer {
    static func analyze(_ imageData: Data) async -> ClipboardImageText {
        await Task.detached(priority: .utility) {
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
        }.value
    }
}
