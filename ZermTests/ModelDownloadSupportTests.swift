import XCTest
@testable import Zerm

final class ModelDownloadSupportTests: XCTestCase {
    func testStateMachinePauseResumeCancelFailureAndCompletion() {
        var machine = ModelDownloadStateMachine()
        machine.start()
        machine.update(bytesDownloaded: 30, totalBytes: 100)
        XCTAssertEqual(machine.state.fractionCompleted, 0.3)
        machine.pause()
        XCTAssertEqual(machine.state.phase, .paused)
        machine.start(resuming: true)
        XCTAssertEqual(machine.state.phase, .resuming)
        machine.fail("network")
        XCTAssertEqual(machine.state.phase, .failed)
        XCTAssertEqual(machine.state.message, "network")
        machine.cancel()
        XCTAssertEqual(machine.state.phase, .queued)
        machine.complete()
        XCTAssertEqual(machine.state.phase, .completed)
        XCTAssertEqual(machine.state.fractionCompleted, 1)
    }

    func testDownloadStateAndResumeDataPersistAndRestore() throws {
        let suite = "ModelDownloadSupportTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let stateStore = ModelDownloadStateStore(defaults: defaults, keyPrefix: suite)
        let state = ModelDownloadState(phase: .paused, fractionCompleted: 0.3, bytesDownloaded: 30, totalBytes: 100)
        try stateStore.save(state, for: "asset")
        XCTAssertEqual(stateStore.load(for: "asset"), state)

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let resumeStore = ModelDownloadResumeDataStore(directory: directory)
        let resumeData = Data([1, 2, 3, 4])
        try resumeStore.save(resumeData, for: "asset/a")
        XCTAssertEqual(resumeStore.load(for: "asset/a"), resumeData)
        resumeStore.remove(for: "asset/a")
        XCTAssertNil(resumeStore.load(for: "asset/a"))
    }

    func testAcceptanceRepeatsOnlyWhenLicenseVersionChangesAndGatesTerms() throws {
        let suite = "ModelDownloadAcceptanceTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ModelDownloadAcceptanceStore(defaults: defaults, keyPrefix: suite)
        XCTAssertFalse(store.hasAccepted(assetID: "model", licenseVersion: "v1"))
        store.accept(assetID: "model", licenseVersion: "v1")
        XCTAssertTrue(store.hasAccepted(assetID: "model", licenseVersion: "v1"))
        XCTAssertFalse(store.hasAccepted(assetID: "model", licenseVersion: "v2"))

        let explicitTerms = ModelProvenance(
            creator: "Google", sourceURL: URL(string: "https://example.com/model")!, downloadHost: "example.com",
            licenseName: "Gemma Community License", licenseSPDX: nil,
            licenseURL: URL(string: "https://example.com/terms")!, attribution: "Google", conversionCredit: nil,
            checksumSHA256: nil
        )
        XCTAssertFalse(ModelDownloadNoticePolicy.canDownload(assetID: "gemma-3-1b-it-Q4_K_M.gguf", provenance: explicitTerms, agreed: false))
        XCTAssertTrue(ModelDownloadNoticePolicy.canDownload(assetID: "gemma-3-1b-it-Q4_K_M.gguf", provenance: explicitTerms, agreed: true))
    }
}
