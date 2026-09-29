import AppKit
import Combine
import Foundation

enum ClipboardLibraryDateFilter: String, CaseIterable, Hashable, Identifiable {
    case anytime
    case today
    case week
    case month

    var id: String { rawValue }
}

struct ClipboardLibraryAppCount: Identifiable, Equatable {
    let name: String
    let count: Int
    var id: String { name }
}

struct ClipboardLibraryStats: Equatable {
    var itemCount = 0
    var storageBytes: Int64 = 0
    var itemsCopiedToday = 0
    var topApps: [ClipboardLibraryAppCount] = []
}

@MainActor
final class ClipboardLibraryModel: ObservableObject {
    @Published private(set) var items: [ClipboardItem] = []
    @Published private(set) var appNames: [String] = []
    @Published private(set) var stats = ClipboardLibraryStats()
    @Published private(set) var detailItem: ClipboardItem?
    @Published private(set) var hasMore = false
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published var query = ""
    @Published var selectedIDs: Set<UUID> = []
    @Published var selectedKinds: Set<ClipboardItemKind> = []
    @Published var selectedAppName: String?
    @Published var dateFilter = ClipboardLibraryDateFilter.anytime
    @Published var sort = ClipboardPanelSort.lastCopy
    @Published var ascending = false

    let store: ClipboardHistoryStore
    private let feed: ClipboardHistoryFeed
    private var feedTask: Task<Void, Never>?
    private var feedRefreshTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var pageCursor = 0
    private let pageSize = 100
    private var searchedRows: [ClipboardItem]?
    private var pendingReload = false
    private var selectionRevision = 0

    init(store: ClipboardHistoryStore, feed: ClipboardHistoryFeed? = nil) {
        self.store = store
        self.feed = feed ?? ClipboardHistoryFeed.shared
    }

    var visibleCount: Int { items.count }
    var selectedItems: [ClipboardItem] { items.filter { selectedIDs.contains($0.id) } }

    func dismissError() { errorMessage = nil }

    func start() async {
        guard feedTask == nil else { return }
        let stream = feed.changes()
        feedTask = Task { [weak self] in
            for await change in stream {
                guard !Task.isCancelled, let self else { return }
                await self.receive(change)
            }
        }
        await refreshStats()
        await reload()
    }

    func stop() {
        feedTask?.cancel()
        feedTask = nil
        feedRefreshTask?.cancel()
        feedRefreshTask = nil
        searchTask?.cancel()
    }

    func scheduleSearch() {
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(160))
            guard !Task.isCancelled else { return }
            await self?.reload()
        }
    }

    func reload() async {
        guard !isLoading else { pendingReload = true; return }
        isLoading = true
        defer { finishLoading() }
        pageCursor = 0
        items = []
        hasMore = false
        let parsed = ClipboardPanelQuery.parse(query)
        do {
            if !parsed.text.isEmpty {
                let rows = try await store.search(text: parsed.text, limit: Int.max)
                searchedRows = sortRows(rows)
                let matches = applyFilters(searchedRows ?? [], query: parsed)
                items = Array(matches.prefix(pageSize))
                hasMore = matches.count > pageSize
                pageCursor = items.count
            } else {
                searchedRows = nil
                try await appendPage(query: parsed, replacing: true)
            }
            selectedIDs.formIntersection(Set(items.map(\.id)))
            if let selectedID = selectedIDs.first { await select(selectedID) }
            else { detailItem = nil }
            errorMessage = nil
        } catch {
            errorMessage = String(localized: "Clipboard history could not be loaded")
        }
    }

    func loadMore() async {
        guard hasMore, !isLoading else { return }
        isLoading = true
        defer { finishLoading() }
        let parsed = ClipboardPanelQuery.parse(query)
        if let searchedRows {
            let matches = applyFilters(searchedRows, query: parsed)
            let next = Array(matches.dropFirst(pageCursor).prefix(pageSize))
            items.append(contentsOf: next)
            pageCursor += next.count
            hasMore = pageCursor < matches.count
            return
        }
        do {
            try await appendPage(query: parsed, replacing: false)
        } catch {
            errorMessage = String(localized: "Clipboard history could not be loaded")
        }
    }

    func select(_ id: UUID) async {
        selectionRevision += 1
        let revision = selectionRevision
        do {
            let item = try await store.itemWithPayload(id)
            if revision == selectionRevision { detailItem = item }
        } catch {
            if revision == selectionRevision { detailItem = nil; errorMessage = error.localizedDescription }
        }
    }

    func clearDetail() { selectionRevision += 1; detailItem = nil }

    private func finishLoading() {
        isLoading = false
        if pendingReload {
            pendingReload = false
            Task { await reload() }
        }
    }

    func reportExportError(_ error: Error) {
        errorMessage = error.localizedDescription
    }

    func toggleKind(_ kind: ClipboardItemKind) {
        if selectedKinds.contains(kind) { selectedKinds.remove(kind) }
        else { selectedKinds.insert(kind) }
        scheduleSearch()
    }

    func setAppFilter(_ name: String?) {
        selectedAppName = name
        scheduleSearch()
    }

    func setDateFilter(_ filter: ClipboardLibraryDateFilter) {
        dateFilter = filter
        scheduleSearch()
    }

    func setSort(_ value: ClipboardPanelSort) {
        sort = value
        scheduleSearch()
    }

    func toggleOrder() {
        ascending.toggle()
        scheduleSearch()
    }

    func togglePinned(_ value: Bool) async { await updateSelected { try await self.store.pin($0.id, pinned: value) } }
    func toggleFavorite(_ value: Bool) async { await updateSelected { try await self.store.favorite($0.id, favorite: value) } }

    func deleteSelection() async {
        let ids = selectedIDs
        for id in ids { try? await store.delete(id) }
        selectedIDs.removeAll()
        detailItem = nil
        await reload()
        await refreshStats()
    }

    func copySelection() async {
        let selected = selectedItems
        guard !selected.isEmpty else { return }
        let payloads: [ClipboardItem]
        do { payloads = try await fullItems(for: selected) }
        catch { errorMessage = error.localizedDescription; return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let pasteboardItems = payloads.flatMap { item -> [NSPasteboardItem] in
            let groups = Dictionary(grouping: item.representations, by: \.itemIndex)
            return groups.keys.sorted().map { index in
                let entry = NSPasteboardItem()
                for representation in groups[index] ?? [] {
                    entry.setData(representation.data, forType: NSPasteboard.PasteboardType(representation.type))
                }
                entry.setData(Data(), forType: ClipboardManager.historyIgnoreType)
                return entry
            }
        }
        if !pasteboardItems.isEmpty { pasteboard.writeObjects(pasteboardItems) }
    }

    func exportSelection(to url: URL) async throws {
        let payloads = try await fullItems(for: selectedItems)
        let entries = payloads.map { ClipboardHistoryArchive.Entry(item: $0, favoriteOrder: nil) }
        try await Task.detached(priority: .utility) { try ClipboardHistoryArchive.write(entries, to: url) }.value
    }

    func refreshStats() async {
        let total = (try? await store.totalCount()) ?? 0
        var cursor = 0
        var todayCount = 0
        var appCounts: [String: Int] = [:]
        while cursor < total {
            let batch = (try? await store.recentPage(offset: cursor, limit: pageSize)) ?? []
            guard !batch.isEmpty else { break }
            cursor += batch.count
            for item in batch {
                if item.lastCopiedAt >= Calendar.current.startOfDay(for: Date()) { todayCount += 1 }
                if let name = item.sourceApp.name?.clipboardLibraryNonEmpty { appCounts[name, default: 0] += 1 }
            }
        }
        let storageBytes = (try? await store.storageSize()) ?? 0
        var topApps: [ClipboardLibraryAppCount] = []
        for (name, count) in appCounts {
            topApps.append(ClipboardLibraryAppCount(name: name, count: count))
        }
        topApps.sort { left, right in
            left.count == right.count ? left.name < right.name : left.count > right.count
        }
        let leadingApps = Array(topApps.prefix(3))
        stats = ClipboardLibraryStats(
            itemCount: total,
            storageBytes: storageBytes,
            itemsCopiedToday: todayCount,
            topApps: leadingApps
        )
        appNames = appCounts.keys.sorted()
    }

    private func appendPage(query: ClipboardPanelQuery, replacing: Bool) async throws {
        let total = try await store.totalCount()
        var additions: [ClipboardItem] = []
        while additions.count < pageSize, pageCursor < total {
            let batch = try await store.sortedPage(sort.engineSort, ascending: ascending, offset: pageCursor, limit: pageSize)
            guard !batch.isEmpty else { break }
            pageCursor += batch.count
            additions.append(contentsOf: applyFilters(batch, query: query))
        }
        if replacing { items = additions } else { items.append(contentsOf: additions) }
        hasMore = pageCursor < total
    }

    private func applyFilters(_ rows: [ClipboardItem], query: ClipboardPanelQuery) -> [ClipboardItem] {
        let kinds = selectedKinds.union(query.filters.kinds)
        let apps = query.filters.sourceApps
        let cutoff: Date? = switch dateFilter {
        case .anytime: nil
        case .today: Calendar.current.startOfDay(for: Date())
        case .week: Calendar.current.date(byAdding: .day, value: -7, to: Date())
        case .month: Calendar.current.date(byAdding: .month, value: -1, to: Date())
        }
        return rows.filter { item in
            if !kinds.isEmpty && !kinds.contains(item.kind) { return false }
            let appValues = [item.sourceApp.name, item.sourceApp.bundleIdentifier].compactMap { $0?.localizedLowercase }
            if let selectedAppName, !appValues.contains(where: { $0.contains(selectedAppName.localizedLowercase) }) { return false }
            if !apps.isEmpty && !apps.contains(where: { token in appValues.contains(where: { $0.contains(token) }) }) { return false }
            if let cutoff, item.lastCopiedAt < cutoff { return false }
            return true
        }
    }

    private func sortRows(_ rows: [ClipboardItem]) -> [ClipboardItem] {
        rows.sorted { left, right in
            let result: ComparisonResult
            switch sort {
            case .lastCopy: result = left.lastCopiedAt.compare(right.lastCopiedAt)
            case .firstCopy: result = left.createdAt.compare(right.createdAt)
            case .copyCount: result = left.useCount == right.useCount ? .orderedSame : (left.useCount < right.useCount ? .orderedAscending : .orderedDescending)
            case .size:
                let leftSize = left.payloadSize ?? 0
                let rightSize = right.payloadSize ?? 0
                result = leftSize == rightSize ? .orderedSame : (leftSize < rightSize ? .orderedAscending : .orderedDescending)
            }
            if result == .orderedSame { return ascending ? left.id.uuidString < right.id.uuidString : left.id.uuidString > right.id.uuidString }
            return ascending ? result == .orderedAscending : result == .orderedDescending
        }
    }

    private func updateSelected(_ operation: (ClipboardItem) async throws -> Void) async {
        for item in selectedItems { try? await operation(item) }
        await reload()
    }

    private func fullItems(for items: [ClipboardItem]) async throws -> [ClipboardItem] {
        var result: [ClipboardItem] = []
        for item in items { result.append(try await store.itemWithPayload(item.id)) }
        return result
    }

    private func receive(_ change: ClipboardHistoryChange) async {
        let storeID: UUID
        switch change {
        case let .inserted(id, _), let .insertedBatch(id, _), let .updated(id, _), let .removed(id, _), let .cleared(id, _): storeID = id
        }
        guard storeID == store.feedStoreID else { return }
        switch change {
        case let .removed(_, ids), let .cleared(_, ids): selectedIDs.subtract(ids)
        case .inserted, .insertedBatch, .updated: break
        }
        feedRefreshTask?.cancel()
        feedRefreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled, let self else { return }
            await self.reload()
            await self.refreshStats()
        }
    }
}

extension String {
    var clipboardLibraryNonEmpty: String? { isEmpty ? nil : self }
}
