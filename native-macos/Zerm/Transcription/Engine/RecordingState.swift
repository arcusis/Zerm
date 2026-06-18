import Foundation

enum RecordingState: Equatable {
    case idle
    case starting
    case recording
    case transcribing
    case enhancing
    case speaking   // Read Aloud (TTS) is playing — reuses the recorder widget
    case busy
}
