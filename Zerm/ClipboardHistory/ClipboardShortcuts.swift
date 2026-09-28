import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let openClipboardHistory = Self("openClipboardHistory", default: .init(.v, modifiers: [.shift, .command]))
    static let pauseClipboardHistory = Self("pauseClipboardHistory")
    static let pasteNextClipboardItem = Self("pasteNextClipboardItem", default: .init(.downArrow, modifiers: .command))
    static let pasteNextClipboardItemFormatted = Self("pasteNextClipboardItemFormatted", default: .init(.v, modifiers: [.control, .option]))
}
