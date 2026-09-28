import AppKit
import SwiftUI

struct ClipboardHistoryPanelView: View {
    @ObservedObject var model: ClipboardHistoryPanelModel
    let controller: ClipboardHistoryPanelController?
    @FocusState private var searchFocused: Bool
    @AppStorage("clipboardHistoryDoubleClickPaste") private var doubleClickPaste = true
    @AppStorage("clipboardHistoryPasteOnClick") private var pasteOnClick = true
    @AppStorage("clipboardHistoryShowBadges") private var showBadges = true
    @State private var pendingClickPaste: Task<Void, Never>?
    @State private var editingTagName = ""
    @State private var editingTagColor = Color.gray

    init(model: ClipboardHistoryPanelModel, controller: ClipboardHistoryPanelController? = nil) {
        self.model = model
        self.controller = controller
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.55)
            HStack(spacing: 0) {
                historyList
                    .frame(minWidth: 280, idealWidth: 320, maxWidth: 390)
                if model.isPreviewVisible {
                    Divider()
                    previewPane
                        .frame(minWidth: 250, maxWidth: .infinity)
                }
                if model.isDetailsVisible {
                    Divider()
                    detailsPane.frame(width: 205)
                }
            }
            .frame(maxHeight: .infinity)
            Divider().opacity(0.55)
            footer
        }
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(alignment: .center) {
            if model.isCommandPaletteVisible { CommandPaletteView(model: model, controller: controller) }
        }
        .environment(
            \.layoutDirection,
            Locale.Language(identifier: Locale.current.identifier).characterDirection == .rightToLeft
                ? .rightToLeft : .leftToRight
        )
        .onAppear { searchFocused = true }
        .sheet(isPresented: $model.isTagEditorVisible) { tagEditor }
        .sheet(isPresented: $model.isTextEditorVisible) { textEditor }
        .confirmationDialog(
            String(localized: "Clear Clipboard History?"),
            isPresented: $model.isClearConfirmationVisible,
            titleVisibility: .visible
        ) {
            Button(String(localized: "Clear"), role: .destructive) { Task { await model.clearHistory() } }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: {
            Text(String(localized: "Pinned items and items protected by your settings stay in history."))
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "clipboard")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.accentColor)
            TextField(String(localized: "Search clipboard history"), text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .focused($searchFocused)
                .accessibilityLabel(String(localized: "Search clipboard history"))
            if !model.query.isEmpty {
                Button {
                    model.query = ""
                    searchFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(String(localized: "Clear Search"))
            }
            kindFilter
            appFilter
            tagFilter
            Menu {
                Picker(String(localized: "Sort By"), selection: $model.sort) {
                    Text(String(localized: "Last Copy")).tag(ClipboardPanelSort.lastCopy)
                    Text(String(localized: "First Copy")).tag(ClipboardPanelSort.firstCopy)
                    Text(String(localized: "Copy Count")).tag(ClipboardPanelSort.copyCount)
                    Text(String(localized: "Size")).tag(ClipboardPanelSort.size)
                }
                Toggle(String(localized: "Reverse Order"), isOn: $model.reversed)
                Divider()
                Toggle(String(localized: "Favorites on Top"), isOn: $model.favoritesOnTop)
                Toggle(String(localized: "Paste on Double Click"), isOn: $doubleClickPaste)
            } label: {
                Image(systemName: "arrow.up.arrow.down.circle")
                    .frame(width: 30, height: 30)
            }
            .menuStyle(.borderlessButton)
            .help(String(localized: "Sort clipboard history"))
            Button {
                model.isPreviewVisible.toggle()
            } label: {
                Image(systemName: model.isPreviewVisible ? "sidebar.right" : "rectangle.rightthird.inset.filled")
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
            .help(String(localized: "Toggle Preview"))
            Button {
                model.isDetailsVisible.toggle()
            } label: {
                Image(systemName: "info.circle").frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
            .help(String(localized: "Toggle Details"))
            Button {
                model.isPinned.toggle()
                controller?.panel?.level = model.isPinned ? .floating : .normal
            } label: {
                Image(systemName: model.isPinned ? "pin.fill" : "pin")
                    .frame(width: 30, height: 30)
                    .foregroundStyle(model.isPinned ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            .help(String(localized: "Keep Window Open"))
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 11)
    }

    private var kindFilter: some View {
        Menu {
            ForEach(ClipboardItemKind.allCases, id: \.self) { kind in
                Toggle(
                    kind.localizedName,
                    isOn: Binding(
                        get: { ClipboardPanelQuery.parse(model.query).filters.kinds.contains(kind) },
                        set: { enabled in updateToken(prefix: "kind:", value: kind.rawValue, enabled: enabled) }
                    ))
            }
        } label: {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .frame(width: 30, height: 30)
        }
        .menuStyle(.borderlessButton)
        .help(String(localized: "Filter by Kind"))
    }

    private var appFilter: some View {
        let names = Array(Set(model.items.compactMap(\.sourceApp.name))).sorted()
        return Menu {
            if names.isEmpty { Text(String(localized: "No Source Apps")) }
            ForEach(names, id: \.self) { name in
                Toggle(
                    name,
                    isOn: Binding(
                        get: {
                            ClipboardPanelQuery.parse(model.query).filters.sourceApps.contains(name.localizedLowercase)
                        },
                        set: { enabled in
                            updateToken(
                                prefix: "app:",
                                value: name.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? name,
                                enabled: enabled)
                        }
                    ))
            }
        } label: {
            Image(systemName: "square.stack.3d.up")
                .frame(width: 30, height: 30)
        }
        .menuStyle(.borderlessButton)
        .help(String(localized: "Filter by Source App"))
    }

    private var tagFilter: some View {
        Menu {
            Button(String(localized: "Create Tag")) { beginTagEditing(nil) }
            if !model.tags.isEmpty { Divider() }
            ForEach(model.tags) { tag in
                Menu {
                    Toggle(String(localized: "Filter by Tag"), isOn: Binding(
                        get: { model.isTagFiltered(tag) },
                        set: { model.setTagFilter(tag, enabled: $0) }
                    ))
                    Button(String(localized: "Attach to Selection")) { Task { await model.setTag(tag, attached: true) } }
                    Button(String(localized: "Detach from Selection")) { Task { await model.setTag(tag, attached: false) } }
                    Divider()
                    Button(String(localized: "Rename Tag")) { beginTagEditing(tag) }
                    Button(String(localized: "Recolor Tag")) { beginTagEditing(tag) }
                    Button(String(localized: "Delete Tag"), role: .destructive) { Task { await model.deleteTag(tag) } }
                } label: {
                    Label(tag.name, systemImage: "tag.fill")
                }
            }
        } label: {
            Image(systemName: "tag")
                .frame(width: 30, height: 30)
        }
        .menuStyle(.borderlessButton)
        .help(String(localized: "Filter by Tag"))
    }

    private var tagEditor: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(model.editingTag == nil ? String(localized: "Create Tag") : String(localized: "Edit Tag"))
                .font(.headline)
            TextField(String(localized: "Tag Name"), text: $editingTagName)
            ColorPicker(String(localized: "Tag Color"), selection: $editingTagColor)
            HStack {
                Button(String(localized: "Cancel")) { model.isTagEditorVisible = false }
                Spacer()
                Button(String(localized: "Save"), action: saveTagEditor)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 320)
        .onAppear(perform: prepareTagEditor)
    }

    private var textEditor: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(String(localized: "Edit Text")).font(.headline)
            TextEditor(text: $model.textBeingEdited).frame(minHeight: 180)
            HStack {
                Button(String(localized: "Cancel")) { model.isTextEditorVisible = false }
                Spacer()
                Button(String(localized: "Save")) { Task { await model.saveEditedText() } }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 460)
    }

    private func prepareTagEditor() {
        editingTagName = model.editingTag?.name ?? ""
        if let tag = model.editingTag, let color = NSColor(hex: tag.colorHex) {
            editingTagColor = Color(nsColor: color)
        } else {
            editingTagColor = .gray
        }
    }

    private func saveTagEditor() {
        let colorHex = NSColor(editingTagColor).hexString
        if let tag = model.editingTag {
            Task { await model.updateTag(tag, name: editingTagName, colorHex: colorHex) }
        } else {
            Task { await model.createTag(name: editingTagName, colorHex: colorHex) }
        }
    }

    private func beginTagEditing(_ tag: ClipboardTag?) {
        model.editingTag = tag
        model.isTagEditorVisible = true
    }

    private var historyList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(Array(model.visibleItems.enumerated()), id: \.element.id) { index, item in
                        ClipboardHistoryRow(
                            item: item,
                            index: index,
                            selectedIDs: model.selectedIDs,
                            showQuickPasteBadge: showBadges && model.isShowingQuickPasteBadges,
                            query: model.query
                        ) {
                            let flags = NSApp.currentEvent?.modifierFlags ?? []
                            model.select(item, toggling: flags.contains(.command), playSelectionSound: true)
                        }
                        .id(item.id)
                        .onTapGesture(count: 1) {
                            guard pasteOnClick else { return }
                            pendingClickPaste?.cancel()
                            pendingClickPaste = Task { @MainActor in
                                try? await Task.sleep(nanoseconds: 250_000_000)
                                guard !Task.isCancelled else { return }
                                controller?.paste(item, pasteSelection: false)
                            }
                        }
                        .onTapGesture(count: 2) {
                            pendingClickPaste?.cancel()
                            if doubleClickPaste { controller?.paste(item, pasteSelection: false) }
                        }
                        .contextMenu {
                            Button(String(localized: "Paste")) { controller?.paste(item, pasteSelection: false) }
                            Button(String(localized: "Copy")) { controller?.copy(item) }
                            Button(String(localized: item.isFavorite ? "Remove Favourite" : "Add to Favourites")) {
                                Task { await model.toggleFavorite(item) }
                            }
                            Button(String(localized: item.isPinned ? "Unpin Item" : "Pin Item")) {
                                Task { await model.togglePinned(item) }
                            }
                            Button(String(localized: "Edit Text")) {
                                model.select(item)
                                model.textBeingEdited = ClipboardPanelText.plainText(from: item.representations, fallback: item.preview)
                                model.isTextEditorVisible = true
                            }
                            if item.isFavorite {
                                Button(String(localized: "Move Favourite Up")) { Task { await model.reorderFavorite(item, by: -1) } }
                                Button(String(localized: "Move Favourite Down")) { Task { await model.reorderFavorite(item, by: 1) } }
                            }
                            if !model.tags.isEmpty {
                                Menu(String(localized: "Tags")) {
                                    ForEach(model.tags) { tag in
                                        Button(String(localized: item.tagIDs.contains(tag.id) ? "Remove Tag" : "Add Tag")) {
                                            model.select(item)
                                            Task { await model.setTag(tag, attached: !item.tagIDs.contains(tag.id)) }
                                        }
                                    }
                                }
                            }
                            Divider()
                            Button(String(localized: "Show in History")) { model.showInHistory(item) }
                            Button(String(localized: "Delete"), role: .destructive) {
                                model.select(item)
                                Task { await model.deleteSelection() }
                            }
                        }
                    }
                    if model.visibleItems.isEmpty { emptyState }
                }
                .padding(9)
            }
            .onChange(of: model.selectedIDs) { _, ids in
                if let id = ids.first {
                    withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(id, anchor: .center) }
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.42))
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "clipboard")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.tertiary)
            Text(
                model.items.isEmpty
                    ? String(localized: "Clipboard history is empty") : String(localized: "No matching items")
            )
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 150)
    }

    @ViewBuilder
    private var previewPane: some View {
        if let item = model.selectedItem {
            ClipboardItemPreview(item: item)
                .padding(20)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            Text(String(localized: "Select an item to preview"))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var detailsPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(String(localized: "Details"))
                .font(.system(size: 13, weight: .semibold))
            if let item = model.selectedItem {
                ClipboardDetailRow(
                    title: String(localized: "Source App"), value: item.sourceApp.name ?? String(localized: "Unknown"))
                ClipboardDetailRow(title: String(localized: "Kind"), value: item.kind.localizedName)
                ClipboardDetailRow(
                    title: String(localized: "Size"),
                    value: ByteCountFormatter.string(
                        fromByteCount: Int64(model.estimatedSize(of: item)), countStyle: .file))
                ClipboardDetailRow(
                    title: String(localized: "First Copied"),
                    value: item.createdAt.formatted(date: .abbreviated, time: .shortened))
                ClipboardDetailRow(
                    title: String(localized: "Last Copied"),
                    value: item.lastUsedAt.formatted(date: .abbreviated, time: .shortened))
                ClipboardDetailRow(title: String(localized: "Copies"), value: "\(item.useCount)")
                ClipboardDetailRow(
                    title: String(localized: "Tags"),
                    value: model.tags.filter { item.tagIDs.contains($0.id) }.map(\.name).joined(separator: ", ").nilIfBlank ?? String(localized: "None")
                )
                if !item.recognizedText.isEmpty {
                    ClipboardDetailRow(title: String(localized: "Recognized Text"), value: item.recognizedText)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.28))
    }

    private var footer: some View {
        HStack(spacing: 9) {
            Text(String(localized: "\(model.visibleItems.count) items"))
                .foregroundStyle(.secondary)
            if model.selectedIDs.count > 1 {
                Text(String(localized: "\(model.selectedIDs.count) selected"))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("↑ ↓  ·  ↩ \(String(localized: "Paste"))  ·  ⌘K")
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .font(.system(size: 11))
        .padding(.horizontal, 15)
        .padding(.vertical, 9)
    }

    private func updateToken(prefix: String, value: String, enabled: Bool) {
        var tokens = model.query.split(whereSeparator: \.isWhitespace).map(String.init)
        let token = prefix + value
        if enabled, !tokens.contains(where: { $0.localizedCaseInsensitiveCompare(token) == .orderedSame }) {
            tokens.append(token)
        }
        if !enabled { tokens.removeAll { $0.localizedCaseInsensitiveCompare(token) == .orderedSame } }
        model.query = tokens.joined(separator: " ")
        searchFocused = true
    }
}

private struct ClipboardHistoryRow: View {
    let item: ClipboardItem
    let index: Int
    let selectedIDs: [UUID]
    let showQuickPasteBadge: Bool
    let query: String
    let action: () -> Void

    private var isSelected: Bool { selectedIDs.contains(item.id) }

    var body: some View {
        HStack(spacing: 10) {
            ClipboardKindIcon(item: item, size: 30)
                .frame(width: 34, height: 34)
                .background(.quaternary.opacity(0.65), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 4) {
                highlightedPreview
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 5) {
                    SourceAppIcon(bundleIdentifier: item.sourceApp.bundleIdentifier)
                    Text(item.sourceApp.name ?? String(localized: "Unknown App"))
                        .lineLimit(1)
                    Text("·")
                    Text(item.lastUsedAt, style: .relative)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if item.isFavorite { Image(systemName: "star.fill").foregroundStyle(.yellow) }
                }
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            }
            if showQuickPasteBadge, index < 9 {
                Text("⌘\(index + 1)")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 5).padding(.vertical, 3)
                    .background(.quaternary, in: Capsule())
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(isSelected ? Color.accentColor.opacity(0.19) : Color.clear, in: RoundedRectangle(cornerRadius: 9))
        .overlay(
            RoundedRectangle(cornerRadius: 9).stroke(
                isSelected ? Color.accentColor.opacity(0.35) : .clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
    }

    private var highlightedPreview: Text {
        let value = item.title?.nilIfBlank ?? item.preview
        guard !query.isEmpty else { return Text(value.isEmpty ? item.kind.localizedName : value) }
        let terms = ClipboardPanelQuery.parse(query).text.split(whereSeparator: \.isWhitespace).map(String.init)
        let searchableTerms = terms.filter { !$0.isEmpty }
        guard !searchableTerms.isEmpty else { return Text(value) }

        var result = Text("")
        var start = value.startIndex
        while start < value.endIndex {
            let searchRange = start..<value.endIndex
            let next = searchableTerms.compactMap { term in
                value.range(of: term, options: [.caseInsensitive, .diacriticInsensitive], range: searchRange)
            }.min { $0.lowerBound < $1.lowerBound }
            guard let next else {
                result = result + Text(String(value[start...])).foregroundColor(.primary)
                break
            }
            if start < next.lowerBound {
                result = result + Text(String(value[start..<next.lowerBound])).foregroundColor(.primary)
            }
            result = result + Text(String(value[next])).foregroundColor(.accentColor).bold()
            start = next.upperBound
        }
        return result
    }
}

private struct ClipboardKindIcon: View {
    let item: ClipboardItem
    let size: CGFloat

    var body: some View {
        Group {
            if item.kind == .image, let data = item.imageRepresentationData {
                AsyncClipboardThumbnail(data: data)
                    .scaledToFill()
            } else {
                Image(systemName: item.kind.symbolName)
                    .font(.system(size: size * 0.47, weight: .medium))
                    .foregroundStyle(item.kind == .color ? Color.purple : Color.accentColor)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

private struct SourceAppIcon: View {
    let bundleIdentifier: String?
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                Image(systemName: "app.dashed").foregroundStyle(.tertiary)
            }
        }
        .frame(width: 12, height: 12)
        .task(id: bundleIdentifier) {
            guard let bundleIdentifier,
                let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
            else { return }
            let path = appURL.path
            image = await Task.detached(priority: .utility) { NSWorkspace.shared.icon(forFile: path) }.value
        }
    }
}

private struct AsyncClipboardThumbnail: View {
    let data: Data
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "photo").foregroundStyle(.tertiary)
            }
        }
        .task(id: data.hashValue) {
            image = await Task.detached(priority: .utility) { NSImage(data: data) }.value
        }
    }
}

private struct ClipboardItemPreview: View {
    let item: ClipboardItem

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(item.kind.localizedName, systemImage: item.kind.symbolName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if item.kind == .image || item.kind == .fileURLs {
                    Button {
                        ClipboardHistoryPanelController.shared.showQuickLook(for: item)
                    } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                    }
                    .buttonStyle(.plain)
                    .help(String(localized: "Quick Look"))
                }
            }
            switch item.kind {
            case .image:
                if let data = item.imageRepresentationData {
                    AsyncClipboardThumbnail(data: data).scaledToFit().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Text(item.preview).foregroundStyle(.secondary)
                }
            case .richText:
                RichClipboardText(item: item)
            case .fileURLs:
                Label(filePath, systemImage: "doc")
                    .font(.system(size: 13))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            case .url:
                Link(destination: URL(string: item.preview) ?? URL(fileURLWithPath: "/")) {
                    Label(item.preview, systemImage: "link")
                        .font(.system(size: 13))
                        .lineLimit(5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            case .color:
                VStack(alignment: .leading, spacing: 10) {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(color(from: item))
                        .frame(maxWidth: .infinity, minHeight: 125, maxHeight: 190)
                    Text(item.preview).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                }
            case .plainText, .email, .other:
                ScrollView {
                    Text(item.preview.isEmpty ? String(localized: "No text preview") : item.preview)
                        .font(.system(size: 13))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func color(from item: ClipboardItem) -> Color {
        let value = item.preview.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        if value.count == 6, let rgb = UInt32(value, radix: 16) {
            return Color(
                red: Double((rgb >> 16) & 0xff) / 255, green: Double((rgb >> 8) & 0xff) / 255,
                blue: Double(rgb & 0xff) / 255)
        }
        return .purple
    }

    private var filePath: String {
        guard let data = item.representations.first(where: { $0.type == "public.file-url" })?.data,
            let url = URL(dataRepresentation: data, relativeTo: nil)
        else { return item.preview }
        return url.path
    }
}

private struct RichClipboardText: View {
    let item: ClipboardItem

    var body: some View {
        ScrollView {
            if let data = item.representations.first(where: { $0.type == "public.rtf" })?.data,
                let attributed = try? NSAttributedString(
                    data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
            {
                Text(AttributedString(attributed)).frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(item.preview).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .textSelection(.enabled)
    }
}

private struct ClipboardDetailRow: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 11)).textSelection(.enabled).lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct CommandPaletteView: View {
    @ObservedObject var model: ClipboardHistoryPanelModel
    let controller: ClipboardHistoryPanelController?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(String(localized: "Commands"))
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
                        Text(command.title).frame(maxWidth: .infinity, alignment: .leading)
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
        .frame(width: 300, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).stroke(.white.opacity(0.16), lineWidth: 1))
        .shadow(color: .black.opacity(0.24), radius: 22, y: 9)
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
        case .other: return String(localized: "Other")
        }
    }

    fileprivate var symbolName: String {
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
