import Foundation

enum RecordingState: Equatable {
    case idle
    case starting
    case recording
    case transcribing
    case enhancing
    case generatingSpeech  // Read Aloud is running the on-device AI rewrite — widget shows "Thinking…"
    case preparingSpeech   // Read Aloud is synthesizing audio — widget shows "Preparing…"
    case speaking          // Read Aloud audio is playing — animated bars
    case busy
}
