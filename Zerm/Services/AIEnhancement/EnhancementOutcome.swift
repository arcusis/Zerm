import Foundation
import LLMkit

/// Everything an enhancement can end in. Every case except `.enhanced` means the user's own
/// text is what they get, and every one of those is recorded and — where the user expected
/// enhancement — shown.
enum EnhancementOutcome: Equatable {
    case enhanced(text: String, duration: TimeInterval)
    case skipped(EnhancementSkipReason)
    case failed(EnhancementFailure)
    case rejected(EnhancementRejection)
    case cancelled
}

enum EnhancementSkipReason: Equatable {
    /// The user's "Skip short transcriptions" setting. Deliberate, so never notified.
    case shortTranscription
    case notConfigured(EnhancementUnavailableReason)
}

enum EnhancementFailure: Error, Equatable {
    case providerUnreachable(AIProvider)
    case timeout
    case emptyResponse
    case network
    case server
    case rateLimited
    case other(String)

    /// Worth another attempt after a short wait.
    var isTransient: Bool {
        switch self {
        case .network, .server, .rateLimited: return true
        default: return false
        }
    }

    init(_ error: Error) {
        switch error {
        case let failure as EnhancementFailure:
            self = failure
        case let error as LLMKitError:
            switch error {
            case .timeout: self = .timeout
            case .networkError: self = .network
            case .noResultReturned: self = .emptyResponse
            case .httpError(let statusCode, let message):
                if statusCode == 429 {
                    self = .rateLimited
                } else if (500...599).contains(statusCode) {
                    self = .server
                } else {
                    self = .other("HTTP \(statusCode): \(message)")
                }
            case .missingAPIKey, .invalidURL, .unsupportedModel, .decodingError, .encodingError:
                self = .other(error.localizedDescription)
            }
        default:
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorTimedOut {
                self = .timeout
            } else if nsError.domain == NSURLErrorDomain,
                      [NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost, NSURLErrorCannotConnectToHost].contains(nsError.code) {
                self = .network
            } else {
                self = .other(error.localizedDescription)
            }
        }
    }
}

enum EnhancementRejection: String, Equatable {
    /// The result grew or dropped a writing system — a translation of mixed dictation.
    case languageChanged
    /// The model introduced itself instead of cleaning the text.
    case selfIntroduction
    /// Far longer than any cleanup of the input could be.
    case tooLong
}

/// What History stores about an enhancement.
enum EnhancementRecordState: String {
    case enhanced
    case skipped
    case failed
    case rejected
}

extension EnhancementOutcome {
    var recordState: EnhancementRecordState? {
        switch self {
        case .enhanced: return .enhanced
        case .skipped: return .skipped
        case .failed: return .failed
        case .rejected: return .rejected
        case .cancelled: return nil
        }
    }

    /// A stable, English reason code for History and diagnostics.
    var recordReason: String? {
        switch self {
        case .enhanced, .cancelled:
            return nil
        case .skipped(.shortTranscription):
            return "shortTranscription"
        case .skipped(.notConfigured(let reason)):
            return "notConfigured:\(reason)"
        case .failed(.other(let message)):
            return "other: \(message)"
        case .failed(let failure):
            return "\(failure)"
        case .rejected(let rejection):
            return rejection.rawValue
        }
    }
}

extension Transcription {
    var enhancementRecordState: EnhancementRecordState? {
        enhancementOutcome.flatMap(EnhancementRecordState.init(rawValue:))
    }

    /// Stores how an enhancement ended. Only `.enhanced` writes `enhancedText`: a skipped, failed
    /// or rejected enhancement must never put the raw transcript — or an error — where History
    /// shows the enhancement.
    ///
    /// - Parameter finalize: Applied to the enhanced text before it is stored, so the user's
    ///   lowercase and punctuation preferences hold for the AI's output too.
    func record(
        _ outcome: EnhancementOutcome,
        of request: EnhancementRequest?,
        finalize: (String) -> String = { $0 }
    ) {
        guard let state = outcome.recordState else { return }
        enhancementOutcome = state.rawValue
        enhancementOutcomeReason = outcome.recordReason
        if let request {
            aiRequestSystemMessage = request.systemMessage
            aiRequestUserMessage = request.userMessage
        }
        guard case .enhanced(let text, let duration) = outcome else {
            enhancedText = nil
            return
        }
        enhancedText = finalize(text)
        enhancementDuration = duration
        aiEnhancementModelName = request?.model
        promptName = request?.promptTitle
    }
}
