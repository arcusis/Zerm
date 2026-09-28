import AppKit
import Foundation

/// A starting point for a Power Mode: settings that visibly change dictation in a kind of app,
/// plus the apps of that kind to suggest. Only apps installed on this Mac are ever bound.
struct PowerModeTemplate: Identifiable {
    struct SuggestedApp: Hashable {
        let bundleIdentifier: String
        let name: String
    }

    let id: String
    let name: String
    let emoji: String
    let summary: String
    let suggestedApps: [SuggestedApp]
    let selectedPrompt: UUID
    let isTextFormattingEnabled: Bool
    let punctuationCleanupMode: PunctuationCleanupMode

    /// The suggested apps present on this Mac, in suggestion order.
    func installedApps(isInstalled: (String) -> Bool = Self.isInstalled) -> [SuggestedApp] {
        suggestedApps.filter { isInstalled($0.bundleIdentifier) }
    }

    /// A Power Mode bound to `apps`, minus any app another mode already uses, since an app can
    /// only trigger one mode. Only prompt and text cleanup are set; model, language, and output
    /// mode keep following the global settings.
    func makeConfiguration(apps: [SuggestedApp], excluding boundBundleIdentifiers: Set<String> = []) -> PowerModeConfig {
        PowerModeConfig(
            name: name,
            emoji: emoji,
            appConfigs: apps
                .filter { !boundBundleIdentifiers.contains($0.bundleIdentifier) }
                .map { AppConfig(bundleIdentifier: $0.bundleIdentifier, appName: $0.name) },
            selectedPrompt: selectedPrompt.uuidString,
            isTextFormattingEnabled: isTextFormattingEnabled,
            punctuationCleanupMode: punctuationCleanupMode
        )
    }

    static func isInstalled(_ bundleIdentifier: String) -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) != nil
    }

    static let all: [PowerModeTemplate] = [
        PowerModeTemplate(
            id: "code",
            name: String(localized: "Code"),
            emoji: "⌘",
            summary: String(localized: "Plain lines without a trailing period, ready for editors and terminals. With AI enhancement, cleans up dictated code and technical terms."),
            suggestedApps: [
                SuggestedApp(bundleIdentifier: "com.apple.dt.Xcode", name: "Xcode"),
                SuggestedApp(bundleIdentifier: "com.microsoft.VSCode", name: "Visual Studio Code"),
                SuggestedApp(bundleIdentifier: "com.todesktop.230313mzl4w4u92", name: "Cursor"),
                SuggestedApp(bundleIdentifier: "dev.zed.Zed", name: "Zed"),
                SuggestedApp(bundleIdentifier: "com.apple.Terminal", name: "Terminal"),
                SuggestedApp(bundleIdentifier: "com.googlecode.iterm2", name: "iTerm"),
                SuggestedApp(bundleIdentifier: "com.mitchellh.ghostty", name: "Ghostty"),
                SuggestedApp(bundleIdentifier: "dev.warp.Warp-Stable", name: "Warp")
            ],
            selectedPrompt: PredefinedPrompts.codingPromptId,
            isTextFormattingEnabled: false,
            punctuationCleanupMode: .removeTrailingPeriod
        ),
        PowerModeTemplate(
            id: "messages",
            name: String(localized: "Messages"),
            emoji: "💬",
            summary: String(localized: "Casual one-line messages without a trailing period. With AI enhancement, keeps a relaxed chat tone."),
            suggestedApps: [
                SuggestedApp(bundleIdentifier: "com.apple.MobileSMS", name: "Messages"),
                SuggestedApp(bundleIdentifier: "com.tinyspeck.slackmacgap", name: "Slack"),
                SuggestedApp(bundleIdentifier: "net.whatsapp.WhatsApp", name: "WhatsApp"),
                SuggestedApp(bundleIdentifier: "ru.keepcoder.Telegram", name: "Telegram"),
                SuggestedApp(bundleIdentifier: "com.hnc.Discord", name: "Discord"),
                SuggestedApp(bundleIdentifier: "com.microsoft.teams2", name: "Microsoft Teams"),
                SuggestedApp(bundleIdentifier: "org.whispersystems.signal-desktop", name: "Signal")
            ],
            selectedPrompt: PredefinedPrompts.chatPromptId,
            isTextFormattingEnabled: false,
            punctuationCleanupMode: .removeTrailingPeriod
        ),
        PowerModeTemplate(
            id: "writing",
            name: String(localized: "Writing"),
            emoji: "✎",
            summary: String(localized: "Full sentences and paragraphs for mail and documents. With AI enhancement, polishes grammar and flow."),
            suggestedApps: [
                SuggestedApp(bundleIdentifier: "com.apple.mail", name: "Mail"),
                SuggestedApp(bundleIdentifier: "com.microsoft.Outlook", name: "Microsoft Outlook"),
                SuggestedApp(bundleIdentifier: "com.apple.Notes", name: "Notes"),
                SuggestedApp(bundleIdentifier: "com.apple.iWork.Pages", name: "Pages"),
                SuggestedApp(bundleIdentifier: "com.microsoft.Word", name: "Microsoft Word"),
                SuggestedApp(bundleIdentifier: "notion.id", name: "Notion"),
                SuggestedApp(bundleIdentifier: "md.obsidian", name: "Obsidian")
            ],
            selectedPrompt: PredefinedPrompts.defaultPromptId,
            isTextFormattingEnabled: true,
            punctuationCleanupMode: .keep
        )
    ]
}

extension PowerModeManager {
    func addConfiguration(from template: PowerModeTemplate, apps: [PowerModeTemplate.SuggestedApp]) {
        let bound = Set(configurations.flatMap { $0.appConfigs ?? [] }.map(\.bundleIdentifier))
        addConfiguration(template.makeConfiguration(apps: apps, excluding: bound))
    }
}
