import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ClipboardLibraryUnavailableView: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "clipboard").font(.system(size: 30)).foregroundStyle(.secondary)
            Text("Clipboard History Is Unavailable").font(.headline)
            Text("Clipboard history store could not be opened").font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ClipboardLibraryView: View {
    @StateObject private var model: ClipboardLibraryModel
    @Environment(\.locale) private var locale
    private let linkService: LinkPreviewService
    private let layoutDirectionOverride: LayoutDirection?
    @State private var confirmsDelete = false
    @State private var showsExportError = false
    @State private var showsInspector = true
    @State private var searchFocused = false
    @State private var showsKindFilter = false
    @State private var showsAppFilter = false

    init(
        store: ClipboardHistoryStore,
        linkService: LinkPreviewService = .shared,
        layoutDirectionOverride: LayoutDirection? = nil
    ) {
        _model = StateObject(wrappedValue: ClipboardLibraryModel(store: store))
        self.linkService = linkService
        self.layoutDirectionOverride = layoutDirectionOverride
    }

    init(
        model: ClipboardLibraryModel,
        linkService: LinkPreviewService = .shared,
        layoutDirectionOverride: LayoutDirection? = nil
    ) {
        _model = StateObject(wrappedValue: model)
        self.linkService = linkService
        self.layoutDirectionOverride = layoutDirectionOverride
    }

    var body: some View {
        // Plain columns instead of .inspector: the inspector nests a second split view inside the main
        // window's NavigationSplitView, and their min-size negotiation looped until AppKit aborted.
        HStack(spacing: 0) {
            browser
                .frame(minWidth: 0, maxWidth: .infinity)
                .clipped()
            if showsInspector {
                Divider()
                previewPane
                    .frame(width: 320)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.layoutDirection, layoutDirectionOverride ?? currentLayoutDirection)
        .task { await model.start() }
        .onDisappear { model.stop() }
        .onChange(of: model.query) { _, _ in model.scheduleSearch() }
        .onChange(of: model.selectedIDs) { _, ids in
            guard ids.count == 1, let id = ids.first else { model.clearDetail(); return }
            Task { await model.select(id) }
        }
        .confirmationDialog(String(localized: "Delete selected items?"), isPresented: $confirmsDelete, titleVisibility: .visible) {
            Button(String(localized: "Delete"), role: .destructive) { Task { await model.deleteSelection() } }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: {
            Text(verbatim: String.localizedStringWithFormat(String(localized: "%lld items will be deleted"), model.selectedIDs.count))
        }
        .alert(String(localized: "Export failed"), isPresented: $showsExportError) {
            Button(String(localized: "OK"), role: .cancel) {}
        } message: {
            Text(verbatim: model.errorMessage ?? String(localized: "Clipboard history could not be exported"))
        }
    }

    private var browser: some View {
        VStack(spacing: 0) {
            pageHeader
            statsHeader
            Divider()
            filters
            Divider()
            itemList
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var pageHeader: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Clipboard History")
                    .font(.title2.weight(.semibold))
                Text(verbatim: String.localizedStringWithFormat(String(localized: "%lld items"), model.stats.itemCount))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !model.selectedIDs.isEmpty {
                Text(verbatim: String.localizedStringWithFormat(String(localized: "%lld selected"), model.selectedIDs.count))
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
                // Icon-only when the window is narrow, so the header never forces a minimum width
                // wider than the split view can give it.
                ViewThatFits(in: .horizontal) {
                    selectionActions.labelStyle(.titleAndIcon)
                    selectionActions.labelStyle(.iconOnly)
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 22)
        .padding(.bottom, 14)
    }

    private var selectionActions: some View {
        HStack {
            Button { Task { await model.copySelection() } } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .keyboardShortcut("c", modifiers: .command)
            .help(String(localized: "Copy selected items"))
            Button { exportSelection() } label: { Label("Export", systemImage: "square.and.arrow.up") }
                .help(String(localized: "Export selected items"))
            Menu {
                Button(String(localized: "Pin")) { Task { await model.togglePinned(true) } }
                Button(String(localized: "Unpin")) { Task { await model.togglePinned(false) } }
                Button(String(localized: "Add to Favorites")) { Task { await model.toggleFavorite(true) } }
                Button(String(localized: "Remove from Favorites")) { Task { await model.toggleFavorite(false) } }
            } label: {
                Label("Organize", systemImage: "slider.horizontal.3")
            }
            .help(String(localized: "Organize selected items"))
            Button(role: .destructive) { confirmsDelete = true } label: {
                Label("Delete", systemImage: "trash")
            }
            .keyboardShortcut(.delete, modifiers: [])
            .help(String(localized: "Delete selected items"))
        }
    }

    private var statsHeader: some View {
        HStack(spacing: 0) {
            stat(String(localized: "Storage Used"), ByteCountFormatter.string(fromByteCount: model.stats.storageBytes, countStyle: .file), symbol: "internaldrive")
            Divider().frame(height: 34)
            stat(String(localized: "Items Copied Today"), "\(model.stats.itemsCopiedToday)", symbol: "sun.max")
            Divider().frame(height: 34)
            let topAppLabel = model.stats.topApps.prefix(2).map { "\($0.name) \($0.count)" }.joined(separator: " · ")
            stat(String(localized: "Top Apps"), topAppLabel.clipboardLibraryNonEmpty ?? String(localized: "No source apps"), symbol: "square.grid.2x2")
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 14)
    }

    private func stat(_ title: String, _ value: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: symbol).font(.caption).foregroundStyle(.secondary)
            Text(verbatim: value).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
    }

    private var filters: some View {
        // Scrolls when narrow: a row of fixed-width menus would otherwise set the page minimum width.
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ClipboardHistorySearchField(
                    text: $model.query,
                    isFocused: $searchFocused,
                    placeholder: String(localized: "Search clipboard history")
                )
                .frame(minWidth: 160, idealWidth: 280, maxWidth: 340)

                Button { showsKindFilter = true } label: {
                    filterLabel("Kind", symbol: "line.3.horizontal.decrease.circle", active: !model.selectedKinds.isEmpty)
                }
                .buttonStyle(.plain)
                .help(String(localized: "Filter by Kind"))
                .popover(isPresented: $showsKindFilter, arrowEdge: .bottom) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            Button(String(localized: "All Kinds")) { model.selectedKinds.removeAll(); showsKindFilter = false }
                            ForEach(ClipboardItemKind.allCases, id: \.self) { kind in
                                Button(kind.libraryLocalizedName) { model.toggleKind(kind); showsKindFilter = false }
                            }
                        }
                        .buttonStyle(.plain)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                    }
                    .frame(width: 220, height: 280)
                }
                Button { showsAppFilter = true } label: {
                    filterLabel("App", symbol: "app", active: model.selectedAppName != nil)
                }
                .buttonStyle(.plain)
                .help(String(localized: "Filter by Source App"))
                .popover(isPresented: $showsAppFilter, arrowEdge: .bottom) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            Button(String(localized: "All Apps")) { model.setAppFilter(nil); showsAppFilter = false }
                            ForEach(model.appNames, id: \.self) { name in
                                Button { model.setAppFilter(name); showsAppFilter = false } label: {
                                    HStack(spacing: 7) {
                                        ClipboardSourceAppIcon(bundleIdentifier: model.items.first(where: { $0.sourceApp.name == name })?.sourceApp.bundleIdentifier, size: 16)
                                        Text(verbatim: name)
                                    }
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                    }
                    .frame(width: 260, height: 280)
                }
                Picker(String(localized: "Date"), selection: Binding(get: { model.dateFilter }, set: { model.setDateFilter($0) })) {
                    Text(verbatim: String(localized: "Any Time")).tag(ClipboardLibraryDateFilter.anytime)
                    Text(verbatim: String(localized: "Today")).tag(ClipboardLibraryDateFilter.today)
                    Text(verbatim: String(localized: "Last 7 Days")).tag(ClipboardLibraryDateFilter.week)
                    Text(verbatim: String(localized: "Last 30 Days")).tag(ClipboardLibraryDateFilter.month)
                }
                .labelsHidden()
                .frame(width: 112)
                Menu {
                    Picker(String(localized: "Sort By"), selection: Binding(get: { model.sort }, set: { model.setSort($0) })) {
                        Text(verbatim: String(localized: "Last Copy")).tag(ClipboardPanelSort.lastCopy)
                        Text(verbatim: String(localized: "First Copy")).tag(ClipboardPanelSort.firstCopy)
                        Text(verbatim: String(localized: "Copy Count")).tag(ClipboardPanelSort.copyCount)
                        Text(verbatim: String(localized: "Size")).tag(ClipboardPanelSort.size)
                    }
                    Divider()
                    Button(model.ascending ? String(localized: "Newest First") : String(localized: "Oldest First")) { model.toggleOrder() }
                } label: { Image(systemName: "arrow.up.arrow.down").frame(width: 28, height: 28) }
                    .help(String(localized: "Sort clipboard history"))
                    .accessibilityLabel(String(localized: "Sort clipboard history"))
                Spacer(minLength: 0)
                if filtersActive {
                    Button(String(localized: "Clear Filters")) {
                        model.selectedKinds.removeAll()
                        model.setAppFilter(nil)
                        model.setDateFilter(.anytime)
                        model.query = ""
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                }
            }
            .font(.callout)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    private func filterLabel(_ title: String, symbol: String, active: Bool) -> some View {
        Label(title, systemImage: symbol)
            .foregroundStyle(active ? Color.accentColor : Color.primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(active ? Color(nsColor: .selectedContentBackgroundColor) : Color.clear, in: Capsule())
    }

    private var itemList: some View {
        VStack(spacing: 0) {
            if model.items.isEmpty && !model.isLoading {
                emptyState
            } else {
                List(selection: $model.selectedIDs) {
                    ForEach(model.items) { item in
                        ClipboardLibraryRow(item: item, linkService: linkService)
                            .tag(item.id)
                            .contextMenu { rowMenu(item) }
                    }
                    if model.hasMore {
                        Button { Task { await model.loadMore() } } label: {
                            HStack { Spacer(); if model.isLoading { ProgressView().controlSize(.small) }; Text("Load More"); Spacer() }
                        }
                        .buttonStyle(.plain)
                        .listRowSeparator(.hidden)
                    }
                }
                .listStyle(.plain)
                .overlay(alignment: .top) {
                    if model.isLoading && model.items.isEmpty { ProgressView().padding(24) }
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    @ViewBuilder
    private func rowMenu(_ item: ClipboardItem) -> some View {
        Button(String(localized: "Copy")) { model.selectedIDs = [item.id]; Task { await model.copySelection() } }
        Button(item.isPinned ? String(localized: "Unpin") : String(localized: "Pin")) { model.selectedIDs = [item.id]; Task { await model.togglePinned(!item.isPinned) } }
        Button(item.isFavorite ? String(localized: "Remove from Favorites") : String(localized: "Add to Favorites")) { model.selectedIDs = [item.id]; Task { await model.toggleFavorite(!item.isFavorite) } }
        Button(String(localized: "Delete"), role: .destructive) { model.selectedIDs = [item.id]; confirmsDelete = true }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(
                String(localized: filtersActive ? "No Matching Items" : "Clipboard History Is Empty"),
                systemImage: filtersActive ? "line.3.horizontal.decrease.circle" : "clipboard"
            )
        } description: {
            Text(verbatim: String(localized: filtersActive ? "Try changing search or filters" : "Copied items will appear here"))
        } actions: {
            if filtersActive {
                Button(String(localized: "Clear Filters"), action: clearFilters)
            }
        }
    }

    private var previewPane: some View {
        Group {
            if let item = model.detailItem {
                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        Label(item.kind.libraryLocalizedName, systemImage: item.kind.librarySymbol)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                        Spacer()
                        if item.isPinned {
                            Image(systemName: "pin.fill")
                                .foregroundStyle(Color.accentColor)
                                .accessibilityLabel(String(localized: "Pinned"))
                        }
                        if item.isFavorite {
                            Image(systemName: "star.fill")
                                .foregroundStyle(Color.accentColor)
                                .accessibilityLabel(String(localized: "Favorite"))
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    Divider()
                    ClipboardRichPreview(item: item, linkService: linkService)
                        .padding(20)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    Divider()
                    HStack(spacing: 14) {
                        HStack(spacing: 6) {
                            ClipboardSourceAppIcon(bundleIdentifier: item.sourceApp.bundleIdentifier, size: 16)
                            Text(verbatim: item.sourceApp.name ?? String(localized: "Unknown App"))
                        }
                        Spacer()
                        Text(verbatim: item.lastCopiedAt.formatted(date: .abbreviated, time: .shortened))
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                }
            } else {
                ContentUnavailableView(
                    "Select an item to preview",
                    systemImage: "rectangle.split.2x1",
                    description: Text("The selected item preview and details appear here.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityElement(children: .contain)
    }

    private var filtersActive: Bool {
        !model.query.isEmpty || !model.selectedKinds.isEmpty || model.selectedAppName != nil || model.dateFilter != .anytime
    }

    private func clearFilters() {
        model.selectedKinds.removeAll()
        model.setAppFilter(nil)
        model.setDateFilter(.anytime)
        model.query = ""
    }

    private var currentLayoutDirection: LayoutDirection {
        Locale.Language(identifier: locale.identifier).characterDirection == .rightToLeft ? .rightToLeft : .leftToRight
    }

    private func exportSelection() {
        let panel = NSSavePanel()
        panel.title = String(localized: "Export selected items")
        panel.nameFieldStringValue = String(localized: "Clipboard History") + ".zip"
        panel.allowedContentTypes = [.zip]
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task {
                do { try await model.exportSelection(to: url) }
                catch { model.reportExportError(error); showsExportError = true }
            }
        }
    }
}

private struct ClipboardLibraryRow: View {
    let item: ClipboardItem
    let linkService: LinkPreviewService

    var body: some View {
        ClipboardHistoryListRow(item: item, index: nil, showQuickPasteBadge: false, query: "", linkService: linkService, isSelected: false, isCurrentClipboard: false)
    }
}

extension ClipboardItemKind {
    var libraryLocalizedName: String {
        switch self {
        case .plainText: String(localized: "Text")
        case .richText: String(localized: "Rich Text")
        case .image: String(localized: "Image")
        case .fileURLs: String(localized: "File")
        case .url: String(localized: "Link")
        case .email: String(localized: "Email")
        case .color: String(localized: "Color")
        case .code: String(localized: "Code")
        case .other: String(localized: "Other")
        }
    }

    var librarySymbol: String {
        switch self {
        case .plainText: "text.alignleft"
        case .richText: "textformat"
        case .image: "photo"
        case .fileURLs: "doc"
        case .url: "link"
        case .email: "envelope"
        case .color: "eyedropper"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .other: "doc.questionmark"
        }
    }
}

extension Color {
    init(clipboardHex: String) {
        if let value = ClipboardColorDetails.parse(clipboardHex) {
            self.init(red: Double(value.red) / 255, green: Double(value.green) / 255, blue: Double(value.blue) / 255)
        } else {
            self = .secondary
        }
    }
}
