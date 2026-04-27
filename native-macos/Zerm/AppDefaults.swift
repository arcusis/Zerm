import Foundation

enum AppDefaults {
    static func registerDefaults() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: [
            // Onboarding & General
            "hasCompletedOnboarding": false,
            "enableAnnouncements": true,
            "autoUpdateCheck": true,

            // Clipboard
            "restoreClipboardAfterPaste": true,
            "clipboardRestoreDelay": 2.0,
            "useAppleScriptPaste": false,

            // Audio & Media
            "isSystemMuteEnabled": true,
            "audioResumptionDelay": 0.0,
            "isPauseMediaEnabled": false,
            "isSoundFeedbackEnabled": true,

            // Recording & Transcription
            "IsTextFormattingEnabled": true,
            "IsVADEnabled": true,
            "AutoStopAfterSilence": true,
            "AutoStopSilenceSeconds": 1.1,
            "AutoStopMinimumRecordingSeconds": 0.8,
            "AutoStopInitialSilenceSeconds": 6.0,
            "AutoStopLevelThreshold": 0.12,
            "RemoveFillerWords": true,
            "SelectedLanguage": "en",
            "AppendTrailingSpace": true,
            "RecorderType": "mini",

            // Cleanup
            "IsTranscriptionCleanupEnabled": false,
            "TranscriptionRetentionMinutes": 1440,
            "IsAudioCleanupEnabled": false,
            "AudioRetentionPeriod": 7,

            // UI & Behavior
            "IsMenuBarOnly": false,
            "powerModePersistConfig": false,
            "powerModeUIFlag": true,
            // Hotkey
            "isMiddleClickToggleEnabled": false,
            "middleClickActivationDelay": 200,

            // Enhancement
            "InstantTranscriptionMode": true,
            "AllowPromptTriggeredEnhancement": false,
            "isAIEnhancementEnabled": false,
            "useClipboardContext": false,
            "useScreenCaptureContext": false,
            "SkipShortEnhancement": true,
            "ShortEnhancementWordThreshold": 3,
            "EnhancementTimeoutSeconds": 2,
            "EnhancementRetryOnTimeout": false,

            // Model
            "PrewarmModelOnWake": true,

        ])

        if defaults.integer(forKey: "ZermFastDefaultsVersion") < 1 {
            defaults.set(true, forKey: "InstantTranscriptionMode")
            defaults.set(false, forKey: "AllowPromptTriggeredEnhancement")
            defaults.set(false, forKey: "isAIEnhancementEnabled")
            defaults.set(false, forKey: "useClipboardContext")
            defaults.set(false, forKey: "useScreenCaptureContext")
            defaults.set(2, forKey: "EnhancementTimeoutSeconds")
            defaults.set(false, forKey: "EnhancementRetryOnTimeout")
            defaults.set(true, forKey: "powerModeUIFlag")
            defaults.set(true, forKey: "AutoStopAfterSilence")
            defaults.set(1, forKey: "ZermFastDefaultsVersion")
        }
    }
}
