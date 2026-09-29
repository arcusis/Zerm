import Testing
@testable import Zerm

struct SettingsPaneRegistryTests {
    @Test func everySettingsPaneHasOneReachableNavigationEntry() {
        let panes = SettingsPane.allCases
        let identifiers = panes.map(\.accessibilityIdentifier)
        let paneIdentifiers = panes.map(\.paneAccessibilityIdentifier)

        #expect(panes.map(\.rawValue) == [
            "general",
            "shortcutsAutomation",
            "audio",
            "clipboardHistory",
            "modelsProviders",
            "permissionsPrivacy",
            "storageBackup",
            "advancedDiagnostics",
            "diagnostics"
        ])
        #expect(Set(identifiers).count == panes.count)
        #expect(Set(paneIdentifiers).count == panes.count)
        #expect(identifiers.allSatisfy { $0.hasPrefix("settings-tab-") })
        #expect(paneIdentifiers.allSatisfy { $0.hasPrefix("settings-pane-") })
    }
}
