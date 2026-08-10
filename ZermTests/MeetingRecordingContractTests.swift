import Foundation
import Testing
@testable import Zerm

/// Pure contract coverage for the meeting architecture. These tests deliberately avoid audio
/// hardware and the user's Application Support directory so they can run on a clean build Mac.
struct MeetingRecordingContractTests {

    @Test func nativeAppleAutoPresentsAResolvedFixedLocale() {
        let result = MeetingLanguagePresentation.resolve(
            provider: .nativeApple,
            requestedCode: LanguagePreference.autoCode,
            supportedLanguages: [
                "en-US": "English (United States)",
                "es-MX": "Spanish (Mexico)"
            ],
            locale: Locale(identifier: "es-MX")
        )

        #expect(result.code == "es-MX")
        #expect(result.displayName != "Auto-detect")
        #expect(result.disclosure != nil)
    }

    @Test func nonAppleProviderMayRetainAutomaticLanguagePresentation() {
        let result = MeetingLanguagePresentation.resolve(
            provider: .whisper,
            requestedCode: LanguagePreference.autoCode,
            supportedLanguages: ["auto": "Auto-detect", "en": "English"],
            locale: Locale(identifier: "en-US")
        )

        #expect(result.code == LanguagePreference.autoCode)
        #expect(result.disclosure == nil)
    }

    @Test func selectedApplicationTargetRoundTripsWithoutLosingProcessIdentity() throws {
        let target = MeetingCaptureTarget.application(
            bundleID: "com.microsoft.teams2",
            appName: "Microsoft Teams",
            processID: 7_654
        )

        let encoded = try JSONEncoder().encode(target)
        let decoded = try JSONDecoder().decode(MeetingCaptureTarget.self, from: encoded)

        #expect(decoded == target)
    }

    @Test func allSystemAudioTargetRoundTripsAsAnExplicitFallback() throws {
        let encoded = try JSONEncoder().encode(MeetingCaptureTarget.allSystemAudio)
        let decoded = try JSONDecoder().decode(MeetingCaptureTarget.self, from: encoded)

        #expect(decoded == .allSystemAudio)
    }

    @Test func transcriptionSnapshotDistinguishesLocalAndCloudRoutes() {
        let local = MeetingTranscriptionSnapshot(
            model: ContractTranscriptionModel(provider: .whisper),
            languageCode: "he"
        )
        let cloud = MeetingTranscriptionSnapshot(
            model: ContractTranscriptionModel(provider: .openai),
            languageCode: "he"
        )

        #expect(local.route == .local)
        #expect(cloud.route == .cloud)
        #expect(local.languageCode == "he")
        #expect(cloud.languageCode == "he")
    }

    @Test func nativeAppleSnapshotPersistsOneConcreteLocaleAcrossLocaleChanges() throws {
        let resolved = try #require(MeetingLanguageResolver.nativeAppleMeetingLocaleCode(
            requestedCode: LanguagePreference.autoCode,
            supportedIdentifiers: ["en-US", "es-MX"],
            locale: Locale(identifier: "es-MX")
        ))
        let snapshot = MeetingTranscriptionSnapshot(
            model: ContractTranscriptionModel(provider: .nativeApple),
            resolvedLanguageCode: resolved
        )

        #expect(snapshot.languageCode == "es-MX")
        #expect(snapshot.languageCode != LanguagePreference.autoCode)

        let restored = try JSONDecoder().decode(
            MeetingTranscriptionSnapshot.self,
            from: JSONEncoder().encode(snapshot)
        )
        let resolvedDuringEnglishReview = MeetingLanguageResolver.nativeAppleLocaleCode(
            requestedCode: restored.languageCode,
            supportedIdentifiers: ["en-US", "es-MX"],
            locale: Locale(identifier: "en-US")
        )
        #expect(resolvedDuringEnglishReview == "es-MX")
        #expect(MeetingLanguageResolver.exactNativeAppleLocaleCode(
            requestedCode: restored.languageCode,
            supportedIdentifiers: ["en-US", "es-MX"]
        ) == "es-MX")
    }

    @Test func nativeAppleBaseLanguageResolvesDeterministically() {
        let resolved = MeetingLanguageResolver.nativeAppleMeetingLocaleCode(
            requestedCode: "en",
            supportedIdentifiers: ["en-GB", "en-US", "he-IL"],
            locale: Locale(identifier: "he-IL")
        )
        #expect(resolved == "en-US")
    }

    @Test func nativeAppleMeetingRejectsUnsupportedExplicitLanguage() {
        let resolved = MeetingLanguageResolver.nativeAppleMeetingLocaleCode(
            requestedCode: "he",
            supportedIdentifiers: ["en-US", "es-MX"],
            locale: Locale(identifier: "en-US")
        )
        #expect(resolved == nil)
    }

    @Test func nativeApplePersistedLocaleDoesNotFallbackDuringReview() {
        #expect(MeetingLanguageResolver.exactNativeAppleLocaleCode(
            requestedCode: "es-MX",
            supportedIdentifiers: ["en-US", "es-ES"]
        ) == nil)
        do {
            _ = try NativeAppleTranscriptionService.persistedMeetingLocale(
                "es-MX",
                supportedIdentifiers: ["en-US", "es-ES"]
            )
            Issue.record("Native Apple silently changed a persisted meeting locale")
        } catch let error as NativeAppleTranscriptionService.ServiceError {
            guard case .localeNotSupported = error else {
                Issue.record("Unexpected persisted-locale error: \(error.localizedDescription)")
                return
            }
        } catch {
            Issue.record("Unexpected persisted-locale error: \(error.localizedDescription)")
        }
    }

    @Test func nativeAppleResultTimeoutCancelsTheUnderlyingStreamTask() async {
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

    @Test func fluidAudioSnapshotDoesNotClaimAnUnsupportedLanguageConstraint() {
        let snapshot = MeetingTranscriptionSnapshot(
            model: ContractTranscriptionModel(provider: .fluidAudio),
            languageCode: "he"
        )
        #expect(snapshot.languageCode == LanguagePreference.autoCode)
        #expect(snapshot.route == .local)
        #expect(LanguageDictionary.forProvider(
            isMultilingual: true,
            provider: .fluidAudio
        ) == [LanguagePreference.autoCode: "Auto-detect"])
    }

    @Test func emptySnapshotLanguageNormalizesToAuto() {
        let snapshot = MeetingTranscriptionSnapshot(
            model: ContractTranscriptionModel(provider: .whisper),
            languageCode: ""
        )

        #expect(snapshot.languageCode == LanguagePreference.autoCode)
    }

    @Test func operationLanguageOverrideDoesNotMutateStoredDictationPreference() {
        let suiteName = "MeetingRecordingContractTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("en", forKey: LanguagePreference.defaultsKey)

        let duringMeeting = LanguagePreference.$operationOverrideCode.withValue("he") {
            LanguagePreference.selectedCode(defaults: defaults)
        }

        #expect(duringMeeting == "he")
        #expect(LanguagePreference.selectedCode(defaults: defaults) == "en")
    }

    @Test func perSourceFrameCursorsNeverConcatenateIndependentTracks() {
        let sessionID = UUID()
        let origin: UInt64 = 1_000_000_000
        let timeline = MeetingAudioTimeline(sessionID: sessionID, originHostTimeNanos: origin)
        let halfSecond = Data(repeating: 0, count: 8_000 * MemoryLayout<Int16>.size)

        func delivery(_ source: MeetingAudioSource, at nanoseconds: UInt64) -> MeetingCaptureDelivery {
            .init(
                source: source,
                data: halfSecond,
                hostTimeNanos: nanoseconds,
                sampleTime: nil,
                sourceSampleRate: 16_000,
                frameCount: 8_000
            )
        }

        let microphone1 = timeline.chunk(delivery(.microphone, at: origin + 100_000_000))
        let system1 = timeline.chunk(delivery(.systemAudio, at: origin + 200_000_000))
        let microphone2 = timeline.chunk(delivery(.microphone, at: origin + 600_000_000))
        let system2 = timeline.chunk(delivery(.systemAudio, at: origin + 700_000_000))

        #expect(microphone1.sessionID == sessionID)
        #expect(system1.sessionID == sessionID)
        #expect(abs((microphone2.timestamp - microphone1.timestamp) - 0.5) < 0.001)
        #expect(abs((system2.timestamp - system1.timestamp) - 0.5) < 0.001)
        #expect(timeline.metrics()[.microphone]?.frames == 16_000)
        #expect(timeline.metrics()[.systemAudio]?.frames == 16_000)
        #expect(abs((system1.timestamp - microphone1.timestamp) - 0.1) < 0.001)
    }

    @Test func persistedClockAnchorsMapFileFramesAcrossCaptureDiscontinuities() {
        let anchors = [
            MeetingClockAnchor(
                fileFrame: 0,
                meetingTime: 0.1,
                hostTimeNanos: 1_100_000_000,
                sourceSampleTime: 0
            ),
            MeetingClockAnchor(
                fileFrame: 8_000,
                meetingTime: 0.7,
                hostTimeNanos: 1_700_000_000,
                sourceSampleTime: 8_000
            )
        ]

        #expect(abs(MeetingTrackClock.meetingTime(forFileTime: 0.25, anchors: anchors) - 0.35) < 0.001)
        #expect(abs(MeetingTrackClock.meetingTime(forFileTime: 0.5, anchors: anchors) - 0.7) < 0.001)
        #expect(abs(MeetingTrackClock.fileTime(forMeetingTime: 0.7, anchors: anchors) - 0.5) < 0.001)
    }

    @Test func seekingInsideMissingAudioClampsToTheNextAvailableFrame() {
        let anchors = [
            MeetingClockAnchor(
                fileFrame: 0,
                meetingTime: 0,
                hostTimeNanos: 1_000_000_000,
                sourceSampleTime: 0
            ),
            // Only half a second exists in the file before capture resumes at meeting second 1.
            MeetingClockAnchor(
                fileFrame: 8_000,
                meetingTime: 1,
                hostTimeNanos: 2_000_000_000,
                sourceSampleTime: 8_000
            )
        ]

        #expect(abs(MeetingTrackClock.fileTime(forMeetingTime: 0.75, anchors: anchors) - 0.5) < 0.001)
        #expect(abs(MeetingTrackClock.meetingTime(forFileTime: 0.5, anchors: anchors) - 1) < 0.001)
    }

    @Test func orderedDropMarkerPreservesGapAtOneFileFrameBoundary() {
        let origin: UInt64 = 5_000_000_000
        let timeline = MeetingAudioTimeline(sessionID: UUID(), originHostTimeNanos: origin)
        let quarterSecond = Data(repeating: 0, count: 4_000 * MemoryLayout<Int16>.size)
        _ = timeline.chunk(.init(
            source: .systemAudio,
            data: quarterSecond,
            hostTimeNanos: origin,
            sampleTime: 0,
            sourceSampleRate: 16_000,
            frameCount: 4_000
        ))
        timeline.recordDiscontinuity(
            source: .systemAudio,
            droppedFrames: 4_000,
            hostTimeNanos: origin + 250_000_000,
            sourceSampleTime: 4_000,
            sourceSampleRate: 16_000
        )
        let resumed = timeline.chunk(.init(
            source: .systemAudio,
            data: quarterSecond,
            hostTimeNanos: origin + 500_000_000,
            sampleTime: 8_000,
            sourceSampleRate: 16_000,
            frameCount: 4_000
        ))

        let anchors = timeline.metrics()[.systemAudio]?.anchors ?? []
        #expect(resumed.timestamp == 0.5)
        #expect(anchors.map(\.fileFrame) == [0, 4_000, 4_000])
        #expect(anchors.map(\.meetingTime) == [0, 0.25, 0.5])
    }

    @Test func playbackLeavesSilenceForDroppedFramesBeforeResumingAtTheSameFileFrame() {
        let anchors = [
            MeetingClockAnchor(
                fileFrame: 0,
                meetingTime: 0,
                hostTimeNanos: 1_000_000_000,
                sourceSampleTime: 0
            ),
            // A drop consumes wall-clock time but writes no frames.
            MeetingClockAnchor(
                fileFrame: 8_000,
                meetingTime: 0.5,
                hostTimeNanos: 1_500_000_000,
                sourceSampleTime: 8_000
            ),
            // The first accepted buffer after the drop resumes at the exact same file frame.
            MeetingClockAnchor(
                fileFrame: 8_000,
                meetingTime: 1,
                hostTimeNanos: 2_000_000_000,
                sourceSampleTime: 16_000
            )
        ]

        #expect(MeetingTrackClock.containsAudio(
            atMeetingTime: 0.25,
            fileDuration: 1,
            anchors: anchors
        ))
        #expect(!MeetingTrackClock.containsAudio(
            atMeetingTime: 0.75,
            fileDuration: 1,
            anchors: anchors
        ))
        #expect(MeetingTrackClock.containsAudio(
            atMeetingTime: 1.25,
            fileDuration: 1,
            anchors: anchors
        ))
    }

    @Test func playbackClockIsIndependentOfDuplicateFrameAnchorInputOrder() {
        let anchors = [
            MeetingClockAnchor(fileFrame: 0, meetingTime: 0, hostTimeNanos: nil, sourceSampleTime: 0),
            MeetingClockAnchor(fileFrame: 8_000, meetingTime: 1, hostTimeNanos: nil, sourceSampleTime: 16_000),
            MeetingClockAnchor(fileFrame: 8_000, meetingTime: 0.5, hostTimeNanos: nil, sourceSampleTime: 8_000)
        ]

        #expect(!MeetingTrackClock.containsAudio(
            atMeetingTime: 0.75,
            fileDuration: 1,
            anchors: anchors
        ))
        #expect(MeetingTrackClock.containsAudio(
            atMeetingTime: 1.25,
            fileDuration: 1,
            anchors: anchors
        ))
    }

    @Test func legacyTracksWithoutAnchorsRetainIdentityClockMapping() {
        #expect(MeetingTrackClock.meetingTime(forFileTime: 12.5, anchors: []) == 12.5)
        #expect(MeetingTrackClock.fileTime(forMeetingTime: 12.5, anchors: []) == 12.5)
    }

    @Test func overlapReconciliationHandlesHebrewAndPunctuation() {
        let suffix = MeetingTranscriber.reconcile(
            previous: "אנחנו משיקים את מערכת ההקלטה החדשה מחר.",
            next: "מערכת ההקלטה החדשה מחר ואז נבדוק אותה"
        )

        #expect(suffix == "ואז נבדוק אותה")
    }

    @Test func unrelatedConsecutiveWindowsArePreserved() {
        let suffix = MeetingTranscriber.reconcile(
            previous: "first agenda item",
            next: "completely different sentence"
        )

        #expect(suffix == "completely different sentence")
    }

    @Test func speakerAttributionNeverCrossesAudioSources() {
        let segment = MeetingTranscriber.Segment(
            source: .microphone,
            start: 0,
            end: 4,
            text: "room speaker only"
        )
        let remoteTurn = MeetingDiarizer.Turn(
            source: .systemAudio,
            speakerIndex: 0,
            start: 0,
            end: 4,
            isFinal: true
        )

        let attributed = MeetingSpeakerAttributor.split([segment], using: [remoteTurn])

        #expect(attributed == [segment])
        #expect(attributed[0].assignedSpeakerIndex == nil)
    }

    @Test func estimatedSpeakerSplitsPreserveEveryTranscriptWordExactlyOnce() {
        let segment = MeetingTranscriber.Segment(
            source: .systemAudio,
            start: 0,
            end: 4,
            text: "one two three four five six"
        )
        let turns = [
            MeetingDiarizer.Turn(
                source: .systemAudio,
                speakerIndex: 0,
                start: 0,
                end: 2,
                isFinal: true
            ),
            MeetingDiarizer.Turn(
                source: .systemAudio,
                speakerIndex: 1,
                start: 2,
                end: 4,
                isFinal: true
            )
        ]

        let attributed = MeetingSpeakerAttributor.split([segment], using: turns)

        #expect(attributed.map(\.text).joined(separator: " ") == segment.text)
        #expect(attributed.map(\.assignedSpeakerIndex) == [0, 1])
        #expect(attributed.allSatisfy { $0.speakerConfidence == .estimatedFromWindow })
    }

    @Test func legacySidecarLineWithoutSourceStillDecodes() throws {
        let legacy = Data(#"{"start":1.5,"end":3.0,"text":"legacy transcript","speaker":"Speaker 1"}"#.utf8)

        let line = try JSONDecoder().decode(MeetingRecordingStore.Sidecar.Line.self, from: legacy)

        #expect(line.source == nil)
        #expect(line.start == 1.5)
        #expect(line.end == 3.0)
        #expect(line.text == "legacy transcript")
    }

    @Test func estimatedSpeakerConfidenceSurvivesSidecarPersistence() throws {
        let original = MeetingRecordingStore.Sidecar.Line(
            source: .systemAudio,
            start: 12,
            end: 14,
            text: "an estimated speaker turn",
            speaker: "Remote Speaker 2",
            speakerConfidence: MeetingTranscriber.Segment.SpeakerConfidence.estimatedFromWindow.rawValue
        )

        let decoded = try JSONDecoder().decode(
            MeetingRecordingStore.Sidecar.Line.self,
            from: JSONEncoder().encode(original)
        )

        #expect(decoded.source == .systemAudio)
        #expect(decoded.speaker == "Remote Speaker 2")
        #expect(decoded.speakerConfidence == "estimatedFromWindow")
    }

    @Test func legacyManifestTrackWithoutClockAnchorsGetsAnIdentityAnchor() throws {
        let legacy = Data(
            #"{"source":"microphone","fileName":"microphone.wav","startOffset":0.25,"duration":5.0,"frames":80000}"#.utf8
        )

        let track = try JSONDecoder().decode(MeetingRecordingStore.Manifest.Track.self, from: legacy)

        #expect(track.clockAnchors.count == 1)
        #expect(track.clockAnchors[0].fileFrame == 0)
        #expect(track.clockAnchors[0].meetingTime == 0.25)
        #expect(MeetingTrackClock.meetingTime(forFileTime: 1, anchors: track.clockAnchors) == 1.25)
    }

    @Test func manifestPersistsProcessingAndSourceHealthContract() throws {
        let id = UUID()
        let issue = MeetingRecordingIssue(
            source: .systemAudio,
            severity: .error,
            code: "capture-overrun",
            message: "A bounded queue dropped frames."
        )
        let manifest = MeetingRecordingStore.Manifest(
            sessionID: id,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            status: .partial,
            duration: 90,
            captureTarget: .application(
                bundleID: "us.zoom.xos",
                appName: "Zoom",
                processID: 42
            ),
            requestedSources: [.microphone, .systemAudio],
            tracks: [
                .init(
                    source: .microphone,
                    fileName: "microphone.wav",
                    startOffset: 0.25,
                    duration: 89.5,
                    frames: 1_432_000
                )
            ],
            transcriptionStatus: .complete,
            diarizationStatus: .failed,
            sourceHealth: [
                MeetingAudioSource.systemAudio.rawValue: .init(
                    status: .degraded,
                    framesCaptured: 100,
                    droppedFrames: 20,
                    lastChunkTimestamp: 2.5,
                    message: "Some frames were dropped."
                )
            ],
            issues: [issue]
        )

        let encoded = try JSONEncoder().encode(manifest)
        let decoded = try JSONDecoder().decode(MeetingRecordingStore.Manifest.self, from: encoded)

        #expect(decoded == manifest)
        #expect(decoded.schemaVersion == MeetingRecordingStore.Manifest.currentSchemaVersion)
        #expect(decoded.sourceHealth[MeetingAudioSource.systemAudio.rawValue]?.droppedFrames == 20)
        #expect(decoded.issues == [issue])
    }

    @Test func summaryRouteAndRunningStateSurviveManifestPersistence() throws {
        let manifest = MeetingRecordingStore.Manifest(
            sessionID: UUID(),
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            status: .processing,
            captureTarget: .allSystemAudio,
            requestedSources: [.microphone],
            summarySnapshot: .init(provider: "Ollama", model: "qwen3", route: .local),
            summaryStatus: .running
        )

        let decoded = try JSONDecoder().decode(
            MeetingRecordingStore.Manifest.self,
            from: JSONEncoder().encode(manifest)
        )

        #expect(decoded.summarySnapshot?.provider == "Ollama")
        #expect(decoded.summarySnapshot?.model == "qwen3")
        #expect(decoded.summarySnapshot?.route == .local)
        #expect(decoded.summaryStatus == .running)
    }
}

private actor CancellationProbe {
    private(set) var value = false
    func markCancelled() { value = true }
}

private struct ContractTranscriptionModel: TranscriptionModel {
    let id = UUID()
    let name = "contract-model"
    let displayName = "Contract Model"
    let description = "A deterministic test model."
    let provider: ModelProvider
    let isMultilingualModel = true
    let supportedLanguages = ["en": "English", "he": "Hebrew"]
}
