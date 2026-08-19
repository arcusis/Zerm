import Foundation
import SwiftData

enum TranscriptionStatus: String, Codable {
    case pending
    case completed
    case failed
}

@Model
final class Transcription {
    var id: UUID
    var text: String
    var enhancedText: String?
    var timestamp: Date
    var duration: TimeInterval
    var audioFileURL: String?
    var transcriptionModelName: String?
    var aiEnhancementModelName: String?
    var promptName: String?
    var transcriptionDuration: TimeInterval?
    var enhancementDuration: TimeInterval?
    var aiRequestSystemMessage: String?
    var aiRequestUserMessage: String?
    var powerModeName: String?
    var powerModeEmoji: String?
    var transcriptionStatus: String?

    /// What History and the list previews should show.
    ///
    /// `enhancedText` is optional, but a stored empty string is not the same as "no
    /// enhancement" — and `enhancedText ?? text` treats it as one, drawing a blank row over a
    /// perfectly good transcript. Records written by 2.8.3 are full of exactly that. Every
    /// reader goes through here so an empty enhancement can only ever fall back to the words
    /// the user actually said.
    var displayText: String {
        guard let enhancedText, !enhancedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return text
        }
        return enhancedText
    }

    /// True only when a real rewrite was stored, so an empty legacy value never shows an
    /// empty "Enhanced" tab or card.
    var hasEnhancement: Bool {
        guard let enhancedText else { return false }
        return !enhancedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    init(text: String,
         duration: TimeInterval,
         enhancedText: String? = nil,
         audioFileURL: String? = nil,
         transcriptionModelName: String? = nil,
         aiEnhancementModelName: String? = nil,
         promptName: String? = nil,
         transcriptionDuration: TimeInterval? = nil,
         enhancementDuration: TimeInterval? = nil,
         aiRequestSystemMessage: String? = nil,
         aiRequestUserMessage: String? = nil,
         powerModeName: String? = nil,
         powerModeEmoji: String? = nil,
         transcriptionStatus: TranscriptionStatus = .pending) {
        self.id = UUID()
        self.text = text
        self.enhancedText = enhancedText
        self.timestamp = Date()
        self.duration = duration
        self.audioFileURL = audioFileURL
        self.transcriptionModelName = transcriptionModelName
        self.aiEnhancementModelName = aiEnhancementModelName
        self.promptName = promptName
        self.transcriptionDuration = transcriptionDuration
        self.enhancementDuration = enhancementDuration
        self.aiRequestSystemMessage = aiRequestSystemMessage
        self.aiRequestUserMessage = aiRequestUserMessage
        self.powerModeName = powerModeName
        self.powerModeEmoji = powerModeEmoji
        self.transcriptionStatus = transcriptionStatus.rawValue
    }
}
