import SwiftUI

enum TranscriptionTab: String, CaseIterable {
    case original = "Original"
    case enhanced = "Enhanced"

    var title: LocalizedStringKey {
        switch self {
        case .original: return "Original"
        case .enhanced: return "Enhanced"
        }
    }
}
