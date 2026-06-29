import Foundation
import AppKit
import SelectedTextKit

class SelectedTextService {
    static func fetchSelectedText() async -> String? {
        // `.shortcut` simulates ⌘C and reads the pasteboard (restoring it afterward).
        // It is the only strategy that works in terminal emulators and TUI apps
        // (e.g. Claude Code, cmux), which render text in custom views that do not
        // expose AXSelectedText (.accessibility) and have no standard Edit ▸ Copy
        // menu item (.menuAction). Keep it last so the cheaper strategies win first.
        let strategies: [TextStrategy] = [.accessibility, .menuAction, .shortcut]
        do {
            let selectedText = try await SelectedTextManager.shared.getSelectedText(strategies: strategies)
            return selectedText
        } catch {
            print("Failed to get selected text: \(error)")
            return nil
        }
    }
}
