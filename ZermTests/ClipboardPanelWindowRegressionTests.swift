import AppKit
import XCTest
@testable import Zerm

@MainActor
final class ClipboardPanelWindowRegressionTests: XCTestCase {
    func testForegroundWindowUsesFrontmostEligibleWindowAndBeatsPointer() {
        let screens = [
            CGRect(x: -1_440, y: 0, width: 1_440, height: 900),
            CGRect(x: 0, y: 0, width: 1_920, height: 1_080),
        ]
        let smallForegroundWindow = CGRect(x: -1_300, y: 80, width: 600, height: 500)

        XCTAssertEqual(
            ClipboardHistoryPanelController.preferredScreenIndex(
                foregroundWindow: smallForegroundWindow,
                pointer: CGPoint(x: 400, y: 300),
                screens: screens
            ),
            0
        )
    }

    func testFrontToBackResolverSkipsIneligibleWindowsWithoutChoosingLargest() {
        let owner: Int32 = 42
        let candidates: [ClipboardHistoryPanelController.ForegroundWindowCandidate] = [
            .init(ownerProcessID: owner, layer: 0, alpha: 1, quartzFrame: CGRect(x: 10, y: 20, width: 40, height: 40)),
            .init(ownerProcessID: owner, layer: 0, alpha: 1, quartzFrame: CGRect(x: -1_000, y: 100, width: 640, height: 480)),
            .init(ownerProcessID: owner, layer: 0, alpha: 1, quartzFrame: CGRect(x: 0, y: 0, width: 1_800, height: 1_000)),
        ]

        XCTAssertEqual(
            ClipboardHistoryPanelController.foregroundWindowFrame(fromFrontToBack: candidates, ownerProcessID: owner),
            candidates[1].quartzFrame
        )
    }

    func testQuartzConversionHandlesUpperScreenAndNegativeOrigin() {
        let primary = CGRect(x: 0, y: 0, width: 1_440, height: 900)
        let quartz = CGRect(x: -1_200, y: -180, width: 1_000, height: 500)

        XCTAssertEqual(
            ClipboardHistoryPanelController.appKitFrame(fromQuartz: quartz, primaryScreenFrame: primary),
            CGRect(x: -1_200, y: 580, width: 1_000, height: 500)
        )
    }

    func testPointerChoosesDisplayWhenForegroundWindowUnavailable() {
        let screens = [
            CGRect(x: -1_440, y: 0, width: 1_440, height: 900),
            CGRect(x: 0, y: 0, width: 1_920, height: 1_080),
        ]

        XCTAssertEqual(
            ClipboardHistoryPanelController.preferredScreenIndex(
                foregroundWindow: nil,
                pointer: CGPoint(x: -800, y: 450),
                screens: screens
            ),
            0
        )
    }

    func testFrameClampsSizeAndOriginInsideSmallNegativeOriginDisplay() {
        let visible = CGRect(x: -800, y: -300, width: 700, height: 400)
        let proposed = CGRect(x: -1_200, y: -500, width: 820, height: 444)

        XCTAssertEqual(ClipboardHistoryPanelController.clampedFrame(proposed, to: visible), visible)
    }

    func testRestoredFrameRaisesLegacySizeBeforeClamping() {
        let visible = CGRect(x: -1_000, y: -200, width: 1_400, height: 800)
        let undersized = CGRect(x: -900, y: -100, width: 200, height: 100)

        XCTAssertEqual(
            ClipboardHistoryPanelController.restoredFrame(
                undersized,
                within: visible,
                minimumSize: CGSize(width: 740, height: 420)
            ),
            CGRect(x: -900, y: -100, width: 740, height: 420)
        )
    }

    func testDisplaySelectionReturnsNilWithoutScreens() {
        XCTAssertNil(
            ClipboardHistoryPanelController.preferredScreenIndex(
                foregroundWindow: CGRect(x: 0, y: 0, width: 100, height: 100),
                pointer: .zero,
                screens: []
            )
        )
    }

    func testCloseAndReopenReusesPanelModelAndRefreshesPasteTarget() async throws {
        let suiteName = "ClipboardPanelWindowRegressionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }
        let store = try ClipboardHistoryStore(directoryURL: directory, keyData: Data(repeating: 7, count: 32), defaults: defaults)
        let items = try (0..<102).map { index -> ClipboardItem in
            try XCTUnwrap(ClipboardItem.capture(
                representations: [ClipboardRepresentation(
                    type: "public.utf8-plain-text",
                    data: Data("Panel history item \(index)".utf8)
                )],
                sourceApp: ClipboardSourceApp(bundleIdentifier: "test.panel", name: "Panel Test")
            ))
        }
        _ = try await store.captureBatch(items)

        let controller = ClipboardHistoryPanelController(defaults: defaults)
        controller.show(store: store, frontmostApplication: nil, present: false)
        let firstPanel = try XCTUnwrap(controller.panel)
        let model = try XCTUnwrap(controller.model)
        await model.loadItems()
        await model.loadMore()
        XCTAssertEqual(model.items.count, items.count)
        model.query = "Panel history"
        try await Task.sleep(for: .milliseconds(180))
        await model.loadItems()
        await model.loadMore()
        XCTAssertEqual(model.items.count, items.count)
        model.select(try XCTUnwrap(model.items.last))
        model.commandQuery = "stale command"
        model.commandSelectionID = "paste"
        model.isCommandPaletteVisible = true
        let firstPresentationID = model.presentationID
        let selectedIDs = model.selectedIDs

        controller.close()
        XCTAssertFalse(firstPanel.isVisible)
        XCTAssertEqual(model.query, "Panel history")
        XCTAssertEqual(model.commandQuery, "")
        XCTAssertNil(model.commandSelectionID)
        XCTAssertFalse(model.isCommandPaletteVisible)

        let refreshedTarget = NSRunningApplication.current
        controller.show(store: store, frontmostApplication: refreshedTarget, present: false)
        XCTAssertTrue(controller.panel === firstPanel)
        XCTAssertTrue(controller.model === model)
        XCTAssertEqual(controller.targetApplicationProcessIdentifier, refreshedTarget.processIdentifier)
        await model.loadItems(preservingLoadedPage: true)
        XCTAssertEqual(model.query, "Panel history")
        XCTAssertEqual(model.items.count, items.count)
        XCTAssertEqual(model.selectedIDs, selectedIDs)
        XCTAssertGreaterThan(model.presentationID, firstPresentationID)

        let replacementStore = try ClipboardHistoryStore(
            directoryURL: directory.appendingPathComponent("replacement", isDirectory: true),
            keyData: Data(repeating: 9, count: 32),
            defaults: defaults
        )
        controller.close()
        controller.show(store: replacementStore, frontmostApplication: nil, present: false)
        XCTAssertFalse(controller.panel === firstPanel)
        XCTAssertFalse(controller.model === model)
        controller.close()
    }
}
