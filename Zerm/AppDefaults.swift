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
            "SkipMuteWithHeadphones": true,
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
            DictationOutputMode.storageKey: DictationOutputMode.instantRefine.rawValue,
            "InstantTranscriptionMode": true,
            "AllowPromptTriggeredEnhancement": false,
            "isAIEnhancementEnabled": true,
            "useClipboardContext": false,
            "useScreenCaptureContext": false,
            "SkipShortEnhancement": true,
            "ShortEnhancementWordThreshold": 3,
            // Applies to Enhanced mode, where the user is waiting on the result. Refine
            // runs after the paste and uses its own, much shorter budget — see
            // AIEnhancementService.timeout(for:).
            "EnhancementTimeoutSeconds": 15,
            "EnhancementRetryOnTimeout": true,

            // Read Aloud speaks the selection exactly by default: deterministic, needs no
            // downloaded model, and never hands the selection to a language model. The AI
            // modes (Retell, Summarize, …) are an explicit choice in Read Aloud settings.
            TTSSettings.Keys.readingMode: ReadAloudMode.exact.rawValue,
            TTSSettings.Keys.naturalReadingAI: false,

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

        if defaults.integer(forKey: "ZermFastDefaultsVersion") < 5 {
            // The old default made Enhancement appear broken: Instant explicitly bypassed it and
            // the independent toggle was off. Instant + Refine preserves immediate paste while
            // allowing the configured AI to replace it afterwards. Only migrate that exact
            // legacy-default combination; never overwrite a deliberate Enhanced/Refine choice.
            let legacyMode = DictationOutputMode.current
            let legacyEnhancementWasEnabled = defaults.bool(forKey: "isAIEnhancementEnabled")
            if legacyMode == .instant, !legacyEnhancementWasEnabled {
                DictationOutputMode.setCurrent(.instantRefine)
                defaults.set(true, forKey: "isAIEnhancementEnabled")
            }

            // Reading mode is no longer migrated here: the registered default (Read exactly)
            // applies unless the user picked a mode themselves.
            defaults.set(5, forKey: "ZermFastDefaultsVersion")
        }

        if defaults.integer(forKey: "ZermFastDefaultsVersion") < 6 {
            // Enhancement has its own default key. Do not write it if the user already chose
            // one; package(for: .enhancement) resolves an installed model on its own.
            if defaults.string(forKey: LocalLLMModelManager.enhancementModelKey) == nil {
                let preferred = LocalLLMModelManager.enhancementDefaultPackage.fileName
                let path = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("com.arcusis.zerm")
                    .appendingPathComponent("LLMModels")
                    .appendingPathComponent(preferred).path
                if FileManager.default.fileExists(atPath: path) {
                    defaults.set(preferred, forKey: LocalLLMModelManager.enhancementModelKey)
                }
            }
            defaults.set(6, forKey: "ZermFastDefaultsVersion")
        }

        PunctuationCleanupMode.migrateLegacyUserDefaultIfNeeded()

        // `integer(forKey:)` is 0 when the key is absent. Production 2.8.2 then
        // treated retention as "older than now" and could sweep audio on launch.
        if defaults.object(forKey: "AudioRetentionPeriod") == nil {
            defaults.set(14, forKey: "AudioRetentionPeriod")
        }
    }
}
