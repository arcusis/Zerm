import Foundation
import SwiftUI

/// Process-local configuration used only by the Debug UI-test host.
///
/// Product launches always receive `.disabled`. UI tests opt in explicitly and get a fresh
/// defaults suite, in-memory SwiftData, a run-unique support directory, deterministic app fixtures,
/// and no updater, cleanup, analytics, prewarm, or network services started by the app host.
struct UITestLaunchConfiguration {
    static let mainWindowSceneID = "main"

    enum Scenario: String {
        case standard
        case nativeApple
        case activeMeeting
    }

    let isEnabled: Bool
    let scenario: Scenario
    let defaults: UserDefaults
    let storageRoot: URL?
    let disablesAnimations: Bool
    let rightToLeft: Bool

    static let current: UITestLaunchConfiguration = {
        #if DEBUG
        let process = ProcessInfo.processInfo
        guard process.arguments.contains("--zerm-ui-testing") else { return .disabled }

        let environment = process.environment
        let suiteName = environment["ZERM_UI_TEST_DEFAULTS_SUITE"]
            ?? "com.arcusis.zerm.uitests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        let storageRoot = environment["ZERM_UI_TEST_STORAGE_ROOT"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory
                .appendingPathComponent("ZermUITests", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defaults.register(defaults: [
            "hasCompletedOnboarding": true,
            "powerModeUIFlag": true,
            "sidebarDictationExpanded": true,
            "meetingCaptureMicrophone": false,
            "meetingCaptureSystemAudio": true,
            "meetingCaptureTargetMode": "detectedApplication",
            "meetingCaptureApplicationBundleID": "com.example.meeting",
            "meetingLiveTranscript": true,
            "meetingIdentifySpeakers": true,
            "meetingSummarise": false,
            "SelectedLanguage": "auto"
        ])

        return UITestLaunchConfiguration(
            isEnabled: true,
            scenario: Scenario(rawValue: environment["ZERM_UI_TEST_SCENARIO"] ?? "") ?? .standard,
            defaults: defaults,
            storageRoot: storageRoot,
            disablesAnimations: environment["ZERM_UI_TEST_DISABLE_ANIMATIONS"] == "1",
            rightToLeft: environment["ZERM_UI_TEST_RTL"] == "1"
        )
        #else
        return .disabled
        #endif
    }()

    private static let disabled = UITestLaunchConfiguration(
        isEnabled: false,
        scenario: .standard,
        defaults: .standard,
        storageRoot: nil,
        disablesAnimations: false,
        rightToLeft: false
    )
}

private struct UITestEnvironmentModifier: ViewModifier {
    let configuration: UITestLaunchConfiguration

    @ViewBuilder
    func body(content: Content) -> some View {
        if configuration.isEnabled {
            content
                .defaultAppStorage(configuration.defaults)
                .environment(\.layoutDirection, configuration.rightToLeft ? .rightToLeft : .leftToRight)
                .transaction { transaction in
                    if configuration.disablesAnimations {
                        transaction.animation = nil
                        transaction.disablesAnimations = true
                    }
                }
        } else {
            content
        }
    }
}

extension View {
    func uiTestEnvironment(_ configuration: UITestLaunchConfiguration) -> some View {
        modifier(UITestEnvironmentModifier(configuration: configuration))
    }
}

#if DEBUG
struct UITestOpenMainWindowCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    let configuration: UITestLaunchConfiguration

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            if configuration.isEnabled {
                Button("Open Main Window") {
                    openWindow(id: UITestLaunchConfiguration.mainWindowSceneID)
                }
                .keyboardShortcut("n", modifiers: .command)
            }
        }
    }
}
#endif
