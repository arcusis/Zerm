import AVFoundation
import AudioToolbox
import Foundation
import Testing
@testable import Zerm

@MainActor
@Suite(.serialized)
struct MeetingRecordingArchitectureTests {

    @Test func dualTracksKeepIndependentClocksAndManifestIdentity() async throws {
        let root = temporaryDirectory("dual-track")
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = DeterministicMeetingCaptureBackend()
        let session = MeetingRecordingSession(libraryRoot: root, captureBackend: backend)
        let sessionID = UUID()
        var chunks: [MeetingAudioChunk] = []
        session.onAudioChunk = { chunks.append($0) }

        try session.start(
            sources: .all,
            target: .application(bundleID: "us.zoom.xos", appName: "Zoom", processID: 42),
            sessionID: sessionID,
            transcriptionSnapshot: nil
        )
        try backend.emit(.microphone, seconds: 0.5, value: 1_000)
        try backend.emit(.systemAudio, seconds: 0.5, value: 2_000)
        try backend.emit(.microphone, seconds: 0.5, value: 1_100)
        try backend.emit(.systemAudio, seconds: 0.5, value: 2_100)

        let recording = try #require(session.stop())
        let mic = chunks.filter { $0.source == .microphone }
        let system = chunks.filter { $0.source == .systemAudio }
        #expect(mic.count == 2)
        #expect(system.count == 2)
        #expect(abs((mic[1].timestamp - mic[0].timestamp) - 0.5) < 0.01)
        #expect(abs((system[1].timestamp - system[0].timestamp) - 0.5) < 0.01)
        #expect(mic.allSatisfy { $0.sessionID == sessionID })
        #expect(system.allSatisfy { $0.sessionID == sessionID })

        let manifest = try #require(MeetingRecordingStore.readManifest(in: recording.folder))
        #expect(manifest.schemaVersion == MeetingRecordingStore.Manifest.currentSchemaVersion)
        #expect(manifest.sessionID == sessionID)
        #expect(manifest.tracks.count == 2)
        #expect(manifest.tracks.allSatisfy { $0.frames == 16_000 })
        if case .application(let bundleID, let appName, let processID) = manifest.captureTarget {
            #expect(bundleID == "us.zoom.xos")
            #expect(appName == "Zoom")
            #expect(processID == 42)
        } else {
            Issue.record("selected application was not persisted")
        }
    }

    @Test func sourceFailureDegradesOnlyThatSourceAndSurvivesRecovery() async throws {
        let root = temporaryDirectory("source-loss")
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = DeterministicMeetingCaptureBackend()
        let session = MeetingRecordingSession(libraryRoot: root, captureBackend: backend)
        try session.start(sources: .all)
        try backend.emit(.microphone, seconds: 0.25)
        backend.fail(.systemAudio, message: "selected process exited")
        for _ in 0..<20 where session.sourceHealth[.systemAudio]?.status != .failed {
            await Task.yield()
        }

        #expect(session.sourceHealth[.microphone]?.status == .capturing)
        #expect(session.sourceHealth[.systemAudio]?.status == .failed)
        let recording = try #require(session.stop())
        let manifest = try #require(MeetingRecordingStore.readManifest(in: recording.folder))
        #expect(manifest.status == .partial)
        #expect(manifest.issues.contains { $0.source == .systemAudio })
    }

    @Test func stopCannotOvertakeADurableMicrophoneWriteFailure() throws {
        let root = temporaryDirectory("microphone-write-failure")
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = DeterministicMeetingCaptureBackend()
        let session = MeetingRecordingSession(libraryRoot: root, captureBackend: backend)
        try session.start(sources: .microphone)
        try backend.emit(.microphone, seconds: 0.25)
        backend.fail(.microphone, message: "simulated durable write failure")

        // Do not yield MainActor: Stop must reconcile the serialized capture failure itself.
        let recording = try #require(session.stop())
        let manifest = try #require(MeetingRecordingStore.readManifest(in: recording.folder))
        #expect(manifest.status == .partial)
        #expect(manifest.tracks.first?.frames == 4_000)
        #expect(manifest.issues.contains {
            $0.source == .microphone && $0.code == "microphone-capture-failed"
        })
    }

    @Test func restoredSelectedApplicationCaptureRetainsTheOutageIssue() throws {
        let root = temporaryDirectory("selected-app-outage")
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = DeterministicMeetingCaptureBackend()
        let session = MeetingRecordingSession(libraryRoot: root, captureBackend: backend)
        try session.start(
            sources: .systemAudio,
            target: .application(bundleID: "com.example.call", appName: "Call", processID: 42),
            sessionID: UUID(),
            transcriptionSnapshot: nil
        )
        try backend.emit(.systemAudio, seconds: 0.25)
        backend.interrupt(.systemAudio, message: "selected application audio disappeared")
        backend.restoreSystemCapture()

        let recording = try #require(session.stop())
        let manifest = try #require(MeetingRecordingStore.readManifest(in: recording.folder))
        #expect(manifest.status == .partial)
        #expect(manifest.issues.contains {
            $0.source == .systemAudio && $0.code == "systemAudio-capture-interrupted"
        })
    }

    @Test func selectedApplicationCanStartWaitingAndRecoverWithoutRestartingMeeting() async throws {
        let root = temporaryDirectory("selected-app-wait")
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = DeterministicMeetingCaptureBackend()
        backend.systemStartsWaiting = true
        let session = MeetingRecordingSession(libraryRoot: root, captureBackend: backend)

        try session.start(
            sources: .all,
            target: .application(bundleID: "com.example.call", appName: "Call", processID: 42),
            sessionID: UUID(),
            transcriptionSnapshot: nil
        )
        await Task.yield()
        #expect(session.state == .recording)
        #expect(session.sourceHealth[.microphone]?.status == .capturing)
        #expect(session.sourceHealth[.systemAudio]?.status == .degraded)

        backend.restoreSystemCapture()
        await Task.yield()
        #expect(session.sourceHealth[.systemAudio]?.status == .capturing)
        _ = session.stop()
    }

    @Test func delayedAndLostChunksPreserveWallClockGaps() async throws {
        let root = temporaryDirectory("clock-gaps")
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = DeterministicMeetingCaptureBackend()
        let session = MeetingRecordingSession(libraryRoot: root, captureBackend: backend)
        var chunks: [MeetingAudioChunk] = []
        session.onAudioChunk = { chunks.append($0) }
        try session.start(sources: .microphone)

        try backend.emit(.microphone, seconds: 0.25, at: 0)
        try backend.emit(.microphone, seconds: 0.25, at: 1.0)
        let recording = try #require(session.stop())

        #expect(chunks.count == 2)
        #expect(abs((chunks[1].timestamp - chunks[0].timestamp) - 1.0) < 0.01)
        let manifest = try #require(MeetingRecordingStore.readManifest(in: recording.folder))
        let track = try #require(manifest.tracks.first)
        #expect(track.frames == 8_000)
        #expect(track.duration >= 1.24)
        #expect(track.clockAnchors.count >= 2)
    }

    @Test func sourceClockDriftCreatesAPersistedAnchor() async throws {
        let root = temporaryDirectory("clock-drift")
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = DeterministicMeetingCaptureBackend()
        let session = MeetingRecordingSession(libraryRoot: root, captureBackend: backend)
        try session.start(sources: .systemAudio)

        try backend.emit(.systemAudio, seconds: 0.5, at: 0)
        try backend.emit(.systemAudio, seconds: 0.5, at: 0.52)
        let recording = try #require(session.stop())
        let manifest = try #require(MeetingRecordingStore.readManifest(in: recording.folder))
        let track = try #require(manifest.tracks.first)
        #expect(track.clockAnchors.count == 2)
        #expect(abs((track.clockAnchors.last?.meetingTime ?? 0) - 0.52) < 0.01)
    }

    @Test func explicitDroppedFramesAdvanceHealthAndClockMetadata() async throws {
        let root = temporaryDirectory("clock-drop")
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = DeterministicMeetingCaptureBackend()
        let session = MeetingRecordingSession(libraryRoot: root, captureBackend: backend)
        try session.start(sources: .systemAudio)
        try backend.emit(.systemAudio, seconds: 0.25, at: 0)
        backend.drop(.systemAudio, frames: 4_000, at: 0.25)
        try backend.emit(.systemAudio, seconds: 0.25, at: 0.5)

        let recording = try #require(session.stop())
        #expect(session.sourceHealth[.systemAudio]?.droppedFrames == 4_000)
        let manifest = try #require(MeetingRecordingStore.readManifest(in: recording.folder))
        #expect(manifest.tracks.first?.clockAnchors.count ?? 0 >= 2)
        #expect(manifest.issues.contains { $0.code == "capture-overrun" })
    }

    @Test func stoppingDisconnectsLateCaptureFromTheNextSession() async throws {
        let root = temporaryDirectory("session-race")
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = DeterministicMeetingCaptureBackend()
        let session = MeetingRecordingSession(libraryRoot: root, captureBackend: backend)
        var received: [UUID] = []
        session.onAudioChunk = { received.append($0.sessionID) }

        let first = UUID()
        try session.start(
            sources: .microphone,
            target: .allSystemAudio,
            sessionID: first,
            transcriptionSnapshot: nil
        )
        try backend.emit(.microphone, seconds: 0.1)
        _ = session.stop()
        try backend.emit(.microphone, seconds: 0.1)

        let second = UUID()
        try session.start(
            sources: .microphone,
            target: .allSystemAudio,
            sessionID: second,
            transcriptionSnapshot: nil
        )
        try backend.emit(.microphone, seconds: 0.1)
        _ = session.stop()

        #expect(received == [first, second])
    }

    @Test func meetingMicrophoneMigratesAndPersistsAClockDiscontinuity() async throws {
        let root = temporaryDirectory("microphone-switch")
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = DeterministicMeetingCaptureBackend()
        backend.emitMicrophoneImmediatelyAfterSwitch = true
        let session = MeetingRecordingSession(libraryRoot: root, captureBackend: backend)
        try session.start(sources: .microphone)
        try backend.emit(.microphone, seconds: 0.25, at: 0)

        NotificationCenter.default.post(
            name: .audioDeviceSwitchRequired,
            object: nil,
            userInfo: ["newDeviceID": AudioDeviceID(9)]
        )

        let recording = try #require(session.stop())
        let manifest = try #require(MeetingRecordingStore.readManifest(in: recording.folder))
        let track = try #require(manifest.tracks.first)
        #expect(track.clockAnchors.count >= 2)
        #expect(zip(track.clockAnchors, track.clockAnchors.dropFirst()).contains { pair in
            pair.0.fileFrame == pair.1.fileFrame && pair.0.meetingTime <= pair.1.meetingTime
        })
        #expect(manifest.issues.contains { $0.code == "microphone-device-switched" })
    }

    @Test func wallClockJumpDoesNotChangeMeetingDuration() throws {
        let root = temporaryDirectory("monotonic-duration")
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = DeterministicMeetingCaptureBackend()
        var uptime: TimeInterval = 100
        var wallClock = Date(timeIntervalSince1970: 1_700_000_000)
        let session = MeetingRecordingSession(
            libraryRoot: root,
            captureBackend: backend,
            monotonicNow: { uptime },
            wallClockNow: { wallClock }
        )
        try session.start(sources: .microphone)
        try backend.emit(.microphone, seconds: 0.25)

        uptime += 12.5
        wallClock = wallClock.addingTimeInterval(86_400)
        let recording = try #require(session.stop())
        let manifest = try #require(MeetingRecordingStore.readManifest(in: recording.folder))

        #expect(abs(recording.duration - 12.5) < 0.001)
        #expect(abs(manifest.duration - 12.5) < 0.001)
    }

    @Test func recoveryRejectsImplausibleWallClockDuration() throws {
        let root = temporaryDirectory("clock-jump-recovery-root")
        let folder = root.appendingPathComponent("meeting", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("microphone.wav")
        let frames = AVAudioFrameCount(16_000)
        let buffer = try #require(AVAudioPCMBuffer(
            pcmFormat: SystemAudioTrackWriter.targetFormat,
            frameCapacity: frames
        ))
        buffer.frameLength = frames
        try {
            let file = try AVAudioFile(
                forWriting: url,
                settings: SystemAudioTrackWriter.targetFormat.settings,
                commonFormat: .pcmFormatInt16,
                interleaved: true
            )
            try file.write(from: buffer)
        }()
        let manifest = MeetingRecordingStore.Manifest(
            sessionID: UUID(),
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            status: .interrupted,
            duration: 86_400,
            captureTarget: .allSystemAudio,
            requestedSources: [.microphone],
            tracks: [
                .init(
                    source: .microphone,
                    fileName: url.lastPathComponent,
                    startOffset: 0,
                    duration: 1,
                    frames: 16_000
                )
            ]
        )
        try MeetingRecordingStore.writeManifest(manifest, into: folder)

        let store = MeetingRecordingStore(libraryRoot: root)
        store.reload()
        let recovered = try #require(store.items.first { $0.id == folder.lastPathComponent })
        #expect(abs(recovered.duration - 1) < 0.001)
    }

    @Test func failedMicrophoneMigrationDoesNotClaimDeadCaptureContinues() async throws {
        let root = temporaryDirectory("microphone-switch-failure")
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = DeterministicMeetingCaptureBackend()
        backend.microphoneSwitchFailsWithoutRollback = true
        let session = MeetingRecordingSession(libraryRoot: root, captureBackend: backend)
        try session.start(sources: .microphone)

        NotificationCenter.default.post(
            name: .audioDeviceSwitchRequired,
            object: nil,
            userInfo: ["newDeviceID": AudioDeviceID(10)]
        )
        await Task.yield()

        #expect(!backend.microphoneCaptureIsActive)
        #expect(session.sourceHealth[.microphone]?.status == .failed)
        #expect(session.issues.contains { $0.code == "microphone-device-switch-failed" })
        _ = session.stop()
    }

    @Test func transientMicrophoneMigrationFailureRetriesWithoutAnotherNotification() async throws {
        let root = temporaryDirectory("microphone-switch-retry")
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = DeterministicMeetingCaptureBackend()
        backend.microphoneSwitchFailuresRemaining = 1
        let session = MeetingRecordingSession(libraryRoot: root, captureBackend: backend)
        try session.start(sources: .microphone)

        NotificationCenter.default.post(
            name: .audioDeviceSwitchRequired,
            object: nil,
            userInfo: ["newDeviceID": AudioDeviceID(11)]
        )
        await Task.yield()
        #expect(!backend.microphoneCaptureIsActive)

        session.retryPendingMicrophoneForTesting()
        #expect(backend.microphoneCaptureIsActive)
        #expect(session.issues.contains { $0.code == "microphone-device-switched" })
        _ = session.stop()
    }

    @Test func controllerCanCompleteWithoutAudioHardware() async throws {
        let root = temporaryDirectory("controller")
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = DeterministicMeetingCaptureBackend()
        let session = MeetingRecordingSession(libraryRoot: root, captureBackend: backend)
        let controller = MeetingRecordingController(engine: nil, session: session)

        controller.start(request: .init(
            sources: .all,
            target: .allSystemAudio,
            identifySpeakers: false
        ))
        #expect(controller.lifecycle.phase == .capturing)
        try backend.emit(.microphone, seconds: 0.25)
        try backend.emit(.systemAudio, seconds: 0.25)
        await controller.stop()

        #expect(controller.lifecycle.phase == .ready)
        #expect(controller.lastRecording != nil)
        #expect(controller.processingProgress == 1)
    }

    @Test func initialManifestFailureAbortsBeforeOpeningCapture() throws {
        struct SimulatedDiskError: Error {}
        let root = temporaryDirectory("manifest-failure")
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = DeterministicMeetingCaptureBackend()
        let session = MeetingRecordingSession(
            libraryRoot: root,
            captureBackend: backend,
            manifestWriter: { _, _ in throw SimulatedDiskError() }
        )

        #expect(throws: MeetingRecordingSession.SessionError.self) {
            try session.start(sources: .microphone)
        }
        #expect(session.state == .idle)
        #expect(backend.startedSources.isEmpty)
    }

    @Test func boundedLiveQueueReportsARecoverableGap() async {
        let gaps = Locked<[MeetingTranscriber.Gap]>([])
        let transcriber = MeetingTranscriber(
            source: .microphone,
            windowSeconds: 0.1,
            overlapSeconds: 0,
            maximumQueuedWindows: 1
        ) { _ in
            try await Task.sleep(for: .milliseconds(40))
            return "hello"
        }
        transcriber.onGap = { gap in gaps.withValue { $0.append(gap) } }
        transcriber.start()
        for _ in 0..<20 {
            transcriber.append(Self.pcm(seconds: 0.1))
        }
        await transcriber.finish()

        #expect(!gaps.value.isEmpty)
        #expect(gaps.value.allSatisfy { $0.source == .microphone })
    }

    @Test func overlappingWordsAreNotDuplicated() {
        let result = MeetingTranscriber.reconcile(
            previous: "we should ship the new recording system tomorrow",
            next: "recording system tomorrow after the final review"
        )
        #expect(result == "after the final review")
    }

    @Test func fuzzyOverlapReconciliationTrimsProviderWordVariation() {
        let result = MeetingTranscriber.reconcileResult(
            previous: "we reviewed the recording system today",
            next: "recording systems today and approved it"
        )
        #expect(result.text == "and approved it")
        #expect(result.droppedPrefixWords == 3)
    }

    @Test func trimmedOverlapAdvancesTheNextSegmentTimestamp() async {
        let callCount = Locked(0)
        let segments = Locked<[MeetingTranscriber.Segment]>([])
        let transcriber = MeetingTranscriber(
            source: .microphone,
            windowSeconds: 0.1,
            overlapSeconds: 0.02,
            maximumQueuedWindows: 2
        ) { _ in
            var index = 0
            callCount.withValue {
                index = $0
                $0 += 1
            }
            return index == 0
                ? "we reviewed the recording system today"
                : "recording systems today and approved it"
        }
        transcriber.onSegment = { segment in segments.withValue { $0.append(segment) } }
        transcriber.start()
        transcriber.append(Self.pcm(seconds: 0.18))
        await transcriber.finish()

        let output = segments.value.sorted { $0.start < $1.start }
        #expect(output.count == 2)
        #expect(output.last?.text == "and approved it")
        #expect((output.last?.start ?? 0) >= 0.099)
    }

    @Test func cloudCoverageRetriesOnlyUncoveredRanges() {
        let missing = MeetingRecordingController.uncoveredRanges(
            within: 0...120,
            coveredBy: [0...30, 28...60, 70...120]
        )
        #expect(missing == [60...70])
    }

    @Test func disjointCloudRetryRangesDoNotShareOverlapContext() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "zerm-disjoint-retry-\(UUID().uuidString).wav"
        )
        defer { try? FileManager.default.removeItem(at: url) }
        let frames = AVAudioFrameCount(90 * 16_000)
        let buffer = try #require(AVAudioPCMBuffer(
            pcmFormat: SystemAudioTrackWriter.targetFormat,
            frameCapacity: frames
        ))
        buffer.frameLength = frames
        // Release the writer before the transcriber opens the same URL. Keeping AVAudioFile
        // alive until the end of this async test made the full parallel suite intermittently
        // observe an unflushed zero-length file even though the isolated test passed.
        try {
            let file = try AVAudioFile(
                forWriting: url,
                settings: SystemAudioTrackWriter.targetFormat.settings,
                commonFormat: .pcmFormatInt16,
                interleaved: true
            )
            try file.write(from: buffer)
        }()

        let transcriber = MeetingTranscriber(source: .microphone) { _ in
            "the repeated agenda phrase"
        }
        let segments = try await transcriber.transcribeFile(
            url,
            source: .microphone,
            meetingRanges: [0...1, 60...61]
        )
        #expect(segments.count == 2)
        #expect(segments.allSatisfy { $0.text == "the repeated agenda phrase" })
    }

    @Test func rewritingALegacyV2ManifestUpgradesItsSchemaContract() throws {
        let folder = temporaryDirectory("manifest-v2-upgrade")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let legacy = MeetingRecordingStore.Manifest(
            schemaVersion: 2,
            sessionID: UUID(),
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            status: .partial,
            duration: 42,
            captureTarget: .allSystemAudio,
            requestedSources: [.microphone],
            tracks: [
                .init(
                    source: .microphone,
                    fileName: "microphone.wav",
                    startOffset: 0,
                    duration: 42,
                    frames: 672_000
                )
            ],
            transcriptionStatus: .pending,
            diarizationStatus: .notRequested
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(legacy).write(
            to: folder.appendingPathComponent(MeetingRecordingStore.manifestName),
            options: .atomic
        )

        let decoded = try #require(MeetingRecordingStore.readManifest(in: folder))
        #expect(decoded.schemaVersion == 2)
        try MeetingRecordingStore.writeManifest(decoded, into: folder)
        let upgraded = try #require(MeetingRecordingStore.readManifest(in: folder))
        #expect(upgraded.schemaVersion == MeetingRecordingStore.Manifest.currentSchemaVersion)
    }

    private static func pcm(seconds: Double, value: Int16 = 1_000) -> Data {
        let samples = Int(seconds * 16_000)
        var value = value.littleEndian
        return Data(bytes: &value, count: MemoryLayout<Int16>.size).repeated(samples)
    }

    private func temporaryDirectory(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "zerm-\(name)-\(UUID().uuidString)",
            isDirectory: true
        )
    }
}

private final class DeterministicMeetingCaptureBackend: MeetingCaptureBackend {
    var onChunk: ((MeetingCaptureDelivery) -> Void)?
    var onFailure: ((MeetingAudioSource, Error) -> Void)?
    var onInterruption: ((MeetingAudioSource, Error) -> Void)?
    var onDroppedFrames: ((MeetingCaptureDiscontinuity) -> Void)?
    var onStateChange: ((MeetingAudioSource, MeetingSourceHealth.Status, String?) -> Void)?

    var microphoneLevelDb: Float = -24
    var microphoneCaptureIsActive: Bool { activeSources.contains(.microphone) }
    var systemAudioLevelDb: Float = -24
    var systemAudioHasSignal = false
    var systemStartsWaiting = false
    var emitMicrophoneImmediatelyAfterSwitch = false
    var microphoneSwitchFailsWithoutRollback = false
    var microphoneSwitchFailuresRemaining = 0

    private var microphoneFile: AVAudioFile?
    private var systemFile: AVAudioFile?
    private var originNanos = AudioConvertHostTimeToNanos(AudioGetCurrentHostTime())
    private var framesBySource: [MeetingAudioSource: Int64] = [:]
    private var activeSources = Set<MeetingAudioSource>()
    private var microphoneDeviceID = AudioDeviceID(1)
    var startedSources: Set<MeetingAudioSource> { activeSources }

    func startMicrophone(writingTo url: URL) throws {
        beginSessionIfNeeded()
        activeSources.insert(.microphone)
        microphoneFile = try AVAudioFile(
            forWriting: url,
            settings: SystemAudioTrackWriter.targetFormat.settings,
            commonFormat: .pcmFormatInt16,
            interleaved: true
        )
    }

    func startSystemAudio(writingTo url: URL, target: MeetingCaptureTarget) throws {
        beginSessionIfNeeded()
        activeSources.insert(.systemAudio)
        systemFile = try AVAudioFile(
            forWriting: url,
            settings: SystemAudioTrackWriter.targetFormat.settings,
            commonFormat: .pcmFormatInt16,
            interleaved: true
        )
        if systemStartsWaiting {
            onStateChange?(
                .systemAudio,
                .degraded,
                "Waiting for the selected application to begin playing audio."
            )
        }
    }

    func stopMicrophone() {
        microphoneFile = nil
        activeSources.remove(.microphone)
    }

    @discardableResult
    func switchMicrophone(
        to deviceID: AudioDeviceID,
        beforeRestart: () -> Void
    ) throws -> Bool {
        guard deviceID != microphoneDeviceID else { return false }
        if microphoneSwitchFailsWithoutRollback || microphoneSwitchFailuresRemaining > 0 {
            microphoneSwitchFailuresRemaining = max(0, microphoneSwitchFailuresRemaining - 1)
            activeSources.remove(.microphone)
            throw NSError(
                domain: "MeetingCaptureTest",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "simulated migration and rollback failure"]
            )
        }
        microphoneDeviceID = deviceID
        beforeRestart()
        activeSources.insert(.microphone)
        if emitMicrophoneImmediatelyAfterSwitch {
            try emit(.microphone, seconds: 0.25, at: 0.5)
        }
        return true
    }
    func stopSystemAudio() {
        systemFile = nil
        activeSources.remove(.systemAudio)
    }

    private func beginSessionIfNeeded() {
        guard activeSources.isEmpty else { return }
        originNanos = AudioConvertHostTimeToNanos(AudioGetCurrentHostTime())
        framesBySource = [:]
    }

    func emit(
        _ source: MeetingAudioSource,
        seconds: Double,
        value: Int16 = 1_000,
        at explicitTime: TimeInterval? = nil
    ) throws {
        let frames = AVAudioFrameCount(seconds * 16_000)
        let buffer = AVAudioPCMBuffer(
            pcmFormat: SystemAudioTrackWriter.targetFormat,
            frameCapacity: frames
        )!
        buffer.frameLength = frames
        for index in 0..<Int(frames) { buffer.int16ChannelData![0][index] = value }
        let file = source == .systemAudio ? systemFile : microphoneFile
        try file?.write(from: buffer)
        if source == .systemAudio { systemAudioHasSignal = true }
        let data = Data(
            bytes: buffer.int16ChannelData![0],
            count: Int(frames) * MemoryLayout<Int16>.size
        )
        let priorFrames = framesBySource[source] ?? 0
        let time = explicitTime ?? Double(priorFrames) / 16_000
        onChunk?(.init(
            source: source,
            data: data,
            hostTimeNanos: originNanos + UInt64(max(0, time) * 1_000_000_000),
            sampleTime: Double(priorFrames),
            sourceSampleRate: 16_000,
            frameCount: Int(frames)
        ))
        framesBySource[source] = priorFrames + Int64(frames)
    }

    func fail(_ source: MeetingAudioSource, message: String) {
        onFailure?(source, NSError(
            domain: "MeetingCaptureTest",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        ))
    }

    func interrupt(_ source: MeetingAudioSource, message: String) {
        onInterruption?(source, NSError(
            domain: "MeetingCaptureTest",
            code: 3,
            userInfo: [NSLocalizedDescriptionKey: message]
        ))
    }

    func restoreSystemCapture() {
        systemStartsWaiting = false
        onStateChange?(.systemAudio, .capturing, nil)
    }

    func drop(_ source: MeetingAudioSource, frames: Int64, at time: TimeInterval) {
        onDroppedFrames?(.init(
            source: source,
            droppedFrames: frames,
            hostTimeNanos: originNanos + UInt64(max(0, time) * 1_000_000_000),
            sourceSampleTime: Double(framesBySource[source] ?? 0),
            sourceSampleRate: 16_000
        ))
        framesBySource[source, default: 0] += frames
    }
}

private final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) { storage = value }

    func withValue(_ body: (inout Value) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        body(&storage)
    }

    var value: Value {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

private extension Data {
    func repeated(_ count: Int) -> Data {
        var result = Data(capacity: self.count * count)
        for _ in 0..<count { result.append(self) }
        return result
    }
}
