import AppKit
import SwiftUI

struct ClipboardHistorySearchField: NSViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    let placeholder: String

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, isFocused: $isFocused)
    }

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.delegate = context.coordinator
        field.placeholderString = placeholder
        field.sendsSearchStringImmediately = true
        field.focusRingType = .default
        field.setAccessibilityLabel(placeholder)
        field.setAccessibilityHelp(String(localized: "Search clipboard history"))
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.text = $text
        context.coordinator.isFocused = $isFocused
        field.placeholderString = placeholder
        if field.stringValue != text { field.stringValue = text }
        if isFocused, field.window?.firstResponder !== field.currentEditor() {
            DispatchQueue.main.async { field.window?.makeFirstResponder(field) }
        }
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var text: Binding<String>
        var isFocused: Binding<Bool>

        init(text: Binding<String>, isFocused: Binding<Bool>) {
            self.text = text
            self.isFocused = isFocused
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            text.wrappedValue = field.stringValue
            isFocused.wrappedValue = true
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            isFocused.wrappedValue = false
        }
    }
}

struct ClipboardRowThumbnail: View {
    let item: ClipboardItem
    var linkService: LinkPreviewService = .shared
    @State private var metadata: ClipboardLinkMetadata?
    @State private var filePreview: ClipboardFilePreview?

    var body: some View {
        Group {
            if item.kind == .color, let color = ClipboardColorDetails.parse(item.preview) {
                RoundedRectangle(cornerRadius: 8).fill(Color(red: Double(color.red) / 255, green: Double(color.green) / 255, blue: Double(color.blue) / 255))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: .separatorColor), lineWidth: 1))
            } else if item.kind == .image, let image = item.thumbnail {
                Image(nsImage: image).resizable().scaledToFill()
            } else if item.kind == .url, let imageData = metadata?.imageData ?? metadata?.iconData,
                      let image = ClipboardPreviewImageCache.image(for: item.contentHash, data: imageData) {
                Image(nsImage: image).resizable().scaledToFill()
            } else if item.kind == .fileURLs, let image = filePreview?.thumbnail {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: glyph).font(.system(size: 16, weight: .medium)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: .controlBackgroundColor))
            }
        }
        .frame(width: 38, height: 38)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .task(id: item.id) {
            metadata = nil
            filePreview = nil
            if item.kind == .url, let url = ClipboardPreviewClassifier.url(from: item) {
                metadata = await linkService.preview(for: url)
            } else if item.kind == .fileURLs,
                      let data = item.representations.first(where: { $0.type == "public.file-url" })?.data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) {
                filePreview = await ClipboardFilePreview.load(url, size: CGSize(width: 48, height: 48))
            }
        }
        .accessibilityLabel(String(localized: "Clipboard item thumbnail"))
    }

    private var glyph: String {
        switch item.kind {
        case .plainText: ClipboardPreviewText.isCode(item.preview) ? "chevron.left.forwardslash.chevron.right" : "text.alignleft"
        case .richText: "doc.richtext"
        case .image: "photo"
        case .fileURLs: "doc"
        case .url: "link"
        case .email: "envelope"
        case .color: "paintpalette"
        case .other: "doc.on.clipboard"
        }
    }
}

struct ClipboardRichPreview: View {
    let item: ClipboardItem
    var linkService: LinkPreviewService = .shared
    @State private var metadata: ClipboardLinkMetadata?
    @State private var filePreviews: [ClipboardFilePreview] = []

    var body: some View {
        Group {
            switch item.kind {
            case .url: linkCard
            case .fileURLs: filesCard
            case .color: colorCard
            case .email: emailCard
            case .image: imageCard
            case .richText: textCard(rich: true)
            case .plainText, .other: textCard(rich: false)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(20)
        .task(id: item.id) { await loadPreviewData() }
    }

    private var linkCard: some View {
        let url = ClipboardPreviewClassifier.url(from: item)
        let kind = url.map(ClipboardPreviewClassifier.linkKind(for:)) ?? .website
        return VStack(alignment: .leading, spacing: 14) {
            if let data = metadata?.imageData ?? metadata?.iconData,
               let image = ClipboardPreviewImageCache.image(for: item.contentHash, data: data) {
                Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: .infinity).frame(maxHeight: 250)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .accessibilityLabel(String(localized: "Clipboard image preview"))
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "link").font(.system(size: 28, weight: .medium)).foregroundStyle(Color.primary)
                    Text(url?.host ?? String(localized: "Link")).font(.caption.weight(.medium)).foregroundStyle(Color.primary)
                }
                .frame(maxWidth: .infinity).frame(height: 128)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            }
            VStack(alignment: .leading, spacing: 6) {
                if let service = kind.serviceName { Text(service).font(.caption.weight(.semibold)).foregroundStyle(.secondary) }
                Text(metadata?.title ?? item.title ?? url?.host ?? item.preview).font(.title3.weight(.semibold)).textSelection(.enabled)
                if let author = metadata?.author { Text(author).font(.subheadline).foregroundStyle(.secondary) }
                if let siteName = metadata?.siteName { Text(siteName).font(.subheadline).foregroundStyle(.secondary) }
                Text(item.preview).font(.caption).foregroundStyle(.tertiary).textSelection(.enabled).lineLimit(2)
            }
        }
    }

    private var filesCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(filePreviews.enumerated()), id: \.offset) { _, file in
                HStack(alignment: .top, spacing: 14) {
                    Group {
                        if let image = file.thumbnail { Image(nsImage: image).resizable().scaledToFill() }
                        else { Image(systemName: file.folderCount == nil ? "doc" : "folder.fill").font(.system(size: 28)).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(nsColor: .controlBackgroundColor)) }
                    }
                    .frame(width: 116, height: 92)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .accessibilityLabel(file.name)
                    VStack(alignment: .leading, spacing: 7) {
                        Text(file.name).font(.headline).textSelection(.enabled).lineLimit(2)
                        Text(file.missing ? String(localized: "File is missing") : file.kind).font(.subheadline).foregroundStyle(.secondary)
                        if let count = file.folderCount { Text(String.localizedStringWithFormat(String(localized: "%lld items"), count)).font(.caption).foregroundStyle(.secondary) }
                        else { Text(file.size).font(.caption).foregroundStyle(.secondary) }
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private var colorCard: some View {
        Group {
            if let color = ClipboardColorDetails.parse(item.preview) {
                VStack(alignment: .leading, spacing: 14) {
                    RoundedRectangle(cornerRadius: 18)
                        .fill(Color(red: Double(color.red) / 255, green: Double(color.green) / 255, blue: Double(color.blue) / 255))
                        .frame(height: 170)
                        .accessibilityLabel(color.hex)
                        .overlay(alignment: .bottomTrailing) {
                            Text(color.contrast).font(.caption.weight(.semibold)).padding(.horizontal, 10).padding(.vertical, 6)
                                .background(.regularMaterial, in: Capsule()).padding(12)
                        }
                    Text(color.hex).font(.title2.monospaced().weight(.semibold)).textSelection(.enabled)
                    Text(color.rgb).font(.body.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    Text(color.hsl).font(.body.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                }
            } else { textCard(rich: false) }
        }
    }

    private var emailCard: some View {
        let address = item.preview.replacingOccurrences(of: "mailto:", with: "", options: .caseInsensitive)
        let domain = address.split(separator: "@").last.map(String.init) ?? ""
        return VStack(alignment: .leading, spacing: 12) {
            Image(systemName: "person.crop.circle.fill").font(.system(size: 50)).foregroundStyle(.secondary)
            Text(address).font(.title3.weight(.semibold)).textSelection(.enabled)
            Label(domain, systemImage: "globe").font(.subheadline).foregroundStyle(.secondary).textSelection(.enabled)
        }
    }

    private var imageCard: some View {
        Group {
            if let image = item.thumbnail {
                Image(nsImage: image).resizable().scaledToFit()
                    .accessibilityLabel(String(localized: "Clipboard image preview"))
            }
            else { Text(String(localized: "Image preview unavailable")).foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func textCard(rich: Bool) -> some View {
        let code = !rich && ClipboardPreviewText.isCode(item.preview)
        return ScrollView {
            Text(item.preview.isEmpty ? String(localized: "No text preview") : item.preview)
                .font(code ? .system(.body, design: .monospaced) : .body)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @MainActor
    private func loadPreviewData() async {
        metadata = nil
        filePreviews = []
        if item.kind == .url, let url = ClipboardPreviewClassifier.url(from: item) {
            metadata = await linkService.preview(for: url)
        } else if item.kind == .fileURLs {
            let urls = item.representations.filter { $0.type == "public.file-url" }.compactMap { URL(dataRepresentation: $0.data, relativeTo: nil) }
            for url in urls.prefix(6) {
                if Task.isCancelled { return }
                filePreviews.append(await ClipboardFilePreview.load(url))
            }
        }
    }
}

enum ClipboardPreviewText {
    static func isCode(_ text: String) -> Bool {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard !text.isEmpty else { return false }
        if lines.contains(where: { $0.hasPrefix("    ") || $0.hasPrefix("\t") || $0.hasPrefix("```") }) { return true }
        let markers = [" = ", " => ", " {", "};", "func ", "let ", "const ", "import ", "<div", "</"]
        return lines.count > 1 && markers.contains(where: text.contains)
    }
}
