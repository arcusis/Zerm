import Foundation

enum RecordingState: Equatable {
    case idle
    case starting
    case recording
    case transcribing
    case enhancing
    case preparingSpeech   // Read Aloud is synthesizing — widget shows a loading indicator
    case speaking          // Read Aloud audio is playing — animated bars
    case busy
}
