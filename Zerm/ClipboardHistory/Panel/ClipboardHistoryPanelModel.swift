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

struct ClipboardPanelFilters: Equatable {
    var kinds: Set<ClipboardItemKind> = []
    var sourceApps: Set<String> = []
    var tags: Set<String> = []
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
            } else if part.localizedCaseInsensitiveHasPrefix("tag:") {
                let value = String(part.dropFirst(4)).removingPercentEncoding ?? String(part.dropFirst(4))
                query.filters.tags.insert(value.localizedLowercase)
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
    @Published var query = "" { didSet { applyQuery() } }
    @Published var sort: ClipboardPanelSort = .lastCopy { didSet { reload() } }
    @Published var reversed = false { didSet { reload() } }
    @Published var favoritesOnTop = ClipboardHistorySettings.bool(ClipboardHistorySettings.Keys.favoritesOnTop, defaultValue: true) {
        didSet {
            UserDefaults.standard.set(favoritesOnTop, forKey: ClipboardHistorySettings.Keys.favoritesOnTop)
            applyQuery()
        }
    }
    @Published private(set) var tags: [ClipboardTag] = []
    @Published var selectedIDs: [UUID] = []
    @Published var isPinned = false
    @Published var isPreviewVisible = true
    @Published var isDetailsVisible = false
    @Published var isCommandPaletteVisible = false
    @Published var isShowingQuickPasteBadges = false
    @Published var isClearConfirmationVisible = false
    @Published var isTagEditorVisible = false
    @Published var editingTag: ClipboardTag?
    @Published var isTextEditorVisible = false
    @Published var textBeingEdited = ""

    let registry = ClipboardPanelCommandRegistry()
    var onCommand: ((String) -> Void)?
    private let store: ClipboardHistoryStore
    private var reloadTask: Task<Void, Never>?
    private var ocrRefreshTask: Task<Void, Never>?
    private var feedTask: Task<Void, Never>?
    /// Loads run one after another in call order, so a slower load can never overwrite a newer one.
    private var loadChain: Task<Void, Never>?
    private var pageOffset = 0
    @Published private(set) var canLoadMore = false
    private var ocrRefreshAttempts = 0
    private var selectionAnchorID: UUID?
    private var selectionLeadID: UUID?

    init(store: ClipboardHistoryStore, initialItems: [ClipboardItem] = [], initialTags: [ClipboardTag] = []) {
        self.store = store
        items = initialItems
        tags = initialTags
        applyQuery()
        registerCoreCommands()
        registerTagCommands()
        feedTask = Task { [weak self] in
            for await change in ClipboardHistoryFeed.shared.changes() {
                guard let self else { return }
                await self.receive(change)
            }
        }
    }

    deinit {
        reloadTask?.cancel()
        ocrRefreshTask?.cancel()
        feedTask?.cancel()
    }

    var selection: [ClipboardItem] {
        selectedIDs.compactMap { id in items.first(where: { $0.id == id }) }
    }

    var selectedItem: ClipboardItem? { selection.first }

    func reload() {
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            await self?.loadItems()
        }
    }

    func loadItems(preservingLoadedPage: Bool = false) async {
        await enqueueLoad { [weak self] in await self?.performLoadItems(preservingLoadedPage: preservingLoadedPage) }
    }

    func loadMore() async {
        await enqueueLoad { [weak self] in await self?.performLoadMore() }
    }

    private func enqueueLoad(_ load: @escaping @MainActor () async -> Void) async {
        let previous = loadChain
        let task = Task { @MainActor in
            await previous?.value
            await load()
        }
        loadChain = task
        await task.value
    }

    private func performLoadItems(preservingLoadedPage: Bool) async {
        if !preservingLoadedPage { pageOffset = 0 }
        var ascending = reversed
        if sort == .firstCopy { ascending.toggle() }
        let requestedCount = preservingLoadedPage ? max(pageOffset, 100) : 100
        guard let fetched = try? await store.sortedPage(sort.engineSort, ascending: ascending, offset: 0, limit: requestedCount) else { return }
        items = fetched
        pageOffset = fetched.count
        canLoadMore = ((try? await store.totalCount()) ?? fetched.count) > pageOffset
        tags = (try? await store.allTags()) ?? tags
        registerTagCommands()
        applyQuery()
        scheduleOCRRefreshIfNeeded(fetched)
        if selectedIDs.isEmpty, let first = visibleItems.first { selectedIDs = [first.id] }
    }

    private func performLoadMore() async {
        guard canLoadMore else { return }
        var ascending = reversed
        if sort == .firstCopy { ascending.toggle() }
        guard let additional = try? await store.sortedPage(sort.engineSort, ascending: ascending, offset: pageOffset, limit: 100) else { return }
        items.append(contentsOf: additional)
        pageOffset += additional.count
        canLoadMore = ((try? await store.totalCount()) ?? pageOffset) > pageOffset
        applyQuery()
    }

    private func receive(_ change: ClipboardHistoryChange) async {
        switch change {
        case let .inserted(storeID, _), let .updated(storeID, _):
            guard storeID == store.feedStoreID else { return }
            await loadItems(preservingLoadedPage: true)
        case let .insertedBatch(storeID, _):
            guard storeID == store.feedStoreID else { return }
            await loadItems(preservingLoadedPage: true)
        case let .removed(storeID, ids), let .cleared(storeID, ids):
            guard storeID == store.feedStoreID else { return }
            await enqueueLoad { [weak self] in self?.applyRemoval(of: ids) }
        }
    }

    /// Runs in the load queue, after any load that was already in flight, so a stale fetch
    /// cannot bring back an item that was just removed.
    private func applyRemoval(of ids: [UUID]) {
        items.removeAll { ids.contains($0.id) }
        selectedIDs.removeAll { ids.contains($0) }
        if selectionAnchorID.map(ids.contains) == true { selectionAnchorID = selectedIDs.first }
        if selectionLeadID.map(ids.contains) == true { selectionLeadID = selectedIDs.last }
        applyQuery()
        if selectedIDs.isEmpty, let first = visibleItems.first { select(first) }
    }

    private func scheduleOCRRefreshIfNeeded(_ fetched: [ClipboardItem]) {
        let needsOCRRefresh = fetched.contains {
            $0.kind == .image && $0.recognizedText.isEmpty && $0.barcodePayloads.isEmpty
        }
        guard needsOCRRefresh else {
            ocrRefreshAttempts = 0
            return
        }
        guard ocrRefreshAttempts < 5 else { return }
        ocrRefreshAttempts += 1
        ocrRefreshTask?.cancel()
        ocrRefreshTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            await self?.loadItems()
        }
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

    func showInHistory(_ item: ClipboardItem) {
        query = ""
        selectedIDs = [item.id]
        selectionAnchorID = item.id
        selectionLeadID = item.id
    }

    func deleteSelection() async {
        let ids = selectedIDs
        for id in ids { try? await store.delete(id) }
        items.removeAll { ids.contains($0.id) }
        selectedIDs = []
        selectionAnchorID = nil
        selectionLeadID = nil
        applyQuery()
        if let first = visibleItems.first { selectedIDs = [first.id] }
    }

    func toggleFavorite(_ item: ClipboardItem) async {
        try? await store.favorite(item.id, favorite: !item.isFavorite)
        reload()
    }

    func togglePinned(_ item: ClipboardItem) async {
        try? await store.pin(item.id, pinned: !item.isPinned)
        reload()
    }

    func createTag(name: String, colorHex: String) async {
        guard let tag = try? await store.createTag(name: name, colorHex: colorHex) else { return }
        for item in selection { try? await store.attachTag(tag.id, to: item.id) }
        editingTag = nil
        isTagEditorVisible = false
        await loadItems()
    }

    func updateTag(_ tag: ClipboardTag, name: String, colorHex: String) async {
        try? await store.renameTag(tag.id, name: name)
        try? await store.recolorTag(tag.id, colorHex: colorHex)
        editingTag = nil
        isTagEditorVisible = false
        await loadItems()
    }

    func deleteTag(_ tag: ClipboardTag) async {
        try? await store.deleteTag(tag.id)
        await loadItems()
    }

    func setTag(_ tag: ClipboardTag, attached: Bool) async {
        for item in selection {
            if attached { try? await store.attachTag(tag.id, to: item.id) }
            else { try? await store.detachTag(tag.id, from: item.id) }
        }
        await loadItems()
    }

    func setTagFilter(_ tag: ClipboardTag, enabled: Bool) {
        var tokens = query.split(whereSeparator: \.isWhitespace).map(String.init)
        let value = tag.name.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? tag.name
        let token = "tag:\(value)"
        tokens.removeAll { $0.localizedCaseInsensitiveCompare(token) == .orderedSame }
        if enabled { tokens.append(token) }
        query = tokens.joined(separator: " ")
    }

    func isTagFiltered(_ tag: ClipboardTag) -> Bool {
        ClipboardPanelQuery.parse(query).filters.tags.contains(tag.name.localizedLowercase)
    }

    func transformSelection(_ transform: ClipboardTextTransform) async {
        guard let selectedItem,
              let item = try? await store.itemWithPayload(selectedItem.id),
              let value = transform.apply(to: ClipboardPanelText.plainText(from: item.representations, fallback: item.preview)),
              let replacement = ClipboardItem.capture(
                representations: [ClipboardRepresentation(type: NSPasteboard.PasteboardType.string.rawValue, data: Data(value.utf8))],
                sourceApp: item.sourceApp
              ),
              let saved = try? await store.capture(replacement) else { return }
        await loadItems()
        select(saved)
    }

    func mergeSelection() async {
        guard let merged = try? await store.merge(selectedIDs) else { return }
        await loadItems()
        select(merged)
    }

    func splitSelection() async {
        guard let item = selectedItem else { return }
        _ = try? await store.split(item.id)
        await loadItems()
    }

    func saveEditedText() async {
        guard let item = selectedItem else { return }
        _ = try? await store.editText(item.id, text: textBeingEdited)
        isTextEditorVisible = false
        await loadItems()
    }

    func clearHistory() async {
        try? await store.clear(
            keepingFavorites: ClipboardHistorySettings.bool(ClipboardHistorySettings.Keys.keepFavoritesOnClear, defaultValue: true),
            keepingTagged: ClipboardHistorySettings.bool(ClipboardHistorySettings.Keys.keepTaggedOnClear, defaultValue: true)
        )
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
        try? await store.reorderFavorites(reordered)
        reload()
    }

    func estimatedSize(of item: ClipboardItem) -> Int {
        item.payloadSize ?? item.representations.reduce(0) { $0 + $1.data.count }
    }

    func applyQuery() {
        let parsed = ClipboardPanelQuery.parse(query)
        let terms = parsed.text.localizedLowercase.split(whereSeparator: \.isWhitespace).map(String.init)
        let tagNamesByID = Dictionary(uniqueKeysWithValues: tags.map { ($0.id, $0.name.localizedLowercase) })
        let filtered = items.filter { item in
            let itemTags = item.tagIDs.compactMap { tagNamesByID[$0] }
            return (parsed.filters.kinds.isEmpty || parsed.filters.kinds.contains(item.kind))
                && (parsed.filters.sourceApps.isEmpty
                    || parsed.filters.sourceApps.contains { app in
                        (item.sourceApp.name ?? "").localizedLowercase.contains(app)
                            || (item.sourceApp.bundleIdentifier ?? "").localizedLowercase.contains(app)
                    })
                && (parsed.filters.tags.isEmpty || parsed.filters.tags.allSatisfy { itemTags.contains($0) })
                && terms.allSatisfy { term in
                    [item.preview, item.title ?? "", item.sourceApp.name ?? "", item.recognizedText,
                     item.barcodePayloads.joined(separator: " "), itemTags.joined(separator: " ")].contains {
                        $0.localizedCaseInsensitiveContains(term)
                    }
                }
        }
        let sorted = favoritesOnTop ? filtered.filter(\.isFavorite) + filtered.filter { !$0.isFavorite } : filtered
        visibleItems = sorted
        selectedIDs = selectedIDs.filter { id in sorted.contains(where: { $0.id == id }) }
        if let selectionAnchorID, !selectedIDs.contains(selectionAnchorID) {
            self.selectionAnchorID = selectedIDs.first
        }
        if let selectionLeadID, !selectedIDs.contains(selectionLeadID) { self.selectionLeadID = selectedIDs.last }
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
        registry.register(.init(id: "merge", title: String(localized: "Merge Selected Items"), isEnabled: { $0.count > 1 }) { [weak self] _ in
            Task { await self?.mergeSelection() }
        })
        registry.register(.init(id: "split", title: String(localized: "Split into Lines"), isEnabled: { $0.count == 1 && [.plainText, .richText].contains($0[0].kind) }) { [weak self] _ in
            Task { await self?.splitSelection() }
        })
        registry.register(.init(id: "edit", title: String(localized: "Edit Text"), isEnabled: { $0.count == 1 && [.plainText, .richText].contains($0[0].kind) }) { [weak self] _ in
            guard let self, let item = self.selectedItem else { return }
            Task { [weak self] in
                guard let self, let loaded = try? await self.store.itemWithPayload(item.id) else { return }
                self.textBeingEdited = ClipboardPanelText.plainText(from: loaded.representations, fallback: loaded.preview)
                self.isTextEditorVisible = true
            }
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
            if ClipboardHistorySettings.bool(ClipboardHistorySettings.Keys.warnBeforeClear, defaultValue: true) {
                self.isClearConfirmationVisible = true
            } else {
                Task { await self.clearHistory() }
            }
        })
        registry.register(.init(id: "pasteNext", title: String(localized: "Paste Next")) { [weak self] _ in self?.onCommand?("pasteNext") })
        registry.register(.init(id: "resetPasteSequence", title: String(localized: "Reset Paste Sequence")) { [weak self] _ in self?.onCommand?("resetPasteSequence") })
        registry.register(.init(id: "createTag", title: String(localized: "Create Tag")) { [weak self] _ in
            self?.editingTag = nil
            self?.isTagEditorVisible = true
        })
        for transform in ClipboardTextTransform.allCases {
            registry.register(.init(id: "transform.\(transform.rawValue)", title: transform.localizedName, isEnabled: { selection in
                selection.count == 1 && [.plainText, .richText, .url, .email, .color].contains(selection[0].kind)
            }) { [weak self] _ in
                Task { await self?.transformSelection(transform) }
            })
        }
    }

    private func registerTagCommands() {
        registry.removeCommands(withPrefix: "tag.")
        for tag in tags {
            registry.register(.init(id: "tag.filter.\(tag.id)", title: String(localized: "Filter by Tag")) { [weak self] _ in
                guard let self else { return }
                self.setTagFilter(tag, enabled: !self.isTagFiltered(tag))
            })
            registry.register(.init(id: "tag.rename.\(tag.id)", title: String(localized: "Rename Tag"), isEnabled: { !$0.isEmpty }) { [weak self] _ in
                self?.editingTag = tag
                self?.isTagEditorVisible = true
            })
            registry.register(.init(id: "tag.recolor.\(tag.id)", title: String(localized: "Recolor Tag"), isEnabled: { !$0.isEmpty }) { [weak self] _ in
                self?.editingTag = tag
                self?.isTagEditorVisible = true
            })
            registry.register(.init(id: "tag.delete.\(tag.id)", title: String(localized: "Delete Tag"), isEnabled: { !$0.isEmpty }) { [weak self] _ in
                Task { await self?.deleteTag(tag) }
            })
            registry.register(.init(id: "tag.attach.\(tag.id)", title: String(localized: "Attach Tag"), isEnabled: { !$0.isEmpty }) { [weak self] _ in
                Task { await self?.setTag(tag, attached: true) }
            })
            registry.register(.init(id: "tag.detach.\(tag.id)", title: String(localized: "Detach Tag"), isEnabled: { !$0.isEmpty }) { [weak self] _ in
                Task { await self?.setTag(tag, attached: false) }
            })
        }
    }
}

extension String {
    fileprivate func localizedCaseInsensitiveHasPrefix(_ prefix: String) -> Bool {
        range(of: prefix, options: [.anchored, .caseInsensitive, .diacriticInsensitive], locale: .current) != nil
    }
}
