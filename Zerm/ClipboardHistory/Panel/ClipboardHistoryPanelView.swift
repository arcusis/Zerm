import AppKit
import SwiftUI

struct ClipboardHistoryPanelView: View {
    @ObservedObject var model: ClipboardHistoryPanelModel
    weak var controller: ClipboardHistoryPanelController?
    private let tracksSystemClipboard: Bool
    private let linkService: LinkPreviewService
    @Environment(\.locale) private var locale
    @Environment(\.openSettings) private var openSettings
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
        GeometryReader { geometry in
            let width = geometry.size.width
            let sidebarWidth = width >= 740 ? 184 : max(112, width * 0.23)
            let previewWidth = width >= 740 ? 280 : max(164, width * 0.27)
            let visibleSidebarWidth = model.isSidebarCollapsed ? 0 : sidebarWidth
            let historyWidth = max(0, width - visibleSidebarWidth - (model.isPreviewVisible ? previewWidth + 1 : 0) - (model.isSidebarCollapsed ? 0 : 1))
            VStack(spacing: 0) {
                listToolbar(availableWidth: width)
                HStack(spacing: 0) {
                    if !model.isSidebarCollapsed {
                        sidebar.frame(width: sidebarWidth)
                            .transition(.move(edge: Locale.Language(identifier: locale.identifier).characterDirection == .rightToLeft ? .trailing : .leading).combined(with: .opacity))
                        Divider()
                    }
                    VStack(spacing: 0) {
                        historyList
                        listFooter
                    }
                    .frame(minWidth: 0, idealWidth: min(430, historyWidth), maxWidth: model.isPreviewVisible ? historyWidth : .infinity)
                    if model.isPreviewVisible {
                        Divider()
                        previewColumn.frame(minWidth: 0, idealWidth: previewWidth, maxWidth: previewWidth)
                            .transition(.move(edge: Locale.Language(identifier: locale.identifier).characterDirection == .rightToLeft ? .leading : .trailing).combined(with: .opacity))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .overlay {
                if model.isCommandPaletteVisible {
                    ZStack {
                        Color.primary.opacity(0.06).contentShape(Rectangle())
                            .onTapGesture { model.isCommandPaletteVisible = false }
                            .accessibilityHidden(true)
                        CommandPaletteView(model: model, availableSize: geometry.size)
                    }
            }
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: model.isSidebarCollapsed)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: model.isPreviewVisible)
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
        .environment(\.layoutDirection, Locale.Language(identifier: locale.identifier).characterDirection == .rightToLeft ? .rightToLeft : .leftToRight)
        .onAppear {
            searchFocused = true
            if tracksSystemClipboard { currentClipboardHash = currentPasteboardHash() }
        }
        .onChange(of: model.isCommandPaletteVisible) {
            if !model.isCommandPaletteVisible { searchFocused = true }
        }
        .onChange(of: model.presentationID) {
            searchFocused = !model.isCommandPaletteVisible
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
        .background(ClipboardPanelKeyFocusObserver {
            if !model.isCommandPaletteVisible { searchFocused = true }
        }.frame(width: 0, height: 0))
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
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

    private func listToolbar(availableWidth: CGFloat) -> some View {
        let compact = availableWidth < 740
        return HStack(spacing: 9) {
            ZStack {
                ClipboardPanelDragHandle()
                HStack(spacing: 8) {
                    Image(systemName: "line.3.horizontal").font(.system(size: 12, weight: .medium)).foregroundStyle(.tertiary)
                    Text("Clipboard History").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary).lineLimit(1)
                }
                .padding(.horizontal, 11)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .allowsHitTesting(false)
            }
            .frame(width: min(166, max(92, availableWidth * 0.23)), height: 36)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Clipboard History"))
            .help("Move Window")

            Button { model.isSidebarCollapsed.toggle() } label: {
                Image(systemName: model.isSidebarCollapsed ? "sidebar.left" : "sidebar.leading")
                    .font(.system(size: 15)).foregroundStyle(.secondary).frame(width: 28, height: 30)
            }
            .buttonStyle(.plain).help("Toggle Sidebar").accessibilityLabel("Toggle Sidebar")

            TextField("Type to search…", text: $model.query)
                .textFieldStyle(.plain).font(.system(size: 14)).focused($searchFocused)
                .accessibilityLabel("Type to search…").help("Search clipboard history")
                .frame(minWidth: compact ? 55 : 105, maxWidth: .infinity)
            if !model.query.isEmpty {
                Button { model.query = ""; searchFocused = true } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain).help("Clear Search").accessibilityLabel("Clear Search")
            }
            if !compact {
                dateMenu
                sortMenu
                commandsButton
                pinButton
            }
            Button { model.isPreviewVisible.toggle() } label: {
                Image(systemName: model.isPreviewVisible ? "rectangle.split.2x1" : "rectangle").font(.system(size: 15)).foregroundStyle(.secondary).frame(width: 27, height: 30)
            }
            .buttonStyle(.plain).help("Toggle Preview").accessibilityLabel("Toggle Preview")
            if model.isPreviewVisible && !compact {
                Button { model.isDetailsVisible.toggle() } label: {
                    Image(systemName: model.isDetailsVisible ? "rectangle.bottomthird.inset.filled" : "rectangle").font(.system(size: 14)).foregroundStyle(.secondary).frame(width: 27, height: 30)
                }
                .buttonStyle(.plain).help("Toggle Details").accessibilityLabel("Toggle Details")
                .accessibilityValue(model.isDetailsVisible ? String(localized: "On") : String(localized: "Off"))
            }
            Menu {
                if compact {
                    dateMenu
                    sortMenu
                    commandsButton
                    pinButton
                    Toggle("Show Details", isOn: $model.isDetailsVisible)
                    Divider()
                }
                Toggle("Paste on Click", isOn: $pasteOnClick)
                Toggle("Paste on Double Click", isOn: $doubleClickPaste)
                Toggle("Show Quick Paste Badges", isOn: $showBadges)
                Divider()
                if let item = model.selectedItem { rowMenu(item); contextMenuAction(item); Divider() }
                Button("Clear Clipboard History") { model.isClearConfirmationVisible = true }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 15)).foregroundStyle(.secondary).frame(width: 27, height: 30)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).help("More Actions").accessibilityLabel("More Actions")
        }
        .padding(.horizontal, 10).frame(maxWidth: .infinity).frame(height: 52)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var commandsButton: some View {
        Button { model.isCommandPaletteVisible.toggle() } label: {
            Image(systemName: "command").font(.system(size: 15)).foregroundStyle(.secondary).frame(width: 27, height: 30)
        }
        .buttonStyle(.plain).help("Commands").accessibilityLabel("Commands")
    }

    private var pinButton: some View {
        Button { model.isPinned.toggle() } label: {
            Image(systemName: model.isPinned ? "pin.fill" : "pin").font(.system(size: 14)).foregroundStyle(.secondary).frame(width: 27, height: 30)
        }
        .buttonStyle(.plain).help("Keep Window Open").accessibilityLabel("Keep Window Open")
        .accessibilityValue(model.isPinned ? String(localized: "On") : String(localized: "Off"))
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
                            .listRowBackground(model.selectedIDs.contains(item.id) ? Color(nsColor: .selectedContentBackgroundColor) : Color.clear)
                            .listRowInsets(EdgeInsets(top: 1, leading: 0, bottom: 1, trailing: 0))
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

    @ViewBuilder
    private func contextMenuAction(_ item: ClipboardItem) -> some View {
        switch item.kind {
        case .url:
            Button("Open Link") {
                if let url = ClipboardPreviewClassifier.url(from: item) { NSWorkspace.shared.open(url) }
            }
        case .image:
            Button("Scan Text") {
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
            Button("Reveal in Finder") {
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
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                .frame(minWidth: 0, maxWidth: 112, alignment: .leading)
            HStack(spacing: 6) {
                if let bundleIdentifier { ClipboardSourceAppIcon(bundleIdentifier: bundleIdentifier, size: 13) }
                Text(value).font(.system(size: 11)).lineLimit(1).truncationMode(.middle).textSelection(.enabled).help(value)
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .trailing)
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
    let availableSize: CGSize
    @FocusState private var searchFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            TextField("Commands", text: $model.commandQuery)
                .textFieldStyle(.plain).padding(10)
                .accessibilityLabel(Text("Commands"))
                .focused($searchFocused)
            Divider()
            ScrollViewReader { proxy in
                if model.filteredCommands.isEmpty {
                    ContentUnavailableView("No matching items", systemImage: "line.3.horizontal.decrease.circle")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(selection: Binding(
                        get: { model.commandSelectionID },
                        set: { model.commandSelectionID = $0 }
                    )) {
                        ForEach(model.filteredCommands) { command in
                            Button {
                                model.commandSelectionID = command.id
                                model.performSelectedCommand()
                            } label: {
                                HStack(spacing: 12) {
                                    Text(LocalizedStringKey(command.title))
                                        .foregroundColor(model.commandSelectionID == command.id ? Color(nsColor: .selectedMenuItemTextColor) : .primary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    if let shortcut = command.shortcut {
                                        Text(shortcut).foregroundColor(model.commandSelectionID == command.id ? Color(nsColor: .selectedMenuItemTextColor).opacity(0.85) : .secondary)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .tag(command.id)
                            .listRowBackground(model.commandSelectionID == command.id ? Color(nsColor: .selectedContentBackgroundColor) : Color.clear)
                            .accessibilityAddTraits(model.commandSelectionID == command.id ? .isSelected : [])
                        }
                    }
                    .listStyle(.plain).scrollContentBackground(.hidden).accessibilityLabel("Commands")
                    .onAppear { scrollToSelection(using: proxy) }
                    .onChange(of: model.commandSelectionID) { scrollToSelection(using: proxy) }
                }
            }
        }
        .frame(
            width: min(340, max(120, availableSize.width - 24)),
            height: min(max(120, availableSize.height - 24), min(360, max(180, CGFloat(model.filteredCommands.count) * 36 + 52)))
        )
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 0.5))
        .onAppear { searchFocused = true }
    }

    private func scrollToSelection(using proxy: ScrollViewProxy) {
        guard let id = model.commandSelectionID else { return }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.12)) { proxy.scrollTo(id, anchor: .center) }
    }
}

private struct ClipboardPanelDragHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> ClipboardDragNSView { ClipboardDragNSView() }
    func updateNSView(_ nsView: ClipboardDragNSView, context: Context) {}
}

private final class ClipboardDragNSView: NSView {
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        NSCursor.closedHand.push()
        defer { NSCursor.pop() }
        window.performDrag(with: event)
    }
}

private struct ClipboardPanelKeyFocusObserver: NSViewRepresentable {
    let onBecameKey: () -> Void

    func makeNSView(context: Context) -> ClipboardPanelFocusNSView {
        let view = ClipboardPanelFocusNSView()
        view.onBecameKey = onBecameKey
        return view
    }

    func updateNSView(_ nsView: ClipboardPanelFocusNSView, context: Context) {
        nsView.onBecameKey = onBecameKey
        nsView.observeWindowKey()
    }
}

private final class ClipboardPanelFocusNSView: NSView {
    var onBecameKey: (() -> Void)?
    private var keyObserver: NSObjectProtocol?
    private weak var observedWindow: NSWindow?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observeWindowKey()
    }

    func observeWindowKey() {
        guard observedWindow !== window else { return }
        if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
        keyObserver = nil
        observedWindow = window
        guard let window else { return }
        keyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            self?.onBecameKey?()
        }
    }

    deinit {
        if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
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
