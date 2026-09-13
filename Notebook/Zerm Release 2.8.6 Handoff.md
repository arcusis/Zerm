# Zerm Release 2.8.6 Handoff

What is done and what is left to ship 2.8.6. Tracking issue #327.

## Done

- **Merged:** all workstreams into `release/2.8.6` (PRs #328–#340), stamped **2.8.6 / 286**. Sparkle notes are in `release-notes/2.8.6.html`, and they state that meeting recordings are deleted.
- **Verified:** `make test` 410 passed, `build-for-testing` succeeds, and `make dev-app` builds `.dev-build/Zerm Dev.app`.
- **Reviewed:** an independent review of the Power Mode/enhancement diff found 7 defects, all fixed before merge.

## Gate 1: hands-on in Zerm Dev (not done)

Run on the owner's Mac with Zerm Dev only. Give it hotkeys that differ from the installed app's, then grant Microphone and Accessibility. See [[Zerm Dev Build Isolation]].

1. **Dictation:**
   - Parakeet V3 (existing cache → first load fetches `JointDecisionv3`), streaming on and off, stopping mid-sentence.
   - Parakeet Unified.
   - ivrit.ai Turbo in Hebrew and mixed Hebrew/English.
   - Whisper ↔ Parakeet switching.
2. **Power Mode:** a global model with no overrides → the same model in every app. One override applies only in its app. Global settings are unchanged afterwards.
3. **Enhancement:**
   - Instant; Instant + Refine (TextEdit replaces in place and keeps the trailing space; Slack keeps raw text).
   - Enhanced with on-device and one cloud provider.
   - Timeout.
   - Ollama not running → fast notice.
4. **Transcribe File:**
   - Two-speaker English file with speakers on.
   - Hebrew file.
   - One-hour file (memory).
   - Video.
   - Cancel.
   - All five exports.
   - Open With from Finder.
   - Open Transcript from History.
5. **Cloud with real keys, in this order:**
   1. OpenAI `gpt-transcribe` (Hebrew)
   2. Soniox
   3. Gladia
   4. AssemblyAI U3.5
   5. Mistral
   6. custom presets
6. **Hebrew UI:** Dashboard ranges, History copy, Models screen, Power Mode editor, Enhancement, onboarding, RTL chevrons.
7. **Upgrade path:** copy a 2.8.5 UserDefaults domain into `com.arcusis.zerm.dev` and launch. Check:
   - Power Modes show "Use global setting".
   - Enhancement mode matches before.
   - Formatting stays off.
   - Retired models and ids are migrated.
   - The meeting folder (dev copy) is deleted.

## Gate 2: signed release

- **Release PR:** merge `release/2.8.6` into `Production`. CodeQL must pass.
- **Build:** `RELEASE_NOTES_FILE=release-notes/2.8.6.html scripts/release.sh` on the signing Mac. It does Developer ID signing, notarization, the Sparkle-signed appcast, the DMG and the zip.
- **Publish:** `gh release create v2.8.6` with both assets. Regenerate the site changelog after the release exists, and merge the appcast PR.
- **Close:** #315–#326, #331, #327.

## Known follow-ups after 2.8.6

- Cloud streaming providers still treat the first commit after stop as final. This needs an end-of-transcript signal from LLMkit.
- Clamshell microphone fallback (VoiceInk `630ae52`) is not ported.
- The Transcribe File queue is in memory only, and diarization is not scheduled against dictation.
- History does not display the stored enhancement outcome yet.

Related: [[Zerm Verification Workflow]], [[Zerm Release Signing]]
