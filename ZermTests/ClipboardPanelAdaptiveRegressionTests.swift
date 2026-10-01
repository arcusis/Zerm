import AppKit
import SwiftUI
import Testing

@testable import Zerm

@MainActor
struct ClipboardPanelAdaptiveRegressionTests {
    @Test func constrainedProposalsKeepPanelAndCommandPaletteInsideBounds() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipboard-panel-adaptive-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suiteName = "clipboard-panel-adaptive-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = try ClipboardHistoryStore(directoryURL: directory, keyData: Data(repeating: 7, count: 32), defaults: defaults)
        let item = try #require(ClipboardItem.capture(
            representations: [.init(type: "public.utf8-plain-text", data: Data("Clipboard layout sample with a long readable title".utf8))],
            sourceApp: .init(bundleIdentifier: "test.editor", name: "Editor")
        ))

        let sizes: [NSSize] = [NSSize(width: 740, height: 420), NSSize(width: 700, height: 400), NSSize(width: 640, height: 360)]
        let queries = ["", String(repeating: "long search query ", count: 30)]
        for localeID in ["en", "he"] {
            for size in sizes {
                for collapsed in [false, true] {
                    for preview in [false, true] {
                        for commandState in [false, true] {
                            for filter in [ClipboardPanelRailFilter.history, .favorites] {
                                let model = ClipboardHistoryPanelModel(store: store, defaults: defaults, initialItems: [item])
                                model.select(item)
                                model.isSidebarCollapsed = collapsed
                                model.isPreviewVisible = preview
                                model.isDetailsVisible = true
                                model.railFilter = filter
                                model.isCommandPaletteVisible = commandState
                                model.commandQuery = commandState && size.width == 640 ? "no matching command result" : ""
                                model.query = queries[localeID == "he" && size.width < 700 ? 1 : 0]
                                let direction: LayoutDirection = localeID == "he" ? .rightToLeft : .leftToRight
                                let root = ClipboardHistoryPanelView(model: model)
                                    .environment(\.locale, Locale(identifier: localeID))
                                    .environment(\.layoutDirection, direction)
                                let host = NSHostingController(rootView: root)
                                let fitting = host.sizeThatFits(in: size)
                                host.view.frame = NSRect(origin: .zero, size: size)
                                host.view.layoutSubtreeIfNeeded()
                                #expect(fitting.width <= size.width, "\(localeID), \(size), sidebar collapsed \(collapsed), preview \(preview), commands \(commandState), filter \(filter): width \(fitting.width)")
                                #expect(fitting.height <= size.height, "\(localeID), \(size), sidebar collapsed \(collapsed), preview \(preview), commands \(commandState), filter \(filter): height \(fitting.height)")
                                #expect(host.view.bounds.width == size.width)
                                #expect(host.view.bounds.height == size.height)
                                if RenderSnapshots.isEnabled, !collapsed, preview, filter == .history {
                                    try await ClipboardHistoryRenderSupport.render(
                                        root,
                                        name: "panel-\(Int(size.width))-\(localeID)-commands-\(commandState).png",
                                        size: size,
                                        appearance: .aqua,
                                        locale: Locale(identifier: localeID),
                                        in: URL(fileURLWithPath: "/tmp/zerm-work/clipboard-adaptive", isDirectory: true)
                                    )
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
