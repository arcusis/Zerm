import AppKit
import Foundation

enum ClipboardPanelSort: String, CaseIterable, Identifiable {
    case lastCopy
    case firstCopy
    case copyCount
    case size

    var id: String { rawValue }
    var engineSort: ClipboardHistorySort { ClipboardHistorySort(rawValue: rawValue) ?? .lastCopy }
}

enum ClipboardPanelDateFilter: String, CaseIterable, Identifiable, Sendable {
    case anytime, today, week, month
    var id: String { rawValue }
}

enum ClipboardPanelRailFilter: Equatable, Sendable {
    case history
    case favorites
    case text
    case kind(ClipboardItemKind)
}

struct ClipboardPanelFilters: Equatable, Sendable {
    var kinds: Set<ClipboardItemKind> = []
    var sourceApps: Set<String> = []
}

struct ClipboardPanelQuery: Equatable {
    var text = ""
    var filters = ClipboardPanelFilters()

    static func parse(_ value: String) -> ClipboardPanelQuery {
        var query = ClipboardPanelQuery()
        var terms: [String] = []
        for token in value.split(whereSeparator: \.isWhitespace) {
            let part = String(token)
            if part.localizedCaseInsensitiveHasPrefix("kind:"),
                let kind = ClipboardItemKind.allCases.first(where: {
                    $0.rawValue.localizedCaseInsensitiveCompare(String(part.dropFirst(5))) == .orderedSame
                })
            {
                query.filters.kinds.insert(kind)
            } else if part.localizedCaseInsensitiveHasPrefix("app:") {
                let value = String(part.dropFirst(4)).removingPercentEncoding ?? String(part.dropFirst(4))
                query.filters.sourceApps.insert(value.localizedLowercase)
            } else {
                terms.append(part)
            }
        }
        query.text = terms.joined(separator: " ")
        return query
    }
}

enum ClipboardPanelText {
    static func plainText(from representations: [ClipboardRepresentation], fallback: String) -> String {
        let textTypes = [
            NSPasteboard.PasteboardType.string.rawValue, "public.utf8-plain-text", "NSStringPboardType", "public.url",
        ]
        if let text = representations.first(where: { textTypes.contains($0.type) }).flatMap({
            String(data: $0.data, encoding: .utf8)
        }) {
            return text
        }
        for representation in representations
        where representation.type == "public.rtf" || representation.type == "public.html" {
            let documentType: NSAttributedString.DocumentType = representation.type == "public.rtf" ? .rtf : .html
            if let attributed = try? NSAttributedString(
                data: representation.data,
                options: [.documentType: documentType],
                documentAttributes: nil
            ) {
                return attributed.string
            }
        }
        return fallback
    }
}

struct ClipboardPanelCommand: Identifiable {
    let id: String
    let title: String
    let shortcut: String?
    let isEnabled: ([ClipboardItem]) -> Bool
    let perform: ([ClipboardItem]) -> Void

    init(
        id: String,
        title: String,
        shortcut: String? = nil,
        isEnabled: @escaping ([ClipboardItem]) -> Bool = { _ in true },
        perform: @escaping ([ClipboardItem]) -> Void
    ) {
        self.id = id
        self.title = title
        self.shortcut = shortcut
        self.isEnabled = isEnabled
        self.perform = perform
    }
}

@MainActor
final class ClipboardPanelCommandRegistry {
    private(set) var commands: [ClipboardPanelCommand] = []

    func register(_ command: ClipboardPanelCommand) {
        commands.removeAll { $0.id == command.id }
        commands.append(command)
    }

    func available(for selection: [ClipboardItem]) -> [ClipboardPanelCommand] {
        commands.filter { $0.isEnabled(selection) }
    }

    func command(withID id: String, for selection: [ClipboardItem]) -> ClipboardPanelCommand? {
        available(for: selection).first { $0.id == id }
    }

    func removeCommands(withPrefix prefix: String) {
        commands.removeAll { $0.id.hasPrefix(prefix) }
    }
}

@MainActor
final class ClipboardHistoryPanelModel: ObservableObject {
    @Published private(set) var items: [ClipboardItem] = []
    @Published private(set) var visibleItems: [ClipboardItem] = []
    @Published var query = "" { didSet { queryChanged() } }
    /// Source app chosen in the sidebar. Kept apart from `query` so the search field shows only what was typed.
    @Published var appFilter: String? { didSet { queryChanged() } }
    @Published var railFilter: ClipboardPanelRailFilter = .history { didSet { queryChanged() } }
    @Published var sort: ClipboardPanelSort = .lastCopy { didSet { queryChanged() } }
    @Published var reversed = false { didSet { queryChanged() } }
    @Published var dateFilter = ClipboardPanelDateFilter.anytime { didSet { queryChanged() } }
    @Published var favoritesOnTop: Bool {
        didSet {
            defaults.set(favoritesOnTop, forKey: ClipboardHistorySettings.Keys.favoritesOnTop)
            queryChanged()
        }
    }
    @Published var selectedIDs: [UUID] = [] {
        didSet {
            if oldValue != selectedIDs { loadSelectedDetail(); updateCommandSelection() }
        }
    }
    @Published private(set) var detailItem: ClipboardItem?
    @Published private(set) var isLoadingDetail = false
    @Published private(set) var sourceApps: [ClipboardSourceAppCount] = []
    @Published var errorMessage: String?
    @Published var isPinned = false
    @Published var isPreviewVisible = true
    @Published var isSidebarCollapsed = true
    @Published var isDetailsVisible = false
    @Published var isCommandPaletteVisible = false {
        didSet { if !oldValue && isCommandPaletteVisible { selectInitialCommand() } }
    }
    @Published var commandQuery = "" { didSet { updateCommandSelection(preferFirst: true) } }
    @Published var presentationID = 0
    @Published var commandSelectionID: String?
    @Published private(set) var filteredCommands: [ClipboardPanelCommand] = []
    @Published var isShowingQuickPasteBadges = false
    @Published var isClearConfirmationVisible = false
    @Published var isTextEditorVisible = false
    @Published var textBeingEdited = ""
    @Published private(set) var editingErrorMessage: String?
    @Published private(set) var isSavingEdit = false

    let registry = ClipboardPanelCommandRegistry()
    var onCommand: ((String) -> Void)?
    private let store: ClipboardHistoryStore
    private let defaults: UserDefaults
    private var reloadTask: Task<Void, Never>?
    private var feedTask: Task<Void, Never>?
    private var feedCoalesceTask: Task<Void, Never>?
    private var pendingFeedChanges: [ClipboardHistoryChange] = []
    private var pageOffset = 0
    private var loadChain: Task<Void, Never>?
    private var loadGeneration = 0
    private var pendingFullLoads = 0
    private var datasetRevision = 0
    private var loadedDatasetRevision = 0
    private var loadedQueryRevision = 0
    @Published private(set) var hasLoadedItems = false
    @Published private(set) var isLoadingItems = false
    @Published private(set) var canLoadMore = false
    @Published private(set) var isLoadingMore = false
    private var selectionAnchorID: UUID?
    private var selectionLeadID: UUID?
    private var detailTask: Task<Void, Never>?
    private var detailCache: [UUID: ClipboardItem] = [:]
    private var detailCacheOrder: [UUID] = []
    private let detailCacheLimit = 12
    private let detailCacheByteLimit = 16 * 1_024 * 1_024
    private var loadedSearchText: String?
    private var queryRevision = 0
    private var editingItemID: UUID?

    init(
        store: ClipboardHistoryStore,
        defaults: UserDefaults = .standard,
        initialItems: [ClipboardItem] = []
    ) {
        self.store = store
        self.defaults = defaults
        _favoritesOnTop = Published(initialValue: ClipboardHistorySettings.bool(ClipboardHistorySettings.Keys.favoritesOnTop, in: defaults, defaultValue: true))
        items = initialItems
        applyQuery()
        registerCoreCommands()
        updateCommandSelection()
        feedTask = Task { [weak self] in
            for await change in ClipboardHistoryFeed.shared.changes() {
                guard !Task.isCancelled else { return }
                await self?.receive(change)
            }
        }
    }

    deinit {
        reloadTask?.cancel()
        feedTask?.cancel()
        feedCoalesceTask?.cancel()
        detailTask?.cancel()
    }

    var selection: [ClipboardItem] {
        selectedIDs.compactMap { id in items.first(where: { $0.id == id }) }
    }

    var selectedItem: ClipboardItem? { selection.first }

    var hasActiveFilters: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || appFilter != nil || railFilter != .history || dateFilter != .anytime
    }

    func reload(debounced: Bool = false, preservingLoadedPage: Bool = false) {
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            if debounced {
                do { try await Task.sleep(for: .milliseconds(120)) }
                catch { return }
            }
            guard !Task.isCancelled else { return }
            await self?.loadItems(preservingLoadedPage: preservingLoadedPage)
        }
    }

    func loadItems(preservingLoadedPage: Bool = false) async {
        pendingFullLoads += 1
        if !isLoadingItems { isLoadingItems = true }
        let previous = loadChain
        loadGeneration += 1
        let generation = loadGeneration
        let task = Task { @MainActor [weak self] in
            await previous?.value
            guard let self else { return }
            await self.performLoadItems(preservingLoadedPage: preservingLoadedPage)
        }
        loadChain = task
        await task.value
        if generation == loadGeneration { loadChain = nil }
        pendingFullLoads = max(0, pendingFullLoads - 1)
        let remainsLoading = pendingFullLoads > 0
        if isLoadingItems != remainsLoading { isLoadingItems = remainsLoading }
    }

    func loadMore() async {
        // Checked at call time: the paging sentinel can fire again before the queued load runs.
        guard (canLoadMore || isLoadingItems), !isLoadingMore else { return }
        isLoadingMore = true
        let previous = loadChain
        loadGeneration += 1
        let generation = loadGeneration
        let task = Task { @MainActor [weak self] in
            await previous?.value
            guard let self else { return }
            await self.performLoadMore()
        }
        loadChain = task
        await task.value
        if generation == loadGeneration { loadChain = nil }
    }

    private func performLoadItems(preservingLoadedPage: Bool) async {
        while !Task.isCancelled {
            let startingQueryRevision = queryRevision
            let startingDatasetRevision = datasetRevision
            await fetchAndPublishItems(preservingLoadedPage: preservingLoadedPage)
            guard !Task.isCancelled else { return }
            if startingQueryRevision == queryRevision && startingDatasetRevision == datasetRevision { return }
        }
    }

    private func fetchAndPublishItems(preservingLoadedPage: Bool) async {
        let revision = queryRevision
        let snapshotRevision = datasetRevision
        let searchText = ClipboardPanelQuery.parse(query).text
        let keepLoadedPage = preservingLoadedPage
            || (pageOffset > 100 && loadedQueryRevision == queryRevision)
        if !keepLoadedPage { pageOffset = 0 }
        var ascending = reversed
        if sort == .firstCopy { ascending.toggle() }
        let requestedCount = keepLoadedPage ? max(pageOffset, 100) : 100
        let page: (items: [ClipboardItem], total: Int)
        do { page = try await fetchPage(ascending: ascending, offset: 0, limit: requestedCount) }
        catch {
            guard !Task.isCancelled, revision == queryRevision, snapshotRevision == datasetRevision else { return }
            hasLoadedItems = true
            errorMessage = error.localizedDescription
            return
        }
        let fetched = page.items
        let apps = (try? await store.sourceAppCounts()) ?? []
        guard !Task.isCancelled, revision == queryRevision, snapshotRevision == datasetRevision else { return }
        if sourceApps != apps { sourceApps = apps }
        if items != fetched { items = fetched }
        if !hasLoadedItems { hasLoadedItems = true }
        pageOffset = fetched.count
        let nextCanLoadMore = page.total > pageOffset
        if canLoadMore != nextCanLoadMore { canLoadMore = nextCanLoadMore }
        loadedSearchText = searchText
        loadedDatasetRevision = snapshotRevision
        loadedQueryRevision = revision
        applyQuery()
        if selectedIDs.isEmpty, let first = visibleItems.first { selectedIDs = [first.id] }
    }

    private func performLoadMore() async {
        defer { isLoadingMore = false }
        if loadedDatasetRevision != datasetRevision || loadedQueryRevision != queryRevision {
            await performLoadItems(preservingLoadedPage: true)
        }
        while !Task.isCancelled {
            guard canLoadMore,
                  loadedDatasetRevision == datasetRevision,
                  loadedQueryRevision == queryRevision else { return }
            let revision = queryRevision
            let snapshotRevision = datasetRevision
            var ascending = reversed
            if sort == .firstCopy { ascending.toggle() }
            let page: (items: [ClipboardItem], total: Int)
            do { page = try await fetchPage(ascending: ascending, offset: pageOffset, limit: 100) }
            catch {
                guard !Task.isCancelled, revision == queryRevision, snapshotRevision == datasetRevision else {
                    if !Task.isCancelled { await performLoadItems(preservingLoadedPage: true) }
                    continue
                }
                errorMessage = error.localizedDescription
                return
            }
            guard !Task.isCancelled else { return }
            guard revision == queryRevision, snapshotRevision == datasetRevision else {
                await performLoadItems(preservingLoadedPage: true)
                continue
            }
            // Store mutations can precede their asynchronous feed event. If an
            // offset page overlaps loaded rows, its ordering changed in flight.
            // Refresh the whole requested prefix so the shifted row is not lost.
            let loadedIDs = Set(items.map(\.id))
            if page.items.contains(where: { loadedIDs.contains($0.id) }) {
                pageOffset += page.items.count
                await performLoadItems(preservingLoadedPage: true)
                return
            }
            let additional = page.items
            if !additional.isEmpty { items.append(contentsOf: additional) }
            pageOffset = items.count
            let nextCanLoadMore = page.total > pageOffset
            if canLoadMore != nextCanLoadMore { canLoadMore = nextCanLoadMore }
            loadedDatasetRevision = snapshotRevision
            loadedQueryRevision = revision
            applyQuery()
            return
        }
    }

    private func receive(_ change: ClipboardHistoryChange) async {
        let storeID: UUID
        switch change {
        case let .inserted(id, _), let .updated(id, _), let .insertedBatch(id, _), let .removed(id, _), let .cleared(id, _): storeID = id
        }
        guard storeID == store.feedStoreID else { return }
        guard feedChangeCanAffectDataset(change) else { return }
        datasetRevision += 1
        pendingFeedChanges.append(change)
        guard feedCoalesceTask == nil else { return }
        feedCoalesceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(35))
            guard !Task.isCancelled, let self else { return }
            let changes = self.pendingFeedChanges
            self.pendingFeedChanges.removeAll(keepingCapacity: true)
            self.feedCoalesceTask = nil
            await self.applyFeedChanges(changes)
        }
    }

    private func feedChangeCanAffectDataset(_ change: ClipboardHistoryChange) -> Bool {
        switch change {
        case let .inserted(_, item), let .updated(_, item):
            return items.first(where: { $0.id == item.id }).map { $0 != item } ?? true
        case let .insertedBatch(_, inserted):
            return inserted.contains { item in items.first(where: { $0.id == item.id }).map { $0 != item } ?? true }
        case let .removed(_, ids), let .cleared(_, ids):
            return !ids.isEmpty
        }
    }

    private func applyFeedChanges(_ changes: [ClipboardHistoryChange]) async {
        enum Change { case upsert(ClipboardItem, inserted: Bool), remove }
        var latest: [UUID: Change] = [:]
        for change in changes {
            switch change {
            case let .inserted(_, item): latest[item.id] = .upsert(item, inserted: true)
            case let .updated(_, item):
                let wasInserted: Bool
                if case let .upsert(_, inserted)? = latest[item.id] { wasInserted = inserted }
                else { wasInserted = false }
                latest[item.id] = .upsert(item, inserted: wasInserted)
            case let .insertedBatch(_, items): for item in items { latest[item.id] = .upsert(item, inserted: true) }
            case let .removed(_, ids), let .cleared(_, ids): for id in ids { latest[id] = .remove }
            }
        }
        let removed = latest.compactMap { id, change -> UUID? in
            if case .remove = change { return id }
            return nil
        }
        if !removed.isEmpty { applyRemoval(of: removed) }
        var needsReload = !removed.isEmpty
        for (id, change) in latest {
            guard case let .upsert(item, inserted) = change else { continue }
            guard let index = items.firstIndex(where: { $0.id == id }) else {
                needsReload = true
                continue
            }
            let previous = items[index]
            guard previous != item else { continue }
            let orderChanged: Bool
            switch sort {
            case .lastCopy: orderChanged = previous.lastCopiedAt != item.lastCopiedAt
            case .firstCopy: orderChanged = previous.createdAt != item.createdAt
            case .copyCount: orderChanged = previous.useCount != item.useCount
            case .size: orderChanged = previous.payloadSize != item.payloadSize
            }
            let favoriteOrderChanged = favoritesOnTop && previous.isFavorite != item.isFavorite
            let parsed = ClipboardPanelQuery.parse(query)
            let searchableChanged = previous.preview != item.preview || previous.title != item.title
                || previous.recognizedText != item.recognizedText || previous.barcodePayloads != item.barcodePayloads
                || previous.sourceApp != item.sourceApp
            let kindChanged = previous.kind != item.kind
            let kindMembershipChanged: Bool
            if case let .kind(kind) = railFilter {
                kindMembershipChanged = (previous.kind == kind) != (item.kind == kind)
            } else { kindMembershipChanged = false }
            let membershipChanged = (!parsed.text.isEmpty && searchableChanged)
                || (appFilter != nil && previous.sourceApp != item.sourceApp)
                || (dateFilter != .anytime && previous.lastCopiedAt != item.lastCopiedAt)
                || (railFilter == .favorites && previous.isFavorite != item.isFavorite)
                || (railFilter == .text && kindChanged)
                || kindMembershipChanged
                || (!parsed.filters.kinds.isEmpty && kindChanged)
                || (parsed.filters.sourceApps.isEmpty == false && previous.sourceApp != item.sourceApp)
            if items[index] != item { items[index] = item }
            let contentChanged = previous.contentHash != item.contentHash || previous.payloadSize != item.payloadSize
            if contentChanged { invalidateDetailCache(for: id) }
            let payloadSource = detailCache[id] ?? (detailItem?.id == id ? detailItem : nil)
            var mergedFullDetail = false
            if let payloadSource {
                if !contentChanged {
                    let merged = item.replacingPayload(from: payloadSource)
                    cacheDetail(merged)
                    if selectedIDs.first == id, detailItem != merged { detailItem = merged }
                    mergedFullDetail = true
                }
            }
            if inserted || orderChanged || favoriteOrderChanged || membershipChanged { needsReload = true }
            else { applyQuery() }
            if selectedIDs.first == id, contentChanged || (!mergedFullDetail && !isLoadingDetail) {
                loadSelectedDetail(keepingCurrentPreview: true)
            }
        }
        if needsReload { reload(preservingLoadedPage: true) }
        else {
            loadedDatasetRevision = datasetRevision
            loadedQueryRevision = queryRevision
        }
    }

    /// Invalidates in-flight fetches before removing IDs, so stale results cannot restore them.
    private func applyRemoval(of ids: [UUID]) {
        guard !ids.isEmpty else { return }
        queryRevision += 1
        ids.forEach { invalidateDetailCache(for: $0) }
        items.removeAll { ids.contains($0.id) }
        pageOffset = items.count
        selectedIDs.removeAll { ids.contains($0) }
        if selectionAnchorID.map(ids.contains) == true { selectionAnchorID = selectedIDs.first }
        if selectionLeadID.map(ids.contains) == true { selectionLeadID = selectedIDs.last }
        applyQuery()
        if selectedIDs.isEmpty, let first = visibleItems.first { select(first) }
        if hasLoadedItems { reload(preservingLoadedPage: true) }
    }

    func select(_ item: ClipboardItem, extending: Bool = false, toggling: Bool = false, playSelectionSound: Bool = false) {
        let previousSelection = selectedIDs
        if toggling {
            if selectedIDs.contains(item.id) {
                selectedIDs.removeAll { $0 == item.id }
                if selectionAnchorID == item.id { selectionAnchorID = selectedIDs.first }
            } else {
                selectedIDs.append(item.id)
                if selectionAnchorID == nil { selectionAnchorID = item.id }
            }
            selectionLeadID = item.id
        } else if extending, let anchor = selectionAnchorID ?? selectedIDs.first,
            let first = visibleItems.firstIndex(where: { $0.id == anchor }),
            let target = visibleItems.firstIndex(where: { $0.id == item.id })
        {
            selectedIDs = Array(visibleItems[min(first, target)...max(first, target)]).map(\.id)
            selectionLeadID = item.id
        } else {
            selectedIDs = [item.id]
            selectionAnchorID = item.id
            selectionLeadID = item.id
        }
        if playSelectionSound, selectedIDs != previousSelection {
            SoundManager.shared.playClipboardSelectionSound()
        }
    }

    func moveSelection(by offset: Int, extending: Bool = false) {
        guard !visibleItems.isEmpty else { return }
        let current =
            visibleItems.firstIndex(where: { $0.id == selectionLeadID })
            ?? visibleItems.firstIndex(where: { $0.id == selectedIDs.first })
            ?? 0
        let next = min(max(current + offset, 0), visibleItems.count - 1)
        select(visibleItems[next], extending: extending, playSelectionSound: true)
    }

    func quickPasteItem(forCommandNumber number: Int) -> ClipboardItem? {
        guard (1...9).contains(number), number <= visibleItems.count else { return nil }
        return visibleItems[number - 1]
    }

    func moveCommandSelection(by offset: Int) {
        guard !filteredCommands.isEmpty else { commandSelectionID = nil; return }
        let current = filteredCommands.firstIndex { $0.id == commandSelectionID } ?? 0
        let next = min(max(current + offset, 0), filteredCommands.count - 1)
        commandSelectionID = filteredCommands[next].id
    }

    @discardableResult
    func performSelectedCommand() -> Bool {
        guard let id = commandSelectionID,
              let command = registry.command(withID: id, for: selection) else { return false }
        command.perform(selection)
        isCommandPaletteVisible = false
        commandQuery = ""
        return true
    }

    private func selectInitialCommand() {
        updateCommandSelection(preferFirst: true)
    }

    private func updateCommandSelection(preferFirst: Bool = false) {
        let needle = commandQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let commands = registry.available(for: selection).filter { command in
            needle.isEmpty || [command.title, command.id, command.shortcut ?? ""].contains {
                $0.localizedCaseInsensitiveContains(needle)
            }
        }
        if filteredCommands.map(\.id) != commands.map(\.id) { filteredCommands = commands }
        if preferFirst || !filteredCommands.contains(where: { $0.id == commandSelectionID }) {
            let nextID = filteredCommands.first?.id
            if commandSelectionID != nextID { commandSelectionID = nextID }
        }
    }

    func showInHistory(_ item: ClipboardItem) {
        clearFilters()
        selectedIDs = [item.id]
        selectionAnchorID = item.id
        selectionLeadID = item.id
        Task {
            await loadItems()
            while !items.contains(where: { $0.id == item.id }), canLoadMore { await loadMore() }
            if let loaded = items.first(where: { $0.id == item.id }) { select(loaded) }
        }
    }

    func clearFilters() {
        query = ""
        appFilter = nil
        railFilter = .history
        dateFilter = .anytime
    }

    func fullItems(for selection: [ClipboardItem]) async throws -> [ClipboardItem] {
        var loaded: [ClipboardItem] = []
        for item in selection { loaded.append(try await store.itemWithPayload(item.id)) }
        return loaded
    }

    func copy(_ item: ClipboardItem, to pasteboard: NSPasteboard = .general) async {
        do {
            let loaded = try await store.itemWithPayload(item.id)
            let groups = Dictionary(grouping: loaded.representations, by: \.itemIndex)
            let objects = groups.keys.sorted().map { index -> NSPasteboardItem in
                let object = NSPasteboardItem()
                for representation in groups[index] ?? [] {
                    object.setData(representation.data, forType: NSPasteboard.PasteboardType(representation.type))
                }
                object.setData(Data(), forType: ClipboardManager.historyIgnoreType)
                return object
            }
            guard !objects.isEmpty else { throw ClipboardHistoryError.missingPayload }
            pasteboard.clearContents()
            guard pasteboard.writeObjects(objects) else { throw ClipboardHistoryError.missingPayload }
        } catch { errorMessage = error.localizedDescription }
    }

    func beginEditing(_ item: ClipboardItem) async {
        guard [.plainText, .richText, .code, .url, .email, .color].contains(item.kind) else { return }
        do {
            let loaded = try await store.itemWithPayload(item.id)
            select(item)
            editingItemID = item.id
            editingErrorMessage = nil
            textBeingEdited = ClipboardPanelText.plainText(from: loaded.representations, fallback: loaded.preview)
            isTextEditorVisible = true
        } catch { errorMessage = error.localizedDescription }
    }

    private func loadSelectedDetail(keepingCurrentPreview: Bool = false) {
        detailTask?.cancel()
        guard let id = selectedIDs.first else {
            if detailItem != nil { detailItem = nil }
            if isLoadingDetail { isLoadingDetail = false }
            return
        }
        if let cached = cachedDetail(for: id) {
            if detailItem != cached { detailItem = cached }
            if isLoadingDetail { isLoadingDetail = false }
            return
        }
        if !keepingCurrentPreview || detailItem?.id != id { detailItem = nil }
        if isLoadingDetail { isLoadingDetail = false }
        if let item = items.first(where: { $0.id == id }), !item.representations.isEmpty {
            if detailItem != item { detailItem = item }
            cacheDetail(item)
            return
        }
        if !isLoadingDetail { isLoadingDetail = true }
        detailTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if !Task.isCancelled, self.selectedIDs.first == id, self.isLoadingDetail {
                    self.isLoadingDetail = false
                }
            }
            do {
                let loaded = try await self.store.itemWithPayload(id)
                guard !Task.isCancelled, self.selectedIDs.first == id else { return }
                let latestMetadata = self.items.first(where: { $0.id == id }) ?? loaded
                let current = latestMetadata.replacingPayload(from: loaded)
                if self.detailItem != current { self.detailItem = current }
                self.cacheDetail(current)
            } catch {
                guard !Task.isCancelled, self.selectedIDs.first == id else { return }
                if self.isTextEditorVisible, self.editingItemID == id {
                    self.editingErrorMessage = error.localizedDescription
                } else { self.errorMessage = error.localizedDescription }
                if self.detailItem?.id == id { self.detailItem = nil }
            }
        }
    }

    private func cachedDetail(for id: UUID) -> ClipboardItem? {
        guard let item = detailCache[id] else { return nil }
        detailCacheOrder.removeAll { $0 == id }
        detailCacheOrder.append(id)
        return item
    }

    private func cacheDetail(_ item: ClipboardItem) {
        let byteCount = detailPayloadSize(item)
        guard byteCount <= detailCacheByteLimit else {
            invalidateDetailCache(for: item.id)
            return
        }
        detailCache[item.id] = item
        detailCacheOrder.removeAll { $0 == item.id }
        detailCacheOrder.append(item.id)
        while detailCacheOrder.count > detailCacheLimit || detailCacheByteCount > detailCacheByteLimit {
            let evictedID = detailCacheOrder.removeFirst()
            detailCache.removeValue(forKey: evictedID)
        }
    }

    private var detailCacheByteCount: Int {
        detailCache.values.reduce(0) { $0 + detailPayloadSize($1) }
    }

    private func detailPayloadSize(_ item: ClipboardItem) -> Int {
        item.representations.reduce(item.thumbnailData?.count ?? 0) { $0 + $1.data.count }
    }

    var detailCacheMetrics: (count: Int, bytes: Int) { (detailCache.count, detailCacheByteCount) }

    private func invalidateDetailCache(for id: UUID) {
        detailCache.removeValue(forKey: id)
        detailCacheOrder.removeAll { $0 == id }
    }

    private func queryChanged() {
        queryRevision += 1
        applyQuery()
        if hasLoadedItems { reload(debounced: true) }
    }

    private func fetchPage(ascending: Bool, offset: Int, limit: Int) async throws -> (items: [ClipboardItem], total: Int) {
        let parsed = ClipboardPanelQuery.parse(query)
        let rail = railFilter
        let app = appFilter
        let filters = parsed.filters
        let cutoff: Date? = switch dateFilter {
        case .anytime: nil
        case .today: Calendar.current.startOfDay(for: Date())
        case .week: Calendar.current.date(byAdding: .day, value: -7, to: Date())
        case .month: Calendar.current.date(byAdding: .day, value: -30, to: Date())
        }
        return try await store.filteredPage(sort.engineSort, ascending: ascending, offset: offset, limit: limit, text: parsed.text, favoritesOnTop: favoritesOnTop) { item in
            switch rail {
            case .history: break
            case .favorites: if !item.isFavorite { return false }
            case .text: if ![.plainText, .richText].contains(item.kind) { return false }
            case .kind(let kind): if item.kind != kind { return false }
            }
            if let app, item.sourceApp.bundleIdentifier != app { return false }
            if let cutoff, item.lastCopiedAt < cutoff { return false }
            if !filters.kinds.isEmpty, !filters.kinds.contains(item.kind) { return false }
            if !filters.sourceApps.isEmpty {
                let values = [item.sourceApp.name ?? "", item.sourceApp.bundleIdentifier ?? ""].map(\.localizedLowercase)
                if !filters.sourceApps.contains(where: { app in values.contains(where: { $0.contains(app) }) }) { return false }
            }
            return true
        }
    }

    func deleteSelection() async {
        let ids = selectedIDs
        do {
            for id in ids { try await store.delete(id) }
        } catch { errorMessage = error.localizedDescription; await loadItems(); return }
        items.removeAll { ids.contains($0.id) }
        selectedIDs = []
        selectionAnchorID = nil
        selectionLeadID = nil
        applyQuery()
        if let first = visibleItems.first { selectedIDs = [first.id] }
    }

    func toggleFavorite(_ item: ClipboardItem) async {
        do { try await store.favorite(item.id, favorite: !item.isFavorite) }
        catch { errorMessage = error.localizedDescription }
        reload()
    }

    func togglePinned(_ item: ClipboardItem) async {
        do { try await store.pin(item.id, pinned: !item.isPinned) }
        catch { errorMessage = error.localizedDescription }
        reload()
    }

    func transformSelection(_ transform: ClipboardTextTransform) async {
        guard let selectedItem else { return }
        do {
            let item = try await store.itemWithPayload(selectedItem.id)
            guard let value = transform.apply(to: ClipboardPanelText.plainText(from: item.representations, fallback: item.preview)) else {
                errorMessage = String(localized: "This transform cannot be applied to the selected text.")
                return
            }
            guard let replacement = ClipboardItem.capture(
                representations: [ClipboardRepresentation(type: NSPasteboard.PasteboardType.string.rawValue, data: Data(value.utf8))],
                sourceApp: item.sourceApp
                  ) else { throw ClipboardHistoryError.missingPayload }
            let saved = try await store.capture(replacement)
            await loadItems()
            select(saved)
        } catch { errorMessage = error.localizedDescription }
    }

    func mergeSelection() async {
        do {
            guard let merged = try await store.merge(selectedIDs) else { throw ClipboardHistoryError.missingPayload }
            await loadItems()
            select(merged)
        } catch { errorMessage = error.localizedDescription }
    }

    func splitSelection() async {
        guard let item = selectedItem else { return }
        do { _ = try await store.split(item.id) }
        catch { errorMessage = error.localizedDescription; return }
        await loadItems()
    }

    func saveEditedText() async {
        guard let id = editingItemID, !isSavingEdit else { return }
        isSavingEdit = true
        editingErrorMessage = nil
        defer { isSavingEdit = false }
        do {
            guard try await store.editText(id, text: textBeingEdited) != nil else { throw ClipboardHistoryError.missingPayload }
            isTextEditorVisible = false
            await loadItems()
        } catch { editingErrorMessage = error.localizedDescription }
    }

    func clearHistory() async {
        do { try await store.clear(
            keepingFavorites: ClipboardHistorySettings.bool(ClipboardHistorySettings.Keys.keepFavoritesOnClear, in: defaults, defaultValue: true),
            keepingTagged: ClipboardHistorySettings.bool(ClipboardHistorySettings.Keys.keepTaggedOnClear, in: defaults, defaultValue: true)
        ) } catch { errorMessage = error.localizedDescription; return }
        selectedIDs = []
        await loadItems()
    }

    func reorderFavorite(_ item: ClipboardItem, by offset: Int) async {
        let favorites = visibleItems.filter(\.isFavorite)
        guard let index = favorites.firstIndex(where: { $0.id == item.id }) else { return }
        let target = min(max(index + offset, 0), favorites.count - 1)
        guard target != index else { return }
        var reordered = favorites.map(\.id)
        let moved = reordered.remove(at: index)
        reordered.insert(moved, at: target)
        do { try await store.reorderFavorites(reordered) }
        catch { errorMessage = error.localizedDescription; return }
        reload()
    }

    func estimatedSize(of item: ClipboardItem) -> Int {
        item.payloadSize ?? item.representations.reduce(0) { $0 + $1.data.count }
    }

    func applyQuery() {
        let parsed = ClipboardPanelQuery.parse(query)
        let terms = parsed.text.localizedLowercase.split(whereSeparator: \.isWhitespace).map(String.init)
        let filtered = items.filter { item in
            let matchesRail: Bool
            switch railFilter {
            case .history: matchesRail = true
            case .favorites: matchesRail = item.isFavorite
            case .text: matchesRail = item.kind == .plainText || item.kind == .richText
            case let .kind(kind): matchesRail = item.kind == kind
            }
            return matchesRail
                && (appFilter == nil || item.sourceApp.bundleIdentifier == appFilter)
                && dateMatches(item.lastCopiedAt)
                && (parsed.filters.kinds.isEmpty || parsed.filters.kinds.contains(item.kind))
                && (parsed.filters.sourceApps.isEmpty
                    || parsed.filters.sourceApps.contains { app in
                        (item.sourceApp.name ?? "").localizedLowercase.contains(app)
                            || (item.sourceApp.bundleIdentifier ?? "").localizedLowercase.contains(app)
                    })
                && (loadedSearchText == parsed.text || terms.allSatisfy { term in
                    [item.preview, item.title ?? "", item.sourceApp.name ?? "", item.recognizedText,
                     item.barcodePayloads.joined(separator: " ")].contains {
                        $0.localizedCaseInsensitiveContains(term)
                    }
                })
        }
        var ascending = reversed
        if sort == .firstCopy { ascending.toggle() }
        let ordered = filtered.sorted { left, right in
            let comparison: ComparisonResult
            switch sort {
            case .lastCopy: comparison = left.lastCopiedAt.compare(right.lastCopiedAt)
            case .firstCopy: comparison = left.createdAt.compare(right.createdAt)
            case .copyCount: comparison = (left.useCount as NSNumber).compare(right.useCount as NSNumber)
            case .size: comparison = ((left.payloadSize ?? 0) as NSNumber).compare((right.payloadSize ?? 0) as NSNumber)
            }
            if comparison == .orderedSame { return ascending ? left.id.uuidString < right.id.uuidString : left.id.uuidString > right.id.uuidString }
            return ascending ? comparison == .orderedAscending : comparison == .orderedDescending
        }
        let sorted = favoritesOnTop ? filtered.filter(\.isFavorite) + ordered.filter { !$0.isFavorite } : ordered
        if visibleItems != sorted { visibleItems = sorted }
        let filteredSelection = selectedIDs.filter { id in sorted.contains(where: { $0.id == id }) }
        if selectedIDs != filteredSelection { selectedIDs = filteredSelection }
        if let selectionAnchorID, !selectedIDs.contains(selectionAnchorID) {
            self.selectionAnchorID = selectedIDs.first
        }
        if let selectionLeadID, !selectedIDs.contains(selectionLeadID) { self.selectionLeadID = selectedIDs.last }
        updateCommandSelection()
    }

    private func dateMatches(_ date: Date) -> Bool {
        switch dateFilter {
        case .anytime: true
        case .today: Calendar.current.isDateInToday(date)
        case .week: date >= Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? .distantPast
        case .month: date >= Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? .distantPast
        }
    }

    private func registerCoreCommands() {
        registry.register(
            .init(id: "paste", title: String(localized: "Paste"), shortcut: "↩", isEnabled: { !$0.isEmpty }) {
                [weak self] _ in self?.onCommand?("paste")
            })
        registry.register(
            .init(id: "copy", title: String(localized: "Copy"), shortcut: "⌘C", isEnabled: { !$0.isEmpty }) {
                [weak self] _ in self?.onCommand?("copy")
            })
        registry.register(
            .init(id: "delete", title: String(localized: "Delete"), shortcut: "⌘⌫", isEnabled: { !$0.isEmpty }) {
                [weak self] _ in self?.onCommand?("delete")
            })
        registry.register(
            .init(id: "showInHistory", title: String(localized: "Show in History"), isEnabled: { !$0.isEmpty }) {
                [weak self] _ in self?.onCommand?("showInHistory")
            })
        registry.register(.init(id: "merge", title: String(localized: "Merge Selected Items"), isEnabled: { selection in
            selection.count > 1 && selection.allSatisfy { [.plainText, .richText, .url, .email, .color].contains($0.kind) }
        }) { [weak self] _ in
            Task { await self?.mergeSelection() }
        })
        registry.register(.init(id: "split", title: String(localized: "Split into Lines"), isEnabled: { $0.count == 1 && [.plainText, .richText].contains($0[0].kind) }) { [weak self] _ in
            Task { await self?.splitSelection() }
        })
        registry.register(.init(id: "edit", title: String(localized: "Edit Text"), isEnabled: { $0.count == 1 && [.plainText, .richText, .code, .url, .email, .color].contains($0[0].kind) }) { [weak self] _ in
            guard let self, let item = self.selectedItem else { return }
            Task { await self.beginEditing(item) }
        })
        registry.register(.init(id: "favorite", title: String(localized: "Toggle Favourite"), isEnabled: { $0.count == 1 }) { [weak self] selection in
            guard let self, let item = selection.first else { return }
            Task { await self.toggleFavorite(item) }
        })
        registry.register(.init(id: "pin", title: String(localized: "Toggle Pin"), isEnabled: { $0.count == 1 }) { [weak self] selection in
            guard let self, let item = selection.first else { return }
            Task { await self.togglePinned(item) }
        })
        registry.register(.init(id: "favorite.moveUp", title: String(localized: "Move Favourite Up"), isEnabled: { $0.count == 1 && $0[0].isFavorite }) { [weak self] selection in
            guard let self, let item = selection.first else { return }
            Task { await self.reorderFavorite(item, by: -1) }
        })
        registry.register(.init(id: "favorite.moveDown", title: String(localized: "Move Favourite Down"), isEnabled: { $0.count == 1 && $0[0].isFavorite }) { [weak self] selection in
            guard let self, let item = selection.first else { return }
            Task { await self.reorderFavorite(item, by: 1) }
        })
        registry.register(.init(id: "clear", title: String(localized: "Clear Clipboard History")) { [weak self] _ in
            guard let self else { return }
            if ClipboardHistorySettings.bool(ClipboardHistorySettings.Keys.warnBeforeClear, in: self.defaults, defaultValue: true) {
                self.isClearConfirmationVisible = true
            } else {
                Task { await self.clearHistory() }
            }
        })
        registry.register(.init(id: "pasteNext", title: String(localized: "Paste Next")) { [weak self] _ in self?.onCommand?("pasteNext") })
        registry.register(.init(id: "resetPasteSequence", title: String(localized: "Reset Paste Sequence")) { [weak self] _ in self?.onCommand?("resetPasteSequence") })
        for transform in ClipboardTextTransform.allCases {
            registry.register(.init(id: "transform.\(transform.rawValue)", title: transform.localizedName, isEnabled: { selection in
                selection.count == 1 && [.plainText, .richText, .code, .url, .email, .color].contains(selection[0].kind)
            }) { [weak self] _ in
                Task { await self?.transformSelection(transform) }
            })
        }
    }

}

extension String {
    fileprivate func localizedCaseInsensitiveHasPrefix(_ prefix: String) -> Bool {
        range(of: prefix, options: [.anchored, .caseInsensitive, .diacriticInsensitive], locale: .current) != nil
    }
}

private extension ClipboardItem {
    func replacingPayload(from payloadItem: ClipboardItem) -> ClipboardItem {
        ClipboardItem(
            id: id,
            contentHash: contentHash,
            kind: kind,
            representations: payloadItem.representations,
            thumbnailData: thumbnailData ?? payloadItem.thumbnailData,
            payloadSize: payloadSize,
            preview: preview,
            createdAt: createdAt,
            lastCopiedAt: lastCopiedAt,
            lastUsedAt: lastUsedAt,
            useCount: useCount,
            isPinned: isPinned,
            isFavorite: isFavorite,
            collectionID: collectionID,
            title: title,
            tagIDs: tagIDs,
            tagDefinitions: tagDefinitions ?? payloadItem.tagDefinitions,
            recognizedText: recognizedText,
            barcodePayloads: barcodePayloads,
            sourceApp: sourceApp
        )
    }
}
