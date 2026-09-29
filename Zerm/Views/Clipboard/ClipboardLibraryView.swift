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
    private let linkService: LinkPreviewService
    private let layoutDirectionOverride: LayoutDirection?
    @State private var confirmsDelete = false
    @State private var showsExportError = false
    @FocusState private var searchFocused: Bool

    init(
        store: ClipboardHistoryStore,
        initialTagID: UUID? = nil,
        linkService: LinkPreviewService = .shared,
        layoutDirectionOverride: LayoutDirection? = nil
    ) {
        _model = StateObject(wrappedValue: ClipboardLibraryModel(store: store, initialTagID: initialTagID))
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
        VStack(spacing: 0) {
            pageHeader
            statsHeader
            Divider()
            filters
            Divider()
            HStack(spacing: 0) {
                itemList
                    .frame(minWidth: 310, idealWidth: 370, maxWidth: 460)
                Divider()
                previewPane
                    .frame(minWidth: 340, maxWidth: .infinity)
            }
            .frame(maxHeight: .infinity)
        }
        .background(.regularMaterial)
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
                    Divider()
                    Menu(String(localized: "Add Tag")) {
                        ForEach(model.tags) { tag in
                            Button(tag.name) { Task { await model.setTag(tag, attached: true) } }
                        }
                    }
                    Menu(String(localized: "Remove Tag")) {
                        ForEach(model.tags) { tag in
                            Button(tag.name) { Task { await model.setTag(tag, attached: false) } }
                        }
                    }
                } label: {
                    Label("Organize", systemImage: "tag")
                }
                Button(role: .destructive) { confirmsDelete = true } label: {
                    Label("Delete", systemImage: "trash")
                }
                .keyboardShortcut(.delete, modifiers: [])
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 22)
        .padding(.bottom, 14)
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
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(String(localized: "Search clipboard history"), text: $model.query)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .accessibilityLabel(String(localized: "Search clipboard history"))
                if !model.query.isEmpty {
                    Button { model.query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.plain)
                        .help(String(localized: "Clear Search"))
                }
            }
            .padding(.horizontal, 10)
            .frame(minWidth: 180, maxWidth: 340)
            .frame(height: 30)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 7))

            Menu {
                ForEach(ClipboardItemKind.allCases, id: \.self) { kind in
                    Toggle(kind.libraryLocalizedName, isOn: Binding(
                        get: { model.selectedKinds.contains(kind) },
                        set: { _ in model.toggleKind(kind) }
                    ))
                }
            } label: { filterLabel("Kind", symbol: "line.3.horizontal.decrease.circle", active: !model.selectedKinds.isEmpty) }
            Menu {
                Button(String(localized: "All Apps")) { model.setAppFilter(nil) }
                ForEach(model.appNames, id: \.self) { name in Button(name) { model.setAppFilter(name) } }
            } label: { filterLabel("App", symbol: "app", active: model.selectedAppName != nil) }
            Menu {
                Button(String(localized: "All Tags")) { model.setTagFilter(nil) }
                ForEach(model.tags) { tag in Button { model.setTagFilter(tag.id) } label: { Label(tag.name, systemImage: "tag.fill") } }
            } label: { filterLabel("Tag", symbol: "tag", active: model.selectedTagID != nil) }
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
            Spacer(minLength: 0)
            if filtersActive {
                Button(String(localized: "Clear Filters")) {
                    model.selectedKinds.removeAll()
                    model.setAppFilter(nil)
                    model.setTagFilter(nil)
                    model.setDateFilter(.anytime)
                    model.query = ""
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
            }
        }
        .font(.callout)
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    private func filterLabel(_ title: String, symbol: String, active: Bool) -> some View {
        Label(title, systemImage: symbol)
            .foregroundStyle(active ? Color.accentColor : Color.primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(active ? Color.accentColor.opacity(0.12) : Color.clear, in: Capsule())
    }

    private var itemList: some View {
        VStack(spacing: 0) {
            if model.items.isEmpty && !model.isLoading {
                emptyState
            } else {
                List(selection: $model.selectedIDs) {
                    ForEach(model.items) { item in
                        ClipboardLibraryRow(item: item, tags: model.tags, linkService: linkService)
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
        Menu(String(localized: "Add Tag")) { ForEach(model.tags) { tag in Button(tag.name) { model.selectedIDs = [item.id]; Task { await model.setTag(tag, attached: true) } } } }
        Button(String(localized: "Delete"), role: .destructive) { model.selectedIDs = [item.id]; confirmsDelete = true }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: filtersActive ? "line.3.horizontal.decrease.circle" : "clipboard")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.tertiary)
            Text(verbatim: filtersActive ? String(localized: "No Matching Items") : String(localized: "Clipboard History Is Empty"))
                .font(.headline)
            Text(verbatim: filtersActive ? String(localized: "Try changing search or filters") : String(localized: "Copied items will appear here"))
                .font(.callout)
                .foregroundStyle(.secondary)
            if filtersActive {
                Button(String(localized: "Clear Filters")) {
                    model.selectedKinds.removeAll()
                    model.setAppFilter(nil)
                    model.setTagFilter(nil)
                    model.setDateFilter(.anytime)
                    model.query = ""
                }
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .multilineTextAlignment(.center)
        .padding(28)
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
                        if item.isPinned { Image(systemName: "pin.fill").foregroundStyle(Color.accentColor).help(String(localized: "Pinned")) }
                        if item.isFavorite { Image(systemName: "star.fill").foregroundStyle(.yellow).help(String(localized: "Favorite")) }
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    Divider()
                    ClipboardRichPreview(item: item, linkService: linkService)
                        .padding(20)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    Divider()
                    HStack(spacing: 14) {
                        Label(item.sourceApp.name ?? String(localized: "Unknown App"), systemImage: "app")
                        Spacer()
                        Text(verbatim: item.lastCopiedAt.formatted(date: .abbreviated, time: .shortened))
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                }
            } else {
                VStack(spacing: 9) {
                    Image(systemName: "rectangle.split.2x1").font(.system(size: 28, weight: .light)).foregroundStyle(.tertiary)
                    Text("Select an item to preview").font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color.primary.opacity(0.025))
    }

    private var filtersActive: Bool {
        !model.query.isEmpty || !model.selectedKinds.isEmpty || model.selectedAppName != nil || model.selectedTagID != nil || model.dateFilter != .anytime
    }

    private var currentLayoutDirection: LayoutDirection {
        Locale.Language(identifier: Locale.current.identifier).characterDirection == .rightToLeft ? .rightToLeft : .leftToRight
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
    let tags: [ClipboardTag]
    let linkService: LinkPreviewService

    var body: some View {
        HStack(spacing: 11) {
            ClipboardRowThumbnail(item: item, linkService: linkService)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(verbatim: item.title?.clipboardLibraryNonEmpty ?? item.preview.clipboardLibraryNonEmpty ?? item.kind.libraryLocalizedName)
                        .font(.callout.weight(.medium))
                        .lineLimit(2)
                        .textSelection(.enabled)
                    Spacer(minLength: 0)
                    if item.isPinned { Image(systemName: "pin.fill").font(.caption2).foregroundStyle(Color.accentColor) }
                    if item.isFavorite { Image(systemName: "star.fill").font(.caption2).foregroundStyle(.yellow) }
                }
                HStack(spacing: 6) {
                    Text(verbatim: item.sourceApp.name ?? String(localized: "Unknown App"))
                    Image(systemName: "circle.fill").font(.system(size: 2))
                    Text(verbatim: item.lastCopiedAt.formatted(date: .abbreviated, time: .shortened))
                    Spacer(minLength: 2)
                    ForEach(tags.filter { item.tagIDs.contains($0.id) }.prefix(2)) { tag in
                        Text(verbatim: tag.name)
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color(clipboardHex: tag.colorHex).opacity(0.14), in: Capsule())
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                Text(verbatim: item.kind.libraryLocalizedName)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
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
        case .other: "doc.questionmark"
        }
    }
}

extension Color {
    init(clipboardHex: String) {
        if let value = ClipboardColorDetails.parse(clipboardHex) {
            self.init(red: Double(value.red) / 255, green: Double(value.green) / 255, blue: Double(value.blue) / 255)
        } else {
            self = .gray
        }
    }
}
