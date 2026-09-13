import Foundation

/// Makes every enhancement the user expected but did not get visible.
///
/// Dictation that silently pastes raw text while enhancement is switched on is indistinguishable
/// from enhancement being broken. Automatic dictation reports are rate-limited per reason, so a
/// provider that stays unconfigured produces one notification, not one per sentence. Manual
/// actions from History always report.
@MainActor
final class EnhancementNotifier {
    static let shared = EnhancementNotifier()

    struct Message: Equatable {
        let title: String
        /// Whether the fix lives in Enhancement settings.
        let opensSettings: Bool
    }

    private let present: @MainActor (Message) -> Void
    private let now: () -> Date
    private let quietPeriod: TimeInterval
    private var lastShown: [String: Date] = [:]

    init(
        quietPeriod: TimeInterval = 120,
        now: @escaping () -> Date = Date.init,
        present: @escaping @MainActor (Message) -> Void = EnhancementNotifier.showNotification
    ) {
        self.quietPeriod = quietPeriod
        self.now = now
        self.present = present
    }

    /// Returns whether a notification was shown.
    @discardableResult
    func report(_ outcome: EnhancementOutcome, purpose: EnhancementPurpose) -> Bool {
        guard let message = Self.message(for: outcome), let key = Self.rateLimitKey(for: outcome) else {
            return false
        }
        if purpose != .manual {
            let time = now()
            if let last = lastShown[key], time.timeIntervalSince(last) < quietPeriod {
                return false
            }
            lastShown[key] = time
        }
        present(message)
        return true
    }

    static func rateLimitKey(for outcome: EnhancementOutcome) -> String? {
        switch outcome {
        case .enhanced, .cancelled, .skipped(.shortTranscription): return nil
        case .skipped(.notConfigured): return "notConfigured"
        case .failed(.providerUnreachable): return "unreachable"
        case .failed(.timeout): return "timeout"
        case .failed: return "failed"
        case .rejected: return "rejected"
        }
    }

    static func message(for outcome: EnhancementOutcome) -> Message? {
        switch outcome {
        case .enhanced, .cancelled, .skipped(.shortTranscription):
            return nil
        case .skipped(.notConfigured(let reason)):
            return Message(title: title(for: reason), opensSettings: true)
        case .failed(.providerUnreachable(let provider)):
            return Message(
                title: String(localized: "Enhancement failed: \(provider.rawValue) is not running or cannot be reached. Your original text was kept."),
                opensSettings: true
            )
        case .failed(.timeout):
            return Message(
                title: String(localized: "Enhancement timed out. Your original text was kept."),
                opensSettings: false
            )
        case .failed(let failure):
            return Message(
                title: String(localized: "Enhancement failed: \(detail(for: failure)). Your original text was kept."),
                opensSettings: false
            )
        case .rejected:
            return Message(
                title: String(localized: "Enhancement discarded because it changed the language or the wording too much. Your original text was kept."),
                opensSettings: false
            )
        }
    }

    private static func title(for reason: EnhancementUnavailableReason) -> String {
        switch reason {
        case .onDeviceModelMissing(let modelName):
            return String(localized: "Enhancement skipped: download \(modelName) in Enhancement settings.")
        case .apiKeyMissing(let provider):
            return String(localized: "Enhancement skipped: add an API key for \(provider.rawValue) in Enhancement settings.")
        case .modelMissing(let provider):
            return String(localized: "Enhancement skipped: choose a model for \(provider.rawValue) in Enhancement settings.")
        case .endpointInvalid(let provider):
            return String(localized: "Enhancement skipped: check the server address for \(provider.rawValue) in Enhancement settings.")
        case .commandMissing:
            return String(localized: "Enhancement skipped: set up the Local CLI command in Enhancement settings.")
        case .transcriptionOnlyProvider(let provider):
            return String(localized: "Enhancement skipped: \(provider.rawValue) only transcribes. Choose an enhancement provider in Enhancement settings.")
        case .promptMissing:
            return String(localized: "Enhancement skipped: no enhancement prompt is available.")
        }
    }

    private static func detail(for failure: EnhancementFailure) -> String {
        switch failure {
        case .emptyResponse: return String(localized: "the AI returned no text")
        case .network: return String(localized: "no network connection")
        case .server: return String(localized: "the provider had a server error")
        case .rateLimited: return String(localized: "the provider's rate limit was reached")
        case .other(let message): return String(message.prefix(80))
        case .providerUnreachable, .timeout: return ""
        }
    }

    static func showNotification(_ message: Message) {
        guard message.opensSettings else {
            NotificationManager.shared.showNotification(title: message.title, type: .warning, duration: 5.0)
            return
        }
        NotificationManager.shared.showNotification(
            title: message.title,
            type: .warning,
            duration: 5.0,
            actionButton: (label: String(localized: "Open Enhancement"), action: {
                MenuBarManager.shared?.openMainWindowAndNavigate(to: "Enhancement")
            })
        )
    }
}
