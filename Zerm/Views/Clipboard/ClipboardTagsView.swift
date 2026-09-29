import AppKit
import SwiftUI

struct ClipboardTagsView: View {
    @StateObject private var model: ClipboardLibraryModel
    @Environment(\.locale) private var locale
    let onOpenHistory: (UUID) -> Void
    private let layoutDirectionOverride: LayoutDirection?
    @State private var itemCounts: [UUID: Int] = [:]
    @State private var showsEditor = false
    @State private var editingTag: ClipboardTag?
    @State private var tagToDelete: ClipboardTag?
    @State private var showsDeleteConfirmation = false

    init(
        store: ClipboardHistoryStore,
        onOpenHistory: @escaping (UUID) -> Void,
        layoutDirectionOverride: LayoutDirection? = nil
    ) {
        _model = StateObject(wrappedValue: ClipboardLibraryModel(store: store))
        self.onOpenHistory = onOpenHistory
        self.layoutDirectionOverride = layoutDirectionOverride
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Tags").font(.title2.weight(.semibold))
                    Text(verbatim: String.localizedStringWithFormat(String(localized: "%lld tags"), model.tags.count))
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    editingTag = nil
                    showsEditor = true
                } label: { Label("New Tag", systemImage: "plus") }
                .keyboardShortcut("n", modifiers: .command)
                .help(String(localized: "Create Tag"))
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            Divider()
            if model.tags.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(model.tags) { tag in tagRow(tag) }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .accessibilityLabel(String(localized: "Tags"))
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.layoutDirection, layoutDirectionOverride ?? currentLayoutDirection)
        .task { await refreshTags() }
        .sheet(isPresented: $showsEditor) {
            ClipboardTagEditor(tag: editingTag) { name, color in
                Task {
                    if let editingTag { await model.updateTag(editingTag, name: name, colorHex: color) }
                    else { await model.createTag(name: name, colorHex: color) }
                    await refreshCounts()
                }
            }
        }
        .confirmationDialog(String(localized: "Delete Tag?"), isPresented: $showsDeleteConfirmation, titleVisibility: .visible) {
            Button(String(localized: "Delete Tag"), role: .destructive) {
                guard let tagToDelete else { return }
                Task { await model.deleteTag(tagToDelete); await refreshCounts() }
            }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: {
            Text("Items with this tag will remain in history without the tag.")
        }
    }

    private func tagRow(_ tag: ClipboardTag) -> some View {
        HStack(spacing: 14) {
            Circle()
                .fill(Color(clipboardHex: tag.colorHex))
                .frame(width: 12, height: 12)
                .overlay(Circle().stroke(Color(nsColor: .separatorColor), lineWidth: 1))
                .accessibilityLabel(String.localizedStringWithFormat(String(localized: "Tag color: %@"), tag.name))
            Button { onOpenHistory(tag.id) } label: {
                HStack {
                    Text(verbatim: tag.name).font(.body.weight(.medium))
                    Spacer()
                    Text(verbatim: String.localizedStringWithFormat(String(localized: "%lld items"), itemCounts[tag.id, default: 0]))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(String(localized: "Open History Filtered by Tag"))
            .accessibilityHint(String(localized: "Opens Clipboard History filtered to this tag."))
            Menu {
                Button(String(localized: "Edit Tag")) { editingTag = tag; showsEditor = true }
                Menu(String(localized: "Merge Into")) {
                    ForEach(model.tags.filter { $0.id != tag.id }) { destination in
                        Button(destination.name) {
                            Task { await model.mergeTag(tag, into: destination); await refreshCounts() }
                        }
                    }
                }
                Button(String(localized: "Delete Tag"), role: .destructive) { tagToDelete = tag; showsDeleteConfirmation = true }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .help(String(localized: "Tag Actions"))
            .accessibilityLabel(String.localizedStringWithFormat(String(localized: "Tag Actions: %@"), tag.name))
        }
        .padding(.vertical, 5)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Tags Yet", systemImage: "tag")
        } description: {
            Text("Create tags to organize clipboard items")
        } actions: {
            Button { editingTag = nil; showsEditor = true } label: { Label("Create Tag", systemImage: "plus") }
        }
    }

    private func refreshTags() async {
        await model.loadTags()
        await refreshCounts()
    }

    private func refreshCounts() async {
        itemCounts = await model.tagCounts()
    }

    private var currentLayoutDirection: LayoutDirection {
        Locale.Language(identifier: locale.identifier).characterDirection == .rightToLeft ? .rightToLeft : .leftToRight
    }
}

private struct ClipboardTagEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var color: Color
    let tag: ClipboardTag?
    let onSave: (String, String) -> Void

    init(tag: ClipboardTag?, onSave: @escaping (String, String) -> Void) {
        self.tag = tag
        self.onSave = onSave
        _name = State(initialValue: tag?.name ?? "")
        _color = State(initialValue: Color(clipboardHex: tag?.colorHex ?? "#527DDB"))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(verbatim: tag == nil ? String(localized: "New Tag") : String(localized: "Edit Tag"))
                .font(.headline)
            TextField(String(localized: "Tag Name"), text: $name)
                .textFieldStyle(.roundedBorder)
            ColorPicker(String(localized: "Tag Color"), selection: $color, supportsOpacity: false)
            HStack {
                Spacer()
                Button(String(localized: "Cancel"), role: .cancel) { dismiss() }
                Button(tag == nil ? String(localized: "Create") : String(localized: "Save")) {
                    onSave(name, NSColor(color).clipboardHexString)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 340)
    }
}

private extension NSColor {
    var clipboardHexString: String {
        guard let value = usingColorSpace(.deviceRGB) else { return "#808080" }
        return String(format: "#%02X%02X%02X", Int(value.redComponent * 255), Int(value.greenComponent * 255), Int(value.blueComponent * 255))
    }
}
