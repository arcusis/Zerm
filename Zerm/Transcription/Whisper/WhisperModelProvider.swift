import Foundation
import SwiftData

/// Protocol that WhisperModelManager conforms to, decoupling TranscriptionServiceRegistry
/// and WhisperTranscriptionService from concrete manager types.
@MainActor
protocol WhisperModelProvider: AnyObject {
    /// Returns the resident context for the model named `name`, loading it once if needed.
    func loadModel(named name: String) async throws -> WhisperContext
}
