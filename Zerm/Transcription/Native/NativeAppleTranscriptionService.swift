import Foundation
import AVFoundation
import os

#if canImport(Speech)
import Speech
#endif

/// Transcription service that leverages the new SpeechAnalyzer / SpeechTranscriber API available on macOS 26 (Tahoe).
/// Falls back with an unsupported-provider error on earlier OS versions so the application can gracefully degrade.
class NativeAppleTranscriptionService: TranscriptionService {
    private let logger = Logger(subsystem: "com.arcusis.zerm", category: "NativeAppleTranscriptionService")

    enum ServiceError: Error, LocalizedError {
        case unsupportedOS
        case transcriptionFailed
        case localeNotSupported
        case invalidModel
        case assetDownloadRequired(String)
        case resultStreamTimedOut

        var errorDescription: String? {
            switch self {
            case .unsupportedOS:
                return "SpeechAnalyzer requires macOS 26 or later."
            case .transcriptionFailed:
                return "Transcription failed using SpeechAnalyzer."
            case .localeNotSupported:
                return "The selected language is not supported by SpeechAnalyzer."
            case .invalidModel:
                return "Invalid model type provided for Native Apple transcription."
            case .assetDownloadRequired(let displayName):
                return "Download required for \(displayName)."
            case .resultStreamTimedOut:
                return "Apple Speech did not finish returning transcription results."
            }
        }
    }

    private func languageDisplayName(for localeIdentifier: String) -> String {
        LanguageDictionary.appleNative[localeIdentifier]
            ?? Locale.current.localizedString(forIdentifier: localeIdentifier)
            ?? localeIdentifier
    }

    static func meetingSupportedLocaleIdentifiers() async -> [String] {
        guard #available(macOS 26, *) else { return [] }
        #if canImport(Speech) && ENABLE_NATIVE_SPEECH_ANALYZER
        let supportedLocales = await SpeechTranscriber.supportedLocales
        return supportedLocales.map { $0.identifier(.bcp47) }
        #else
        return []
        #endif
    }

    static func persistedMeetingLocale(
        _ localeIdentifier: String,
        supportedIdentifiers: [String]
    ) throws -> String {
        guard let exact = MeetingLanguageResolver.exactNativeAppleLocaleCode(
            requestedCode: localeIdentifier,
            supportedIdentifiers: supportedIdentifiers
        ) else {
            throw ServiceError.localeNotSupported
        }
        return exact
    }

    func transcribe(audioURL: URL, model: any TranscriptionModel) async throws -> String {
        guard model is NativeAppleModel else {
            throw ServiceError.invalidModel
        }

        guard #available(macOS 26, *) else {
            logger.error("SpeechAnalyzer is not available on this macOS version")
            throw ServiceError.unsupportedOS
        }

        // Feature gated: SpeechAnalyzer/SpeechTranscriber are future APIs.
        // Enable by defining ENABLE_NATIVE_SPEECH_ANALYZER in build settings once building against macOS 26+ SDKs.
        #if canImport(Speech) && ENABLE_NATIVE_SPEECH_ANALYZER
        let audioFile = try AVAudioFile(forReading: audioURL)
        let audioDuration = Double(audioFile.length) / audioFile.processingFormat.sampleRate

        let supportedLocales = await SpeechTranscriber.supportedLocales
        let installedLocales = await SpeechTranscriber.installedLocales
        let supportedIdentifiers = Set(supportedLocales.map { $0.identifier(.bcp47) })
        let installedIdentifiers = Set(installedLocales.map { $0.identifier(.bcp47) })

        // `auto` is Zerm's provider-neutral sentinel, not a locale identifier. Meeting jobs have
        // already persisted one concrete locale; ordinary Dictation resolves the sentinel once
        // for this operation using the same deterministic policy.
        let selectedLanguage = LanguagePreference.selectedCode()
        let selectedLocaleIdentifier: String
        if LanguagePreference.operationOverrideCode != nil {
            // A meeting override is already a persisted, runtime-validated locale. Never
            // reinterpret it using the current machine locale during review/reprocessing.
            selectedLocaleIdentifier = try Self.persistedMeetingLocale(
                selectedLanguage,
                supportedIdentifiers: supportedLocales.map { $0.identifier(.bcp47) }
            )
        } else {
            selectedLocaleIdentifier = MeetingLanguageResolver.nativeAppleLocaleCode(
                requestedCode: selectedLanguage,
                supportedIdentifiers: supportedLocales.map { $0.identifier(.bcp47) }
            )
        }
        let locale = supportedLocales.first {
            $0.identifier(.bcp47).caseInsensitiveCompare(selectedLocaleIdentifier) == .orderedSame
        } ?? Locale(identifier: selectedLocaleIdentifier)
        let isLocaleSupported = supportedIdentifiers.contains(selectedLocaleIdentifier)
        let isLocaleInstalled = installedIdentifiers.contains(selectedLocaleIdentifier)

        guard isLocaleSupported else {
            logger.error("Transcription failed: Locale '\(selectedLocaleIdentifier, privacy: .public)' is not supported by SpeechTranscriber.")
            throw ServiceError.localeNotSupported
        }

        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: []
        )

        // A supported-but-not-yet-downloaded locale used to be a dead end: the error named the
        // missing language and nothing in the app could ever fetch it, so picking Apple's model
        // with a fresh locale simply never worked. Ask the system to install it instead, and
        // only give up if that fails. (Upstream VoiceInk #837.)
        if !isLocaleInstalled {
            logger.notice("Assets for '\(selectedLocaleIdentifier, privacy: .public)' are not installed; requesting download.")
            do {
                try await downloadAssets(for: transcriber)
            } catch {
                logger.error("Asset download for '\(selectedLocaleIdentifier, privacy: .public)' failed: \(error.localizedDescription, privacy: .public)")
                throw ServiceError.assetDownloadRequired(languageDisplayName(for: selectedLocaleIdentifier))
            }

            let nowInstalled = await SpeechTranscriber.installedLocales
                .contains { $0.identifier(.bcp47) == selectedLocaleIdentifier }
            guard nowInstalled else {
                throw ServiceError.assetDownloadRequired(languageDisplayName(for: selectedLocaleIdentifier))
            }
            logger.notice("Assets for '\(selectedLocaleIdentifier, privacy: .public)' installed.")
        }

        await ensureModelIsReserved(for: locale, transcriber: transcriber)

        let modules: [any SpeechModule] = [transcriber]
        let analyzer = SpeechAnalyzer(modules: modules)
        let resultTask = Task<String, Error> {
            var transcript = ""
            for try await result in transcriber.results {
                transcript += String(result.text.characters)
            }
            return transcript
        }

        do {
            let lastSampleTime = try await analyzer.analyzeSequence(from: audioFile)
            if let lastSampleTime {
                try await analyzer.finalizeAndFinish(through: lastSampleTime)
            } else {
                resultTask.cancel()
                await analyzer.cancelAndFinishNow()
                logger.error("Transcription failed: Apple Speech received no audio samples for '\(selectedLocaleIdentifier, privacy: .public)'.")
                throw ServiceError.transcriptionFailed
            }
        } catch {
            resultTask.cancel()
            await analyzer.cancelAndFinishNow()
            throw error
        }

        let resultTimeout = max(20.0, audioDuration * 4.0 + 10.0)
        let finalTranscription: String
        do {
            finalTranscription = try await Self.awaitResult(
                resultTask,
                timeoutNanoseconds: UInt64(resultTimeout * 1_000_000_000)
            )
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            resultTask.cancel()
            await analyzer.cancelAndFinishNow()
            throw error
        }

        logger.notice("Native transcription successful. Length: \(finalTranscription.count, privacy: .public) characters.")
        return finalTranscription
        #else
        logger.notice("Native Apple transcription is disabled in this build (Speech APIs not enabled).")
        throw ServiceError.unsupportedOS
        #endif
    }

    /// Downloads the speech assets a transcriber needs, if the system says any are missing.
    @available(macOS 26, *)
    private func downloadAssets(for transcriber: SpeechTranscriber) async throws {
        #if canImport(Speech) && ENABLE_NATIVE_SPEECH_ANALYZER
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) else {
            // Nothing to fetch: the system already considers the modules satisfied.
            return
        }
        try await request.downloadAndInstall()
        #endif
    }

    @available(macOS 26, *)
    private func ensureModelIsReserved(for locale: Locale, transcriber: SpeechTranscriber) async {
        #if canImport(Speech) && ENABLE_NATIVE_SPEECH_ANALYZER
        let localeIdentifier = locale.identifier(.bcp47)
        let reservedLocales = await AssetInventory.reservedLocales
        guard !reservedLocales.contains(where: { $0.identifier(.bcp47) == localeIdentifier }) else {
            return
        }

        for reservedLocale in reservedLocales {
            await AssetInventory.release(reservedLocale: reservedLocale)
        }

        do {
            let reserved = try await AssetInventory.reserve(locale: locale)
            if !reserved {
                let finalStatus = await AssetInventory.status(forModules: [transcriber])
                logger.warning("Apple Speech asset reservation returned false for '\(localeIdentifier, privacy: .public)'. Continuing — locale is already downloaded. Status: \(String(describing: finalStatus), privacy: .public).")
            }
        } catch {
            let finalStatus = await AssetInventory.status(forModules: [transcriber])
            logger.warning("Apple Speech asset reservation failed for '\(localeIdentifier, privacy: .public)': \(error.localizedDescription, privacy: .public). Continuing — locale is already downloaded. Status: \(String(describing: finalStatus), privacy: .public).")
        }
        #endif
    }

    static func awaitResult(
        _ resultTask: Task<String, Error>,
        timeoutNanoseconds: UInt64
    ) async throws -> String {
        let gate = NativeResultGate()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let resultWaiter = Task {
                    do {
                        gate.resolve(.success(try await resultTask.value), continuation: continuation)
                    } catch {
                        gate.resolve(.failure(error), continuation: continuation)
                    }
                }
                gate.register(resultWaiter)
                let timeoutWaiter = Task {
                    if timeoutNanoseconds > 0 {
                        try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                    }
                    guard !Task.isCancelled else { return }
                    if gate.resolve(
                        .failure(ServiceError.resultStreamTimedOut),
                        continuation: continuation
                    ) {
                        resultTask.cancel()
                    }
                }
                gate.register(timeoutWaiter)
            }
        } onCancel: {
            resultTask.cancel()
        }
    }
}

private final class NativeResultGate: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false
    private var waiters: [Task<Void, Never>] = []

    func register(_ waiter: Task<Void, Never>) {
        lock.lock()
        if completed {
            lock.unlock()
            waiter.cancel()
            return
        }
        waiters.append(waiter)
        lock.unlock()
    }

    @discardableResult
    func resolve(
        _ result: Result<String, Error>,
        continuation: CheckedContinuation<String, Error>
    ) -> Bool {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return false
        }
        completed = true
        let waiters = waiters
        self.waiters.removeAll()
        lock.unlock()
        waiters.forEach { $0.cancel() }
        continuation.resume(with: result)
        return true
    }
}
