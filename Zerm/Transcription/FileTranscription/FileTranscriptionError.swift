import Foundation

/// Why a file transcription job failed, phrased for the person who dropped the file.
enum FileTranscriptionError: Error, Equatable, Sendable {
    case unsupportedFile
    case noAudio
    case unreadableFile
    case noModelSelected
    case modelUnavailable(String)
    case cloudKeyMissing(String)
    case network
    case noSpeech
    case failed(String)

    var message: String {
        switch self {
        case .unsupportedFile:
            return String(localized: "This file type is not supported. Add an audio or video file.")
        case .noAudio:
            return String(localized: "This file has no audio to transcribe.")
        case .unreadableFile:
            return String(localized: "The audio in this file could not be read.")
        case .noModelSelected:
            return String(localized: "Choose a transcription model first.")
        case .modelUnavailable(let model):
            return String(localized: "\(model) is not downloaded or could not be loaded. Download it in Dictation Models.")
        case .cloudKeyMissing(let model):
            return String(localized: "\(model) needs a valid API key. Add one in Dictation Models.")
        case .network:
            return String(localized: "The cloud service could not be reached. Check your connection and retry.")
        case .noSpeech:
            return String(localized: "No speech was recognized in this file.")
        case .failed(let detail):
            return String(localized: "Transcription failed: \(detail)")
        }
    }

    /// Maps errors from conversion, the transcription services and persistence. `modelName` is
    /// the display name of the job's model, used in model and key messages.
    init(_ error: Error, modelName: String) {
        switch error {
        case let error as FileTranscriptionError:
            self = error
        case let error as AudioFileConverter.ConversionError:
            switch error {
            case .unreadable: self = .unreadableFile
            case .emptyAudio: self = .noAudio
            }
        case let error as CloudTranscriptionError:
            switch error {
            case .missingAPIKey, .invalidAPIKey:
                self = .cloudKeyMissing(modelName)
            case .apiRequestFailed(let statusCode, _) where statusCode == 401 || statusCode == 403:
                self = .cloudKeyMissing(modelName)
            case .networkError:
                self = .network
            default:
                self = .failed(error.localizedDescription)
            }
        case let error as URLError where Self.networkCodes.contains(error.code):
            self = .network
        case ZermEngineError.modelLoadFailed:
            self = .modelUnavailable(modelName)
        default:
            self = .failed(error.localizedDescription)
        }
    }

    private static let networkCodes: Set<URLError.Code> = [
        .notConnectedToInternet, .timedOut, .networkConnectionLost, .cannotFindHost,
        .cannotConnectToHost, .dnsLookupFailed, .internationalRoamingOff, .dataNotAllowed
    ]
}
