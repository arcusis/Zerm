import Foundation
import Testing
@testable import Zerm

@MainActor
struct SystemAudioCaptureReadinessTests {
    @Test func activeMeetingPreventsTheReadinessProbe() {
        let readiness = SystemAudioCaptureReadiness(
            verificationToken: "active-meeting-test",
            isMeetingActive: { true },
            probe: { .verified }
        )

        readiness.test()
        #expect(readiness.status == .failed("Stop the active meeting before testing system audio."))
    }

    @Test func successfulProbeIsRememberedOnlyForTheCurrentBuildAndOS() async {
        let suite = "zerm.tests.system-audio.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let readiness = SystemAudioCaptureReadiness(
            defaults: defaults,
            verificationToken: "build-282-os-26",
            isMeetingActive: { false },
            probe: { .verified }
        )
        #expect(readiness.status == .notTested)

        readiness.test()
        await Task.yield()
        await Task.yield()
        guard case .verified = readiness.status else {
            Issue.record("A successful end-to-end probe should be shown as verified")
            return
        }

        let sameRuntime = SystemAudioCaptureReadiness(
            defaults: defaults,
            verificationToken: "build-282-os-26",
            isMeetingActive: { false },
            probe: { .verified }
        )
        guard case .verified = sameRuntime.status else {
            Issue.record("The same build and OS should remember the verified result")
            return
        }

        let changedRuntime = SystemAudioCaptureReadiness(
            defaults: defaults,
            verificationToken: "build-283-os-26",
            isMeetingActive: { false },
            probe: { .verified }
        )
        #expect(changedRuntime.status == .notTested)
    }

    @Test func failedProbeDoesNotLeaveAStaleGreenState() async {
        let suite = "zerm.tests.system-audio.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let readiness = SystemAudioCaptureReadiness(
            defaults: defaults,
            verificationToken: "test-runtime",
            isMeetingActive: { false },
            probe: { .failed("No signal returned") }
        )
        readiness.test()
        await Task.yield()
        await Task.yield()

        #expect(readiness.status == .failed("No signal returned"))

        let relaunched = SystemAudioCaptureReadiness(
            defaults: defaults,
            verificationToken: "test-runtime",
            isMeetingActive: { false },
            probe: { .verified }
        )
        #expect(relaunched.status == .notTested)
    }
}
