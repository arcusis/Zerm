import Foundation
import Testing

@testable import Zerm

@Suite(.serialized)
struct ClipboardPanelStateRegressionTests {
    @MainActor
    @Test func completedEmptyImageRecognitionPublishesUpdatedMetadata() async throws {
        try await withModel { _, store, _ in
            let stream = ClipboardHistoryFeed.shared.changes()
            var completedItem: ClipboardItem?
            let observer = Task { @MainActor in
                for await change in stream {
                    if case let .updated(storeID, item) = change, storeID == store.feedStoreID {
                        completedItem = item
                        return
                    }
                }
            }
            defer { observer.cancel() }

            let image = ClipboardItem(
                contentHash: "empty-image-ocr",
                kind: .image,
                representations: [ClipboardRepresentation(type: "public.png", data: Data([0, 1, 2, 3]))],
                preview: "Image",
                sourceApp: ClipboardSourceApp(bundleIdentifier: nil, name: nil)
            )
            _ = try await store.capture(image)
            await eventually { completedItem?.id == image.id }

            #expect(completedItem?.recognizedText.isEmpty == true)
            #expect(completedItem?.barcodePayloads.isEmpty == true)
        }
    }

    @MainActor
    @Test func identicalSelectionPreservesLoadedDetail() async throws {
        try await withModel { model, store, _ in
            let item = ClipboardItem(
                contentHash: "state-detail",
                kind: .plainText,
                representations: [ClipboardRepresentation(type: "public.utf8-plain-text", data: Data("detail body".utf8))],
                preview: "detail body",
                sourceApp: ClipboardSourceApp(bundleIdentifier: "test.editor", name: "Editor")
            )
            _ = try await store.capture(item)
            await model.loadItems()
            await eventually { model.detailItem?.id == item.id }

            let detail = try #require(model.detailItem)
            model.selectedIDs = model.selectedIDs

            #expect(model.detailItem == detail)
            #expect(model.detailItem?.representations.first?.data == Data("detail body".utf8))
        }
    }

    @MainActor
    @Test func coalescedUpdatesSettleNewestMetadataAndRemovalWins() async throws {
        try await withModel { model, store, _ in
            let item = ClipboardItem(
                contentHash: "state-update",
                kind: .plainText,
                representations: [ClipboardRepresentation(type: "public.utf8-plain-text", data: Data("value".utf8))],
                preview: "value",
                sourceApp: ClipboardSourceApp(bundleIdentifier: nil, name: nil)
            )
            _ = try await store.capture(item)
            await model.loadItems()
            try await store.favorite(item.id)
            try await store.pin(item.id)
            await eventually {
                model.items.first(where: { $0.id == item.id })?.isFavorite == true
                    && model.items.first(where: { $0.id == item.id })?.isPinned == true
            }

            try await store.delete(item.id)
            await eventually { !model.items.contains(where: { $0.id == item.id }) }
            try? await Task.sleep(for: .milliseconds(100))
            #expect(!model.items.contains(where: { $0.id == item.id }))
        }
    }

    @MainActor
    @Test func fullReloadAndPagingSerializeWithoutDuplicateRowsOrStuckFlags() async throws {
        try await withModel { model, store, _ in
            let rows = (0..<125).map { index in
                ClipboardItem(
                    contentHash: "overlap-\(index)",
                    kind: .plainText,
                    representations: [ClipboardRepresentation(type: "public.utf8-plain-text", data: Data("row \(index)".utf8))],
                    preview: "row \(index)",
                    sourceApp: ClipboardSourceApp(bundleIdentifier: nil, name: nil)
                )
            }
            _ = try await store.captureBatch(rows)
            await model.loadItems()

            let reload = Task { await model.loadItems() }
            await model.loadMore()
            await reload.value

            #expect(model.items.count == 125)
            #expect(Set(model.items.map(\.id)).count == 125)
            #expect(!model.isLoadingItems)
            #expect(!model.isLoadingMore)

            let laterSelection = try #require(model.items.last)
            model.select(laterSelection)
            await model.loadItems(preservingLoadedPage: true)
            #expect(model.selectedIDs == [laterSelection.id])
            #expect(model.items.count == 125)
        }
    }

    @MainActor
    @Test func insertThenUpdateAndOffPageFavoriteRefreshCurrentPage() async throws {
        try await withModel { model, store, _ in
            let rows = (0..<140).map { index in
                ClipboardItem(
                    contentHash: "off-page-\(index)",
                    kind: .plainText,
                    representations: [ClipboardRepresentation(type: "public.utf8-plain-text", data: Data("row \(index)".utf8))],
                    preview: "row \(index)",
                    sourceApp: ClipboardSourceApp(bundleIdentifier: nil, name: nil)
                )
            }
            _ = try await store.captureBatch(rows)
            await model.loadItems()
            await eventually { model.items.count == 100 }

            let offPage = try #require(rows.first(where: { row in !model.items.contains(where: { $0.id == row.id }) }))
            try await store.favorite(offPage.id)
            await eventually { model.items.first?.id == offPage.id && model.items.first?.isFavorite == true }

            let inserted = ClipboardItem(
                contentHash: "insert-then-update",
                kind: .plainText,
                representations: [ClipboardRepresentation(type: "public.utf8-plain-text", data: Data("new".utf8))],
                preview: "new",
                sourceApp: ClipboardSourceApp(bundleIdentifier: nil, name: nil)
            )
            _ = try await store.capture(inserted)
            try await store.favorite(inserted.id)
            await eventually { model.items.first(where: { $0.id == inserted.id })?.isFavorite == true }
            #expect(model.items.contains(where: { $0.id == inserted.id }))
        }
    }

    @MainActor
    @Test func rapidQueryChangeAndPagingUseLatestQuery() async throws {
        try await withModel { model, store, _ in
            let rows = (0..<240).map { index in
                let matches = index < 120
                let text = matches ? "needle row \(index)" : "other row \(index)"
                return ClipboardItem(
                    contentHash: "query-page-\(index)",
                    kind: .plainText,
                    representations: [ClipboardRepresentation(type: "public.utf8-plain-text", data: Data(text.utf8))],
                    preview: text,
                    sourceApp: ClipboardSourceApp(bundleIdentifier: nil, name: nil)
                )
            }
            _ = try await store.captureBatch(rows)
            await model.loadItems()

            model.query = "needle"
            let reload = Task { await model.loadItems() }
            let paging = Task { await model.loadMore() }
            await reload.value
            await paging.value

            #expect(model.items.count == 120)
            #expect(model.items.allSatisfy { $0.preview.localizedCaseInsensitiveContains("needle") })
            #expect(Set(model.items.map(\.id)).count == 120)
            #expect(!model.isLoadingItems)
            #expect(!model.isLoadingMore)
        }
    }

    @MainActor
    @Test func feedUpdateOverlappingPagingKeepsCurrentDatasetAndUniqueRows() async throws {
        try await withModel { model, store, _ in
            let rows = (0..<125).map { index in
                ClipboardItem(
                    contentHash: "feed-page-\(index)",
                    kind: .plainText,
                    representations: [ClipboardRepresentation(type: "public.utf8-plain-text", data: Data("feed row \(index)".utf8))],
                    preview: "feed row \(index)",
                    sourceApp: ClipboardSourceApp(bundleIdentifier: nil, name: nil)
                )
            }
            _ = try await store.captureBatch(rows)
            await model.loadItems()
            let favoriteID = try #require(rows.first(where: { item in !model.items.contains(where: { $0.id == item.id }) })?.id)

            let paging = Task { await model.loadMore() }
            try await store.favorite(favoriteID)
            await paging.value
            await eventually {
                model.items.first(where: { $0.id == favoriteID })?.isFavorite == true
                    && model.items.count == 125
            }

            #expect(Set(model.items.map(\.id)).count == 125)
            #expect(model.items.first(where: { $0.id == favoriteID })?.isFavorite == true)
            #expect(!model.isLoadingItems)
            #expect(!model.isLoadingMore)
        }
    }

    @MainActor
    @Test func metadataMergesIntoPreviewAndContentEditRefreshesSameID() async throws {
        try await withModel { model, store, _ in
            let item = ClipboardItem(
                contentHash: "metadata-preview",
                kind: .plainText,
                representations: [ClipboardRepresentation(type: "public.utf8-plain-text", data: Data("old text".utf8))],
                preview: "old text",
                sourceApp: ClipboardSourceApp(bundleIdentifier: "test.editor", name: "Editor")
            )
            _ = try await store.capture(item)
            await model.loadItems()
            await eventually { model.detailItem?.id == item.id }
            let originalPayload = try #require(model.detailItem?.representations)

            try await store.favorite(item.id)
            try await store.pin(item.id)
            await eventually { model.detailItem?.isFavorite == true && model.detailItem?.isPinned == true }
            #expect(model.detailItem?.representations == originalPayload)

            let current = try #require(model.detailItem)
            let ocrUpdate = ClipboardItem(
                id: current.id,
                contentHash: current.contentHash,
                kind: current.kind,
                representations: current.representations,
                thumbnailData: current.thumbnailData,
                payloadSize: current.payloadSize,
                preview: current.preview,
                createdAt: current.createdAt,
                lastCopiedAt: current.lastCopiedAt,
                lastUsedAt: current.lastUsedAt,
                useCount: current.useCount,
                isPinned: current.isPinned,
                isFavorite: current.isFavorite,
                collectionID: current.collectionID,
                title: current.title,
                tagIDs: current.tagIDs,
                tagDefinitions: current.tagDefinitions,
                recognizedText: "recognized marker",
                barcodePayloads: current.barcodePayloads,
                sourceApp: current.sourceApp
            )
            ClipboardHistoryFeed.shared.publish(.updated(storeID: store.feedStoreID, item: ocrUpdate))
            await eventually { model.detailItem?.recognizedText == "recognized marker" }
            #expect(model.detailItem?.representations == originalPayload)

            _ = try await store.editText(item.id, text: "new text")
            await eventually {
                model.detailItem?.representations.first?.data == Data("new text".utf8)
            }
            #expect(model.detailItem?.id == item.id)
        }
    }

    @MainActor
    @Test func previewCacheRespectsByteBudgetAndKeepsSelectedLargeItemAvailable() async throws {
        let rows = (0..<5).map { index in
            ClipboardItem(
                contentHash: "cache-\(index)",
                kind: .other,
                representations: [ClipboardRepresentation(type: "application/octet-stream", data: Data(repeating: UInt8(index), count: 4 * 1_024 * 1_024))],
                preview: "cache row \(index)",
                sourceApp: ClipboardSourceApp(bundleIdentifier: nil, name: nil)
            )
        }
        let huge = ClipboardItem(
            contentHash: "cache-huge",
            kind: .other,
            representations: [ClipboardRepresentation(type: "application/octet-stream", data: Data(repeating: 99, count: 17 * 1_024 * 1_024))],
            preview: "huge selected row",
            sourceApp: ClipboardSourceApp(bundleIdentifier: nil, name: nil)
        )
        try await withModel(initialItems: rows + [huge]) { model, _, _ in
            for item in rows + [huge] { model.select(item) }
            #expect(model.detailItem?.id == huge.id)
            #expect(model.detailCacheMetrics.count <= 4)
            #expect(model.detailCacheMetrics.bytes <= 16 * 1_024 * 1_024)
        }
    }

    @MainActor
    @Test func commandQueryNavigationAndExecutionUseEnabledRegistryCommands() async throws {
        try await withModel { model, _, _ in
            var performed: [String] = []
            model.registry.register(.init(id: "alpha", title: "Alpha Action") { _ in performed.append("alpha") })
            model.registry.register(.init(id: "beta", title: "Beta Action") { _ in performed.append("beta") })
            model.registry.register(.init(id: "disabled", title: "Disabled Action", isEnabled: { _ in false }) { _ in performed.append("disabled") })
            model.commandQuery = "action"
            model.isCommandPaletteVisible = true

            #expect(model.filteredCommands.map(\.id).contains("disabled") == false)
            #expect(model.commandSelectionID == "alpha")
            model.moveCommandSelection(by: 1)
            #expect(model.commandSelectionID == "beta")
            #expect(model.performSelectedCommand())
            #expect(performed == ["beta"])
            #expect(!model.isCommandPaletteVisible)
        }
    }

    @MainActor
    private func eventually(timeout: TimeInterval = 5, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition())
    }

    private func withModel(
        initialItems: [ClipboardItem] = [],
        _ body: @MainActor (ClipboardHistoryPanelModel, ClipboardHistoryStore, UserDefaults) async throws -> Void
    ) async throws {
        let suite = "ClipboardPanelStateRegressionTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        let store = try ClipboardHistoryStore(
            directoryURL: directory,
            keyData: Data(repeating: 31, count: 32),
            defaults: defaults
        )
        let model = await MainActor.run { ClipboardHistoryPanelModel(store: store, defaults: defaults, initialItems: initialItems) }
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        try await body(model, store, defaults)
    }
}
