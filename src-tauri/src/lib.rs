mod audio;
mod hotkey;
mod ollama;
mod state;
mod whisper;

use anyhow::{anyhow, Result};
use parking_lot::Mutex;
use serde::Serialize;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Arc;
use tauri::menu::{Menu, MenuItem, PredefinedMenuItem};
use tauri::tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent};
use tauri::{
    AppHandle, Emitter, Manager, PhysicalPosition, WebviewUrl, WebviewWindow, WebviewWindowBuilder,
};

use state::{DashboardData, HotkeyChoice, PersistentState, PillPosition, PromptMode};

const READY_EVENT: &str = "zerm://ready";
const ERROR_EVENT: &str = "zerm://error";
const RECORDING_EVENT: &str = "zerm://recording-start";
const PROCESSING_EVENT: &str = "zerm://processing-start";
const TRANSCRIPT_EVENT: &str = "zerm://transcript";
const DONE_EVENT: &str = "zerm://done";
const DASHBOARD_UPDATED_EVENT: &str = "zerm://dashboard-updated";
const AUDIO_LEVEL_EVENT: &str = "zerm://audio-level";

// Set before calling app.exit(0) so the RunEvent::ExitRequested handler
// below knows this is an intentional quit, not a last-window-closed event.
static INTENTIONAL_QUIT: AtomicBool = AtomicBool::new(false);

// Monotonic job counter so a fresh recording can invalidate in-flight
// processing from a previous recording — prevents stale auto-paste after
// the user tabs away.
static NEXT_JOB_ID: AtomicU64 = AtomicU64::new(1);
static CURRENT_JOB_ID: AtomicU64 = AtomicU64::new(0);

// Known-good SHA-256 digest and max byte size for the Whisper model we ship.
// Pinned so that a compromised CDN or repo commit can't silently swap in a
// different file. Confirmed against Hugging Face LFS metadata (see
// ggerganov/whisper.cpp on HF for the `ggml-small.bin` LFS oid).
const WHISPER_SMALL_SHA256: &str =
    "1be3a9b2063867b937e64e2ec7483364a79917e157fa98c5d94b5c1fffea987b";
const WHISPER_SMALL_MAX_BYTES: u64 = 500_000_000;
// Pinned to a commit rather than `main` so the repo owner can't rev the
// file under the pinned digest without also changing the URL.
// Commit-pinned so the repo owner can't swap the bytes under this URL.
// Verified: ggerganov/whisper.cpp LFS oid at this revision matches the
// SHA-256 we pin above. If this revision ever 404s, bump both together.
const WHISPER_SMALL_URL: &str =
    "https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-small.bin";
const PILL_WIDTH: i32 = 240;
const PILL_HEIGHT: i32 = 74;
const STATE_FILE: &str = "zerm-state.json";

#[derive(Clone, Debug, PartialEq, Eq)]
struct FocusIdentity {
    pid: u32,
    bundle_id: String,
}

#[derive(Clone, Serialize)]
struct DonePayload {
    transcript: String,
    output: String,
}

struct Pipeline {
    whisper: Arc<Mutex<Option<whisper::Whisper>>>,
    audio_buffer: Arc<Mutex<Vec<f32>>>,
    capture: Arc<Mutex<Option<audio::CaptureHandle>>>,
    recording: Arc<AtomicBool>,
    active_job_id: Arc<AtomicU64>,
    paste_target: Arc<Mutex<Option<FocusIdentity>>>,
    tray_anchor: Arc<Mutex<Option<PhysicalPosition<f64>>>>,
    persistent: Arc<Mutex<PersistentState>>,
    state_path: Arc<Mutex<Option<PathBuf>>>,
}

impl Pipeline {
    fn new() -> Self {
        Self {
            whisper: Arc::new(Mutex::new(None)),
            audio_buffer: Arc::new(Mutex::new(Vec::with_capacity(48_000 * 30))),
            capture: Arc::new(Mutex::new(None)),
            recording: Arc::new(AtomicBool::new(false)),
            active_job_id: Arc::new(AtomicU64::new(0)),
            paste_target: Arc::new(Mutex::new(None)),
            tray_anchor: Arc::new(Mutex::new(None)),
            persistent: Arc::new(Mutex::new(PersistentState::default())),
            state_path: Arc::new(Mutex::new(None)),
        }
    }

    /// Serialize state snapshots and writes in one ordered critical section.
    /// The previous detached-thread version serialized filesystem writes but
    /// could still let an older snapshot land after a newer setting.
    fn save_persistent_result(&self, remove_backup: bool) -> Result<()> {
        static SAVE_GUARD: once_cell::sync::Lazy<std::sync::Mutex<()>> =
            once_cell::sync::Lazy::new(|| std::sync::Mutex::new(()));

        let _guard = SAVE_GUARD.lock().expect("save lock poisoned");
        let path = self.state_path.lock().clone();
        let snapshot = self.persistent.lock().clone();
        let Some(p) = path else {
            if remove_backup {
                return Err(anyhow!("state path is unavailable; cannot erase backup"));
            }
            return Ok(());
        };

        snapshot.save(&p)?;
        if remove_backup {
            PersistentState::remove_backup(&p)?;
        }
        Ok(())
    }

    fn save_persistent(&self) {
        if let Err(e) = self.save_persistent_result(false) {
            log::error!("failed to save state: {e:#}");
        }
    }

    fn save_persistent_erasing_backup(&self) -> Result<()> {
        self.save_persistent_result(true)
    }
}

fn whisper_candidates() -> &'static [&'static str] {
    &["ggml-medium.bin", "ggml-small.bin", "ggml-small.en.bin"]
}

fn user_models_dir(app: &AppHandle) -> Option<PathBuf> {
    app.path().app_data_dir().ok().map(|d| d.join("models"))
}

fn dev_models_dir() -> PathBuf {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    manifest_dir
        .parent()
        .map(|p| p.join("models"))
        .unwrap_or_else(|| PathBuf::from("models"))
}

fn whisper_model_path(app: &AppHandle) -> PathBuf {
    if let Ok(p) = std::env::var("ZERM_WHISPER_MODEL") {
        return PathBuf::from(p);
    }
    // Prefer the user's app-data dir (where the auto-downloader writes), then
    // fall back to the dev `models/` directory next to the source tree.
    let dirs: Vec<PathBuf> = [user_models_dir(app), Some(dev_models_dir())]
        .into_iter()
        .flatten()
        .collect();
    for dir in &dirs {
        for candidate in whisper_candidates() {
            let path = dir.join(candidate);
            if path.exists() {
                return path;
            }
        }
    }
    // Fallback path that won't exist — the load will error and the user gets
    // the missing-model banner with a download button.
    dirs.first()
        .cloned()
        .unwrap_or_else(dev_models_dir)
        .join("ggml-small.bin")
}

/// Languages where our current default (`gemma3:4b`) is too weak —
/// especially when the speaker mixes the local language with English
/// technical terms. For these we auto-upgrade to a multilingual-first
/// model if the user hasn't explicitly overridden `llm_model`.
fn is_multilingual_heavy(lang: &str) -> bool {
    matches!(
        lang,
        "he" | "ru" | "ar" | "fa" | "ur" | "zh" | "ja" | "ko" | "th" | "hi" | "bn" | "el"
    )
}

/// Model to use for a given detected language, honoring ZERM_LLM_MODEL
/// and the persisted `llm_model` setting first; falling back to
/// `aya-expanse:8b` for Hebrew/Russian/Arabic/CJK and `gemma3:4b` for
/// Latin-script languages.
fn llm_model_for_lang(pipeline: &Pipeline, lang: &str) -> String {
    if let Ok(env) = std::env::var("ZERM_LLM_MODEL") {
        return env;
    }
    let user_set = pipeline.persistent.lock().settings.llm_model.clone();
    if user_set != "gemma3:4b" {
        // User has an explicit override; respect it.
        return user_set;
    }
    if is_multilingual_heavy(lang) {
        "aya-expanse:8b".to_string()
    } else {
        "gemma3:4b".to_string()
    }
}

fn current_llm_model(pipeline: &Pipeline) -> String {
    if let Ok(env) = std::env::var("ZERM_LLM_MODEL") {
        return env;
    }
    pipeline.persistent.lock().settings.llm_model.clone()
}

fn copy_to_clipboard(text: &str) -> Result<()> {
    let mut clipboard = arboard::Clipboard::new()?;
    clipboard.set_text(text.to_string())?;
    Ok(())
}

#[cfg(target_os = "macos")]
fn frontmost_focus_identity() -> Option<FocusIdentity> {
    let script = r#"
tell application "System Events"
  set frontApp to first application process whose frontmost is true
  set frontPid to unix id of frontApp
  try
    set frontBundle to bundle identifier of frontApp
  on error
    set frontBundle to ""
  end try
  return (frontPid as text) & tab & frontBundle
end tell
"#;
    let out = std::process::Command::new("osascript")
        .args(["-e", script])
        .output()
        .ok()?;
    if !out.status.success() {
        log::warn!(
            "auto-paste: could not read frontmost app: {}",
            String::from_utf8_lossy(&out.stderr)
        );
        return None;
    }
    let stdout = String::from_utf8_lossy(&out.stdout);
    let mut parts = stdout.trim().split('\t');
    let pid = parts.next()?.parse::<u32>().ok()?;
    let bundle_id = parts.next().unwrap_or("").trim().to_string();
    Some(FocusIdentity { pid, bundle_id })
}

#[cfg(not(target_os = "macos"))]
fn frontmost_focus_identity() -> Option<FocusIdentity> {
    None
}

#[cfg(target_os = "macos")]
fn focus_still_matches(expected: &FocusIdentity) -> bool {
    match frontmost_focus_identity() {
        Some(current) if &current == expected => true,
        Some(current) => {
            log::warn!(
                "auto-paste cancelled: focus changed from {:?} to {:?}",
                expected,
                current
            );
            false
        }
        None => {
            log::warn!("auto-paste cancelled: could not verify focused app");
            false
        }
    }
}

#[cfg(not(target_os = "macos"))]
fn focus_still_matches(_expected: &FocusIdentity) -> bool {
    false
}

/// Send a Cmd+V keystroke to the currently focused application via
/// CoreGraphics. We never grab focus ourselves (the pill has `focus: false`),
/// so the previously focused app is still the recipient. If nothing is focused
/// for text input the keystroke is a no-op.
#[cfg(target_os = "macos")]
fn send_paste_keystroke(expected: FocusIdentity) {
    use core_graphics::event::{CGEvent, CGEventFlags, CGEventTapLocation, KeyCode};
    use core_graphics::event_source::{CGEventSource, CGEventSourceStateID};

    if !focus_still_matches(&expected) {
        return;
    }

    let source = match CGEventSource::new(CGEventSourceStateID::HIDSystemState) {
        Ok(source) => source,
        Err(()) => {
            log::warn!("auto-paste: could not create CoreGraphics event source");
            return;
        }
    };

    let command_flag = CGEventFlags::CGEventFlagCommand;
    let command_down = match CGEvent::new_keyboard_event(source.clone(), KeyCode::COMMAND, true) {
        Ok(event) => event,
        Err(()) => {
            log::warn!("auto-paste: could not create Command key-down event");
            return;
        }
    };
    let key_down = match CGEvent::new_keyboard_event(source.clone(), KeyCode::ANSI_V, true) {
        Ok(event) => event,
        Err(()) => {
            log::warn!("auto-paste: could not create Cmd+V key-down event");
            return;
        }
    };
    let key_up = match CGEvent::new_keyboard_event(source.clone(), KeyCode::ANSI_V, false) {
        Ok(event) => event,
        Err(()) => {
            log::warn!("auto-paste: could not create Cmd+V key-up event");
            return;
        }
    };
    let command_up = match CGEvent::new_keyboard_event(source, KeyCode::COMMAND, false) {
        Ok(event) => event,
        Err(()) => {
            log::warn!("auto-paste: could not create Command key-up event");
            return;
        }
    };

    command_down.set_flags(command_flag);
    key_down.set_flags(command_flag);
    key_up.set_flags(command_flag);
    command_up.set_flags(CGEventFlags::CGEventFlagNull);
    command_down.post(CGEventTapLocation::HID);
    key_down.post(CGEventTapLocation::HID);
    key_up.post(CGEventTapLocation::HID);
    command_up.post(CGEventTapLocation::HID);
}

#[cfg(not(target_os = "macos"))]
fn send_paste_keystroke(_expected: FocusIdentity) {
    // TODO: cross-platform keystroke synthesis (Win: SendInput; Linux: xdotool/wtype)
    log::debug!("auto-paste: not implemented on this platform yet");
}

fn emit_error(app: &AppHandle, msg: impl Into<String>) {
    let msg = msg.into();
    log::error!("{msg}");
    let _ = app.emit(ERROR_EVENT, msg);
}

fn emit_dashboard_update(app: &AppHandle) {
    if let Some(state) = app.try_state::<Arc<Pipeline>>() {
        let data = state.persistent.lock().dashboard();
        let _ = app.emit(DASHBOARD_UPDATED_EVENT, data);
    }
}

fn show_pill(app: &AppHandle, _pipeline: &Pipeline) {
    let Some(window) = app.get_webview_window("main") else {
        return;
    };
    // Don't reposition — the user may have dragged the pill to a preferred spot.
    let _ = window.show();
    let _ = window.set_always_on_top(true);
}

#[cfg(target_os = "macos")]
fn enable_window_drag(window: &WebviewWindow) {
    use objc2::msg_send;
    use objc2::runtime::AnyObject;
    let Ok(ptr) = window.ns_window() else {
        return;
    };
    if ptr.is_null() {
        return;
    }
    unsafe {
        let obj: *mut AnyObject = ptr.cast();
        let _: () = msg_send![obj, setMovable: true];
        let _: () = msg_send![obj, setMovableByWindowBackground: true];
    }
}

#[cfg(not(target_os = "macos"))]
fn enable_window_drag(_window: &WebviewWindow) {}

fn hide_pill(app: &AppHandle) {
    if let Some(window) = app.get_webview_window("main") {
        let _ = window.hide();
    }
}

fn open_dashboard_window(app: &AppHandle) {
    if let Some(window) = app.get_webview_window("dashboard") {
        let _ = window.show();
        let _ = window.set_focus();
        return;
    }
    let result =
        WebviewWindowBuilder::new(app, "dashboard", WebviewUrl::App("dashboard.html".into()))
            .title("Zerm")
            .inner_size(820.0, 560.0)
            .min_inner_size(640.0, 460.0)
            .center()
            .resizable(true)
            .decorations(true)
            .visible(true)
            .build();
    if let Err(e) = result {
        emit_error(app, format!("failed to open dashboard: {e:#}"));
    }
}

fn handle_toggle(app: &AppHandle, pipeline: &Pipeline) {
    // compare_exchange instead of fetch_xor: if the user manually stops
    // at the exact moment VAD/hard-limit auto-stop fires, the two
    // "stop" attempts must not compose into a net "start". Only the
    // first one that actually observes the matching prior state wins;
    // the loser is a no-op.
    if pipeline
        .recording
        .compare_exchange(false, true, Ordering::SeqCst, Ordering::SeqCst)
        .is_ok()
    {
        log::info!("toggle → start");
        handle_press(app, pipeline);
        return;
    }
    if pipeline
        .recording
        .compare_exchange(true, false, Ordering::SeqCst, Ordering::SeqCst)
        .is_ok()
    {
        log::info!("toggle → stop");
        handle_release(app, pipeline);
        return;
    }
    // Lost both races. Another toggle claimed whatever transition we
    // were about to make; drop silently so auto-stop + manual-stop
    // concurrent firings don't double-bounce.
    log::debug!("toggle lost race, no-op");
}

fn handle_press(app: &AppHandle, pipeline: &Pipeline) {
    if pipeline.whisper.lock().is_none() {
        pipeline.recording.store(false, Ordering::SeqCst);
        emit_error(
            app,
            "Whisper is still loading. Open the dashboard to finish setup.",
        );
        open_dashboard_window(app);
        return;
    }

    pipeline.audio_buffer.lock().clear();

    // Invalidate any in-flight previous recording so its eventual paste
    // can't fire. We bump CURRENT_JOB_ID at press time — not at release —
    // so a user can press-A, press-B before A's processing finishes and
    // A still gets cancelled from pasting.
    let job_id = NEXT_JOB_ID.fetch_add(1, Ordering::SeqCst);
    CURRENT_JOB_ID.store(job_id, Ordering::SeqCst);
    pipeline.active_job_id.store(job_id, Ordering::SeqCst);
    *pipeline.paste_target.lock() = frontmost_focus_identity();

    let vad_enabled = pipeline.persistent.lock().settings.vad_enabled;
    let app_for_stop = app.clone();

    let result = audio::start_capture(pipeline.audio_buffer.clone(), move |reason| {
        // The hard-length limit MUST stop the pipeline regardless of VAD
        // setting — otherwise with VAD off we'd quietly drop the mic
        // stream at 20min and leave the app marked "recording" forever.
        if matches!(reason, audio::StopReason::Silence) && !vad_enabled {
            return;
        }
        let app = app_for_stop.clone();
        tauri::async_runtime::spawn(async move {
            if let Some(state) = app.try_state::<Arc<Pipeline>>() {
                handle_toggle(&app, &state);
            }
        });
    });

    match result {
        Ok(handle) => {
            let level = handle.level.clone();
            *pipeline.capture.lock() = Some(handle);
            show_pill(app, pipeline);
            let _ = app.emit(RECORDING_EVENT, ());

            // Spawn audio-level emitter at ~30fps while recording
            let app_for_level = app.clone();
            let recording_flag = pipeline.recording.clone();
            tauri::async_runtime::spawn(async move {
                let mut interval = tokio::time::interval(std::time::Duration::from_millis(33));
                while recording_flag.load(Ordering::SeqCst) {
                    interval.tick().await;
                    let lvl = *level.lock();
                    let _ = app_for_level.emit(AUDIO_LEVEL_EVENT, lvl);
                }
                // One last "0" to settle the bars
                let _ = app_for_level.emit(AUDIO_LEVEL_EVENT, 0.0_f32);
            });
        }
        Err(e) => {
            pipeline.recording.store(false, Ordering::SeqCst);
            *pipeline.paste_target.lock() = None;
            emit_error(app, format!("audio capture failed: {e:#}"));
        }
    }
}

fn handle_release(app: &AppHandle, pipeline: &Pipeline) {
    let capture = pipeline.capture.lock().take();
    let (sample_rate, channels) = if let Some(handle) = capture {
        let sr = handle.sample_rate;
        let ch = handle.channels;
        let _ = handle.stop.send(());
        (sr, ch)
    } else {
        return;
    };

    let _ = app.emit(PROCESSING_EVENT, ());

    // Job id was allocated at press time. Processing keeps that id; an
    // intervening press bumped CURRENT_JOB_ID past ours, so auto-paste
    // will self-cancel when process() compares.
    let job_id = pipeline.active_job_id.load(Ordering::SeqCst);

    let raw = std::mem::take(&mut *pipeline.audio_buffer.lock());
    let app_clone = app.clone();
    let whisper = pipeline.whisper.clone();
    let pipeline_for_model = Arc::clone(
        // `pipeline: &Pipeline` is behind Tauri's state::<Arc<Pipeline>>()
        // so the caller side gives us an Arc to re-clone.
        &app.state::<Arc<Pipeline>>().inner().clone(),
    );
    let (prompt_mode, vocabulary, allow_unverified_ollama) = {
        let p = pipeline.persistent.lock();
        (
            p.settings.prompt_mode,
            p.settings.vocabulary.join(", "),
            p.settings.allow_unverified_ollama,
        )
    };

    let job = ProcessJob {
        raw,
        sample_rate,
        channels,
        prompt_mode,
        vocabulary,
        allow_unverified_ollama,
        job_id,
    };

    tauri::async_runtime::spawn(async move {
        let result = process(&app_clone, whisper, pipeline_for_model, job).await;
        if let Err(e) = result {
            emit_error(&app_clone, format!("processing failed: {e:#}"));
        }
    });
}

struct ProcessJob {
    raw: Vec<f32>,
    sample_rate: u32,
    channels: u16,
    prompt_mode: PromptMode,
    vocabulary: String,
    allow_unverified_ollama: bool,
    job_id: u64,
}

async fn process(
    app: &AppHandle,
    whisper: Arc<Mutex<Option<whisper::Whisper>>>,
    pipeline: Arc<Pipeline>,
    job: ProcessJob,
) -> Result<()> {
    let ProcessJob {
        raw,
        sample_rate,
        channels,
        prompt_mode,
        vocabulary,
        allow_unverified_ollama,
        job_id,
    } = job;

    if raw.len() < (sample_rate as usize) / 4 {
        log::warn!("audio too short ({} samples), skipping", raw.len());
        let _ = app.emit(
            DONE_EVENT,
            DonePayload {
                transcript: String::new(),
                output: String::new(),
            },
        );
        return Ok(());
    }

    let prepared = tauri::async_runtime::spawn_blocking(move || {
        audio::prepare_for_whisper(&raw, sample_rate, channels)
    })
    .await?;

    let whisper_for_blocking = whisper.clone();
    let initial_prompt = if vocabulary.trim().is_empty() {
        None
    } else {
        Some(format!("Vocabulary: {}", vocabulary.trim()))
    };
    let (raw_transcript, detected_lang) =
        tauri::async_runtime::spawn_blocking(move || -> Result<(String, String)> {
            let guard = whisper_for_blocking.lock();
            let w = guard
                .as_ref()
                .ok_or_else(|| anyhow::anyhow!("whisper model not loaded yet"))?;
            w.transcribe_with_options(&prepared, None, initial_prompt.as_deref())
        })
        .await??;

    log::info!("detected language: {detected_lang}");
    let transcript = state::strip_whisper_tokens(&raw_transcript);
    // Transcripts contain dictated text which may include secrets (PII,
    // credentials, draft messages). Keep them out of info-level logs.
    log::debug!("transcript ({} chars)", transcript.len());
    let _ = app.emit(TRANSCRIPT_EVENT, transcript.clone());

    if transcript.is_empty() {
        let _ = app.emit(
            DONE_EVENT,
            DonePayload {
                transcript: String::new(),
                output: String::new(),
            },
        );
        return Ok(());
    }

    // Pick the model based on the detected language. Hebrew/Russian/CJK
    // auto-upgrade to `aya-expanse:8b` (a multilingual-first model) if
    // the user hasn't explicitly overridden `llm_model`. Latin scripts
    // keep the faster `gemma3:4b` default.
    let llm_model = llm_model_for_lang(&pipeline, &detected_lang);
    log::info!("using llm model: {llm_model} (lang={detected_lang})");

    let output = if matches!(prompt_mode, PromptMode::Off)
        && ollama::system_prompt_for_lang(prompt_mode, &detected_lang).is_some()
    {
        // Off mode on a non-Latin script still gets a bespoke minimal-
        // cleanup pass (the language-specific prompt already IS light-touch).
        log::info!("non-latin Off mode → language-specific cleanup");
        match ollama::reformat_lang(
            &llm_model,
            &transcript,
            prompt_mode,
            &detected_lang,
            allow_unverified_ollama,
        )
        .await
        {
            Ok(t) => t,
            Err(e) => {
                log::warn!("lang-specific cleanup failed, using raw: {e:#}");
                transcript.clone()
            }
        }
    } else {
        match ollama::reformat_lang(
            &llm_model,
            &transcript,
            prompt_mode,
            &detected_lang,
            allow_unverified_ollama,
        )
        .await
        {
            Ok(t) => t,
            Err(e) => {
                log::warn!("ollama reformat failed, falling back to raw: {e:#}");
                emit_error(app, format!("ollama: {e:#} (using raw transcript)"));
                transcript.clone()
            }
        }
    };

    // Gate ALL user-visible side effects on the still-current check.
    // If the user started a new recording while we were in Whisper or
    // Ollama, we must not overwrite their clipboard, paste anything,
    // emit a "Copied" UI state, or append to history. The stale job
    // finishes silently.
    let still_current = CURRENT_JOB_ID.load(Ordering::SeqCst) == job_id;
    if !still_current {
        log::info!(
            "job {job_id} is stale (newer recording started); skipping clipboard + history + paste"
        );
        return Ok(());
    }

    if let Err(e) = copy_to_clipboard(&output) {
        emit_error(app, format!("clipboard: {e:#}"));
    }

    let (auto_paste, save_history) = app
        .try_state::<Arc<Pipeline>>()
        .map(|s| {
            let p = s.persistent.lock();
            (p.settings.auto_paste, p.settings.save_history)
        })
        .unwrap_or((false, true));

    if auto_paste && !output.is_empty() {
        tokio::time::sleep(std::time::Duration::from_millis(70)).await;
        // Re-check inside the delay window — user may have Cmd-tabbed
        // during the 70ms and triggered another recording.
        if CURRENT_JOB_ID.load(Ordering::SeqCst) == job_id {
            let paste_target = pipeline.paste_target.lock().clone();
            if let Some(expected) = paste_target {
                tauri::async_runtime::spawn_blocking(move || send_paste_keystroke(expected));
            } else {
                log::warn!("auto-paste cancelled: focused app was not captured at recording start");
            }
        }
    }

    if save_history {
        if let Some(state) = app.try_state::<Arc<Pipeline>>() {
            state
                .persistent
                .lock()
                .record(transcript.clone(), output.clone());
            state.save_persistent();
        }
    }
    emit_dashboard_update(app);

    let _ = app.emit(DONE_EVENT, DonePayload { transcript, output });
    Ok(())
}

fn build_tray(app: &tauri::App, pipeline: Arc<Pipeline>) -> tauri::Result<()> {
    let app_handle = app.handle().clone();

    let toggle_item =
        MenuItem::with_id(app, "toggle", "Start / Stop Recording", true, None::<&str>)?;
    let dashboard_item =
        MenuItem::with_id(app, "dashboard", "Open Zerm Dashboard…", true, None::<&str>)?;
    let separator = PredefinedMenuItem::separator(app)?;
    let quit_item = MenuItem::with_id(app, "quit", "Quit Zerm", true, None::<&str>)?;
    let menu = Menu::with_items(
        app,
        &[&toggle_item, &dashboard_item, &separator, &quit_item],
    )?;

    let pipeline_for_menu = pipeline.clone();
    let pipeline_for_click = pipeline.clone();
    let app_for_menu = app_handle.clone();
    let app_for_click = app_handle.clone();
    let tray_anchor = pipeline.tray_anchor.clone();

    let tray = TrayIconBuilder::with_id("zerm-tray")
        .icon(app.default_window_icon().unwrap().clone())
        .icon_as_template(true)
        .menu(&menu)
        .show_menu_on_left_click(false)
        .tooltip("Zerm — voice to clipboard")
        .on_menu_event(move |app, event| match event.id.as_ref() {
            "quit" => {
                INTENTIONAL_QUIT.store(true, Ordering::SeqCst);
                app.exit(0);
            }
            "toggle" => handle_toggle(&app_for_menu, &pipeline_for_menu),
            "dashboard" => open_dashboard_window(&app_for_menu),
            _ => {}
        })
        .on_tray_icon_event(move |tray, event| {
            if let Ok(Some(rect)) = tray.rect() {
                if let Some(anchor) = anchor_from_rect(&rect) {
                    *tray_anchor.lock() = Some(anchor);
                }
            }
            if let TrayIconEvent::Click {
                button: MouseButton::Left,
                button_state: MouseButtonState::Up,
                ..
            } = event
            {
                let _ = pipeline_for_click;
                open_dashboard_window(&app_for_click);
            }
        })
        .build(app)?;

    if let Ok(Some(rect)) = tray.rect() {
        if let Some(anchor) = anchor_from_rect(&rect) {
            *pipeline.tray_anchor.lock() = Some(anchor);
        }
    }

    Ok(())
}

fn anchor_from_rect(rect: &tauri::Rect) -> Option<PhysicalPosition<f64>> {
    let (px, py) = match rect.position {
        tauri::Position::Physical(p) => (p.x as f64, p.y as f64),
        tauri::Position::Logical(p) => (p.x, p.y),
    };
    let (sw, sh) = match rect.size {
        tauri::Size::Physical(s) => (s.width as f64, s.height as f64),
        tauri::Size::Logical(s) => (s.width, s.height),
    };
    Some(PhysicalPosition {
        x: px + sw / 2.0,
        y: py + sh,
    })
}

fn clamp_pill_position(window: &WebviewWindow, pos: PillPosition) -> PillPosition {
    let Ok(monitors) = window.available_monitors() else {
        return pos;
    };
    let Some(monitor) = monitors.first() else {
        return pos;
    };

    for monitor in &monitors {
        let origin = monitor.position();
        let size = monitor.size();
        let max_x = origin.x + size.width as i32;
        let max_y = origin.y + size.height as i32;
        let visible_x = pos.x + PILL_WIDTH > origin.x && pos.x < max_x;
        let visible_y = pos.y + PILL_HEIGHT > origin.y && pos.y < max_y;
        if visible_x && visible_y {
            return pos;
        }
    }

    let origin = monitor.position();
    let size = monitor.size();
    let max_x = (origin.x + size.width as i32 - PILL_WIDTH).max(origin.x);
    let max_y = (origin.y + size.height as i32 - PILL_HEIGHT).max(origin.y);
    PillPosition {
        x: pos.x.clamp(origin.x, max_x),
        y: pos.y.clamp(origin.y, max_y),
    }
}

/// Gate every dashboard-only command behind a window-label check.
/// Prevents the always-on-top pill window (label = "main") from being
/// tricked into calling privileged commands like install_ollama or
/// clear_history if its WebView content were ever compromised.
fn require_dashboard(window: &tauri::WebviewWindow) -> Result<(), String> {
    if window.label() == "dashboard" {
        Ok(())
    } else {
        Err(format!(
            "command not permitted from window '{}' (dashboard only)",
            window.label()
        ))
    }
}

fn require_pill(window: &tauri::WebviewWindow) -> Result<(), String> {
    if window.label() == "main" {
        Ok(())
    } else {
        Err(format!(
            "command not permitted from window '{}' (pill only)",
            window.label()
        ))
    }
}

#[tauri::command]
fn pill_done(window: tauri::WebviewWindow, app: AppHandle) {
    // Only the pill should hide itself.
    if window.label() == "main" {
        hide_pill(&app);
    }
}

#[tauri::command]
fn get_dashboard(
    window: tauri::WebviewWindow,
    state: tauri::State<'_, Arc<Pipeline>>,
) -> Result<DashboardData, String> {
    require_dashboard(&window)?;
    Ok(state.persistent.lock().dashboard())
}

#[tauri::command]
fn set_llm_model(
    window: tauri::WebviewWindow,
    model: String,
    app: AppHandle,
    state: tauri::State<'_, Arc<Pipeline>>,
) -> Result<(), String> {
    require_dashboard(&window)?;
    let trimmed = model.trim().to_string();
    if trimmed.is_empty() {
        return Err("model cannot be empty".into());
    }
    state.persistent.lock().settings.llm_model = trimmed;
    state.save_persistent();
    emit_dashboard_update(&app);
    Ok(())
}

#[tauri::command]
fn set_vad_enabled(
    window: tauri::WebviewWindow,
    enabled: bool,
    app: AppHandle,
    state: tauri::State<'_, Arc<Pipeline>>,
) -> Result<(), String> {
    require_dashboard(&window)?;
    state.persistent.lock().settings.vad_enabled = enabled;
    state.save_persistent();
    emit_dashboard_update(&app);
    Ok(())
}

#[tauri::command]
fn set_auto_paste(
    window: tauri::WebviewWindow,
    enabled: bool,
    app: AppHandle,
    state: tauri::State<'_, Arc<Pipeline>>,
) -> Result<(), String> {
    require_dashboard(&window)?;
    state.persistent.lock().settings.auto_paste = enabled;
    state.save_persistent();
    emit_dashboard_update(&app);
    Ok(())
}

#[tauri::command]
fn set_allow_unverified_ollama(
    window: tauri::WebviewWindow,
    enabled: bool,
    app: AppHandle,
    state: tauri::State<'_, Arc<Pipeline>>,
) -> Result<(), String> {
    require_dashboard(&window)?;
    let original = {
        let mut p = state.persistent.lock();
        let original = p.clone();
        p.settings.allow_unverified_ollama = enabled;
        original
    };
    if let Err(e) = state.save_persistent_result(false) {
        *state.persistent.lock() = original;
        return Err(e.to_string());
    }
    emit_dashboard_update(&app);
    Ok(())
}

#[tauri::command]
fn set_save_history(
    window: tauri::WebviewWindow,
    enabled: bool,
    app: AppHandle,
    state: tauri::State<'_, Arc<Pipeline>>,
) -> Result<(), String> {
    require_dashboard(&window)?;
    if enabled {
        state.persistent.lock().settings.save_history = true;
        state.save_persistent();
    } else {
        let original = {
            let mut p = state.persistent.lock();
            let original = p.clone();
            p.settings.save_history = false;
            p.history.clear();
            p.stats = state::Stats::default();
            original
        };
        if let Err(e) = state.save_persistent_erasing_backup() {
            *state.persistent.lock() = original;
            return Err(e.to_string());
        }
    }
    emit_dashboard_update(&app);
    Ok(())
}

#[tauri::command]
fn set_prompt_mode(
    window: tauri::WebviewWindow,
    mode: String,
    app: AppHandle,
    state: tauri::State<'_, Arc<Pipeline>>,
) -> Result<(), String> {
    require_dashboard(&window)?;
    let parsed = match mode.as_str() {
        "off" => PromptMode::Off,
        "developer" | "agent" => PromptMode::Developer, // "agent" kept for back-compat
        "conversational" => PromptMode::Conversational,
        "professional" => PromptMode::Professional,
        other => return Err(format!("unknown prompt mode: {other}")),
    };
    state.persistent.lock().settings.prompt_mode = parsed;
    state.save_persistent();
    emit_dashboard_update(&app);
    Ok(())
}

#[tauri::command]
fn set_hotkey(
    window: tauri::WebviewWindow,
    key: String,
    app: AppHandle,
    state: tauri::State<'_, Arc<Pipeline>>,
) -> Result<(), String> {
    require_dashboard(&window)?;
    #[cfg(not(target_os = "macos"))]
    {
        let _ = key;
        return Err("custom modifier-only hotkeys are only supported on macOS; use Ctrl+Shift+Space on this platform".into());
    }

    #[cfg(target_os = "macos")]
    {
        let choice =
            HotkeyChoice::from_key(&key).ok_or_else(|| format!("unknown hotkey: {key}"))?;
        state.persistent.lock().settings.hotkey = choice;
        state.save_persistent();
        hotkey::set_hotkey(choice.key_code(), choice.flag_bit());
        log::info!("hotkey changed to {}", choice.label());
        emit_dashboard_update(&app);
        Ok(())
    }
}

#[tauri::command]
fn add_vocabulary_term(
    window: tauri::WebviewWindow,
    term: String,
    app: AppHandle,
    state: tauri::State<'_, Arc<Pipeline>>,
) -> Result<(), String> {
    require_dashboard(&window)?;
    let trimmed = term.trim().to_string();
    if trimmed.is_empty() {
        return Err("term cannot be empty".into());
    }
    {
        let mut p = state.persistent.lock();
        let already = p
            .settings
            .vocabulary
            .iter()
            .any(|t| t.eq_ignore_ascii_case(&trimmed));
        if !already {
            p.settings.vocabulary.push(trimmed);
            p.settings.vocabulary.sort_by_key(|a| a.to_lowercase());
        }
    }
    state.save_persistent();
    emit_dashboard_update(&app);
    Ok(())
}

#[tauri::command]
fn remove_vocabulary_term(
    window: tauri::WebviewWindow,
    term: String,
    app: AppHandle,
    state: tauri::State<'_, Arc<Pipeline>>,
) -> Result<(), String> {
    require_dashboard(&window)?;
    {
        let mut p = state.persistent.lock();
        p.settings.vocabulary.retain(|t| t != &term);
    }
    state.save_persistent();
    emit_dashboard_update(&app);
    Ok(())
}

#[tauri::command]
fn clear_vocabulary(
    window: tauri::WebviewWindow,
    app: AppHandle,
    state: tauri::State<'_, Arc<Pipeline>>,
) -> Result<(), String> {
    require_dashboard(&window)?;
    state.persistent.lock().settings.vocabulary.clear();
    state.save_persistent();
    emit_dashboard_update(&app);
    Ok(())
}

#[tauri::command]
fn clear_history(
    window: tauri::WebviewWindow,
    app: AppHandle,
    state: tauri::State<'_, Arc<Pipeline>>,
) -> Result<(), String> {
    require_dashboard(&window)?;
    let original = {
        let mut p = state.persistent.lock();
        let original = p.clone();
        p.history.clear();
        p.stats = state::Stats::default();
        original
    };
    if let Err(e) = state.save_persistent_erasing_backup() {
        *state.persistent.lock() = original;
        return Err(e.to_string());
    }
    emit_dashboard_update(&app);
    Ok(())
}

#[tauri::command]
fn copy_history_entry(
    window: tauri::WebviewWindow,
    timestamp: u64,
    state: tauri::State<'_, Arc<Pipeline>>,
) -> Result<(), String> {
    require_dashboard(&window)?;
    let entry = state
        .persistent
        .lock()
        .history
        .iter()
        .find(|e| e.timestamp == timestamp)
        .cloned();
    match entry {
        Some(e) => {
            let text = if e.output.is_empty() {
                e.transcript
            } else {
                e.output
            };
            copy_to_clipboard(&text).map_err(|err| err.to_string())
        }
        None => Err("history entry not found".into()),
    }
}

#[tauri::command]
fn quit_app(window: tauri::WebviewWindow, app: AppHandle) -> Result<(), String> {
    require_dashboard(&window)?;
    INTENTIONAL_QUIT.store(true, Ordering::SeqCst);
    app.exit(0);
    Ok(())
}

#[tauri::command]
fn set_pill_position(
    window: tauri::WebviewWindow,
    x: i32,
    y: i32,
    state: tauri::State<'_, Arc<Pipeline>>,
) -> Result<(), String> {
    require_pill(&window)?;
    let pos = clamp_pill_position(&window, PillPosition { x, y });
    state.persistent.lock().pill_position = Some(pos);
    state.save_persistent();
    Ok(())
}

#[tauri::command]
fn get_pill_position(
    window: tauri::WebviewWindow,
    state: tauri::State<'_, Arc<Pipeline>>,
) -> Result<Option<PillPosition>, String> {
    require_dashboard(&window)?;
    Ok(state.persistent.lock().pill_position)
}

#[tauri::command]
fn open_dashboard(app: AppHandle) {
    // Allowed from any window — opening the dashboard is how users recover
    // if something goes weird. Not gated.
    open_dashboard_window(&app);
}

#[derive(Clone, Serialize)]
struct SetupStatus {
    whisper_model_present: bool,
    whisper_loaded: bool,
    whisper_model_path: Option<String>,
    ollama_running: bool,
    ollama_model_pulled: bool,
    ollama_model_name: String,
    ollama_identity_warning: Option<String>,
    allow_unverified_ollama: bool,
    hotkey_configurable: bool,
    runtime_hotkey_label: String,
}

#[tauri::command]
async fn check_setup(window: tauri::WebviewWindow, app: AppHandle) -> Result<SetupStatus, String> {
    require_dashboard(&window)?;
    let path = whisper_model_path(&app);
    let whisper_model_present = path.exists();
    let whisper_loaded = app
        .try_state::<Arc<Pipeline>>()
        .map(|state| state.whisper.lock().is_some())
        .unwrap_or(false);
    // Match runtime resolution: env var overrides, otherwise persisted setting,
    // otherwise default. Previously this only honoured the env var so setup
    // could report-and-pull one model while the runtime used another.
    let settings = app
        .try_state::<Arc<Pipeline>>()
        .map(|state| state.persistent.lock().settings.clone());
    let allow_unverified_ollama = settings
        .as_ref()
        .map(|s| s.allow_unverified_ollama)
        .unwrap_or(false);
    let model_name = std::env::var("ZERM_LLM_MODEL")
        .ok()
        .or_else(|| settings.as_ref().map(|s| s.llm_model.clone()))
        .unwrap_or_else(|| "gemma3:4b".to_string());

    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(2))
        .build()
        .ok();
    let identity_report = ollama::verify_identity_report().await.ok();
    let ollama_identity_warning = identity_report
        .as_ref()
        .and_then(|report| report.warning.clone());
    let ollama_identity_ok = identity_report.is_some();
    let (ollama_running, ollama_model_pulled) = match (client, ollama_identity_ok) {
        (Some(c), true) => match c.get("http://127.0.0.1:11434/api/tags").send().await {
            Ok(resp) if resp.status().is_success() => {
                let pulled = resp
                    .json::<serde_json::Value>()
                    .await
                    .ok()
                    .and_then(|v| {
                        v.get("models").and_then(|m| m.as_array()).map(|arr| {
                            arr.iter().any(|m| {
                                m.get("name")
                                    .and_then(|n| n.as_str())
                                    .map(|n| {
                                        n == model_name || n.starts_with(&format!("{model_name}:"))
                                    })
                                    .unwrap_or(false)
                            })
                        })
                    })
                    .unwrap_or(false);
                (true, pulled)
            }
            _ => (false, false),
        },
        _ => (false, false),
    };

    Ok(SetupStatus {
        whisper_model_present,
        whisper_loaded,
        whisper_model_path: Some(path.display().to_string()),
        ollama_running,
        ollama_model_pulled,
        ollama_model_name: model_name,
        ollama_identity_warning,
        allow_unverified_ollama,
        hotkey_configurable: cfg!(target_os = "macos"),
        runtime_hotkey_label: if cfg!(target_os = "macos") {
            app.try_state::<Arc<Pipeline>>()
                .map(|state| state.persistent.lock().settings.hotkey.label().to_string())
                .unwrap_or_else(|| "Right Option".to_string())
        } else {
            "Ctrl+Shift+Space".to_string()
        },
    })
}

#[derive(Clone, Serialize)]
struct DownloadProgress {
    downloaded: u64,
    total: u64,
}

// GitHub Releases API: we ask for the latest release, find the asset
// whose name matches our platform, extract its published `digest`
// (SHA-256), download from that asset's download_url, and verify the
// streamed bytes match the digest before launching anything.
#[cfg(target_os = "macos")]
const OLLAMA_ASSET_NAME: &str = "Ollama-darwin.zip";
#[cfg(target_os = "windows")]
const OLLAMA_ASSET_NAME: &str = "OllamaSetup.exe";

// Hard upper bound; the current Windows installer is roughly 1.9 GB.
const OLLAMA_INSTALLER_MAX_BYTES: u64 = 2_500_000_000;
#[cfg(target_os = "macos")]
const OLLAMA_MACOS_TEAM_ID: &str = "3MU9H2V9Y9";
#[cfg(target_os = "macos")]
const OLLAMA_MACOS_BUNDLE_ID: &str = "com.electron.ollama";
#[cfg(target_os = "windows")]
const OLLAMA_WINDOWS_PUBLISHER_CN: &str = "Ollama Inc.";
#[cfg(target_os = "windows")]
const OLLAMA_WINDOWS_ORG_SERIAL: &str = "2713355";
#[cfg(target_os = "windows")]
const OLLAMA_WINDOWS_ISSUER_CN: &str = "DigiCert G5 CS ECC SHA384 2021 CA1";
#[cfg(target_os = "windows")]
const OLLAMA_WINDOWS_SIGNER_THUMBPRINT: &str = "716CD3BC8C02361431A18F56F98C72DE88066103";

#[cfg(any(target_os = "macos", target_os = "windows"))]
#[derive(serde::Deserialize)]
struct GhAsset {
    name: String,
    browser_download_url: String,
    digest: Option<String>,
}

#[cfg(any(target_os = "macos", target_os = "windows"))]
#[derive(serde::Deserialize)]
struct GhRelease {
    tag_name: String,
    assets: Vec<GhAsset>,
}

#[cfg(target_os = "macos")]
fn verify_macos_app_signature(app_path: &str) -> Result<(), String> {
    let verify = std::process::Command::new("codesign")
        .args(["--verify", "--deep", "--strict", "--verbose=2", app_path])
        .output()
        .map_err(|e| format!("codesign verify: {e}"))?;
    if !verify.status.success() {
        return Err(format!(
            "codesign verify failed: {}",
            String::from_utf8_lossy(&verify.stderr)
        ));
    }

    let details = std::process::Command::new("codesign")
        .args(["-dv", "--verbose=4", app_path])
        .output()
        .map_err(|e| format!("codesign details: {e}"))?;
    let codesign_text = String::from_utf8_lossy(&details.stderr);
    if !codesign_text.contains("Authority=Developer ID Application") {
        return Err("Ollama.app is not signed with a Developer ID Application certificate".into());
    }
    if !codesign_text.contains(&format!("Identifier={OLLAMA_MACOS_BUNDLE_ID}")) {
        return Err("Ollama.app bundle identifier does not match the expected Ollama app".into());
    }
    let team_id = codesign_text
        .lines()
        .find_map(|line| line.strip_prefix("TeamIdentifier="))
        .map(str::trim)
        .filter(|team| !team.is_empty())
        .ok_or_else(|| "Ollama.app signature has no TeamIdentifier".to_string())?;
    if team_id != OLLAMA_MACOS_TEAM_ID {
        return Err(format!(
            "Ollama.app TeamIdentifier mismatch: expected {OLLAMA_MACOS_TEAM_ID}, got {team_id}"
        ));
    }

    let gatekeeper = std::process::Command::new("spctl")
        .args(["-a", "-vv", "-t", "exec", app_path])
        .output()
        .map_err(|e| format!("spctl: {e}"))?;
    if !gatekeeper.status.success() {
        return Err(format!(
            "Gatekeeper rejected Ollama.app: {}{}",
            String::from_utf8_lossy(&gatekeeper.stdout),
            String::from_utf8_lossy(&gatekeeper.stderr)
        ));
    }

    log::info!("verified Ollama.app signature, TeamIdentifier={team_id}");
    Ok(())
}

#[cfg(target_os = "windows")]
fn verify_windows_installer_signature(installer_path: &std::path::Path) -> Result<(), String> {
    let publisher_re = OLLAMA_WINDOWS_PUBLISHER_CN.replace('.', "\\.");
    let issuer_re = OLLAMA_WINDOWS_ISSUER_CN.replace('.', "\\.");
    let script = format!(
        "$s = Get-AuthenticodeSignature -LiteralPath '{}'; \
         if ($s.Status -ne 'Valid') {{ throw \"Authenticode status: $($s.Status)\" }}; \
         $subject = $s.SignerCertificate.Subject; \
         $issuer = $s.SignerCertificate.Issuer; \
         if ($s.SignerCertificate.Thumbprint -ne '{}') {{ throw \"Unexpected signer thumbprint: $($s.SignerCertificate.Thumbprint)\" }}; \
         if ($subject -notmatch 'CN={}' -or $subject -notmatch 'O={}' -or $subject -notmatch 'SERIALNUMBER={}') {{ throw \"Unexpected signer: $subject\" }}; \
         if ($issuer -notmatch 'CN={}') {{ throw \"Unexpected issuer: $issuer\" }}; \
         if (-not ($s.SignerCertificate.EnhancedKeyUsageList | Where-Object {{ $_.FriendlyName -eq 'Code Signing' }})) {{ throw \"Signer certificate is not valid for code signing\" }}; \
         Write-Output $s.SignerCertificate.Subject",
        installer_path.display().to_string().replace('\'', "''"),
        OLLAMA_WINDOWS_SIGNER_THUMBPRINT,
        publisher_re.replace('\'', "''"),
        publisher_re.replace('\'', "''"),
        OLLAMA_WINDOWS_ORG_SERIAL,
        issuer_re.replace('\'', "''"),
    );
    let out = std::process::Command::new("powershell")
        .args(["-NoProfile", "-NonInteractive", "-Command", &script])
        .output()
        .map_err(|e| format!("powershell signature check: {e}"))?;
    if !out.status.success() {
        return Err(format!(
            "Ollama installer signature check failed: {}{}",
            String::from_utf8_lossy(&out.stdout),
            String::from_utf8_lossy(&out.stderr)
        ));
    }
    log::info!(
        "verified Ollama installer Authenticode signer: {}",
        String::from_utf8_lossy(&out.stdout).trim()
    );
    Ok(())
}

#[tauri::command]
async fn install_ollama(window: tauri::WebviewWindow, app: AppHandle) -> Result<(), String> {
    require_dashboard(&window)?;

    // Linux: do NOT fetch + pipe `curl | sh`. Instead open Ollama's
    // download page in the user's browser so they install via their
    // distribution package manager, with sudo prompts under their own
    // shell, reviewable scripts, etc. The remote-shell-script exec
    // path is not acceptable.
    #[cfg(target_os = "linux")]
    {
        let _ = app.emit("zerm://ollama-install-progress", "launching");
        // xdg-open is the de-facto open-URL command on Linux desktops.
        std::process::Command::new("xdg-open")
            .arg("https://ollama.com/download/linux")
            .spawn()
            .map_err(|e| format!("xdg-open: {e}"))?;
        let _ = app.emit("zerm://ollama-install-progress", "done");
        return Ok(());
    }

    #[cfg(any(target_os = "macos", target_os = "windows"))]
    {
        use futures_util::StreamExt;
        use sha2::{Digest, Sha256};
        use tokio::io::AsyncWriteExt;

        let cache_dir = app
            .path()
            .app_cache_dir()
            .map_err(|e| format!("cache dir: {e}"))?;
        tokio::fs::create_dir_all(&cache_dir)
            .await
            .map_err(|e| format!("mkdir: {e}"))?;

        // Step 1. Ask GitHub for the current Ollama release metadata.
        // GitHub ships an authoritative SHA-256 digest per asset via the
        // v3 API (`assets[].digest` of the form "sha256:<hex>"). That
        // becomes our integrity pin — no ongoing hard-coded hash
        // maintenance, but a supply-chain compromise would have to
        // compromise github.com AND the attacker's own CDN in lockstep.
        let _ = app.emit("zerm://ollama-install-progress", "resolving");
        let client = reqwest::Client::builder()
            .timeout(std::time::Duration::from_secs(30))
            .user_agent("Zerm")
            .build()
            .map_err(|e| format!("http client: {e}"))?;
        let release: GhRelease = client
            .get("https://api.github.com/repos/ollama/ollama/releases/latest")
            .header("Accept", "application/vnd.github+json")
            .send()
            .await
            .map_err(|e| format!("gh api: {e}"))?
            .error_for_status()
            .map_err(|e| format!("gh api status: {e}"))?
            .json()
            .await
            .map_err(|e| format!("gh api parse: {e}"))?;
        let asset = release
            .assets
            .iter()
            .find(|a| a.name == OLLAMA_ASSET_NAME)
            .ok_or_else(|| {
                format!(
                    "GitHub release {} has no asset named {OLLAMA_ASSET_NAME}",
                    release.tag_name
                )
            })?;
        let expected_digest = asset
            .digest
            .as_deref()
            .and_then(|d| d.strip_prefix("sha256:"))
            .ok_or_else(|| {
                "GitHub release asset is missing a sha256 digest — refusing to install".to_string()
            })?
            .to_ascii_lowercase();
        let download_url = reqwest::Url::parse(&asset.browser_download_url)
            .map_err(|e| format!("release asset URL parse: {e}"))?;
        if download_url.host_str() != Some("github.com") {
            return Err(format!(
                "refusing Ollama asset from unexpected host: {}",
                download_url.host_str().unwrap_or("<none>")
            ));
        }

        // Step 2. Download the asset into a randomized tempfile within
        // the user's app_cache_dir (never /tmp, never a predictable name),
        // streaming SHA-256 as bytes land.
        let suffix = match std::env::consts::OS {
            "macos" => ".zip",
            "windows" => ".exe",
            _ => "",
        };
        let tmp = tempfile::Builder::new()
            .prefix(".ollama-installer-")
            .suffix(suffix)
            .tempfile_in(&cache_dir)
            .map_err(|e| format!("tempfile: {e}"))?;

        let _ = app.emit("zerm://ollama-install-progress", "downloading");
        let resp = client
            .get(download_url)
            .send()
            .await
            .map_err(|e| format!("request: {e}"))?
            .error_for_status()
            .map_err(|e| format!("status: {e}"))?;
        let total_bytes = resp.content_length();
        if let Some(len) = total_bytes {
            if len > OLLAMA_INSTALLER_MAX_BYTES {
                return Err(format!(
                    "refusing: content-length {len} exceeds cap {OLLAMA_INSTALLER_MAX_BYTES}"
                ));
            }
        }

        let std_tmp = tmp.reopen().map_err(|e| format!("reopen: {e}"))?;
        let mut file = tokio::fs::File::from_std(std_tmp);
        let mut stream = resp.bytes_stream();
        let mut hasher = Sha256::new();
        let mut written: u64 = 0;
        while let Some(chunk) = stream.next().await {
            let chunk = chunk.map_err(|e| format!("chunk: {e}"))?;
            written += chunk.len() as u64;
            if written > OLLAMA_INSTALLER_MAX_BYTES {
                return Err(format!(
                    "refusing: download exceeded {OLLAMA_INSTALLER_MAX_BYTES} byte cap"
                ));
            }
            hasher.update(&chunk);
            file.write_all(&chunk)
                .await
                .map_err(|e| format!("write: {e}"))?;
            if let Some(total) = total_bytes {
                let _ = app.emit(
                    "zerm://ollama-install-progress",
                    serde_json::json!({
                        "status": "downloading",
                        "downloaded": written,
                        "total": total
                    }),
                );
            }
        }
        file.flush().await.map_err(|e| format!("flush: {e}"))?;
        file.sync_all().await.map_err(|e| format!("sync: {e}"))?;
        drop(file);

        // Step 3. Verify the streamed hash matches the GitHub-published
        // digest BEFORE anything executes.
        let got = hex::encode(hasher.finalize());
        if got != expected_digest {
            return Err(format!(
                "Ollama installer hash mismatch — refusing to launch. \
                 expected sha256 {expected_digest}, got {got}. \
                 (Release tag: {})",
                release.tag_name
            ));
        }

        let persist_name = match std::env::consts::OS {
            "macos" => "Ollama-installer.zip",
            "windows" => "OllamaSetup.exe",
            _ => "ollama-installer",
        };
        let persisted = cache_dir.join(persist_name);
        let _ = tmp
            .persist(&persisted)
            .map_err(|e| format!("persist: {}", e.error))?;
        let installer_path = cache_dir.join(persist_name);

        let _ = app.emit("zerm://ollama-install-progress", "launching");

        #[cfg(target_os = "macos")]
        {
            let extract_dir = tempfile::Builder::new()
                .prefix(".ollama-extract-")
                .tempdir_in(&cache_dir)
                .map_err(|e| format!("extract tempdir: {e}"))?;
            let status = std::process::Command::new("unzip")
                .args([
                    "-o",
                    installer_path.to_str().unwrap(),
                    "-d",
                    extract_dir.path().to_str().unwrap(),
                ])
                .status()
                .map_err(|e| format!("unzip: {e}"))?;
            if !status.success() {
                return Err(format!("unzip exited {status}"));
            }
            let extracted_app = extract_dir.path().join("Ollama.app");
            let extracted_app_str = extracted_app
                .to_str()
                .ok_or_else(|| "extracted Ollama.app path is not valid UTF-8".to_string())?;
            let _ = app.emit("zerm://ollama-install-progress", "verifying");
            verify_macos_app_signature(extracted_app_str)?;

            let _ = app.emit("zerm://ollama-install-progress", "installing");
            let install_path = std::path::Path::new("/Applications/Ollama.app");
            let staged_path = std::path::Path::new("/Applications/Ollama.app.zerm-new");
            if staged_path.exists() {
                std::fs::remove_dir_all(staged_path)
                    .map_err(|e| format!("remove staged Ollama.app: {e}"))?;
            }
            let status = std::process::Command::new("ditto")
                .args([extracted_app_str, "/Applications/Ollama.app.zerm-new"])
                .status()
                .map_err(|e| format!("ditto: {e}"))?;
            if !status.success() {
                return Err(format!("ditto exited {status}"));
            }
            verify_macos_app_signature("/Applications/Ollama.app.zerm-new")?;
            if install_path.exists() {
                std::fs::remove_dir_all(install_path)
                    .map_err(|e| format!("remove existing Ollama.app: {e}"))?;
            }
            std::fs::rename(staged_path, install_path)
                .map_err(|e| format!("install verified Ollama.app: {e}"))?;
            verify_macos_app_signature("/Applications/Ollama.app")?;
            let _ = std::process::Command::new("open")
                .arg("/Applications/Ollama.app")
                .spawn();
        }

        #[cfg(target_os = "windows")]
        {
            let _ = app.emit("zerm://ollama-install-progress", "verifying");
            verify_windows_installer_signature(&installer_path)?;
            std::process::Command::new("cmd")
                .args(["/C", "start", "", installer_path.to_str().unwrap()])
                .spawn()
                .map_err(|e| format!("launch: {e}"))?;
        }

        let _ = app.emit("zerm://ollama-install-progress", "done");
        Ok(())
    }
}

#[tauri::command]
async fn pull_ollama_model(
    window: tauri::WebviewWindow,
    app: AppHandle,
    state: tauri::State<'_, Arc<Pipeline>>,
    model: String,
) -> Result<(), String> {
    require_dashboard(&window)?;
    use futures_util::StreamExt;

    let allow_unverified = state.persistent.lock().settings.allow_unverified_ollama;
    ollama::verify_identity_with_policy(allow_unverified)
        .await
        .map_err(|e| format!("Ollama identity check failed: {e:#}"))?;

    let _ = app.emit(
        "zerm://ollama-pull-progress",
        serde_json::json!({ "status": "starting", "model": model }),
    );

    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(60 * 30)) // 30 min for big models
        .build()
        .map_err(|e| format!("client: {e}"))?;

    let resp = client
        .post("http://127.0.0.1:11434/api/pull")
        .json(&serde_json::json!({ "name": model, "stream": true }))
        .send()
        .await
        .map_err(|e| format!("request: {e}"))?
        .error_for_status()
        .map_err(|e| format!("status: {e}"))?;

    let mut stream = resp.bytes_stream();
    let mut buf: Vec<u8> = Vec::new();
    while let Some(chunk) = stream.next().await {
        let chunk = chunk.map_err(|e| format!("chunk: {e}"))?;
        buf.extend_from_slice(&chunk);
        while let Some(pos) = buf.iter().position(|&b| b == b'\n') {
            let line = buf.drain(..=pos).collect::<Vec<u8>>();
            if let Ok(json) = serde_json::from_slice::<serde_json::Value>(&line) {
                let _ = app.emit("zerm://ollama-pull-progress", json);
            }
        }
    }

    let _ = app.emit(
        "zerm://ollama-pull-progress",
        serde_json::json!({ "status": "success" }),
    );
    Ok(())
}

#[tauri::command]
async fn download_whisper_model(
    window: tauri::WebviewWindow,
    app: AppHandle,
) -> Result<String, String> {
    require_dashboard(&window)?;
    use futures_util::StreamExt;
    use sha2::{Digest, Sha256};
    use tokio::io::AsyncWriteExt;

    const FILENAME: &str = "ggml-small.bin";

    let dir = user_models_dir(&app).ok_or_else(|| "could not resolve app data dir".to_string())?;
    tokio::fs::create_dir_all(&dir)
        .await
        .map_err(|e| format!("create dir: {e}"))?;
    let dest = dir.join(FILENAME);

    // Use a randomized temp path inside the user's app-data dir (not /tmp),
    // so no other user/process can pre-create a symlink at a predictable
    // path and substitute a malicious file. `tempfile` opens with O_EXCL
    // on unix and CreateFile DISPOSITION_CREATE_NEW on Windows.
    let tmp_file = tempfile::Builder::new()
        .prefix(".ggml-small-")
        .suffix(".part")
        .tempfile_in(&dir)
        .map_err(|e| format!("tempfile: {e}"))?;

    let resp = reqwest::get(WHISPER_SMALL_URL)
        .await
        .map_err(|e| format!("request: {e}"))?
        .error_for_status()
        .map_err(|e| format!("status: {e}"))?;

    // Don't trust Content-Length; use it only to reject obviously-wrong
    // responses early.
    if let Some(len) = resp.content_length() {
        if len > WHISPER_SMALL_MAX_BYTES {
            return Err(format!(
                "refusing: content-length {len} exceeds cap {WHISPER_SMALL_MAX_BYTES}"
            ));
        }
    }
    let total = resp.content_length().unwrap_or(0);
    let _ = app.emit(
        "zerm://whisper-download-progress",
        DownloadProgress {
            downloaded: 0,
            total,
        },
    );

    let std_tmp = tmp_file.reopen().map_err(|e| format!("reopen: {e}"))?;
    let mut file = tokio::fs::File::from_std(std_tmp);
    let mut hasher = Sha256::new();
    let mut downloaded: u64 = 0;
    let mut last_emit: u64 = 0;
    let mut stream = resp.bytes_stream();
    while let Some(chunk) = stream.next().await {
        let chunk = chunk.map_err(|e| format!("chunk: {e}"))?;
        downloaded += chunk.len() as u64;
        if downloaded > WHISPER_SMALL_MAX_BYTES {
            return Err(format!(
                "refusing: stream exceeded {WHISPER_SMALL_MAX_BYTES} byte cap"
            ));
        }
        hasher.update(&chunk);
        file.write_all(&chunk)
            .await
            .map_err(|e| format!("write: {e}"))?;
        if downloaded - last_emit > 256 * 1024 {
            last_emit = downloaded;
            let _ = app.emit(
                "zerm://whisper-download-progress",
                DownloadProgress { downloaded, total },
            );
        }
    }
    file.flush().await.map_err(|e| format!("flush: {e}"))?;
    file.sync_all().await.map_err(|e| format!("sync: {e}"))?;
    drop(file);

    // Verify the pinned hash BEFORE the file becomes live. If it doesn't
    // match we drop the tempfile (which deletes itself) and error out.
    let got = hex::encode(hasher.finalize());
    if got != WHISPER_SMALL_SHA256 {
        return Err(format!(
            "whisper model hash mismatch: expected {WHISPER_SMALL_SHA256}, got {got}"
        ));
    }

    // Atomic replace: tempfile::NamedTempFile::persist wraps the
    // platform-correct atomic rename (rename(2) on unix, MoveFileExW
    // with REPLACE_EXISTING on Windows). We keep the verified tempfile
    // untouched if persist fails, so a working old model is never lost
    // to a half-finished replacement.
    tmp_file
        .persist(&dest)
        .map_err(|e| format!("persist: {}", e.error))?;

    let _ = app.emit(
        "zerm://whisper-download-progress",
        DownloadProgress {
            downloaded: total,
            total,
        },
    );

    let pipeline = app.state::<Arc<Pipeline>>().inner().clone();
    let whisper_arc = pipeline.whisper.clone();
    let app_for_ready = app.clone();
    let dest_for_load = dest.clone();
    std::thread::spawn(move || {
        log::info!("reloading whisper model from {dest_for_load:?}");
        match whisper::Whisper::load(&dest_for_load) {
            Ok(w) => {
                let silence: Vec<f32> = vec![0.0; 16_000];
                let _ = w.transcribe(&silence);
                *whisper_arc.lock() = Some(w);
                let _ = app_for_ready.emit(READY_EVENT, ());
                log::info!("whisper ready (post-download)");
            }
            Err(e) => emit_error(
                &app_for_ready,
                format!("whisper post-download load failed: {e:#}"),
            ),
        }
    });

    Ok(dest.display().to_string())
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    let _ = env_logger::Builder::from_env(env_logger::Env::default().default_filter_or("info"))
        .try_init();

    let pipeline = Arc::new(Pipeline::new());
    let pipeline_for_setup = pipeline.clone();

    // On non-macOS platforms we register a Ctrl+Shift+Space hotkey via the
    // global-shortcut plugin. On macOS the NSEvent monitor below does the
    // modifier-only push-to-talk instead, so the plugin is registered but
    // no shortcut is bound.
    let pipeline_for_plugin = pipeline.clone();
    let gs_builder = tauri_plugin_global_shortcut::Builder::new().with_handler(
        move |app: &AppHandle, _sc, event| {
            use tauri_plugin_global_shortcut::ShortcutState;
            if matches!(event.state(), ShortcutState::Pressed) {
                let app = app.clone();
                let pipeline = pipeline_for_plugin.clone();
                tauri::async_runtime::spawn(async move {
                    handle_toggle(&app, &pipeline);
                });
            }
        },
    );

    tauri::Builder::default()
        .plugin(gs_builder.build())
        .invoke_handler(tauri::generate_handler![
            pill_done,
            get_dashboard,
            set_llm_model,
            set_vad_enabled,
            set_auto_paste,
            set_allow_unverified_ollama,
            set_save_history,
            set_prompt_mode,
            set_hotkey,
            add_vocabulary_term,
            remove_vocabulary_term,
            clear_vocabulary,
            clear_history,
            copy_history_entry,
            quit_app,
            open_dashboard,
            set_pill_position,
            get_pill_position,
            check_setup,
            download_whisper_model,
            install_ollama,
            pull_ollama_model,
        ])
        .setup(move |app| {
            let app_handle = app.handle().clone();

            // Load persistent state from app data dir
            if let Ok(dir) = app.path().app_data_dir() {
                let path = dir.join(STATE_FILE);
                let loaded = PersistentState::load_with_backup(&path);
                *pipeline_for_setup.persistent.lock() = loaded;
                *pipeline_for_setup.state_path.lock() = Some(path);
                log::info!("state dir: {dir:?}");
            }

            // Apply saved hotkey choice
            let hotkey_choice = pipeline_for_setup.persistent.lock().settings.hotkey;
            hotkey::set_hotkey(hotkey_choice.key_code(), hotkey_choice.flag_bit());

            if let Err(e) = build_tray(app, pipeline_for_setup.clone()) {
                log::error!("failed to build tray: {e:#}");
            }

            // Enable native macOS drag-by-background on the pill window,
            // then restore its saved position if any.
            if let Some(window) = app.get_webview_window("main") {
                enable_window_drag(&window);
                if let Some(pos) = pipeline_for_setup.persistent.lock().pill_position {
                    let pos = clamp_pill_position(&window, pos);
                    let _ = window.set_position(tauri::Position::Physical(
                        PhysicalPosition { x: pos.x, y: pos.y },
                    ));
                }
            }

            // Background-load Whisper, then pre-warm
            let whisper_arc = pipeline_for_setup.whisper.clone();
            let app_for_load = app_handle.clone();
            let app_for_path = app_handle.clone();
            std::thread::spawn(move || {
                let path = whisper_model_path(&app_for_path);
                log::info!("loading whisper model from {path:?}");
                match whisper::Whisper::load(&path) {
                    Ok(w) => {
                        log::info!("pre-warming whisper (Metal kernels)…");
                        let silence: Vec<f32> = vec![0.0; 16_000];
                        let _ = w.transcribe(&silence);
                        *whisper_arc.lock() = Some(w);
                        let _ = app_for_load.emit(READY_EVENT, ());
                        log::info!("whisper ready");
                    }
                    Err(e) => {
                        emit_error(
                            &app_for_load,
                            format!(
                                "whisper model load failed at {path:?}: {e:#}. Set ZERM_WHISPER_MODEL or place ggml-small.en.bin in models/."
                            ),
                        );
                    }
                }
            });

            // Pre-warm Ollama
            let model_for_warmup = current_llm_model(&pipeline_for_setup);
            tauri::async_runtime::spawn(async move {
                log::info!("pre-warming ollama ({model_for_warmup})…");
                match ollama::reformat(&model_for_warmup, "ping", PromptMode::Developer).await {
                    Ok(_) => log::info!("ollama ready"),
                    Err(e) => log::warn!("ollama pre-warm failed: {e:#}"),
                }
            });

            // Tap-to-toggle global hotkey
            let app_for_hotkey = app_handle.clone();
            let pipeline_for_hotkey = pipeline_for_setup.clone();
            let installed = hotkey::install(move |pressed| {
                if pressed {
                    let app = app_for_hotkey.clone();
                    let pipeline = pipeline_for_hotkey.clone();
                    tauri::async_runtime::spawn(async move {
                        handle_toggle(&app, &pipeline);
                    });
                }
            });
            if installed {
                log::info!(
                    "zerm started. Tap {} to record. Click tray icon for dashboard.",
                    hotkey_choice.label()
                );
            } else if cfg!(target_os = "macos") {
                emit_error(
                    &app_handle,
                    "Hotkey monitor failed. Grant Accessibility in System Settings → Privacy & Security.",
                );
            } else {
                // Windows / Linux: register Ctrl+Shift+Space via the plugin.
                #[cfg(not(target_os = "macos"))]
                {
                    use tauri_plugin_global_shortcut::{
                        Code, GlobalShortcutExt, Modifiers, Shortcut,
                    };
                    let shortcut = Shortcut::new(
                        Some(Modifiers::CONTROL | Modifiers::SHIFT),
                        Code::Space,
                    );
                    match app.global_shortcut().register(shortcut) {
                        Ok(_) => log::info!(
                            "zerm started. Tap Ctrl+Shift+Space to record. Click tray for dashboard."
                        ),
                        Err(e) => emit_error(
                            &app_handle,
                            format!(
                                "could not register Ctrl+Shift+Space: {e:#}. Another app may own it."
                            ),
                        ),
                    }
                }
            }

            // Open the dashboard automatically so the user can see the app
            let app_for_dash = app_handle.clone();
            tauri::async_runtime::spawn(async move {
                tokio::time::sleep(std::time::Duration::from_millis(400)).await;
                open_dashboard_window(&app_for_dash);
            });

            Ok(())
        })
        .manage(pipeline)
        .build(tauri::generate_context!())
        .expect("error while building tauri application")
        .run(|_app, event| {
            if let tauri::RunEvent::ExitRequested { api, .. } = event {
                // Prevent the LSUIElement/tray-icon behaviour where the app
                // quits when the last window closes. But let the user quit
                // explicitly via the tray "Quit Zerm" item or dashboard
                // "Quit" button, which set INTENTIONAL_QUIT first.
                if !INTENTIONAL_QUIT.load(Ordering::SeqCst) {
                    api.prevent_exit();
                }
            }
        });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn privacy_erase_requires_state_path() {
        let pipeline = Pipeline::new();

        let err = pipeline.save_persistent_erasing_backup().unwrap_err();

        assert!(err.to_string().contains("state path is unavailable"));
    }

    #[test]
    fn privacy_erase_removes_sensitive_backup() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("zerm-state.json");
        let backup = PersistentState::backup_path(&path);
        let pipeline = Pipeline::new();
        *pipeline.state_path.lock() = Some(path.clone());

        {
            let mut state = pipeline.persistent.lock();
            state.settings.save_history = true;
            state.record("secret transcript".to_string(), "secret output".to_string());
        }
        pipeline.save_persistent_result(false).unwrap();

        {
            let mut state = pipeline.persistent.lock();
            state.settings.save_history = false;
            state.history.clear();
            state.stats = state::Stats::default();
        }
        pipeline.save_persistent_erasing_backup().unwrap();

        assert!(!backup.exists());
        let raw = std::fs::read_to_string(&path).unwrap();
        assert!(!raw.contains("secret transcript"));
        assert!(!raw.contains("secret output"));
    }
}
