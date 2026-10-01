import AppKit
import Foundation
import SwiftUI
import Testing

@testable import Zerm

@Suite(.serialized)
struct ClipboardPanelInterfaceRegressionTests {
    @MainActor
    @Test func sidebarAndPreviewCombinationsFitAndRenderAtMinimumWindow() throws {
        let suite = "ClipboardPanelInterfaceRegressionTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let store = try ClipboardHistoryStore(directoryURL: directory, keyData: Data(repeating: 9, count: 32), defaults: defaults)
        let item = try #require(ClipboardItem.capture(
            representations: [ClipboardRepresentation(type: NSPasteboard.PasteboardType.string.rawValue, data: Data(String(repeating: "Readable selection ", count: 16).utf8))],
            sourceApp: ClipboardSourceApp(bundleIdentifier: "com.example.editor", name: "Example Editor")
        ))
        let minimum = ClipboardHistoryPanel.minimumContentSize

        for collapsed in [false, true] {
            for previewVisible in [false, true] {
                let model = ClipboardHistoryPanelModel(store: store, defaults: defaults, initialItems: [item])
                model.isSidebarCollapsed = collapsed
                model.isPreviewVisible = previewVisible
                model.isDetailsVisible = false
                model.select(item)
                let host = NSHostingController(rootView: ClipboardHistoryPanelView(model: model))
                let fitting = host.sizeThatFits(in: minimum)
                #expect(fitting.width <= minimum.width, "collapsed \(collapsed), preview \(previewVisible): needs \(fitting.width) pt")
                #expect(fitting.height <= minimum.height, "collapsed \(collapsed), preview \(previewVisible): needs \(fitting.height) pt tall")
                try render(host.view, at: minimum)
            }
        }
    }

    @MainActor
    @Test func searchableCommandsAndNoResultsRenderAtMinimumWindow() throws {
        let suite = "ClipboardPanelCommandsRenderTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let store = try ClipboardHistoryStore(directoryURL: directory, keyData: Data(repeating: 4, count: 32), defaults: defaults)
        let model = ClipboardHistoryPanelModel(store: store, defaults: defaults)
        model.registry.register(ClipboardPanelCommand(id: "test.copy", title: "Copy", shortcut: "⌘C", perform: { _ in }))
        model.registry.register(ClipboardPanelCommand(id: "test.delete", title: "Delete", perform: { _ in }))
        model.isCommandPaletteVisible = true
        model.commandSelectionID = "test.delete"

        let minimum = ClipboardHistoryPanel.minimumContentSize
        let host = NSHostingController(rootView: ClipboardHistoryPanelView(model: model))
        let fitting = host.sizeThatFits(in: minimum)
        #expect(fitting.width <= minimum.width)
        #expect(fitting.height <= minimum.height)
        try render(host.view, at: minimum)

        model.commandQuery = "no command matches this"
        host.view.layoutSubtreeIfNeeded()
        try render(host.view, at: minimum)
    }

    @MainActor
    private func render(_ view: NSView, at size: NSSize) throws {
        view.frame = NSRect(origin: .zero, size: size)
        view.layoutSubtreeIfNeeded()
        view.needsDisplay = true
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        #expect(bitmap.pixelsWide > 0)
        #expect(bitmap.pixelsHigh > 0)
    }
}
