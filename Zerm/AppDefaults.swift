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
            "restoreClipboardAfterPaste": false,
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
            // 1.1s was short enough that a normal thinking pause in long-form
            // dictation tripped auto-stop and cut the recording off. 2.5s tolerates
            // natural pauses while still stopping promptly when the user is done.
            "AutoStopSilenceSeconds": 2.5,
            "AutoStopMinimumRecordingSeconds": 0.8,
            "AutoStopInitialSilenceSeconds": 6.0,
            "AutoStopLevelThreshold": 0.12,
            "RemoveFillerWords": true,
            "SelectedLanguage": "auto",
            "AppendTrailingSpace": true,
            "RecorderType": "mini",

            // Cleanup — retain raw voice for 14 days by default (privacy)
            "IsTranscriptionCleanupEnabled": false,
            "TranscriptionRetentionMinutes": 1440,
            "IsAudioCleanupEnabled": true,
            "AudioRetentionPeriod": 14,

            // UI & Behavior
            "IsMenuBarOnly": false,
            "powerModePersistConfig": false,
            "powerModeUIFlag": true,
            // Hotkey
            "isMiddleClickToggleEnabled": false,
            "middleClickActivationDelay": 200,

            // Enhancement
            DictationOutputMode.storageKey: DictationOutputMode.instant.rawValue,
            "InstantTranscriptionMode": true,
            "AllowPromptTriggeredEnhancement": false,
            "isAIEnhancementEnabled": false,
            "useClipboardContext": false,
            "useScreenCaptureContext": false,
            "SkipShortEnhancement": true,
            "ShortEnhancementWordThreshold": 3,
            // Applies to Enhanced mode, where the user is waiting on the result. Refine
            // runs after the paste and uses its own, much shorter budget — see
            // AIEnhancementService.timeout(for:).
            "EnhancementTimeoutSeconds": 15,
            "EnhancementRetryOnTimeout": true,

            // Model
            "PrewarmModelOnWake": true,

            // Diagnostics
            "DebugLoggingEnabled": false,

            // Echo cancel / AGC for noisy rooms (VoiceProcessingIO)
            "UseVoiceProcessingIO": false,

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

        if defaults.integer(forKey: "ZermFastDefaultsVersion") < 2 {
            defaults.set(false, forKey: "restoreClipboardAfterPaste")
            defaults.set(2, forKey: "ZermFastDefaultsVersion")
        }

        // Deep-review defaults: auto language + audio retention on for privacy.
        if defaults.integer(forKey: "ZermFastDefaultsVersion") < 3 {
            if defaults.object(forKey: "SelectedLanguage") as? String == "en"
                || defaults.object(forKey: "SelectedLanguage") == nil {
                defaults.set("auto", forKey: "SelectedLanguage")
            }
            // Only flip audio cleanup on for installs that never customized it.
            if defaults.object(forKey: "IsAudioCleanupEnabled") == nil {
                defaults.set(true, forKey: "IsAudioCleanupEnabled")
            }
            if defaults.integer(forKey: "AudioRetentionPeriod") == 0 {
                defaults.set(14, forKey: "AudioRetentionPeriod")
            }
            defaults.set(3, forKey: "ZermFastDefaultsVersion")
        }

        // Fold the hidden InstantTranscriptionMode flag into an explicit output mode, and
        // undo the 2-second enhancement timeout the v1 block forced on everyone. Two
        // seconds is shorter than almost any LLM round-trip, so Enhanced mode timed out
        // and silently pasted the raw transcript — one of the reasons enhancement looked
        // switched off while its toggle read ON.
        if defaults.integer(forKey: "ZermFastDefaultsVersion") < 4 {
            if defaults.string(forKey: DictationOutputMode.storageKey) == nil {
                let wasInstant = defaults.object(forKey: "InstantTranscriptionMode") as? Bool ?? true
                defaults.set(
                    (wasInstant ? DictationOutputMode.instant : .enhanced).rawValue,
                    forKey: DictationOutputMode.storageKey
                )
            }
            // Only raise the timeout where it is still the value v1 forced, so a user who
            // deliberately chose a short timeout keeps it.
            if defaults.integer(forKey: "EnhancementTimeoutSeconds") == 2 {
                defaults.set(15, forKey: "EnhancementTimeoutSeconds")
                defaults.set(true, forKey: "EnhancementRetryOnTimeout")
            }
            defaults.set(4, forKey: "ZermFastDefaultsVersion")
        }

        PunctuationCleanupMode.migrateLegacyUserDefaultIfNeeded()
    }
}
