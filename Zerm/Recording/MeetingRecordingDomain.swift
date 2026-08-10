import AudioToolbox
import Foundation

/// A physical or logical stream that belongs to a meeting.
///
/// Sources are never mixed in memory. They retain their identity through capture, transcription,
/// diarization, persistence and playback so two independent clocks cannot accidentally become one
/// longer, synthetic conversation.
enum MeetingAudioSource: String, Codable, CaseIterable, Hashable, Sendable {
    case microphone
    case systemAudio
    case imported

    var displayName: String {
        switch self {
        case .microphone: return String(localized: "Room")
        case .systemAudio: return String(localized: "Call")
        case .imported: return String(localized: "Imported audio")
        }
    }
}

/// Which process the remote-audio tap is allowed to hear.
enum MeetingCaptureTarget: Codable, Equatable, Sendable {
    case application(bundleID: String, appName: String, processID: Int32)
    case allSystemAudio

    private enum CodingKeys: String, CodingKey { case kind, bundleID, appName, processID }
    private enum Kind: String, Codable { case application, allSystemAudio }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .application:
            self = .application(
                bundleID: try container.decode(String.self, forKey: .bundleID),
                appName: try container.decode(String.self, forKey: .appName),
                processID: try container.decode(Int32.self, forKey: .processID)
            )
        case .allSystemAudio:
            self = .allSystemAudio
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .application(let bundleID, let appName, let processID):
            try container.encode(Kind.application, forKey: .kind)
            try container.encode(bundleID, forKey: .bundleID)
            try container.encode(appName, forKey: .appName)
            try container.encode(processID, forKey: .processID)
        case .allSystemAudio:
            try container.encode(Kind.allSystemAudio, forKey: .kind)
        }
    }
}

/// Immutable routing metadata captured before a meeting starts.
///
/// The actual model value is retained privately by the controller for inference. This Codable
/// representation is deliberately sufficient to explain and reproduce what happened later.
struct MeetingTranscriptionSnapshot: Codable, Equatable, Sendable {
    enum Route: String, Codable, Sendable { case local, cloud }

    let modelName: String
    let modelDisplayName: String
    let provider: ModelProvider
    let languageCode: String
    let route: Route

    init(
        model: any TranscriptionModel,
        languageCode: String,
        locale: Locale = .current
    ) {
        modelName = model.name
        modelDisplayName = model.displayName
        provider = model.provider
        self.languageCode = MeetingLanguageResolver.canonicalCode(
            provider: model.provider,
            requestedCode: languageCode,
            locale: locale
        )
        switch model.provider {
        case .whisper, .fluidAudio, .nativeApple:
            route = .local
        default:
            route = .cloud
        }
    }

    /// Creates a snapshot from a provider-validated language contract. Native Apple meetings use
    /// this after querying SpeechTranscriber's runtime locales, so review never re-resolves a
    /// persisted `auto` value against a different machine or locale.
    init(model: any TranscriptionModel, resolvedLanguageCode: String) {
        modelName = model.name
        modelDisplayName = model.displayName
        provider = model.provider
        languageCode = resolvedLanguageCode
        switch model.provider {
        case .whisper, .fluidAudio, .nativeApple:
            route = .local
        default:
            route = .cloud
        }
    }
}

/// Canonicalizes the provider-neutral language preference into the contract a provider can
/// actually honor. Durable meeting jobs persist this result, not a mutable locale-dependent
/// sentinel, so a later locale or Settings change cannot alter review/reprocessing behavior.
enum MeetingLanguageResolver {
    /// Resolves a meeting's Native Apple locale against the exact runtime capability set.
    /// Explicit unsupported languages fail closed instead of silently switching languages.
    static func nativeAppleMeetingLocaleCode(
        requestedCode: String,
        supportedIdentifiers: [String],
        locale: Locale = .current
    ) -> String? {
        let supported = Array(Set(supportedIdentifiers)).sorted()
        guard !supported.isEmpty else { return nil }
        let requested = requestedCode.isEmpty ? LanguagePreference.autoCode : requestedCode

        if requested != LanguagePreference.autoCode {
            if let exact = exactNativeAppleLocaleCode(
                requestedCode: requested,
                supportedIdentifiers: supported
            ) {
                return exact
            }
            let language = Locale(identifier: requested).language.languageCode?.identifier
            let candidates = supported.filter {
                Locale(identifier: $0).language.languageCode?.identifier == language
            }
            guard !candidates.isEmpty else { return nil }
            return preferredNativeAppleLocale(from: candidates, language: language, locale: locale)
        }

        let currentIdentifier = locale.identifier(.bcp47)
        if let exact = exactNativeAppleLocaleCode(
            requestedCode: currentIdentifier,
            supportedIdentifiers: supported
        ) {
            return exact
        }
        let currentLanguage = locale.language.languageCode?.identifier
        let candidates = supported.filter {
            Locale(identifier: $0).language.languageCode?.identifier == currentLanguage
        }
        if !candidates.isEmpty {
            return preferredNativeAppleLocale(from: candidates, language: currentLanguage, locale: locale)
        }
        return supported.first(where: { $0.caseInsensitiveCompare("en-US") == .orderedSame })
            ?? supported[0]
    }

    static func exactNativeAppleLocaleCode(
        requestedCode: String,
        supportedIdentifiers: [String]
    ) -> String? {
        supportedIdentifiers.first {
            $0.caseInsensitiveCompare(requestedCode) == .orderedSame
        }
    }

    private static func preferredNativeAppleLocale(
        from candidates: [String],
        language: String?,
        locale: Locale
    ) -> String {
        let currentIdentifier = locale.identifier(.bcp47)
        if let current = candidates.first(where: {
            $0.caseInsensitiveCompare(currentIdentifier) == .orderedSame
        }) {
            return current
        }
        let conventional: [String: String] = [
            "ar": "ar-SA", "de": "de-DE", "en": "en-US", "es": "es-ES",
            "fr": "fr-FR", "it": "it-IT", "ja": "ja-JP", "ko": "ko-KR",
            "pt": "pt-BR", "yue": "yue-CN", "zh": "zh-CN",
        ]
        if let preferred = language.flatMap({ conventional[$0] }),
           let match = candidates.first(where: {
               $0.caseInsensitiveCompare(preferred) == .orderedSame
           }) {
            return match
        }
        return candidates.sorted()[0]
    }

    static func canonicalCode(
        provider: ModelProvider,
        requestedCode: String,
        locale: Locale = .current
    ) -> String {
        let requested = requestedCode.isEmpty ? LanguagePreference.autoCode : requestedCode
        switch provider {
        case .nativeApple:
            return nativeAppleLocaleCode(
                requestedCode: requested,
                supportedIdentifiers: Array(LanguageDictionary.appleNative.keys),
                locale: locale
            )
        case .fluidAudio:
            // FluidAudio's multilingual ASR chooses the spoken language internally and exposes no
            // supported language constraint. Persisting an explicit code would falsely claim that
            // inference was forced to that language.
            return LanguagePreference.autoCode
        default:
            return requested
        }
    }

    static func nativeAppleLocaleCode(
        requestedCode: String,
        supportedIdentifiers: [String],
        locale: Locale = .current
    ) -> String {
        let supported = Array(Set(supportedIdentifiers)).sorted()
        guard !supported.isEmpty else { return "en-US" }

        if requestedCode != LanguagePreference.autoCode, !requestedCode.isEmpty {
            if let exact = supported.first(where: {
                $0.caseInsensitiveCompare(requestedCode) == .orderedSame
            }) {
                return exact
            }
            let requestedLanguage = Locale(identifier: requestedCode).language.languageCode?.identifier
            let candidates = supported.filter {
                Locale(identifier: $0).language.languageCode?.identifier == requestedLanguage
            }
            if !candidates.isEmpty {
                let currentIdentifier = locale.identifier(.bcp47)
                if let current = candidates.first(where: {
                    $0.caseInsensitiveCompare(currentIdentifier) == .orderedSame
                }) {
                    return current
                }
                let conventional: [String: String] = [
                    "ar": "ar-SA", "de": "de-DE", "en": "en-US", "es": "es-ES",
                    "fr": "fr-FR", "it": "it-IT", "ja": "ja-JP", "ko": "ko-KR",
                    "pt": "pt-BR", "yue": "yue-CN", "zh": "zh-CN",
                ]
                if let preferred = requestedLanguage.flatMap({ conventional[$0] }),
                   candidates.contains(preferred) {
                    return preferred
                }
                return candidates[0]
            }
        }

        let currentIdentifier = locale.identifier(.bcp47)
        if let exactCurrent = supported.first(where: {
            $0.caseInsensitiveCompare(currentIdentifier) == .orderedSame
        }) {
            return exactCurrent
        }
        let currentLanguage = locale.language.languageCode?.identifier
        if let sameLanguage = supported.first(where: {
            Locale(identifier: $0).language.languageCode?.identifier == currentLanguage
        }) {
            return sameLanguage
        }
        return supported.contains("en-US") ? "en-US" : supported[0]
    }
}

/// The local engine selected for meeting summarization. Meeting text is never routed to the
/// mutable cloud enhancement provider; a future cloud summary would require a separate explicit
/// authorization and a different route value.
struct MeetingSummarySnapshot: Codable, Equatable, Sendable {
    enum Route: String, Codable, Sendable { case local }

    let provider: String
    let model: String
    let route: Route

    static var configuredOllama: MeetingSummarySnapshot {
        .init(
            provider: "Ollama",
            model: UserDefaults.standard.string(forKey: "ollamaSelectedModel") ?? "mistral",
            route: .local
        )
    }
}

/// One capture delivery positioned on the meeting's monotonic clock.
struct MeetingAudioChunk: @unchecked Sendable {
    let sessionID: UUID
    let source: MeetingAudioSource
    let timestamp: TimeInterval
    let sampleRate: Double
    let frameCount: Int
    let data: Data

    var duration: TimeInterval { Double(frameCount) / sampleRate }
    var end: TimeInterval { timestamp + duration }
}

/// Raw backend delivery with the timestamp supplied by Core Audio, before it is placed on the
/// meeting timeline. `hostTimeNanos` is shared across devices; `sampleTime` is retained for
/// diagnosing source-clock discontinuities and drift.
struct MeetingCaptureDelivery: @unchecked Sendable {
    let source: MeetingAudioSource
    let data: Data
    let hostTimeNanos: UInt64?
    let sampleTime: Double?
    let sourceSampleRate: Double
    let frameCount: Int
}

/// A hole in one source's file-frame stream, ordered between accepted capture deliveries.
struct MeetingCaptureDiscontinuity: Sendable {
    let source: MeetingAudioSource
    let droppedFrames: Int64
    let hostTimeNanos: UInt64?
    let sourceSampleTime: Double?
    let sourceSampleRate: Double
}

struct MeetingClockAnchor: Codable, Equatable, Sendable {
    let fileFrame: Int64
    let meetingTime: TimeInterval
    let hostTimeNanos: UInt64?
    let sourceSampleTime: Double?
}

enum MeetingTrackClock {
    private static func fileOrdered(_ anchors: [MeetingClockAnchor]) -> [MeetingClockAnchor] {
        anchors.sorted { lhs, rhs in
            if lhs.fileFrame == rhs.fileFrame { return lhs.meetingTime < rhs.meetingTime }
            return lhs.fileFrame < rhs.fileFrame
        }
    }

    static func containsAudio(
        atMeetingTime meetingTime: TimeInterval,
        fileDuration: TimeInterval,
        sampleRate: Double = 16_000,
        anchors: [MeetingClockAnchor]
    ) -> Bool {
        guard !anchors.isEmpty else { return meetingTime >= 0 && meetingTime < fileDuration }
        let ordered = fileOrdered(anchors)
        guard meetingTime >= ordered[0].meetingTime else { return false }
        for index in ordered.indices {
            let anchor = ordered[index]
            let nextFrame = index + 1 < ordered.count
                ? ordered[index + 1].fileFrame
                : Int64(fileDuration * sampleRate)
            let audioEnd = anchor.meetingTime
                + Double(max(0, nextFrame - anchor.fileFrame)) / sampleRate
            if meetingTime >= anchor.meetingTime, meetingTime < audioEnd { return true }
            if index + 1 < ordered.count, meetingTime < ordered[index + 1].meetingTime {
                return false
            }
        }
        return false
    }

    static func meetingTime(
        forFileTime fileTime: TimeInterval,
        sampleRate: Double = 16_000,
        anchors: [MeetingClockAnchor]
    ) -> TimeInterval {
        guard !anchors.isEmpty else { return fileTime }
        let ordered = fileOrdered(anchors)
        let frame = Int64(max(0, fileTime) * sampleRate)
        let anchor = ordered.last { $0.fileFrame <= frame } ?? ordered[0]
        return anchor.meetingTime + Double(frame - anchor.fileFrame) / sampleRate
    }

    static func fileTime(
        forMeetingTime meetingTime: TimeInterval,
        sampleRate: Double = 16_000,
        anchors: [MeetingClockAnchor]
    ) -> TimeInterval {
        guard !anchors.isEmpty else { return meetingTime }
        let ordered = anchors.sorted { lhs, rhs in
            if lhs.meetingTime == rhs.meetingTime { return lhs.fileFrame < rhs.fileFrame }
            return lhs.meetingTime < rhs.meetingTime
        }
        let anchorIndex = ordered.lastIndex { $0.meetingTime <= meetingTime } ?? 0
        let anchor = ordered[anchorIndex]
        if anchorIndex + 1 < ordered.count {
            let next = ordered[anchorIndex + 1]
            let continuousEnd = anchor.meetingTime
                + Double(next.fileFrame - anchor.fileFrame) / sampleRate
            // There are no file frames inside a capture discontinuity. Seeking into that
            // wall-clock gap must land on the first resumed frame, rather than extrapolating
            // through the file and skipping valid audio after the gap.
            if meetingTime >= continuousEnd, meetingTime < next.meetingTime {
                return Double(next.fileFrame) / sampleRate
            }
        }
        return Double(anchor.fileFrame) / sampleRate + max(0, meetingTime - anchor.meetingTime)
    }
}

struct MeetingSourceHealth: Codable, Equatable, Sendable {
    enum Status: String, Codable, Sendable {
        case requested
        case capturing
        case silent
        case degraded
        case failed
        case stopped
    }

    var status: Status
    var framesCaptured: Int64 = 0
    var droppedFrames: Int64 = 0
    var lastChunkTimestamp: TimeInterval?
    var message: String?

    static let requested = MeetingSourceHealth(status: .requested)
}

struct MeetingRecordingIssue: Codable, Equatable, Identifiable, Sendable {
    enum Severity: String, Codable, Sendable { case information, warning, error }

    let id: UUID
    let occurredAt: Date
    let source: MeetingAudioSource?
    let severity: Severity
    let code: String
    let message: String

    init(
        id: UUID = UUID(),
        occurredAt: Date = Date(),
        source: MeetingAudioSource? = nil,
        severity: Severity,
        code: String,
        message: String
    ) {
        self.id = id
        self.occurredAt = occurredAt
        self.source = source
        self.severity = severity
        self.code = code
        self.message = message
    }
}

/// A view-friendly snapshot of the coordinator state machine.
struct MeetingRecordingLifecycle: Equatable, Sendable {
    enum Phase: String, Codable, Sendable {
        case idle
        case preflighting
        case capturing
        case stopping
        case processing
        case ready
        case partial
        case failed
    }

    let phase: Phase
    let sessionID: UUID?
    let pendingJobs: Int
    let issues: [MeetingRecordingIssue]

    static let idle = MeetingRecordingLifecycle(phase: .idle, sessionID: nil, pendingJobs: 0, issues: [])
}

/// The preferred start contract. The old `start(sources:...)` API remains as an adapter.
struct MeetingRecordingRequest {
    let sources: MeetingRecordingSession.Sources
    let target: MeetingCaptureTarget
    let transcribeLive: Bool
    let identifySpeakers: Bool

    init(
        sources: MeetingRecordingSession.Sources = .all,
        target: MeetingCaptureTarget = .allSystemAudio,
        transcribeLive: Bool = true,
        identifySpeakers: Bool = true
    ) {
        self.sources = sources
        self.target = target
        self.transcribeLive = transcribeLive
        self.identifySpeakers = identifySpeakers
    }
}

extension Notification.Name {
    static let meetingRecordingWillStart = Notification.Name("meetingRecordingWillStart")
    static let meetingRecordingDidStart = Notification.Name("meetingRecordingDidStart")
    static let meetingRecordingDidStop = Notification.Name("meetingRecordingDidStop")
}

enum MeetingRecordingNotificationKey {
    static let sessionID = "sessionID"
}

/// Assigns source-local frame sequences to one shared monotonic meeting timeline.
final class MeetingAudioTimeline: @unchecked Sendable {
    struct SourceMetrics {
        let startOffset: TimeInterval
        let frames: Int64
        let droppedFrames: Int64
        let timelineDuration: TimeInterval
        let anchors: [MeetingClockAnchor]
    }

    private struct Cursor {
        var firstFrameTime: TimeInterval?
        var frames: Int64 = 0
        var droppedFrames: Int64 = 0
        var lastEndTime: TimeInterval?
        var anchors: [MeetingClockAnchor] = []
        var lastAnchorTime: TimeInterval?
        var firstSourceSampleTime: Double?
        var lastSourceSampleEnd: Double?
    }

    private let lock = NSLock()
    private let sessionID: UUID
    private let originHostTimeNanos: UInt64
    private var cursors: [MeetingAudioSource: Cursor] = [:]

    init(
        sessionID: UUID,
        originHostTimeNanos: UInt64 = AudioConvertHostTimeToNanos(AudioGetCurrentHostTime())
    ) {
        self.sessionID = sessionID
        self.originHostTimeNanos = originHostTimeNanos
    }

    func chunk(_ delivery: MeetingCaptureDelivery, outputSampleRate: Double = 16_000) -> MeetingAudioChunk {
        let frames = delivery.frameCount
        lock.lock()
        var cursor = cursors[delivery.source] ?? Cursor()
        let expected = cursor.lastEndTime
        let expectedSourceSample = cursor.lastSourceSampleEnd
        let timestamp: TimeInterval
        if let host = delivery.hostTimeNanos, host >= originHostTimeNanos {
            timestamp = Double(host - originHostTimeNanos) / 1_000_000_000
        } else if let sampleTime = delivery.sampleTime,
                  let firstSample = cursor.firstSourceSampleTime,
                  let firstFrameTime = cursor.firstFrameTime,
                  delivery.sourceSampleRate > 0 {
            timestamp = firstFrameTime + (sampleTime - firstSample) / delivery.sourceSampleRate
        } else if let expected {
            timestamp = expected
        } else {
            timestamp = 0
        }
        if cursor.firstFrameTime == nil { cursor.firstFrameTime = timestamp }
        if cursor.firstSourceSampleTime == nil { cursor.firstSourceSampleTime = delivery.sampleTime }

        let drift = expected.map { abs(timestamp - $0) } ?? .infinity
        let sampleDiscontinuity: Bool
        if let expectedSourceSample, let sampleTime = delivery.sampleTime {
            sampleDiscontinuity = abs(expectedSourceSample - sampleTime)
                > max(1, delivery.sourceSampleRate * 0.005)
        } else {
            sampleDiscontinuity = false
        }
        let shouldAnchor = cursor.anchors.isEmpty
            || drift > 0.005
            || sampleDiscontinuity
            || timestamp - (cursor.lastAnchorTime ?? 0) >= 60
        if shouldAnchor {
            cursor.anchors.append(.init(
                fileFrame: cursor.frames,
                meetingTime: timestamp,
                hostTimeNanos: delivery.hostTimeNanos,
                sourceSampleTime: delivery.sampleTime
            ))
            cursor.lastAnchorTime = timestamp
        }
        cursor.frames += Int64(frames)
        cursor.lastEndTime = timestamp + Double(frames) / outputSampleRate
        if let sampleTime = delivery.sampleTime, delivery.sourceSampleRate > 0 {
            cursor.lastSourceSampleEnd = sampleTime
                + Double(frames) / outputSampleRate * delivery.sourceSampleRate
        }
        cursors[delivery.source] = cursor
        lock.unlock()

        return MeetingAudioChunk(
            sessionID: sessionID,
            source: delivery.source,
            timestamp: timestamp,
            sampleRate: outputSampleRate,
            frameCount: frames,
            data: delivery.data
        )
    }

    func recordDiscontinuity(
        source: MeetingAudioSource,
        droppedFrames: Int64,
        hostTimeNanos: UInt64?,
        sourceSampleTime: Double? = nil,
        sourceSampleRate: Double = 16_000
    ) {
        lock.lock()
        var cursor = cursors[source] ?? Cursor()
        let meetingTime: TimeInterval
        if let hostTimeNanos, hostTimeNanos >= originHostTimeNanos {
            meetingTime = Double(hostTimeNanos - originHostTimeNanos) / 1_000_000_000
        } else {
            meetingTime = (cursor.lastEndTime ?? 0) + Double(droppedFrames) / 16_000
        }
        cursor.anchors.append(.init(
            fileFrame: cursor.frames,
            meetingTime: meetingTime,
            hostTimeNanos: hostTimeNanos,
            sourceSampleTime: sourceSampleTime
        ))
        cursor.lastAnchorTime = meetingTime
        cursor.lastEndTime = meetingTime
        cursor.droppedFrames += max(0, droppedFrames)
        if let sourceSampleTime, sourceSampleRate > 0 {
            cursor.lastSourceSampleEnd = sourceSampleTime
                + Double(droppedFrames) / 16_000 * sourceSampleRate
        }
        cursors[source] = cursor
        lock.unlock()
    }

    func metrics() -> [MeetingAudioSource: SourceMetrics] {
        lock.lock()
        defer { lock.unlock() }
        return cursors.reduce(into: [:]) { result, entry in
            result[entry.key] = SourceMetrics(
                startOffset: entry.value.firstFrameTime ?? 0,
                frames: entry.value.frames,
                droppedFrames: entry.value.droppedFrames,
                timelineDuration: max(
                    0,
                    (entry.value.lastEndTime ?? 0) - (entry.value.firstFrameTime ?? 0)
                ),
                anchors: entry.value.anchors
            )
        }
    }
}
