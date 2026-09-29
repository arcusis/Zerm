import AppKit
import SwiftUI

struct ClipboardHistoryListRow: View {
    let item: ClipboardItem
    let index: Int?
    let showQuickPasteBadge: Bool
    let query: String
    let linkService: LinkPreviewService
    let isSelected: Bool
    let isCurrentClipboard: Bool

    var body: some View {
        HStack(spacing: 11) {
            ClipboardRowThumbnail(item: item, linkService: linkService, size: 36)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    highlightedTitle
                        .font(.callout.weight(.medium)).lineLimit(1).truncationMode(.tail).textSelection(.enabled)
                    Spacer(minLength: 0)
                    if item.isPinned { Image(systemName: "pin.fill").font(.caption2).foregroundStyle(Color.accentColor).accessibilityLabel(String(localized: "Pinned")) }
                    if item.isFavorite { Image(systemName: "star.fill").font(.caption2).foregroundStyle(Color.accentColor).accessibilityLabel(String(localized: "Favorite")) }
                    if showQuickPasteBadge, let index, index < 9 {
                        Text("⌘\(index + 1)").font(.system(size: 10, weight: .medium, design: .rounded)).foregroundStyle(.secondary)
                            .accessibilityLabel(String.localizedStringWithFormat(String(localized: "Paste with Command %lld"), Int64(index + 1)))
                    }
                }
                HStack(spacing: 5) {
                    ClipboardSourceAppIcon(bundleIdentifier: item.sourceApp.bundleIdentifier, size: 13)
                    Text(verbatim: item.sourceApp.name ?? String(localized: "Unknown App"))
                    Text("·")
                    Text(verbatim: item.lastCopiedAt.clipboardHistoryDate)
                    Text("·")
                    Text(verbatim: item.kind.historyLocalizedName)
                    Spacer(minLength: 0)
                }
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 4).frame(minHeight: 44)
        .contentShape(Rectangle())
        .background {
            ZStack(alignment: .leading) {
                if isSelected { RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(0.08)).padding(.horizontal, 4) }
                if isCurrentClipboard { Capsule().fill(Color.accentColor).frame(width: 2, height: 24).padding(.leading, 3) }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: String.localizedStringWithFormat(
            String(localized: "clipboard_row_accessibility_label"), item.kind.historyLocalizedName,
            item.title?.clipboardHistoryNonEmpty ?? item.preview, item.sourceApp.name ?? String(localized: "Unknown App"),
            item.lastCopiedAt.formatted(date: .abbreviated, time: .shortened)
        )))
    }

    private var highlightedTitle: Text {
        let value = item.title?.clipboardHistoryNonEmpty ?? item.preview.clipboardHistoryNonEmpty ?? item.kind.historyLocalizedName
        let terms = ClipboardPanelQuery.parse(query).text.split(whereSeparator: \.isWhitespace).map(String.init).filter { !$0.isEmpty }
        guard !terms.isEmpty else { return Text(verbatim: value) }
        var result = Text("")
        var cursor = value.startIndex
        while cursor < value.endIndex {
            let range = cursor..<value.endIndex
            guard let match = terms.compactMap({ value.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive], range: range) })
                .min(by: { $0.lowerBound < $1.lowerBound }) else {
                result = result + Text(verbatim: String(value[cursor...])).foregroundColor(.primary)
                break
            }
            if cursor < match.lowerBound { result = result + Text(verbatim: String(value[cursor..<match.lowerBound])).foregroundColor(.primary) }
            result = result + Text(verbatim: String(value[match])).foregroundColor(.accentColor)
            cursor = match.upperBound
        }
        return result
    }
}

struct ClipboardSourceAppIcon: View {
    let bundleIdentifier: String?
    var size: CGFloat = 14

    var body: some View {
        Group {
            if let image = ClipboardApplicationIconCache.image(for: bundleIdentifier) {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                Image(systemName: "app.dashed").resizable().scaledToFit().foregroundStyle(.tertiary).padding(1)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

@MainActor
enum ClipboardApplicationIconCache {
    private static let images = NSCache<NSString, NSImage>()

    static func image(for bundleIdentifier: String?) -> NSImage? {
        guard let bundleIdentifier, !bundleIdentifier.isEmpty else { return nil }
        let key = bundleIdentifier as NSString
        if let cached = images.object(forKey: key) { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        images.setObject(icon, forKey: key)
        return icon
    }
}

extension ClipboardItemKind {
    var historyLocalizedName: String {
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
}

private extension String {
    var clipboardHistoryNonEmpty: String? { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self }
}

private extension Date {
    var clipboardHistoryDate: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(self) { return formatted(date: .omitted, time: .shortened) }
        if calendar.isDateInYesterday(self) { return String(localized: "Yesterday") + " " + formatted(date: .omitted, time: .shortened) }
        return formatted(.dateTime.day().month(.abbreviated))
    }
}
