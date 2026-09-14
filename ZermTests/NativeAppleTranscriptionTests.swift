import Foundation
import Testing
@testable import Zerm

/// Locale resolution and result-stream behavior of Apple Speech transcription, without audio.
struct NativeAppleTranscriptionTests {

    @Test func autoResolvesToTheCurrentLocale() {
        let resolved = SpeechLocaleResolver.localeCode(
            requestedCode: LanguagePreference.autoCode,
            supportedIdentifiers: ["en-US", "es-MX"],
            locale: Locale(identifier: "es-MX")
        )
        #expect(resolved == "es-MX")
    }

    @Test func baseLanguageResolvesDeterministically() {
        let resolved = SpeechLocaleResolver.localeCode(
            requestedCode: "en",
            supportedIdentifiers: ["en-GB", "en-US", "he-IL"],
            locale: Locale(identifier: "he-IL")
        )
        #expect(resolved == "en-US")
    }

    @Test func exactLocaleMatchIgnoresCaseAndNeverFallsBack() {
        #expect(SpeechLocaleResolver.exactLocaleCode(
            requestedCode: "es-mx",
            supportedIdentifiers: ["en-US", "es-MX"]
        ) == "es-MX")
        #expect(SpeechLocaleResolver.exactLocaleCode(
            requestedCode: "es-MX",
            supportedIdentifiers: ["en-US", "es-ES"]
        ) == nil)
    }

    @Test func overrideLocaleDoesNotFallBackToAnotherLocale() {
        do {
            _ = try NativeAppleTranscriptionService.overrideLocale(
                "es-MX",
                supportedIdentifiers: ["en-US", "es-ES"]
            )
            Issue.record("Native Apple silently changed an operation's locale")
        } catch let error as NativeAppleTranscriptionService.ServiceError {
            guard case .localeNotSupported = error else {
                Issue.record("Unexpected override-locale error: \(error.localizedDescription)")
                return
            }
        } catch {
            Issue.record("Unexpected override-locale error: \(error.localizedDescription)")
        }
    }

    @Test func operationLanguageOverrideDoesNotMutateStoredDictationPreference() {
        let suiteName = "NativeAppleTranscriptionTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("en", forKey: LanguagePreference.defaultsKey)

        let duringOperation = LanguagePreference.$operationOverrideCode.withValue("he") {
            LanguagePreference.selectedCode(defaults: defaults)
        }

        #expect(duringOperation == "he")
        #expect(LanguagePreference.selectedCode(defaults: defaults) == "en")
    }

    @Test func resultTimeoutCancelsTheUnderlyingStreamTask() async {
        let cancellation = CancellationProbe()
        let resultTask = Task<String, Error> {
            do {
                try await Task.sleep(for: .seconds(60))
                return "unexpected"
            } catch {
                await cancellation.markCancelled()
                throw error
            }
        }

        do {
            _ = try await NativeAppleTranscriptionService.awaitResult(
                resultTask,
                timeoutNanoseconds: 0
            )
            Issue.record("The Native Apple result stream did not time out")
        } catch let error as NativeAppleTranscriptionService.ServiceError {
            guard case .resultStreamTimedOut = error else {
                Issue.record("Unexpected Native Apple timeout error: \(error.localizedDescription)")
                return
            }
        } catch {
            Issue.record("Unexpected Native Apple timeout error: \(error.localizedDescription)")
        }

        for _ in 0..<20 {
            if await cancellation.value { break }
            await Task.yield()
        }
        let underlyingTaskWasCancelled = await cancellation.value
        #expect(underlyingTaskWasCancelled)
    }
}

private actor CancellationProbe {
    private(set) var value = false
    func markCancelled() { value = true }
}
