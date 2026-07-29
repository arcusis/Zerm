# Zerm Refine In Place

How Zerm delivers instant dictation *and* AI enhancement at the same time, added 2026-07-29.

## The problem it replaces

Enhancement used to sit **before** the paste (`TranscriptionPipeline`, the `await enhancementService.enhance(...)` call), so turning it on added the full LLM round-trip to every dictation. Rather than fix that, a hidden flag had been introduced to switch enhancement off entirely:

`InstantTranscriptionMode` — no UI anywhere, defaulted `true`, and force-set `true` for every existing install by the `ZermFastDefaultsVersion < 1` migration. It disabled enhancement in three independent places:

1. `AIEnhancementService.init` cleared `isEnhancementEnabled` on every launch, and the property's `didSet` **persisted** the change — so the user's choice was erased between sessions.
2. `TranscriptionPipeline` gated the enhancement branch on it, so a toggle reading ON still never enhanced.
3. `PowerModeSessionManager.applyConfiguration` cleared it again on every Power Mode switch. The seeded default config matched when nothing else did, so this fired on essentially every recording.

The same migration also pinned `EnhancementTimeoutSeconds = 2` with retry off. Two seconds is shorter than almost any LLM round-trip, so anything that did run timed out and silently pasted the raw transcript.

**Net effect: AI enhancement was dead product-wide while its toggle read ON.**

## The design

`DictationOutputMode` replaces the flag with three explicit cases:

| Mode | Behaviour |
|---|---|
| `instant` | Paste raw, never enhance. Byte-for-byte the old fast path. |
| `instantRefine` | Paste raw immediately, then replace it in place when the enhancement returns. |
| `enhanced` | Wait for the enhancement, paste once. |

Enhancement is slow only because of *where* it sat. Moving it after the paste costs the paste path nothing.

## Refine mechanism

`Zerm/Services/TextReplacement/` — modelled on `AutoLearnVocabularyService`, which had the same AX shape and (worth knowing) **has never had a single call site**, so it was a style reference, not a proven one.

- `AXTextAnchor` — captures the focused element and caret *before* the paste, then confirms where the text landed by polling `kAXSelectedTextRange` and reading the range back.
- `TargetAppCapabilities` — decides whether in-place replacement is even possible; caches the verdict per bundle ID.
- `AXTextReplacer` — the gates, and the two-call selection-then-write replacement.
- `RefineInPlaceCoordinator` — owns the lifecycle: value-change observer, app-switch bail-out, hard 10 s deadline, fallback.

### Non-negotiable details

- **`AXUIElementSetMessagingTimeout(element, 0.15)` on every handle.** Accessibility reads are synchronous IPC; the default timeout is six seconds, which against a wedged app would freeze Zerm. Capture also runs off the main actor.
- **All range arithmetic in UTF-16 code units**, never `String.count`. An emoji is one Character but two code units and a flag is four; measuring with `count` leaves the replacement range short and overwrites the wrong span. Covered by `ZermTests/RefineInPlaceTests.swift`.
- **`CFEqual` to compare `AXUIElement`, not `==`** — the latter compares references. Some Chromium/WebKit hosts return a fresh wrapper per query and compare unequal, which is a false negative, i.e. the safe direction.
- **The decisive gate** is that the string still at the recorded range is byte-identical to what was pasted. AX ranges are absolute: an edit *before* the range shifts it and the check fails; an edit *after* leaves the offsets valid and replacing is still correct.
- **Minimum 12 UTF-16 units.** Below that an accidental match on a shifted range stops being far-fetched.

### Where it actually works

| Class | In-place replacement |
|---|---|
| Native AppKit text (TextEdit, Notes, Mail, Xcode) | Yes — the happy path |
| Electron (Slack, VS Code, Cursor, Discord, Notion) | **No.** Chromium exposes no working `AXSelectedText` setter, and contenteditable exposes nothing settable |
| Browser web content | **No**, beyond simple form controls |
| Terminals / TUIs | **Hard deny-list.** The shell owns the line buffer; AX mirrors a read-only screen |
| Secure fields, or any time `IsSecureEventInputEnabled()` | Never read, never write |

The fallback is therefore the *usual* path, not an edge case: the refined text is persisted to the record and offered via a notification with a Copy action. It is never placed on the clipboard unasked.

**Every gate fails closed. The design can fail to improve the text; it cannot corrupt it.**

## Interactions that bite

- **Auto-send is incompatible.** The field is submitted ~500 ms after the paste, so there is nothing left to refine. When a Power Mode has an auto-send key, the mode degrades to `.enhanced` — decided at mode-resolution time, not at paste time.
- **`SelectedTextService.fetchSelectedText()` posts a synthetic ⌘C** and is called from `getSystemMessage`. During a background refine that would fire while the user is typing. `EnhancementContextPolicy.minimal` suppresses it, and screen capture, for refine.
- **`LlamaEngine` is an `actor`**, so a refine serialises against a Read Aloud rewrite. `RefineInPlaceCoordinator.shouldYield` cancels the refine when Read Aloud starts — Read Aloud is user-initiated, refine is speculative.
- **`scheduleWhisperIdleUnload`** only guarded on `recordingState == .idle`, which is true during a refine. It now also checks `isRefining`.
- **Power Mode enhancement** is now a tri-state (`PowerModeEnhancementOverride`: inherit / on / off). The old bool could not express "leave it alone", which is what made every Power Mode clobber the global toggle. Legacy configs decode `true → .on` and `false → .inherit`, because a `false` was almost always the seeded default rather than a deliberate choice.

## Budgets

- Anchor capture runs concurrently with the clipboard write and resolves inside the pre-paste delay that already existed. **Zero added time on the paste path.**
- The on-device model is pre-warmed at record start (`LocalLLMModelManager.prewarm()`, split out from the Read-Aloud-gated `prewarmIfNeeded()`), so it is resident when transcription ends.
- Refine timeout is a fixed 4 s and deliberately not user-configurable — a refinement landing after the user has moved on is worthless. `EnhancementTimeoutSeconds` (now defaulting to 15) applies only to `.enhanced`, where someone is actually waiting.

Related: [[Zerm Latency Budget]], [[Zerm On-Device LLM]], [[Zerm Auto Paste]], [[Zerm Usage Statistics]], [[Zerm Native Writing Layer Verification]]
