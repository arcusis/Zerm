mod audio;
mod hotkey;
mod ollama;
mod state;
mod whisper;

use anyhow::Result;
use parking_lot::Mutex;
use serde::Serialize;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use tauri::menu::{Menu, MenuItem, PredefinedMenuItem};
use tauri::tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent};
use tauri::{AppHandle, Emitter, Manager, PhysicalPosition, WebviewUrl, WebviewWindow, WebviewWindowBuilder};

use state::{DashboardData, HotkeyChoice, PersistentState, PillPosition, PromptMode};

const READY_EVENT: &str = "zerm://ready";
const ERROR_EVENT: &str = "zerm://error";
const RECORDING_EVENT: &str = "zerm://recording-start";
const PROCESSING_EVENT: &str = "zerm://processing-start";
const TRANSCRIPT_EVENT: &str = "zerm://transcript";
const DONE_EVENT: &str = "zerm://done";
const DASHBOARD_UPDATED_EVENT: &str = "zerm://dashboard-updated";
const AUDIO_LEVEL_EVENT: &str = "zerm://audio-level";
const PILL_WIDTH: i32 = 240;
const STATE_FILE: &str = "zerm-state.json";

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
            tray_anchor: Arc::new(Mutex::new(None)),
            persistent: Arc::new(Mutex::new(PersistentState::default())),
            state_path: Arc::new(Mutex::new(None)),
        }
    }

    fn save_persistent(&self) {
        let path = self.state_path.lock().clone();
        let snapshot = self.persistent.lock().clone();
        if let Some(p) = path {
            std::thread::spawn(move || {
                if let Err(e) = snapshot.save(&p) {
                    log::error!("failed to save state: {e:#}");
                }
            });
        }
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
        .unwrap_or_else(|| dev_models_dir())
        .join("ggml-small.bin")
}

fn looks_non_latin(text: &str) -> bool {
    text.chars()
        .filter(|c| c.is_alphabetic())
        .take(40)
        .any(|c| !c.is_ascii())
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

/// Send a Cmd+V keystroke to the currently focused application via
/// AppleScript / System Events. We never grab focus ourselves (the pill
/// has `focus: false`), so the previously focused app is still the
/// recipient. If nothing is focused for text input the keystroke is a
/// no-op.
#[cfg(target_os = "macos")]
fn send_paste_keystroke() {
    let script =
        "tell application \"System Events\" to keystroke \"v\" using command down";
    match std::process::Command::new("osascript")
        .args(["-e", script])
        .output()
    {
        Ok(out) if !out.status.success() => {
            log::warn!(
                "auto-paste: osascript exited {}: {}",
                out.status,
                String::from_utf8_lossy(&out.stderr)
            );
        }
        Err(e) => log::warn!("auto-paste: spawn failed: {e}"),
        _ => {}
    }
}

#[cfg(not(target_os = "macos"))]
fn send_paste_keystroke() {
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
    let result = WebviewWindowBuilder::new(app, "dashboard", WebviewUrl::App("dashboard.html".into()))
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
    let was_recording = pipeline.recording.fetch_xor(true, Ordering::SeqCst);
    if was_recording {
        log::info!("toggle → stop");
        handle_release(app, pipeline);
    } else {
        log::info!("toggle → start");
        handle_press(app, pipeline);
    }
}

fn handle_press(app: &AppHandle, pipeline: &Pipeline) {
    pipeline.audio_buffer.lock().clear();

    let vad_enabled = pipeline.persistent.lock().settings.vad_enabled;
    let app_for_vad = app.clone();

    let result = audio::start_capture(pipeline.audio_buffer.clone(), move || {
        if !vad_enabled {
            return;
        }
        let app = app_for_vad.clone();
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
                let mut interval =
                    tokio::time::interval(std::time::Duration::from_millis(33));
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

    let raw = std::mem::take(&mut *pipeline.audio_buffer.lock());
    let app_clone = app.clone();
    let whisper = pipeline.whisper.clone();
    let llm_model = current_llm_model(pipeline);
    let (prompt_mode, vocabulary) = {
        let p = pipeline.persistent.lock();
        (p.settings.prompt_mode, p.settings.vocabulary.join(", "))
    };

    tauri::async_runtime::spawn(async move {
        let result = process(
            &app_clone,
            whisper,
            raw,
            sample_rate,
            channels,
            llm_model,
            prompt_mode,
            vocabulary,
        )
        .await;
        if let Err(e) = result {
            emit_error(&app_clone, format!("processing failed: {e:#}"));
        }
    });
}

async fn process(
    app: &AppHandle,
    whisper: Arc<Mutex<Option<whisper::Whisper>>>,
    raw: Vec<f32>,
    sample_rate: u32,
    channels: u16,
    llm_model: String,
    prompt_mode: PromptMode,
    vocabulary: String,
) -> Result<()> {
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
    let raw_transcript = tauri::async_runtime::spawn_blocking(move || -> Result<String> {
        let guard = whisper_for_blocking.lock();
        let w = guard
            .as_ref()
            .ok_or_else(|| anyhow::anyhow!("whisper model not loaded yet"))?;
        w.transcribe_with_options(&prepared, None, initial_prompt.as_deref())
    })
    .await??;

    let transcript = state::strip_whisper_tokens(&raw_transcript);
    log::info!("transcript: {transcript}");
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

    let needs_cleanup = looks_non_latin(&transcript);
    let output = if matches!(prompt_mode, PromptMode::Off) && needs_cleanup {
        // Non-Latin transcript with no AI mode → run a conservative cleanup
        // pass so that misheard non-English input still gets punctuation /
        // typo fixes without changing meaning.
        log::info!("non-latin transcript detected, running minimal cleanup pass");
        match ollama::reformat_with_system(
            &llm_model,
            &transcript,
            ollama::minimal_cleanup_prompt(),
        )
        .await
        {
            Ok(t) => t,
            Err(e) => {
                log::warn!("minimal cleanup failed, using raw: {e:#}");
                transcript.clone()
            }
        }
    } else {
        match ollama::reformat(&llm_model, &transcript, prompt_mode).await {
            Ok(t) => t,
            Err(e) => {
                log::warn!("ollama reformat failed, falling back to raw: {e:#}");
                emit_error(app, format!("ollama: {e:#} (using raw transcript)"));
                transcript.clone()
            }
        }
    };

    if let Err(e) = copy_to_clipboard(&output) {
        emit_error(app, format!("clipboard: {e:#}"));
    }

    let auto_paste = app
        .try_state::<Arc<Pipeline>>()
        .map(|s| s.persistent.lock().settings.auto_paste)
        .unwrap_or(true);

    if auto_paste && !output.is_empty() {
        // Tiny delay so the clipboard write is observable before the paste fires.
        tokio::time::sleep(std::time::Duration::from_millis(70)).await;
        tauri::async_runtime::spawn_blocking(send_paste_keystroke);
    }

    if let Some(state) = app.try_state::<Arc<Pipeline>>() {
        state
            .persistent
            .lock()
            .record(transcript.clone(), output.clone());
        state.save_persistent();
    }
    emit_dashboard_update(app);

    let _ = app.emit(DONE_EVENT, DonePayload { transcript, output });
    Ok(())
}

fn build_tray(app: &tauri::App, pipeline: Arc<Pipeline>) -> tauri::Result<()> {
    let app_handle = app.handle().clone();

    let toggle_item = MenuItem::with_id(app, "toggle", "Start / Stop Recording", true, None::<&str>)?;
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
            "quit" => app.exit(0),
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

#[tauri::command]
fn pill_done(app: AppHandle) {
    hide_pill(&app);
}

#[tauri::command]
fn get_dashboard(state: tauri::State<'_, Arc<Pipeline>>) -> DashboardData {
    state.persistent.lock().dashboard()
}

#[tauri::command]
fn set_llm_model(
    model: String,
    app: AppHandle,
    state: tauri::State<'_, Arc<Pipeline>>,
) -> Result<(), String> {
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
    enabled: bool,
    app: AppHandle,
    state: tauri::State<'_, Arc<Pipeline>>,
) -> Result<(), String> {
    state.persistent.lock().settings.vad_enabled = enabled;
    state.save_persistent();
    emit_dashboard_update(&app);
    Ok(())
}

#[tauri::command]
fn set_auto_paste(
    enabled: bool,
    app: AppHandle,
    state: tauri::State<'_, Arc<Pipeline>>,
) -> Result<(), String> {
    state.persistent.lock().settings.auto_paste = enabled;
    state.save_persistent();
    emit_dashboard_update(&app);
    Ok(())
}

#[tauri::command]
fn set_prompt_mode(
    mode: String,
    app: AppHandle,
    state: tauri::State<'_, Arc<Pipeline>>,
) -> Result<(), String> {
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
    key: String,
    app: AppHandle,
    state: tauri::State<'_, Arc<Pipeline>>,
) -> Result<(), String> {
    let choice = HotkeyChoice::from_key(&key).ok_or_else(|| format!("unknown hotkey: {key}"))?;
    state.persistent.lock().settings.hotkey = choice;
    state.save_persistent();
    hotkey::set_hotkey(choice.key_code(), choice.flag_bit());
    log::info!("hotkey changed to {}", choice.label());
    emit_dashboard_update(&app);
    Ok(())
}

#[tauri::command]
fn add_vocabulary_term(
    term: String,
    app: AppHandle,
    state: tauri::State<'_, Arc<Pipeline>>,
) -> Result<(), String> {
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
            p.settings
                .vocabulary
                .sort_by(|a, b| a.to_lowercase().cmp(&b.to_lowercase()));
        }
    }
    state.save_persistent();
    emit_dashboard_update(&app);
    Ok(())
}

#[tauri::command]
fn remove_vocabulary_term(
    term: String,
    app: AppHandle,
    state: tauri::State<'_, Arc<Pipeline>>,
) -> Result<(), String> {
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
    app: AppHandle,
    state: tauri::State<'_, Arc<Pipeline>>,
) -> Result<(), String> {
    state.persistent.lock().settings.vocabulary.clear();
    state.save_persistent();
    emit_dashboard_update(&app);
    Ok(())
}

#[tauri::command]
fn clear_history(app: AppHandle, state: tauri::State<'_, Arc<Pipeline>>) -> Result<(), String> {
    {
        let mut p = state.persistent.lock();
        p.history.clear();
        p.stats = state::Stats::default();
    }
    state.save_persistent();
    emit_dashboard_update(&app);
    Ok(())
}

#[tauri::command]
fn copy_history_entry(
    timestamp: u64,
    state: tauri::State<'_, Arc<Pipeline>>,
) -> Result<(), String> {
    let entry = state
        .persistent
        .lock()
        .history
        .iter()
        .find(|e| e.timestamp == timestamp)
        .cloned();
    match entry {
        Some(e) => copy_to_clipboard(&e.output).map_err(|err| err.to_string()),
        None => Err("history entry not found".into()),
    }
}

#[tauri::command]
fn quit_app(app: AppHandle) {
    app.exit(0);
}

#[tauri::command]
fn set_pill_position(
    x: i32,
    y: i32,
    state: tauri::State<'_, Arc<Pipeline>>,
) -> Result<(), String> {
    state.persistent.lock().pill_position = Some(PillPosition { x, y });
    state.save_persistent();
    Ok(())
}

#[tauri::command]
fn get_pill_position(state: tauri::State<'_, Arc<Pipeline>>) -> Option<PillPosition> {
    state.persistent.lock().pill_position
}

#[tauri::command]
fn open_dashboard(app: AppHandle) {
    open_dashboard_window(&app);
}

#[derive(Clone, Serialize)]
struct SetupStatus {
    whisper_model_present: bool,
    whisper_model_path: Option<String>,
    ollama_running: bool,
    ollama_model_pulled: bool,
    ollama_model_name: String,
}

#[tauri::command]
async fn check_setup(app: AppHandle) -> SetupStatus {
    let path = whisper_model_path(&app);
    let whisper_model_present = path.exists();
    let model_name = std::env::var("ZERM_LLM_MODEL").unwrap_or_else(|_| "gemma3:4b".to_string());

    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(2))
        .build()
        .ok();
    let (ollama_running, ollama_model_pulled) = match client {
        Some(c) => match c.get("http://localhost:11434/api/tags").send().await {
            Ok(resp) if resp.status().is_success() => {
                let pulled = resp
                    .json::<serde_json::Value>()
                    .await
                    .ok()
                    .and_then(|v| {
                        v.get("models")
                            .and_then(|m| m.as_array())
                            .map(|arr| {
                                arr.iter().any(|m| {
                                    m.get("name")
                                        .and_then(|n| n.as_str())
                                        .map(|n| n == model_name || n.starts_with(&format!("{model_name}:")))
                                        .unwrap_or(false)
                                })
                            })
                    })
                    .unwrap_or(false);
                (true, pulled)
            }
            _ => (false, false),
        },
        None => (false, false),
    };

    SetupStatus {
        whisper_model_present,
        whisper_model_path: Some(path.display().to_string()),
        ollama_running,
        ollama_model_pulled,
        ollama_model_name: model_name,
    }
}

#[derive(Clone, Serialize)]
struct DownloadProgress {
    downloaded: u64,
    total: u64,
}

#[cfg(target_os = "macos")]
const OLLAMA_INSTALLER_URL: &str = "https://ollama.com/download/Ollama-darwin.zip";
#[cfg(target_os = "windows")]
const OLLAMA_INSTALLER_URL: &str = "https://ollama.com/download/OllamaSetup.exe";
#[cfg(target_os = "linux")]
const OLLAMA_INSTALLER_URL: &str = "https://ollama.com/install.sh";

#[tauri::command]
async fn install_ollama(app: AppHandle) -> Result<(), String> {
    let tmp_name = match std::env::consts::OS {
        "macos" => "Ollama.zip",
        "windows" => "OllamaSetup.exe",
        _ => "ollama-install.sh",
    };
    let tmp = std::env::temp_dir().join(tmp_name);

    use futures_util::StreamExt;
    use tokio::io::AsyncWriteExt;

    let _ = app.emit("zerm://ollama-install-progress", "downloading");
    let resp = reqwest::get(OLLAMA_INSTALLER_URL)
        .await
        .map_err(|e| format!("request: {e}"))?
        .error_for_status()
        .map_err(|e| format!("status: {e}"))?;
    let mut file = tokio::fs::File::create(&tmp)
        .await
        .map_err(|e| format!("create: {e}"))?;
    let mut stream = resp.bytes_stream();
    while let Some(chunk) = stream.next().await {
        let chunk = chunk.map_err(|e| format!("chunk: {e}"))?;
        file.write_all(&chunk)
            .await
            .map_err(|e| format!("write: {e}"))?;
    }
    file.flush().await.ok();
    drop(file);

    let _ = app.emit("zerm://ollama-install-progress", "launching");

    #[cfg(target_os = "macos")]
    {
        // Unzip into /Applications
        let status = std::process::Command::new("unzip")
            .args(["-o", tmp.to_str().unwrap(), "-d", "/Applications/"])
            .status()
            .map_err(|e| format!("unzip: {e}"))?;
        if !status.success() {
            return Err(format!("unzip exited {status}"));
        }
        // Launch it so the Ollama server starts
        let _ = std::process::Command::new("open")
            .arg("/Applications/Ollama.app")
            .spawn();
    }

    #[cfg(target_os = "windows")]
    {
        std::process::Command::new("cmd")
            .args(["/C", "start", "", tmp.to_str().unwrap()])
            .spawn()
            .map_err(|e| format!("launch: {e}"))?;
    }

    #[cfg(target_os = "linux")]
    {
        // Open the installer in the user's default terminal so they see the
        // sudo prompt and progress output.
        let script = tmp.to_string_lossy().into_owned();
        let candidates: &[&[&str]] = &[
            &["x-terminal-emulator", "-e", "sh", &script],
            &["gnome-terminal", "--", "sh", &script],
            &["konsole", "-e", "sh", &script],
            &["xterm", "-e", "sh", &script],
        ];
        let mut launched = false;
        for args in candidates {
            if std::process::Command::new(args[0])
                .args(&args[1..])
                .spawn()
                .is_ok()
            {
                launched = true;
                break;
            }
        }
        if !launched {
            return Err(
                "Could not find a terminal emulator. Run this manually: \
                 `curl -fsSL https://ollama.com/install.sh | sh`"
                    .into(),
            );
        }
    }

    let _ = app.emit("zerm://ollama-install-progress", "done");
    Ok(())
}

#[tauri::command]
async fn pull_ollama_model(app: AppHandle, model: String) -> Result<(), String> {
    use futures_util::StreamExt;

    let _ = app.emit(
        "zerm://ollama-pull-progress",
        serde_json::json!({ "status": "starting", "model": model }),
    );

    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(60 * 30)) // 30 min for big models
        .build()
        .map_err(|e| format!("client: {e}"))?;

    let resp = client
        .post("http://localhost:11434/api/pull")
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
async fn download_whisper_model(app: AppHandle) -> Result<String, String> {
    use futures_util::StreamExt;
    use tokio::io::AsyncWriteExt;

    const URL: &str =
        "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin";
    const FILENAME: &str = "ggml-small.bin";

    let dir = user_models_dir(&app)
        .ok_or_else(|| "could not resolve app data dir".to_string())?;
    tokio::fs::create_dir_all(&dir)
        .await
        .map_err(|e| format!("create dir: {e}"))?;
    let dest = dir.join(FILENAME);
    let tmp = dir.join(format!("{FILENAME}.part"));

    let resp = reqwest::get(URL)
        .await
        .map_err(|e| format!("request: {e}"))?
        .error_for_status()
        .map_err(|e| format!("status: {e}"))?;
    let total = resp.content_length().unwrap_or(0);
    let _ = app.emit(
        "zerm://whisper-download-progress",
        DownloadProgress { downloaded: 0, total },
    );

    let mut file = tokio::fs::File::create(&tmp)
        .await
        .map_err(|e| format!("create file: {e}"))?;
    let mut downloaded: u64 = 0;
    let mut last_emit: u64 = 0;
    let mut stream = resp.bytes_stream();
    while let Some(chunk) = stream.next().await {
        let chunk = chunk.map_err(|e| format!("chunk: {e}"))?;
        file.write_all(&chunk)
            .await
            .map_err(|e| format!("write: {e}"))?;
        downloaded += chunk.len() as u64;
        if downloaded - last_emit > 256 * 1024 {
            last_emit = downloaded;
            let _ = app.emit(
                "zerm://whisper-download-progress",
                DownloadProgress { downloaded, total },
            );
        }
    }
    file.flush().await.map_err(|e| format!("flush: {e}"))?;
    drop(file);

    tokio::fs::rename(&tmp, &dest)
        .await
        .map_err(|e| format!("rename: {e}"))?;

    let _ = app.emit(
        "zerm://whisper-download-progress",
        DownloadProgress { downloaded: total, total },
    );

    // Trigger an in-place reload of the model
    let pipeline = app.state::<Arc<Pipeline>>().inner().clone();
    let whisper_arc = pipeline.whisper.clone();
    let dest_for_load = dest.clone();
    std::thread::spawn(move || {
        log::info!("reloading whisper model from {dest_for_load:?}");
        match whisper::Whisper::load(&dest_for_load) {
            Ok(w) => {
                let silence: Vec<f32> = vec![0.0; 16_000];
                let _ = w.transcribe(&silence);
                *whisper_arc.lock() = Some(w);
                log::info!("whisper ready (post-download)");
            }
            Err(e) => log::error!("whisper post-download load failed: {e:#}"),
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
                let loaded = PersistentState::load(&path);
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
                api.prevent_exit();
            }
        });
}
