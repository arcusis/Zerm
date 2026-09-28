import Foundation
import Testing
@testable import Zerm

/// Power Mode templates bind only installed apps and change dictation visibly (#355).
struct PowerModeTemplateTests {

    private func template(_ id: String) throws -> PowerModeTemplate {
        try #require(PowerModeTemplate.all.first { $0.id == id })
    }

    @Test func templatesAreDistinctAndUseExistingPrompts() {
        let ids = PowerModeTemplate.all.map(\.id)
        #expect(Set(ids).count == ids.count)
        let promptIDs = Set(PredefinedPrompts.createDefaultPrompts().map(\.id))
        for template in PowerModeTemplate.all {
            #expect(!template.suggestedApps.isEmpty, "\(template.id)")
            #expect(promptIDs.contains(template.selectedPrompt), "\(template.id)")
        }
    }

    @Test func onlyInstalledAppsAreSuggested() throws {
        let code = try template("code")
        let installed: Set<String> = ["com.apple.Terminal", "dev.zed.Zed"]
        let apps = code.installedApps { installed.contains($0) }
        #expect(apps.map(\.bundleIdentifier) == ["dev.zed.Zed", "com.apple.Terminal"])
        #expect(code.installedApps { _ in false }.isEmpty)
    }

    @Test func aConfigurationChangesCleanupAndPromptButInheritsTheRest() throws {
        let messages = try template("messages")
        let config = messages.makeConfiguration(apps: messages.suggestedApps.prefix(2).map { $0 })

        #expect(config.appConfigs?.map(\.bundleIdentifier) == ["com.apple.MobileSMS", "com.tinyspeck.slackmacgap"])
        #expect(config.selectedPrompt == PredefinedPrompts.chatPromptId.uuidString)
        #expect(config.punctuationCleanupMode == .removeTrailingPeriod)
        #expect(config.isTextFormattingEnabled == false)
        #expect(config.selectedTranscriptionModelName == nil)
        #expect(config.selectedLanguage == nil)
        #expect(config.outputMode == nil)
        #expect(!config.isDefault)
    }

    @Test func appsAlreadyBoundToAnotherModeAreLeftOut() throws {
        let writing = try template("writing")
        let config = writing.makeConfiguration(apps: writing.suggestedApps, excluding: ["com.apple.mail"])
        #expect(config.appConfigs?.contains { $0.bundleIdentifier == "com.apple.mail" } == false)
        #expect(config.appConfigs?.count == writing.suggestedApps.count - 1)
    }
}
