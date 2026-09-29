import AppKit
import SwiftUI

struct ClipboardHistoryPanelView: View {
    @ObservedObject var model: ClipboardHistoryPanelModel
    let controller: ClipboardHistoryPanelController?
    private let tracksSystemClipboard: Bool
    private let linkService: LinkPreviewService
    @Environment(\.locale) private var locale
    @Environment(\.openSettings) private var openSettings
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @AppStorage("clipboardHistoryDoubleClickPaste") private var doubleClickPaste = true
    @AppStorage("clipboardHistoryPasteOnClick") private var pasteOnClick = false
    @AppStorage("clipboardHistoryShowBadges") private var showBadges = true
    @FocusState private var searchFocused: Bool
    @State private var pendingClickPaste: Task<Void, Never>?
    @State private var currentClipboardHash: String?
    @State private var showsAllApps = false

    init(model: ClipboardHistoryPanelModel, controller: ClipboardHistoryPanelController? = nil, linkService: LinkPreviewService = .shared, tracksSystemClipboard: Bool = false) {
        self.model = model
        self.controller = controller
        self.linkService = linkService
        self.tracksSystemClipboard = tracksSystemClipboard
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: model.isSidebarCollapsed ? 46 : 184)
            Divider()
            VStack(spacing: 0) {
                listToolbar
                historyList
                listFooter
            }
            // The list fills the panel when the preview is hidden; otherwise the columns center and leave gaps.
            .frame(minWidth: 260, idealWidth: 360, maxWidth: model.isPreviewVisible ? 420 : .infinity)
            if model.isPreviewVisible {
                Divider()
                previewColumn.frame(minWidth: 280, maxWidth: .infinity)
            }
        }
        // Sidebar (184) + list (260) + preview (280) + dividers must fit the window minimum; if the
        // columns' minimums exceed the window, SwiftUI overflows and clips both edges.
        .frame(minWidth: ClipboardHistoryPanel.minimumContentSize.width, minHeight: ClipboardHistoryPanel.minimumContentSize.height)
        .background {
            ZStack {
                Rectangle().fill(.background)
                if !reduceTransparency {
                    if #available(macOS 26.0, *) { Color.clear.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 13, style: .continuous)) }
                    else { VisualEffectView(material: .hudWindow, blendingMode: .behindWindow) }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay {
            if model.isCommandPaletteVisible {
                ZStack {
                    Color.primary.opacity(0.06).contentShape(Rectangle())
                        .onTapGesture { model.isCommandPaletteVisible = false }
                        .accessibilityHidden(true)
                    CommandPaletteView(model: model, controller: controller)
                }
            }
        }
        .environment(\.layoutDirection, Locale.Language(identifier: locale.identifier).characterDirection == .rightToLeft ? .rightToLeft : .leftToRight)
        .onAppear {
            searchFocused = true
            if tracksSystemClipboard { currentClipboardHash = currentPasteboardHash() }
        }
        .onChange(of: model.items.map(\.id)) {
            if tracksSystemClipboard { currentClipboardHash = currentPasteboardHash() }
        }
        .sheet(isPresented: $model.isTextEditorVisible) { textEditor }
        .alert("Clipboard History Error", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: { Text(verbatim: model.errorMessage ?? "") }
        .onDisappear { pendingClickPaste?.cancel() }
        .confirmationDialog("Clear Clipboard History?", isPresented: $model.isClearConfirmationVisible, titleVisibility: .visible) {
            Button("Clear", role: .destructive) { Task { await model.clearHistory() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Pinned items and items protected by your settings stay in history.")
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                if !model.isSidebarCollapsed { Text("Clipboard History").font(.caption.weight(.semibold)).foregroundStyle(.secondary) }
                Spacer(minLength: 0)
                Button { model.isSidebarCollapsed.toggle() } label: { Image(systemName: model.isSidebarCollapsed ? "sidebar.left" : "sidebar.leading") }
                    .buttonStyle(.plain).help("Toggle Sidebar").accessibilityLabel("Toggle Sidebar")
            }.padding(.horizontal, 8).padding(.bottom, 5)
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    sidebarButton("All", symbol: "clock.arrow.circlepath", filter: .history)
                    sidebarButton("Favorites", symbol: "star", filter: .favorites)
                    Divider().padding(.vertical, 4)
                    ForEach(sidebarKinds.indices, id: \.self) { index in
                        let entry = sidebarKinds[index]
                        sidebarButton(entry.title, symbol: entry.symbol, filter: entry.filter)
                    }
                    Divider().padding(.vertical, 4)
                    if !model.isSidebarCollapsed { Text("Apps").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal, 8) }
                    ForEach(Array(appEntries.prefix(showsAllApps ? appEntries.count : 5))) { app in
                        appButton(app)
                    }
                    if appEntries.count > 5 {
                        Button { showsAllApps.toggle() } label: {
                            if model.isSidebarCollapsed { Image(systemName: showsAllApps ? "chevron.up" : "ellipsis") }
                            else { Text(showsAllApps ? LocalizedStringKey("Show Fewer") : LocalizedStringKey("More…")) }
                        }
                        .buttonStyle(.plain).font(.callout).padding(.leading, model.isSidebarCollapsed ? 8 : 26)
                        .accessibilityLabel(Text(showsAllApps ? LocalizedStringKey("Show Fewer Apps") : LocalizedStringKey("More Apps")))
                        .help(showsAllApps ? LocalizedStringKey("Show Fewer Apps") : LocalizedStringKey("More Apps"))
                    }
                }.padding(.bottom, 8)
            }
        }
        .padding(.vertical, 8)
        .frame(maxHeight: .infinity, alignment: .topLeading)
    }

    private var sidebarKinds: [(title: LocalizedStringKey, symbol: String, filter: ClipboardPanelRailFilter)] {
        [("Text", "doc", .text), ("Images", "photo", .kind(.image)), ("Links", "link", .kind(.url)),
         ("Files", "doc.on.doc", .kind(.fileURLs)), ("Colors", "paintpalette", .kind(.color)),
         ("Emails", "envelope", .kind(.email)), ("Code", "chevron.left.forwardslash.chevron.right", .kind(.code))]
    }

    private var appEntries: [ClipboardSourceAppCount] { model.sourceApps }

    private func sidebarButton(_ title: LocalizedStringKey, symbol: String, filter: ClipboardPanelRailFilter) -> some View {
        Button { model.railFilter = filter; if case .history = filter { removeAppToken() } } label: {
            HStack(spacing: 8) {
                Image(systemName: symbol).frame(width: 16)
                if !model.isSidebarCollapsed { Text(title).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading) }
            }
            .font(.callout).padding(.horizontal, 9).frame(height: 27)
            .background(isSelected(filter) ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain).help(title).accessibilityLabel(Text(title))
        .accessibilityAddTraits(isSelected(filter) ? .isSelected : [])
    }

    private func appButton(_ app: ClipboardSourceAppCount) -> some View {
        let selected = model.appFilter == app.bundleIdentifier
        return Button {
            model.appFilter = selected ? nil : app.bundleIdentifier
        } label: {
            HStack(spacing: 7) {
                ClipboardSourceAppIcon(bundleIdentifier: app.bundleIdentifier, size: 16)
                if !model.isSidebarCollapsed { Text(app.name).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading); Text("\(app.count)").foregroundStyle(.tertiary) }
            }
            .font(.callout).padding(.horizontal, 8).frame(height: 27)
            .background(selected ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain).help(app.name).accessibilityLabel(app.name)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func removeAppToken() {
        model.appFilter = nil
    }

    private func railButton(_ title: String.LocalizationValue, symbol: String, filter: ClipboardPanelRailFilter) -> some View {
        Button { model.railFilter = filter } label: {
            Image(systemName: symbol).font(.system(size: 15, weight: .regular))
                .foregroundStyle(isSelected(filter) ? Color.primary : Color.secondary)
                .frame(width: 30, height: 30)
                .background(isSelected(filter) ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .help(String(localized: title))
        .accessibilityLabel(String(localized: title))
        .accessibilityAddTraits(isSelected(filter) ? .isSelected : [])
    }

    private func isSelected(_ filter: ClipboardPanelRailFilter) -> Bool { model.railFilter == filter }

    private var listToolbar: some View {
        HStack(spacing: 8) {
            dateMenu
            TextField("Type to search…", text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .focused($searchFocused)
                .accessibilityLabel("Type to search…")
                .help("Search clipboard history")
                .frame(maxWidth: .infinity)
            if !model.query.isEmpty {
                Button { model.query = ""; searchFocused = true } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain).help("Clear Search").accessibilityLabel("Clear Search")
            }
            Button {
                model.isPinned.toggle()
                controller?.panel?.level = model.isPinned ? .floating : .normal
            } label: { Image(systemName: model.isPinned ? "pin.fill" : "pin").font(.system(size: 15, weight: .regular)).frame(width: 23, height: 28) }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help("Keep Window Open")
                .accessibilityLabel("Keep Window Open")
                .accessibilityValue(model.isPinned ? String(localized: "On") : String(localized: "Off"))
            sortMenu
            Button { model.isCommandPaletteVisible.toggle() } label: { Text("⌘").font(.system(size: 15, weight: .regular)).foregroundStyle(.secondary).frame(width: 23, height: 28) }
                .buttonStyle(.plain).help("Commands").accessibilityLabel("Commands")
            if !model.isPreviewVisible {
                Button { model.isPreviewVisible = true } label: { Image(systemName: "sidebar.right").font(.system(size: 15, weight: .regular)).foregroundStyle(.secondary).frame(width: 23, height: 28) }
                    .buttonStyle(.plain).help("Toggle Preview").accessibilityLabel("Toggle Preview")
            }
        }
        .padding(.horizontal, 9).frame(height: 40)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var dateMenu: some View {
        Menu {
            Picker("Date", selection: $model.dateFilter) {
                Text("Any Time").tag(ClipboardPanelDateFilter.anytime)
                Text("Today").tag(ClipboardPanelDateFilter.today)
                Text("Last 7 Days").tag(ClipboardPanelDateFilter.week)
                Text("Last 30 Days").tag(ClipboardPanelDateFilter.month)
            }
        } label: {
            Image(systemName: model.dateFilter == .anytime ? "calendar" : "calendar.badge.clock")
                .font(.system(size: 15)).foregroundStyle(model.dateFilter == .anytime ? Color.secondary : Color.accentColor).frame(width: 23, height: 28)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden)
        .help("Filter by Date").accessibilityLabel("Filter by Date")
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort By", selection: $model.sort) {
                Text("Last Copy").tag(ClipboardPanelSort.lastCopy)
                Text("First Copy").tag(ClipboardPanelSort.firstCopy)
                Text("Copy Count").tag(ClipboardPanelSort.copyCount)
                Text("Size").tag(ClipboardPanelSort.size)
            }
            Toggle("Reverse Order", isOn: $model.reversed)
            Divider()
            Toggle("Favorites on Top", isOn: $model.favoritesOnTop)
            Toggle("Paste on Double Click", isOn: $doubleClickPaste)
            Toggle("Show Quick Paste Badges", isOn: $showBadges)
        } label: { Image(systemName: "arrow.up.arrow.down").font(.system(size: 15, weight: .regular)).foregroundStyle(.secondary).frame(width: 23, height: 28) }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).help("Sort clipboard history")
            .accessibilityLabel("Sort clipboard history")
    }

    private var historyList: some View {
        Group {
            if ((!model.hasLoadedItems && model.items.isEmpty) || model.isLoadingItems) && model.visibleItems.isEmpty {
                ProgressView("Loading clipboard history").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.visibleItems.isEmpty {
                unavailableHistoryView
            } else {
                List(selection: selectionBinding) {
                    ForEach(Array(model.visibleItems.enumerated()), id: \.element.id) { index, item in
                        ClipboardHistoryRow(item: item, index: index, showQuickPasteBadge: showBadges, query: model.query, linkService: linkService, isCurrentClipboard: item.contentHash == currentClipboardHash, isSelected: model.selectedIDs.contains(item.id))
                            .tag(item.id)
                            .listRowInsets(EdgeInsets(top: 1, leading: 0, bottom: 1, trailing: 0))
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .onTapGesture(count: 1) {
                                guard pasteOnClick else { return }
                                pendingClickPaste?.cancel()
                                pendingClickPaste = Task { @MainActor in
                                    try? await Task.sleep(for: .milliseconds(250))
                                    guard !Task.isCancelled, model.selectedItem?.id == item.id else { return }
                                    controller?.paste(item, pasteSelection: false)
                                }
                            }
                            .onTapGesture(count: 2) { pendingClickPaste?.cancel(); if doubleClickPaste { controller?.paste(item, pasteSelection: false) } }
                            .contextMenu { rowMenu(item) }
                    }
                    if model.canLoadMore {
                        HStack(spacing: 7) {
                            ProgressView().controlSize(.small).opacity(model.isLoadingMore ? 1 : 0)
                            Text("Loading more history").font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 8).listRowSeparator(.hidden)
                        .task(id: model.items.count) { await model.loadMore() }
                    }
                }
                .listStyle(.plain).scrollContentBackground(.hidden)
                .accessibilityLabel("Clipboard History")
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var selectionBinding: Binding<Set<UUID>> {
        Binding(get: { Set(model.selectedIDs) }, set: { selection in
            let previous = Set(model.selectedIDs)
            let ordered = model.visibleItems.filter { selection.contains($0.id) }
            let nextIDs = ordered.map(\.id)
            if nextIDs.count == previous.count + 1, let added = ordered.first(where: { !previous.contains($0.id) }) {
                model.select(added, toggling: true, playSelectionSound: true)
            } else if nextIDs.count == 1, let item = ordered.first { model.select(item, playSelectionSound: true) }
            else { model.selectedIDs = nextIDs }
        })
    }

    private var unavailableHistoryView: some View {
        let isEmpty = !model.hasActiveFilters && model.items.isEmpty
        return ContentUnavailableView {
            Label(isEmpty ? LocalizedStringKey("No clipboard items yet") : LocalizedStringKey("No matching items"), systemImage: isEmpty ? "clipboard" : "line.3.horizontal.decrease.circle")
        } description: {
            Text(isEmpty ? LocalizedStringKey("Copy text, images, or links to add them while Clipboard History is enabled.") : LocalizedStringKey("Try another search or clear filters to see more items."))
        } actions: {
            if isEmpty { Button("Clipboard History Settings") {
                UserDefaults.standard.set(SettingsPane.clipboardHistory.rawValue, forKey: "selectedSettingsPane")
                openSettings()
            } }
            else { Button("Clear Filters", action: clearFilters) }
        }
    }

    private var listFooter: some View {
        HStack(spacing: 6) {
            keyCap("↓")
            keyCap("↑")
            Text("Navigate").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
            Spacer(minLength: 5)
            keyCap("↵")
            if let targetApplicationName = controller?.targetApplicationName {
                Text(String.localizedStringWithFormat(String(localized: "Paste to %@"), targetApplicationName))
                    .font(.system(size: 10, weight: .medium)).foregroundStyle(.primary).lineLimit(1).truncationMode(.middle)
            } else {
                Text("Paste").font(.system(size: 10, weight: .medium)).foregroundStyle(.primary)
            }
        }
        .padding(.horizontal, 8).frame(height: 32).overlay(alignment: .top) { Divider() }
    }

    private func keyCap(_ title: String) -> some View {
        Text(title).font(.system(size: 10, weight: .semibold)).frame(minWidth: 17, minHeight: 17)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 0.5))
    }

    private var previewColumn: some View {
        VStack(spacing: 0) {
            previewToolbar
            if let item = model.detailItem {
                if model.isPreviewVisible { ScrollView { ClipboardRichPreview(item: item, linkService: linkService).padding(.top, 4) }.frame(maxHeight: .infinity) }
                if model.isDetailsVisible { detailsInspector(item) }
            } else if model.isLoadingDetail {
                ProgressView("Loading preview").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView("Select an item to preview", systemImage: "doc.text.magnifyingglass").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var previewToolbar: some View {
        HStack(spacing: 8) {
            actionButton("doc.on.clipboard", title: "Copy") { if let item = model.selectedItem { controller?.copy(item) } }
                .disabled(model.selectedItem == nil)
            if let item = model.detailItem { contextAction(item) }
            Spacer(minLength: 4)
            Button { if let item = model.selectedItem { Task { await model.toggleFavorite(item) } } } label: {
                Image(systemName: model.selectedItem?.isFavorite == true ? "star.fill" : "star")
                    .font(.system(size: 15, weight: .regular)).foregroundStyle(.secondary).frame(width: 23, height: 27)
            }
            .buttonStyle(.plain).help(String(localized: model.selectedItem?.isFavorite == true ? "Remove Favourite" : "Add to Favourites"))
            .accessibilityLabel(String(localized: model.selectedItem?.isFavorite == true ? "Remove Favourite" : "Add to Favourites"))
            .disabled(model.selectedItem == nil)
            Menu {
                if let item = model.selectedItem { rowMenu(item) }
                Divider()
                Button("Clear Clipboard History") { model.isClearConfirmationVisible = true }
            } label: { Image(systemName: "ellipsis").font(.system(size: 15, weight: .regular)).foregroundStyle(.secondary).frame(width: 23, height: 27) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).help("More Actions").accessibilityLabel("More Actions")
            Button { model.isDetailsVisible.toggle() } label: { Image(systemName: model.isDetailsVisible ? "rectangle.bottomthird.inset.filled" : "rectangle").font(.system(size: 15, weight: .regular)).foregroundStyle(.secondary).frame(width: 23, height: 27) }
                .buttonStyle(.plain).help("Toggle Details").accessibilityLabel("Toggle Details")
                .accessibilityValue(model.isDetailsVisible ? String(localized: "On") : String(localized: "Off"))
            Button { model.isPreviewVisible.toggle() } label: { Image(systemName: "sidebar.right").font(.system(size: 15, weight: .regular)).foregroundStyle(.secondary).frame(width: 23, height: 27) }
                .buttonStyle(.plain).help("Toggle Preview").accessibilityLabel("Toggle Preview")
        }
        .padding(.horizontal, 10).frame(height: 40).overlay(alignment: .bottom) { Divider() }
    }

    private func actionButton(_ symbol: String, title: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 15, weight: .regular)).foregroundStyle(.secondary).frame(width: 23, height: 27) }
            .buttonStyle(.plain).help(title).accessibilityLabel(Text(title))
    }

    @ViewBuilder
    private func contextAction(_ item: ClipboardItem) -> some View {
        switch item.kind {
        case .url:
            actionButton("globe", title: "Open Link") {
                if let url = ClipboardPreviewClassifier.url(from: item) { NSWorkspace.shared.open(url) }
            }
        case .image:
            actionButton("text.viewfinder", title: "Scan Text") {
                guard let data = item.imageRepresentationData else { return }
                Task { @MainActor in
                    let result = await ClipboardImageAnalyzer.analyze(data)
                    guard !result.recognizedText.isEmpty else {
                        model.errorMessage = String(localized: "No text found in this image.")
                        return
                    }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(result.recognizedText, forType: .string)
                }
            }
        case .fileURLs:
            actionButton("folder", title: "Reveal in Finder") {
                let urls = item.representations.filter { $0.type == "public.file-url" }.compactMap { URL(dataRepresentation: $0.data, relativeTo: nil) }
                if let url = urls.first { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
        default: EmptyView()
        }
    }

    private func detailsInspector(_ item: ClipboardItem) -> some View {
        VStack(spacing: 0) {
            detailRow("Application", value: item.sourceApp.name ?? String(localized: "Unknown App"), bundleIdentifier: item.sourceApp.bundleIdentifier)
            detailRow("Type", value: item.kind.localizedName)
            switch item.kind {
            case .url: detailRow("URL", value: item.preview)
            case .image:
                if let size = ClipboardPanelImageDimensions.size(item) {
                    detailRow("Image dimensions", value: "\(size.width)×\(size.height)")
                }
                detailRow("Image size", value: ByteCountFormatter.string(fromByteCount: Int64(model.estimatedSize(of: item)), countStyle: .file))
            case .fileURLs:
                detailRow("Path", value: filePath(item))
                detailRow("Size", value: ByteCountFormatter.string(fromByteCount: Int64(model.estimatedSize(of: item)), countStyle: .file))
            case .color:
                if let color = ClipboardColorDetails.parse(item.preview) {
                    detailRow("Hex", value: color.hex)
                    detailRow("RGB", value: color.rgb)
                }
            default: EmptyView()
            }
            detailRow("Copy time", value: item.lastCopiedAt.formatted(date: .abbreviated, time: .shortened))
        }
        .padding(.horizontal, 13).padding(.vertical, 7)
        .background(Color.clear)
        .overlay(alignment: .top) { Divider() }
        .frame(maxHeight: 142, alignment: .top)
    }

    private func detailRow(_ title: LocalizedStringKey, value: String, bundleIdentifier: String? = nil) -> some View {
        HStack(spacing: 7) {
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 112, alignment: .leading)
            HStack(spacing: 6) {
                if let bundleIdentifier { ClipboardSourceAppIcon(bundleIdentifier: bundleIdentifier, size: 13) }
                Text(value).font(.system(size: 11)).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .frame(height: 21)
    }

    @ViewBuilder
    private func rowMenu(_ item: ClipboardItem) -> some View {
        Button("Paste") { controller?.paste(item, pasteSelection: false) }
        Button("Copy") { controller?.copy(item) }
        Button(String(localized: item.isFavorite ? "Remove Favourite" : "Add to Favourites")) { Task { await model.toggleFavorite(item) } }
        Button(String(localized: item.isPinned ? "Unpin Item" : "Pin Item")) { Task { await model.togglePinned(item) } }
        if [.plainText, .richText, .code, .url, .email, .color].contains(item.kind) {
            Button("Edit Text") { Task { await model.beginEditing(item) } }
        }
        if item.isFavorite {
            Button("Move Favourite Up") { Task { await model.reorderFavorite(item, by: -1) } }
            Button("Move Favourite Down") { Task { await model.reorderFavorite(item, by: 1) } }
        }
        Divider()
        Button("Show in History") { model.showInHistory(item) }
        Button("Delete", role: .destructive) { model.select(item); Task { await model.deleteSelection() } }
    }

    private var textEditor: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Edit Text").font(.headline)
            TextEditor(text: $model.textBeingEdited).frame(minHeight: 180)
                .accessibilityLabel("Edit Text").disabled(model.isSavingEdit)
            if let message = model.editingErrorMessage {
                Text(verbatim: message).font(.callout).foregroundStyle(.red).textSelection(.enabled)
            }
            HStack {
            Button("Cancel") { model.isTextEditorVisible = false }.keyboardShortcut(.cancelAction)
                    .disabled(model.isSavingEdit)
                Spacer()
                if model.isSavingEdit { ProgressView().controlSize(.small).accessibilityLabel("Saving changes") }
                Button("Save") { Task { await model.saveEditedText() } }.keyboardShortcut(.defaultAction)
                    .disabled(model.isSavingEdit)
            }
        }
        .padding(22).frame(width: 460)
    }

    private func clearFilters() {
        model.clearFilters()
        searchFocused = true
    }

    private func updateToken(prefix: String, value: String, enabled: Bool) {
        var tokens = model.query.split(whereSeparator: \.isWhitespace).map(String.init)
        let token = prefix + value
        if enabled, !tokens.contains(where: { $0.localizedCaseInsensitiveCompare(token) == .orderedSame }) { tokens.append(token) }
        if !enabled { tokens.removeAll { $0.localizedCaseInsensitiveCompare(token) == .orderedSame } }
        model.query = tokens.joined(separator: " ")
        searchFocused = true
    }

    private func filePath(_ item: ClipboardItem) -> String {
        guard let data = item.representations.first(where: { $0.type == "public.file-url" })?.data,
              let url = URL(dataRepresentation: data, relativeTo: nil) else { return item.preview }
        return url.path
    }

    private func currentPasteboardHash() -> String? {
        let items = NSPasteboard.general.pasteboardItems ?? []
        let representations = items.enumerated().flatMap { index, item in
            item.types.compactMap { type in item.data(forType: type).map { ClipboardRepresentation(itemIndex: index, type: type.rawValue, data: $0) } }
        }
        return ClipboardItem.capture(representations: representations, sourceApp: ClipboardSourceApp(bundleIdentifier: nil, name: nil))?.contentHash
    }
}

private struct ClipboardPanelImageDimensions {
    let width: Int
    let height: Int

    static func size(_ item: ClipboardItem) -> ClipboardPanelImageDimensions? {
        guard let data = item.representations.first(where: { ["public.tiff", "public.png", "public.jpeg", "public.gif", "public.bmp"].contains($0.type) })?.data ?? item.thumbnailData,
              let image = NSImage(data: data), let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return ClipboardPanelImageDimensions(width: cgImage.width, height: cgImage.height)
    }
}

private struct ClipboardHistoryRow: View {
    let item: ClipboardItem
    let index: Int
    let showQuickPasteBadge: Bool
    let query: String
    let linkService: LinkPreviewService
    let isCurrentClipboard: Bool
    let isSelected: Bool

    var body: some View {
        ClipboardHistoryListRow(
            item: item,
            index: index,
            showQuickPasteBadge: showQuickPasteBadge,
            query: query,
            linkService: linkService,
            isSelected: isSelected,
            isCurrentClipboard: isCurrentClipboard
        )
    }
}

private struct CommandPaletteView: View {
    @ObservedObject var model: ClipboardHistoryPanelModel
    let controller: ClipboardHistoryPanelController?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                Text("Commands")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 11).padding(.vertical, 8)
                ForEach(model.registry.available(for: model.selection)) { command in
                    Button {
                        switch command.id {
                        case "paste": if let item = model.selectedItem { controller?.paste(item) }
                        case "copy": if let item = model.selectedItem { controller?.copy(item) }
                        case "delete": Task { await model.deleteSelection() }
                        case "showInHistory": if let item = model.selectedItem { model.showInHistory(item) }
                        default: command.perform(model.selection)
                        }
                        model.isCommandPaletteVisible = false
                    } label: {
                        HStack {
                            Text(LocalizedStringKey(command.title)).frame(maxWidth: .infinity, alignment: .leading)
                            if let shortcut = command.shortcut { Text(shortcut).foregroundStyle(.tertiary) }
                        }
                        .font(.system(size: 12))
                        .padding(.horizontal, 11).padding(.vertical, 7)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(7)
        }
        .frame(width: 300, alignment: .leading)
        .frame(maxHeight: 320)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).stroke(Color(nsColor: .separatorColor), lineWidth: 0.5))
    }
}

extension ClipboardItemKind {
    fileprivate var localizedName: String {
        switch self {
        case .plainText: return String(localized: "Text")
        case .richText: return String(localized: "Rich Text")
        case .image: return String(localized: "Image")
        case .fileURLs: return String(localized: "File")
        case .url: return String(localized: "Link")
        case .email: return String(localized: "Email")
        case .color: return String(localized: "Color")
        case .code: return String(localized: "Code")
        case .other: return String(localized: "Other")
        }
    }

    var rowSymbolName: String {
        switch self {
        case .plainText: "doc"
        case .richText: "doc.richtext"
        case .image: "photo"
        case .fileURLs: "doc.on.doc"
        case .url: "link"
        case .email: "envelope"
        case .color: "paintpalette"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .other: "doc"
        }
    }
}

extension ClipboardItem {
    fileprivate var imageRepresentationData: Data? {
        representations.first(where: {
            ["public.tiff", "public.png", "public.jpeg", "public.gif", "public.bmp"].contains($0.type)
        })?.data
    }
}

extension String {
    fileprivate var nilIfBlank: String? { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self }
}

private extension NSColor {
    convenience init?(hex: String) {
        let value = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        guard value.count == 6, let rgb = UInt32(value, radix: 16) else { return nil }
        self.init(
            calibratedRed: CGFloat((rgb >> 16) & 0xff) / 255,
            green: CGFloat((rgb >> 8) & 0xff) / 255,
            blue: CGFloat(rgb & 0xff) / 255,
            alpha: 1
        )
    }

    var hexString: String {
        guard let color = usingColorSpace(.deviceRGB) else { return "#808080" }
        return String(
            format: "#%02X%02X%02X",
            Int(color.redComponent * 255),
            Int(color.greenComponent * 255),
            Int(color.blueComponent * 255)
        )
    }
}
