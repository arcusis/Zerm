mod audio;
mod hotkey;
pub mod insertion;
mod ollama;
pub mod platform;
mod state;
mod whisper;

use anyhow::{anyhow, Result};
use parking_lot::Mutex;
use serde::Serialize;
use std::fs::OpenOptions;
use std::io::Write;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Arc;
use std::time::{Instant, SystemTime, UNIX_EPOCH};
use tauri::menu::{Menu, MenuItem, PredefinedMenuItem};
use tauri::tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent};
use tauri::{
    AppHandle, Emitter, Manager, Monitor, PhysicalPosition, WebviewUrl, WebviewWindow,
    WebviewWindowBuilder,
};

use insertion::{
    AppContext as InsertionAppContext, InsertionPlan, InsertionRequest, InsertionStrategy,
    Platform as InsertionPlatform, StrategySelector,
};
use state::{
    DashboardData, HotkeyChoice, PersistentState, PillPosition, PowerModeProfile, ProfileContext,
    PromptMode,
};

const READY_EVENT: &str = "zerm://ready";
const ERROR_EVENT: &str = "zerm://error";
const RECORDING_EVENT: &str = "zerm://recording-start";
const PROCESSING_EVENT: &str = "zerm://processing-start";
const TRANSCRIPT_EVENT: &str = "zerm://transcript";
const DONE_EVENT: &str = "zerm://done";
const PASTED_EVENT: &str = "zerm://pasted";
const DASHBOARD_UPDATED_EVENT: &str = "zerm://dashboard-updated";
const AUDIO_LEVEL_EVENT: &str = "zerm://audio-level";
const TAP_TO_TOGGLE_THRESHOLD_MS: u128 = 250;

// Set before calling app.exit(0) so the RunEvent::ExitRequested handler
// below knows this is an intentional quit, not a last-window-closed event.
static INTENTIONAL_QUIT: AtomicBool = AtomicBool::new(false);

// Monotonic job counter so a fresh recording can invalidate in-flight
// processing from a previous recording — prevents stale auto-paste after
// the user tabs away.
static NEXT_JOB_ID: AtomicU64 = AtomicU64::new(1);
static CURRENT_JOB_ID: AtomicU64 = AtomicU64::new(0);
static INPUT_MONITOR_READY: AtomicBool = AtomicBool::new(false);

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
    pid: i32,
    bundle_id: String,
    app_name: Option<String>,
}

#[derive(Clone, Debug)]
struct CapturedPasteTarget {
    identity: FocusIdentity,
    #[cfg(target_os = "macos")]
    focused_element: Option<MacAxElement>,
    #[cfg(target_os = "macos")]
    initial_text: Option<String>,
    #[cfg(target_os = "macos")]
    role: Option<String>,
    #[cfg(target_os = "macos")]
    subrole: Option<String>,
    #[cfg(target_os = "macos")]
    ax_value_readable: bool,
    #[cfg(target_os = "macos")]
    target_center: Option<(f64, f64)>,
}

#[derive(Clone, Serialize)]
struct DonePayload {
    transcript: String,
    output: String,
    copied: bool,
    pasted: bool,
    state: String,
    message: Option<String>,
}

#[derive(Clone, Serialize)]
struct InsertionDiagnostic {
    strategy: String,
    status: String,
    detail: String,
    target_bundle_id: Option<String>,
    confirmed: bool,
}

impl InsertionDiagnostic {
    fn copied(detail: impl Into<String>) -> Self {
        Self {
            strategy: "clipboard_copy".to_string(),
            status: "copied".to_string(),
            detail: detail.into(),
            target_bundle_id: None,
            confirmed: true,
        }
    }

    fn pasted(target: &FocusIdentity, strategy: impl Into<String>) -> Self {
        Self {
            strategy: strategy.into(),
            status: "pasted".to_string(),
            detail: "Auto-paste completed against the target captured when recording started."
                .to_string(),
            target_bundle_id: Some(target.bundle_id.clone()),
            confirmed: true,
        }
    }

    fn failed(strategy: impl Into<String>, detail: impl Into<String>) -> Self {
        Self {
            strategy: strategy.into(),
            status: "failed".to_string(),
            detail: detail.into(),
            target_bundle_id: None,
            confirmed: false,
        }
    }
}

#[derive(Clone, Debug)]
enum TextClipboardSnapshot {
    Text(String),
    NonTextOrUnavailable,
}

#[cfg(target_os = "macos")]
#[derive(Debug)]
struct MacAxElement {
    ptr: core_foundation::base::CFTypeRef,
}

#[cfg(target_os = "macos")]
unsafe impl Send for MacAxElement {}

#[cfg(target_os = "macos")]
impl Clone for MacAxElement {
    fn clone(&self) -> Self {
        let retained = unsafe { core_foundation::base::CFRetain(self.ptr) };
        Self { ptr: retained }
    }
}

#[cfg(target_os = "macos")]
impl Drop for MacAxElement {
    fn drop(&mut self) {
        unsafe { core_foundation::base::CFRelease(self.ptr) };
    }
}

#[cfg(target_os = "macos")]
impl MacAxElement {
    unsafe fn from_create_rule(ptr: core_foundation::base::CFTypeRef) -> Option<Self> {
        if ptr.is_null() {
            None
        } else {
            Some(Self { ptr })
        }
    }

    fn as_ax(&self) -> AxUiElementRef {
        self.ptr as AxUiElementRef
    }
}

fn native_debug_log_path() -> Option<PathBuf> {
    let home = std::env::var_os("HOME")?;
    Some(
        PathBuf::from(home)
            .join("Library")
            .join("Logs")
            .join("Zerm")
            .join("native-debug.log"),
    )
}

const NATIVE_DEBUG_LOG_MAX_BYTES: u64 = 1024 * 1024;
const NATIVE_DEBUG_LOG_ROTATED_NAME: &str = "native-debug.log.1";

fn native_debug_log(message: impl AsRef<str>) {
    static LOG_GUARD: once_cell::sync::Lazy<std::sync::Mutex<()>> =
        once_cell::sync::Lazy::new(|| std::sync::Mutex::new(()));

    let Some(path) = native_debug_log_path() else {
        return;
    };
    let _guard = LOG_GUARD.lock().expect("native debug log lock poisoned");
    if let Some(parent) = path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    if std::fs::metadata(&path)
        .map(|metadata| metadata.len() > NATIVE_DEBUG_LOG_MAX_BYTES)
        .unwrap_or(false)
    {
        let rotated = path.with_file_name(NATIVE_DEBUG_LOG_ROTATED_NAME);
        let _ = std::fs::remove_file(&rotated);
        let _ = std::fs::rename(&path, rotated);
    }
    let millis = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_millis())
        .unwrap_or_default();
    if let Ok(mut file) = OpenOptions::new().create(true).append(true).open(path) {
        let _ = writeln!(
            file,
            "[{} pid={}] {}",
            millis,
            std::process::id(),
            message.as_ref()
        );
    }
}

#[cfg(target_os = "macos")]
#[derive(Clone, Copy)]
struct NativePillPanel {
    panel: usize,
}

#[derive(Clone)]
struct PillPlacement {
    position: PillPosition,
    monitor: Monitor,
}

#[cfg(target_os = "macos")]
static NATIVE_PILL_PANEL: once_cell::sync::Lazy<std::sync::Mutex<Option<NativePillPanel>>> =
    once_cell::sync::Lazy::new(|| std::sync::Mutex::new(None));

fn format_focus_identity(identity: Option<&FocusIdentity>) -> String {
    match identity {
        Some(identity) => format!(
            "pid={} bundle_id={} app_name={}",
            identity.pid,
            identity.bundle_id,
            identity.app_name.as_deref().unwrap_or("<unknown>")
        ),
        None => "<none>".to_string(),
    }
}

fn context_from_paste_target(target: &CapturedPasteTarget) -> ProfileContext {
    ProfileContext {
        bundle_id: non_empty_string(target.identity.bundle_id.clone()),
        app_name: target.identity.app_name.clone().and_then(non_empty_string),
        window_title: None,
        browser_url_or_domain: None,
        language: None,
    }
}

fn non_empty_string(value: String) -> Option<String> {
    let trimmed = value.trim();
    if trimmed.is_empty() {
        None
    } else {
        Some(trimmed.to_string())
    }
}

fn current_binary_path_string() -> String {
    std::env::current_exe()
        .map(|path| path.display().to_string())
        .unwrap_or_else(|err| format!("<current_exe failed: {err}>"))
}

fn window_frame_string(window: &WebviewWindow) -> String {
    let pos = window.outer_position();
    let size = window.outer_size();
    match (pos, size) {
        (Ok(pos), Ok(size)) => format!(
            "coordinate_space=tauri_physical_pixels x={} y={} width={} height={}",
            pos.x, pos.y, size.width, size.height
        ),
        (pos, size) => format!("position={pos:?} size={size:?}"),
    }
}

fn monitor_key(monitor: &Monitor) -> String {
    let origin = monitor.position();
    let size = monitor.size();
    format!(
        "name={:?};physical_origin=({},{});physical_size={}x{};scale={}",
        monitor.name(),
        origin.x,
        origin.y,
        size.width,
        size.height,
        monitor.scale_factor()
    )
}

fn monitor_string(monitor: &Monitor) -> String {
    let origin = monitor.position();
    let size = monitor.size();
    let scale = monitor.scale_factor();
    format!(
        "key=\"{}\" coordinate_space=tauri_physical_pixels origin=({}, {}) size={}x{} scale_factor={} logical_origin=({:.2}, {:.2}) logical_size={:.2}x{:.2}",
        monitor_key(monitor),
        origin.x,
        origin.y,
        size.width,
        size.height,
        scale,
        origin.x as f64 / scale,
        origin.y as f64 / scale,
        size.width as f64 / scale,
        size.height as f64 / scale
    )
}

fn monitor_contains_physical_point(monitor: &Monitor, x: f64, y: f64) -> bool {
    let origin = monitor.position();
    let size = monitor.size();
    x >= origin.x as f64
        && x < (origin.x + size.width as i32) as f64
        && y >= origin.y as f64
        && y < (origin.y + size.height as i32) as f64
}

fn monitor_contains_logical_point(monitor: &Monitor, x: f64, y: f64) -> bool {
    let origin = monitor.position();
    let size = monitor.size();
    let scale = monitor.scale_factor();
    let min_x = origin.x as f64 / scale;
    let min_y = origin.y as f64 / scale;
    let max_x = min_x + size.width as f64 / scale;
    let max_y = min_y + size.height as f64 / scale;
    x >= min_x && x < max_x && y >= min_y && y < max_y
}

#[cfg(target_os = "macos")]
fn appkit_panel_frame_for_physical_top_left(
    pos: PillPosition,
    monitor: &Monitor,
    width: f64,
    height: f64,
) -> objc2_foundation::NSRect {
    use objc2_foundation::{NSPoint, NSRect, NSSize};

    let origin = monitor.position();
    let size = monitor.size();
    let scale = monitor.scale_factor();
    let monitor_min_y = origin.y as f64 / scale;
    let monitor_height = size.height as f64 / scale;
    let top_y = pos.y as f64 / scale;
    let relative_top_y = top_y - monitor_min_y;
    NSRect::new(
        NSPoint::new(
            pos.x as f64 / scale,
            monitor_min_y + monitor_height - relative_top_y - height,
        ),
        NSSize::new(width, height),
    )
}

fn monitor_containing_physical_point(window: &WebviewWindow, x: f64, y: f64) -> Option<Monitor> {
    window
        .available_monitors()
        .ok()?
        .into_iter()
        .find(|monitor| monitor_contains_physical_point(monitor, x, y))
}

fn monitor_from_logical_point(window: &WebviewWindow, x: f64, y: f64) -> Option<Monitor> {
    window.monitor_from_point(x, y).ok().flatten().or_else(|| {
        window
            .available_monitors()
            .ok()?
            .into_iter()
            .find(|monitor| monitor_contains_logical_point(monitor, x, y))
    })
}

fn monitor_from_physical_point(window: &WebviewWindow, x: f64, y: f64) -> Option<Monitor> {
    monitor_containing_physical_point(window, x, y)
        .or_else(|| window.monitor_from_point(x, y).ok().flatten())
}

fn monitor_string_from_physical_point(window: &WebviewWindow, x: f64, y: f64) -> String {
    let physical_match = monitor_containing_physical_point(window, x, y);
    let normalized_api_result = physical_match.as_ref().and_then(|monitor| {
        let scale = monitor.scale_factor();
        window
            .monitor_from_point(x / scale, y / scale)
            .ok()
            .flatten()
    });

    if let Some(monitor) = physical_match {
        return format!(
            "{} resolved_by=physical_pixel_bounds monitor_from_point_input=logical_points({:.2}, {:.2}) monitor_from_point_result={}",
            monitor_string(&monitor),
            x / monitor.scale_factor(),
            y / monitor.scale_factor(),
            normalized_api_result
                .as_ref()
                .map(monitor_key)
                .unwrap_or_else(|| "<none>".to_string())
        );
    }

    match window.monitor_from_point(x, y) {
        Ok(Some(monitor)) => {
            format!(
                "{} resolved_by=monitor_from_point_fallback input_assumed=logical_points({x:.2}, {y:.2})",
                monitor_string(&monitor)
            )
        }
        Ok(None) => "<no monitor at physical/logical point>".to_string(),
        Err(err) => format!("<monitor_from_point failed: {err}>"),
    }
}

fn monitor_string_from_logical_point(window: &WebviewWindow, x: f64, y: f64) -> String {
    match monitor_from_logical_point(window, x, y) {
        Some(monitor) => format!(
            "{} resolved_by=logical_point input=macos_logical_points({x:.2}, {y:.2})",
            monitor_string(&monitor)
        ),
        None => "<no monitor at logical point>".to_string(),
    }
}

fn pill_screen_string(window: &WebviewWindow) -> String {
    match (window.outer_position(), window.outer_size()) {
        (Ok(pos), Ok(size)) => monitor_string_from_physical_point(
            window,
            pos.x as f64 + size.width as f64 / 2.0,
            pos.y as f64 + size.height as f64 / 2.0,
        ),
        _ => "<pill frame unavailable>".to_string(),
    }
}

#[cfg(target_os = "macos")]
unsafe extern "C" {
    fn class_getName(cls: *const objc2::runtime::AnyClass) -> *const std::os::raw::c_char;
}

#[cfg(target_os = "macos")]
fn objc_class(name: &'static [u8]) -> Option<&'static objc2::runtime::AnyClass> {
    let name = std::ffi::CStr::from_bytes_with_nul(name).ok()?;
    objc2::runtime::AnyClass::get(name)
}

#[cfg(target_os = "macos")]
fn appkit_class_name(obj: *mut objc2::runtime::AnyObject) -> String {
    use objc2::msg_send;

    if obj.is_null() {
        return "<null>".to_string();
    }
    unsafe {
        let cls: *const objc2::runtime::AnyClass = msg_send![obj, class];
        if cls.is_null() {
            return "<no class>".to_string();
        }
        let name = class_getName(cls);
        if name.is_null() {
            return "<class name unavailable>".to_string();
        }
        std::ffi::CStr::from_ptr(name)
            .to_string_lossy()
            .into_owned()
    }
}

#[cfg(target_os = "macos")]
fn appkit_window_debug_info(label: &str, obj: *mut objc2::runtime::AnyObject) -> String {
    use objc2::{msg_send, sel};

    if obj.is_null() {
        return format!("{label}_window=<null>");
    }
    unsafe {
        let panel_class = objc_class(b"NSPanel\0");
        let is_panel = panel_class
            .map(|class| msg_send![obj, isKindOfClass: class])
            .unwrap_or(false);
        let class_name = appkit_class_name(obj);
        let level: i64 = msg_send![obj, level];
        let style_mask: u64 = msg_send![obj, styleMask];
        let collection_behavior: u64 = msg_send![obj, collectionBehavior];
        let can_become_key: bool = msg_send![obj, canBecomeKeyWindow];
        let can_become_main: bool = msg_send![obj, canBecomeMainWindow];
        let is_visible: bool = msg_send![obj, isVisible];
        let responds_to_active_space: bool =
            msg_send![obj, respondsToSelector: sel!(isOnActiveSpace)];
        let is_on_active_space = if responds_to_active_space {
            let value: bool = msg_send![obj, isOnActiveSpace];
            Some(value)
        } else {
            None
        };
        let non_activating_panel = 1 << 7;
        let hud_window = 1 << 13;
        let can_join_all_spaces = 1 << 0;
        let stationary = 1 << 4;
        let full_screen_auxiliary = 1 << 8;
        let ignores_cycle = 1 << 6;
        format!(
            "{label}_window_class={} {label}_is_kind_of_NSPanel={} {label}_level={} {label}_styleMask={} {label}_nonactivating_panel_bit={} {label}_hud_window_bit={} {label}_collectionBehavior={} {label}_can_join_all_spaces={} {label}_stationary={} {label}_full_screen_auxiliary={} {label}_ignores_cycle={} {label}_canBecomeKeyWindow={} {label}_canBecomeMainWindow={} {label}_isVisible={} {label}_isOnActiveSpace={:?}",
            class_name,
            is_panel,
            level,
            style_mask,
            (style_mask & non_activating_panel) != 0,
            (style_mask & hud_window) != 0,
            collection_behavior,
            (collection_behavior & can_join_all_spaces) != 0,
            (collection_behavior & stationary) != 0,
            (collection_behavior & full_screen_auxiliary) != 0,
            (collection_behavior & ignores_cycle) != 0,
            can_become_key,
            can_become_main,
            is_visible,
            is_on_active_space
        )
    }
}

#[cfg(target_os = "macos")]
fn appkit_window_frame_info(label: &str, obj: *mut objc2::runtime::AnyObject) -> String {
    use objc2::msg_send;

    if obj.is_null() {
        return format!("{label}_frame=<null>");
    }
    unsafe {
        let frame: objc2_foundation::NSRect = msg_send![obj, frame];
        format!(
            "{label}_frame_coordinate_space=appkit_logical_points {label}_frame_x={:.2} {label}_frame_y={:.2} {label}_frame_width={:.2} {label}_frame_height={:.2}",
            frame.origin.x, frame.origin.y, frame.size.width, frame.size.height
        )
    }
}

#[cfg(target_os = "macos")]
fn macos_window_debug_info(window: &WebviewWindow) -> String {
    let Ok(ptr) = window.ns_window() else {
        return "tauri_pill_window=<ns_window unavailable>".to_string();
    };
    if ptr.is_null() {
        return "tauri_pill_window=<null ns_window>".to_string();
    }
    let obj: *mut objc2::runtime::AnyObject = ptr.cast();
    format!(
        "{} {}",
        appkit_window_debug_info("tauri_pill", obj),
        appkit_window_frame_info("tauri_pill", obj)
    )
}

#[cfg(not(target_os = "macos"))]
fn macos_window_debug_info(_window: &WebviewWindow) -> String {
    "<unsupported platform>".to_string()
}

fn target_screen_string(window: &WebviewWindow, pipeline: Option<&Pipeline>) -> String {
    #[cfg(target_os = "macos")]
    {
        let Some(target) = pipeline.and_then(|state| state.paste_target.lock().as_ref().cloned())
        else {
            return "<no captured target>".to_string();
        };
        let Some((x, y)) = target.target_center else {
            return "<captured target has no AX geometry>".to_string();
        };
        monitor_string_from_logical_point(window, x, y)
    }

    #[cfg(not(target_os = "macos"))]
    {
        let _ = window;
        let _ = pipeline;
        "<unsupported platform>".to_string()
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum RecordingLifecycle {
    Idle,
    Starting {
        stop_requested: bool,
        started_at: Instant,
    },
    Recording {
        started_at: Instant,
    },
    Stopping,
    Processing {
        job_id: u64,
    },
}

impl RecordingLifecycle {
    fn label(self) -> &'static str {
        match self {
            RecordingLifecycle::Idle => "idle",
            RecordingLifecycle::Starting { .. } => "starting",
            RecordingLifecycle::Recording { .. } => "recording",
            RecordingLifecycle::Stopping => "stopping",
            RecordingLifecycle::Processing { .. } => "processing",
        }
    }

    fn audio_level_active(self) -> bool {
        matches!(
            self,
            RecordingLifecycle::Recording { .. } | RecordingLifecycle::Stopping
        )
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum RecordingAction {
    Start,
    Stop,
    PendingStop,
    KeepRecording,
    Ignore,
}

fn request_toggle_transition(lifecycle: &mut RecordingLifecycle) -> RecordingAction {
    match *lifecycle {
        RecordingLifecycle::Idle | RecordingLifecycle::Processing { .. } => {
            *lifecycle = RecordingLifecycle::Starting {
                stop_requested: false,
                started_at: Instant::now(),
            };
            RecordingAction::Start
        }
        RecordingLifecycle::Starting {
            ref mut stop_requested,
            ..
        } => {
            *stop_requested = true;
            RecordingAction::PendingStop
        }
        RecordingLifecycle::Recording { .. } => {
            *lifecycle = RecordingLifecycle::Stopping;
            RecordingAction::Stop
        }
        RecordingLifecycle::Stopping => RecordingAction::Ignore,
    }
}

fn request_press_transition(lifecycle: &mut RecordingLifecycle) -> RecordingAction {
    match *lifecycle {
        RecordingLifecycle::Idle | RecordingLifecycle::Processing { .. } => {
            *lifecycle = RecordingLifecycle::Starting {
                stop_requested: false,
                started_at: Instant::now(),
            };
            RecordingAction::Start
        }
        RecordingLifecycle::Recording { .. } => {
            *lifecycle = RecordingLifecycle::Stopping;
            RecordingAction::Stop
        }
        _ => RecordingAction::Ignore,
    }
}

fn request_release_transition(lifecycle: &mut RecordingLifecycle) -> RecordingAction {
    match *lifecycle {
        RecordingLifecycle::Starting {
            ref mut stop_requested,
            started_at,
        } => {
            if started_at.elapsed().as_millis() < TAP_TO_TOGGLE_THRESHOLD_MS {
                return RecordingAction::KeepRecording;
            }
            *stop_requested = true;
            RecordingAction::PendingStop
        }
        RecordingLifecycle::Recording { started_at } => {
            if started_at.elapsed().as_millis() < TAP_TO_TOGGLE_THRESHOLD_MS {
                return RecordingAction::KeepRecording;
            }
            *lifecycle = RecordingLifecycle::Stopping;
            RecordingAction::Stop
        }
        _ => RecordingAction::Ignore,
    }
}

#[derive(Clone, Serialize)]
struct CaptureDiagnostic {
    status: String,
    raw_samples: usize,
    sample_rate: u32,
    channels: u16,
    approx_seconds: f64,
    device_name: Option<String>,
    sample_format: Option<String>,
    peak_rms: Option<f32>,
    detail: Option<String>,
}

struct Pipeline {
    whisper: Arc<Mutex<Option<whisper::Whisper>>>,
    audio_buffer: Arc<Mutex<Vec<f32>>>,
    capture: Arc<Mutex<Option<audio::CaptureHandle>>>,
    lifecycle: Arc<Mutex<RecordingLifecycle>>,
    active_job_id: Arc<AtomicU64>,
    paste_target: Arc<Mutex<Option<CapturedPasteTarget>>>,
    last_insertion: Arc<Mutex<Option<InsertionDiagnostic>>>,
    last_capture: Arc<Mutex<Option<CaptureDiagnostic>>>,
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
            lifecycle: Arc::new(Mutex::new(RecordingLifecycle::Idle)),
            active_job_id: Arc::new(AtomicU64::new(0)),
            paste_target: Arc::new(Mutex::new(None)),
            last_insertion: Arc::new(Mutex::new(None)),
            last_capture: Arc::new(Mutex::new(None)),
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

    fn set_last_insertion(&self, diagnostic: InsertionDiagnostic) {
        *self.last_insertion.lock() = Some(diagnostic);
    }

    fn lifecycle_label(&self) -> String {
        self.lifecycle.lock().label().to_string()
    }

    fn set_idle(&self, reason: &str) {
        *self.lifecycle.lock() = RecordingLifecycle::Idle;
        native_debug_log(format!("recording lifecycle -> idle reason=\"{reason}\""));
    }

    fn finish_processing_job(&self, job_id: u64) {
        let mut lifecycle = self.lifecycle.lock();
        if matches!(*lifecycle, RecordingLifecycle::Processing { job_id: id } if id == job_id)
            && self.active_job_id.load(Ordering::SeqCst) == job_id
        {
            *lifecycle = RecordingLifecycle::Idle;
            native_debug_log(format!(
                "recording lifecycle -> idle reason=\"processing finished\" job_id={job_id}"
            ));
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

#[cfg(target_os = "macos")]
fn maybe_run_auto_paste_self_test() {
    let mut args = std::env::args().skip(1);
    let Some(flag) = args.next() else {
        return;
    };
    if flag != "--zerm-autopaste-self-test" {
        return;
    }

    let text = args
        .next()
        .unwrap_or_else(|| "ZERM_AUTOPASTE_SELF_TEST".to_string());
    if let Err(e) = copy_to_clipboard(&text) {
        eprintln!("auto-paste self-test failed to copy text: {e:#}");
        std::process::exit(2);
    }
    std::thread::sleep(std::time::Duration::from_millis(250));
    let Some(target) = capture_paste_target() else {
        eprintln!("auto-paste self-test could not find a non-Zerm focused app");
        std::process::exit(3);
    };
    match send_paste_to_target(target, &text) {
        Ok(_) => std::process::exit(0),
        Err(e) => {
            eprintln!("auto-paste self-test failed: {e}");
            std::process::exit(4);
        }
    }
}

fn copy_to_clipboard(text: &str) -> Result<()> {
    let mut clipboard = arboard::Clipboard::new()?;
    clipboard.set_text(text.to_string())?;
    Ok(())
}

fn snapshot_text_clipboard() -> Result<TextClipboardSnapshot> {
    let mut clipboard = arboard::Clipboard::new()?;
    match clipboard.get_text() {
        Ok(text) => Ok(TextClipboardSnapshot::Text(text)),
        Err(e) => {
            log::info!("clipboard preservation: previous clipboard was not readable text: {e}");
            Ok(TextClipboardSnapshot::NonTextOrUnavailable)
        }
    }
}

fn restore_text_clipboard(snapshot: TextClipboardSnapshot) -> Result<()> {
    match snapshot {
        TextClipboardSnapshot::Text(text) => copy_to_clipboard(&text),
        TextClipboardSnapshot::NonTextOrUnavailable => {
            log::info!(
                "clipboard preservation: leaving output on clipboard because previous contents were not readable text"
            );
            Ok(())
        }
    }
}

#[cfg(target_os = "macos")]
fn frontmost_focus_identity() -> Option<FocusIdentity> {
    use objc2_app_kit::NSWorkspace;

    let app = NSWorkspace::sharedWorkspace().frontmostApplication()?;
    let pid = app.processIdentifier();
    if pid <= 0 {
        log::warn!("auto-paste: frontmost app did not expose a process id");
        return None;
    }
    let bundle_id = app
        .bundleIdentifier()
        .map(|value| value.to_string())
        .unwrap_or_default();
    let app_name = app.localizedName().map(|value| value.to_string());
    if pid == std::process::id() as i32 || bundle_id == "com.arcusis.zerm" {
        log::warn!("auto-paste: Zerm was focused at recording start; no external paste target");
        return None;
    }
    Some(FocusIdentity {
        pid,
        bundle_id,
        app_name,
    })
}

#[cfg(not(target_os = "macos"))]
fn frontmost_focus_identity() -> Option<FocusIdentity> {
    None
}

#[cfg(target_os = "macos")]
fn accessibility_is_trusted() -> bool {
    unsafe { AXIsProcessTrusted() != 0 }
}

#[cfg(not(target_os = "macos"))]
fn accessibility_is_trusted() -> bool {
    true
}

#[cfg(target_os = "macos")]
fn request_accessibility_trust_prompt() -> bool {
    use core_foundation::base::TCFType;
    use core_foundation::boolean::CFBoolean;
    use core_foundation::dictionary::CFDictionary;
    use core_foundation::string::CFStringRef;

    unsafe extern "C" {
        static kAXTrustedCheckOptionPrompt: CFStringRef;
        fn AXIsProcessTrustedWithOptions(
            options: core_foundation::dictionary::CFDictionaryRef,
        ) -> std::ffi::c_uchar;
    }

    let prompt_key = unsafe {
        core_foundation::string::CFString::wrap_under_get_rule(kAXTrustedCheckOptionPrompt)
    };
    let prompt_value = CFBoolean::true_value();
    let options = CFDictionary::from_CFType_pairs(&[(prompt_key, prompt_value)]);
    unsafe { AXIsProcessTrustedWithOptions(options.as_concrete_TypeRef()) != 0 }
}

#[cfg(not(target_os = "macos"))]
fn request_accessibility_trust_prompt() -> bool {
    true
}

#[cfg(target_os = "macos")]
fn prompt_for_input_permission_if_needed() {
    if accessibility_is_trusted() {
        return;
    }
    if !request_accessibility_trust_prompt() {
        log::info!("macOS Accessibility prompt requested; waiting for user approval");
    }
}

#[cfg(not(target_os = "macos"))]
fn prompt_for_input_permission_if_needed() {}

#[cfg(target_os = "macos")]
fn auto_paste_is_ready() -> bool {
    accessibility_is_trusted()
}

#[cfg(not(target_os = "macos"))]
fn auto_paste_is_ready() -> bool {
    false
}

#[cfg(target_os = "macos")]
#[link(name = "ApplicationServices", kind = "framework")]
extern "C" {
    fn AXIsProcessTrusted() -> std::ffi::c_uchar;
}

#[cfg(target_os = "macos")]
type AxError = i32;
#[cfg(target_os = "macos")]
type AxValueRef = *const std::ffi::c_void;
#[cfg(target_os = "macos")]
type AxUiElementRef = *const std::ffi::c_void;
#[cfg(target_os = "macos")]
type AxValueType = u32;

#[cfg(target_os = "macos")]
const AX_ERROR_SUCCESS: AxError = 0;
#[cfg(target_os = "macos")]
const AX_VALUE_CF_RANGE_TYPE: AxValueType = 4;
#[cfg(target_os = "macos")]
const AX_VALUE_CGPOINT_TYPE: AxValueType = 1;
#[cfg(target_os = "macos")]
const AX_VALUE_CGSIZE_TYPE: AxValueType = 2;

#[cfg(target_os = "macos")]
#[repr(C)]
#[derive(Clone, Copy, Debug)]
struct AxPoint {
    x: f64,
    y: f64,
}

#[cfg(target_os = "macos")]
#[repr(C)]
#[derive(Clone, Copy, Debug)]
struct AxSize {
    width: f64,
    height: f64,
}

#[cfg(target_os = "macos")]
unsafe extern "C" {
    fn AXUIElementCreateApplication(pid: i32) -> AxUiElementRef;
    fn AXUIElementCopyAttributeValue(
        element: AxUiElementRef,
        attribute: core_foundation::string::CFStringRef,
        value: *mut core_foundation::base::CFTypeRef,
    ) -> AxError;
    fn AXUIElementSetAttributeValue(
        element: AxUiElementRef,
        attribute: core_foundation::string::CFStringRef,
        value: core_foundation::base::CFTypeRef,
    ) -> AxError;
    fn AXValueCreate(value_type: AxValueType, value: *const std::ffi::c_void) -> AxValueRef;
    fn AXValueGetTypeID() -> core_foundation::base::CFTypeID;
    fn AXValueGetType(value: AxValueRef) -> AxValueType;
    fn AXValueGetValue(
        value: AxValueRef,
        value_type: AxValueType,
        out_value: *mut std::ffi::c_void,
    ) -> std::ffi::c_uchar;
}

#[cfg(target_os = "macos")]
fn ax_attr(name: &str) -> core_foundation::string::CFString {
    core_foundation::string::CFString::new(name)
}

#[cfg(target_os = "macos")]
unsafe fn ax_copy_attr(
    element: AxUiElementRef,
    attr: &core_foundation::string::CFString,
) -> Result<core_foundation::base::CFTypeRef, AxError> {
    use core_foundation::base::TCFType;

    let mut value: core_foundation::base::CFTypeRef = std::ptr::null();
    let err = AXUIElementCopyAttributeValue(element, attr.as_concrete_TypeRef(), &mut value);
    if err == AX_ERROR_SUCCESS && !value.is_null() {
        Ok(value)
    } else {
        if !value.is_null() {
            core_foundation::base::CFRelease(value);
        }
        Err(err)
    }
}

#[cfg(target_os = "macos")]
unsafe fn ax_set_attr(
    element: AxUiElementRef,
    attr: &core_foundation::string::CFString,
    value: core_foundation::base::CFTypeRef,
) -> Result<(), AxError> {
    use core_foundation::base::TCFType;

    let err = AXUIElementSetAttributeValue(element, attr.as_concrete_TypeRef(), value);
    if err == AX_ERROR_SUCCESS {
        Ok(())
    } else {
        Err(err)
    }
}

#[cfg(target_os = "macos")]
unsafe fn ax_copy_string_attr(
    element: AxUiElementRef,
    attr: &core_foundation::string::CFString,
) -> Result<String, String> {
    use core_foundation::base::{CFGetTypeID, TCFType};
    use core_foundation::string::{CFString, CFStringRef};

    let value = ax_copy_attr(element, attr).map_err(|e| format!("AXError {e}"))?;
    if CFGetTypeID(value) != CFString::type_id() {
        let actual = CFGetTypeID(value);
        core_foundation::base::CFRelease(value);
        return Err(format!("attribute is not a string (CFTypeID {actual})"));
    }
    let value = CFString::wrap_under_create_rule(value as CFStringRef);
    Ok(value.to_string())
}

#[cfg(target_os = "macos")]
unsafe fn ax_copy_range_attr(
    element: AxUiElementRef,
    attr: &core_foundation::string::CFString,
) -> Result<core_foundation::base::CFRange, String> {
    use core_foundation::base::CFGetTypeID;

    let value = ax_copy_attr(element, attr).map_err(|e| format!("AXError {e}"))?;
    if CFGetTypeID(value) != AXValueGetTypeID()
        || AXValueGetType(value as AxValueRef) != AX_VALUE_CF_RANGE_TYPE
    {
        let actual = CFGetTypeID(value);
        core_foundation::base::CFRelease(value);
        return Err(format!(
            "attribute is not an AX CFRange (CFTypeID {actual})"
        ));
    }

    let mut range = core_foundation::base::CFRange {
        location: 0,
        length: 0,
    };
    let ok = AXValueGetValue(
        value as AxValueRef,
        AX_VALUE_CF_RANGE_TYPE,
        &mut range as *mut core_foundation::base::CFRange as *mut std::ffi::c_void,
    ) != 0;
    core_foundation::base::CFRelease(value);
    if ok {
        Ok(range)
    } else {
        Err("could not decode AXSelectedTextRange".to_string())
    }
}

#[cfg(target_os = "macos")]
unsafe fn ax_copy_point_attr(
    element: AxUiElementRef,
    attr: &core_foundation::string::CFString,
) -> Result<AxPoint, String> {
    use core_foundation::base::CFGetTypeID;

    let value = ax_copy_attr(element, attr).map_err(|e| format!("AXError {e}"))?;
    if CFGetTypeID(value) != AXValueGetTypeID()
        || AXValueGetType(value as AxValueRef) != AX_VALUE_CGPOINT_TYPE
    {
        let actual = CFGetTypeID(value);
        core_foundation::base::CFRelease(value);
        return Err(format!(
            "attribute is not an AX CGPoint (CFTypeID {actual})"
        ));
    }

    let mut point = AxPoint { x: 0.0, y: 0.0 };
    let ok = AXValueGetValue(
        value as AxValueRef,
        AX_VALUE_CGPOINT_TYPE,
        &mut point as *mut AxPoint as *mut std::ffi::c_void,
    ) != 0;
    core_foundation::base::CFRelease(value);
    if ok {
        Ok(point)
    } else {
        Err("could not decode AXPosition".to_string())
    }
}

#[cfg(target_os = "macos")]
unsafe fn ax_copy_size_attr(
    element: AxUiElementRef,
    attr: &core_foundation::string::CFString,
) -> Result<AxSize, String> {
    use core_foundation::base::CFGetTypeID;

    let value = ax_copy_attr(element, attr).map_err(|e| format!("AXError {e}"))?;
    if CFGetTypeID(value) != AXValueGetTypeID()
        || AXValueGetType(value as AxValueRef) != AX_VALUE_CGSIZE_TYPE
    {
        let actual = CFGetTypeID(value);
        core_foundation::base::CFRelease(value);
        return Err(format!("attribute is not an AX CGSize (CFTypeID {actual})"));
    }

    let mut size = AxSize {
        width: 0.0,
        height: 0.0,
    };
    let ok = AXValueGetValue(
        value as AxValueRef,
        AX_VALUE_CGSIZE_TYPE,
        &mut size as *mut AxSize as *mut std::ffi::c_void,
    ) != 0;
    core_foundation::base::CFRelease(value);
    if ok {
        Ok(size)
    } else {
        Err("could not decode AXSize".to_string())
    }
}

#[cfg(target_os = "macos")]
fn ax_target_center(element: &MacAxElement) -> Option<(f64, f64)> {
    let position_attr = ax_attr("AXPosition");
    let size_attr = ax_attr("AXSize");
    let position = unsafe { ax_copy_point_attr(element.as_ax(), &position_attr).ok()? };
    let size = unsafe { ax_copy_size_attr(element.as_ax(), &size_attr).ok()? };
    Some((
        position.x + (size.width / 2.0),
        position.y + (size.height / 2.0),
    ))
}

#[cfg(target_os = "macos")]
fn ax_read_text(element: &MacAxElement) -> Option<String> {
    let value_attr = ax_attr("AXValue");
    unsafe { ax_copy_string_attr(element.as_ax(), &value_attr).ok() }
}

#[cfg(target_os = "macos")]
fn ax_text_has_new_insert(before: Option<&str>, after: &str, inserted: &str) -> bool {
    if inserted.is_empty() || after.is_empty() {
        return false;
    }
    let before_count = before
        .map(|value| value.matches(inserted).count())
        .unwrap_or(0);
    after.matches(inserted).count() > before_count
}

#[cfg(target_os = "macos")]
fn ax_verify_inserted(
    element: &MacAxElement,
    before: Option<&str>,
    inserted: &str,
) -> Result<(), String> {
    let after = ax_read_text(element)
        .ok_or_else(|| "could not verify insertion because AXValue is unreadable".to_string())?;
    let changed = before != Some(after.as_str());
    if changed && (ax_text_has_new_insert(before, &after, inserted) || after.ends_with(inserted)) {
        Ok(())
    } else {
        Err("AXValue did not contain the inserted text after insertion".to_string())
    }
}

#[cfg(target_os = "macos")]
fn replace_utf16_range(
    current: &str,
    range: core_foundation::base::CFRange,
    replacement: &str,
) -> Option<String> {
    if range.location < 0 || range.length < 0 {
        return None;
    }
    let mut units: Vec<u16> = current.encode_utf16().collect();
    let start = range.location as usize;
    let length = range.length as usize;
    let end = start.checked_add(length)?;
    if start > units.len() || end > units.len() {
        return None;
    }
    units.splice(start..end, replacement.encode_utf16());
    String::from_utf16(&units).ok()
}

#[cfg(target_os = "macos")]
unsafe fn ax_set_cursor_after_insert(
    element: AxUiElementRef,
    selected_text_range_attr: &core_foundation::string::CFString,
    start: isize,
    inserted_text: &str,
) {
    let cursor = core_foundation::base::CFRange {
        location: start + inserted_text.encode_utf16().count() as isize,
        length: 0,
    };
    let value = AXValueCreate(
        AX_VALUE_CF_RANGE_TYPE,
        &cursor as *const core_foundation::base::CFRange as *const std::ffi::c_void,
    );
    if !value.is_null() {
        let _ = ax_set_attr(
            element,
            selected_text_range_attr,
            value as core_foundation::base::CFTypeRef,
        );
        core_foundation::base::CFRelease(value as core_foundation::base::CFTypeRef);
    }
}

#[cfg(target_os = "macos")]
fn ax_is_secure_field(role: Option<&str>, subrole: Option<&str>) -> bool {
    role.is_some_and(|value| value.to_ascii_lowercase().contains("secure"))
        || subrole.is_some_and(|value| value.to_ascii_lowercase().contains("secure"))
}

#[cfg(target_os = "macos")]
fn capture_focused_ax_element(identity: &FocusIdentity) -> Option<MacAxElement> {
    let app = unsafe { AXUIElementCreateApplication(identity.pid) };
    if app.is_null() {
        log::warn!(
            "auto-paste: could not create AX application for pid {}",
            identity.pid
        );
        return None;
    }
    let focused_attr = ax_attr("AXFocusedUIElement");
    let focused = unsafe { ax_copy_attr(app, &focused_attr).ok() };
    unsafe { core_foundation::base::CFRelease(app as core_foundation::base::CFTypeRef) };
    focused.and_then(|ptr| unsafe { MacAxElement::from_create_rule(ptr) })
}

#[cfg(target_os = "macos")]
fn capture_paste_target() -> Option<CapturedPasteTarget> {
    let identity = frontmost_focus_identity()?;
    let focused_element = capture_focused_ax_element(&identity);
    let role_attr = ax_attr("AXRole");
    let subrole_attr = ax_attr("AXSubrole");
    let role = focused_element
        .as_ref()
        .and_then(|element| unsafe { ax_copy_string_attr(element.as_ax(), &role_attr).ok() });
    let subrole = focused_element
        .as_ref()
        .and_then(|element| unsafe { ax_copy_string_attr(element.as_ax(), &subrole_attr).ok() });
    if ax_is_secure_field(role.as_deref(), subrole.as_deref()) {
        log::warn!(
            "auto-paste: refusing to capture secure field in {:?}",
            identity
        );
        return None;
    }
    let initial_text = focused_element.as_ref().and_then(ax_read_text);
    let ax_value_readable = initial_text.is_some();
    let target_center = focused_element.as_ref().and_then(ax_target_center);
    native_debug_log(format!(
        "capture target={} ax_role={:?} ax_subrole={:?} focused_element_captured={} ax_value_readable={} ax_target_center={:?} ax_coordinate_space=macos_accessibility_logical_points",
        format_focus_identity(Some(&identity)),
        role,
        subrole,
        focused_element.is_some(),
        ax_value_readable,
        target_center
    ));
    log::info!(
        "auto-paste: captured target pid={} bundle={} role={:?} subrole={:?} readable_text={}",
        identity.pid,
        identity.bundle_id,
        role,
        subrole,
        initial_text.is_some()
    );
    Some(CapturedPasteTarget {
        identity,
        focused_element,
        initial_text,
        role,
        subrole,
        ax_value_readable,
        target_center,
    })
}

#[cfg(not(target_os = "macos"))]
fn capture_paste_target() -> Option<CapturedPasteTarget> {
    frontmost_focus_identity().map(|identity| CapturedPasteTarget { identity })
}

#[cfg(target_os = "macos")]
fn insert_text_via_captured_accessibility(
    target: &CapturedPasteTarget,
    text: &str,
) -> Result<(), String> {
    use core_foundation::base::TCFType;

    let element = target
        .focused_element
        .as_ref()
        .ok_or_else(|| "no focused AX element was captured at recording start".to_string())?;
    if ax_is_secure_field(target.role.as_deref(), target.subrole.as_deref()) {
        return Err("captured target is a secure field".to_string());
    }

    let selected_text_attr = ax_attr("AXSelectedText");
    let selected_text_range_attr = ax_attr("AXSelectedTextRange");
    let value_attr = ax_attr("AXValue");
    let replacement = core_foundation::string::CFString::new(text);
    let before = ax_read_text(element).or_else(|| target.initial_text.clone());

    let selected_text_result = unsafe {
        ax_set_attr(
            element.as_ax(),
            &selected_text_attr,
            replacement.as_CFTypeRef(),
        )
    };
    if selected_text_result.is_ok() {
        return direct_ax_success_or_verify(target, element, before.as_deref(), text);
    }

    let current = unsafe { ax_copy_string_attr(element.as_ax(), &value_attr)? };
    let range = unsafe { ax_copy_range_attr(element.as_ax(), &selected_text_range_attr)? };
    let next = replace_utf16_range(&current, range, text)
        .ok_or_else(|| "selected text range is outside AXValue".to_string())?;
    let replacement = core_foundation::string::CFString::new(&next);
    unsafe {
        ax_set_attr(element.as_ax(), &value_attr, replacement.as_CFTypeRef())
            .map_err(|e| format!("captured element rejected AXValue update (AXError {e})"))?;
        ax_set_cursor_after_insert(
            element.as_ax(),
            &selected_text_range_attr,
            range.location,
            text,
        );
    }
    direct_ax_success_or_verify(target, element, Some(&current), text)
}

fn auto_paste_permission_message() -> String {
    #[cfg(target_os = "macos")]
    {
        "Auto-paste needs macOS Accessibility permission. Use Open Accessibility Settings from Zerm, then enable /Applications/Zerm.app and retry.".to_string()
    }

    #[cfg(not(target_os = "macos"))]
    {
        "Auto-paste keystroke synthesis is not implemented on this platform yet.".to_string()
    }
}

#[cfg(target_os = "macos")]
fn open_accessibility_settings() -> Result<(), String> {
    std::process::Command::new("/usr/bin/open")
        .arg("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        .spawn()
        .map_err(|e| format!("open Accessibility settings: {e}"))?;
    Ok(())
}

#[cfg(target_os = "macos")]
fn open_microphone_settings() -> Result<(), String> {
    std::process::Command::new("/usr/bin/open")
        .arg("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
        .spawn()
        .map_err(|e| format!("open Microphone settings: {e}"))?;
    Ok(())
}

#[cfg(target_os = "macos")]
fn macos_signature_permission_note() -> Option<String> {
    let exe = std::env::current_exe().ok()?;
    let out = std::process::Command::new("/usr/bin/codesign")
        .args(["-dv", "--verbose=4"])
        .arg(exe)
        .output()
        .ok()?;
    let text = String::from_utf8_lossy(&out.stderr);
    if text.contains("Signature=adhoc") || !text.contains("TeamIdentifier=") {
        Some(" This installed build is not Developer ID signed, so macOS can show a stale Accessibility toggle that does not apply to the current binary. Install a signed production build, or remove and re-add /Applications/Zerm.app after this exact build is installed.".to_string())
    } else {
        None
    }
}

#[derive(Clone, Serialize)]
struct InputPermissionStatus {
    required: bool,
    granted: bool,
    title: String,
    detail: String,
    settings_label: String,
}

#[derive(Clone, Serialize)]
struct AppSigningStatus {
    status: String,
    authority: Option<String>,
    team_identifier: Option<String>,
    identifier: Option<String>,
    path: Option<String>,
    detail: Option<String>,
    warning: Option<String>,
    trusted: Option<bool>,
    stable_tcc_identity: Option<bool>,
    notarized: Option<bool>,
}

fn app_signing_status() -> Option<AppSigningStatus> {
    #[cfg(target_os = "macos")]
    {
        let diagnostics = platform::macos_permissions::collect_macos_permission_diagnostics();
        let authority = diagnostics.codesign.authorities.first().cloned();
        let signature_kind = diagnostics.tcc_identity.signature_kind.clone();
        let status = match signature_kind {
            platform::macos_permissions::SignatureKind::DeveloperId => {
                "Developer ID signed".to_string()
            }
            platform::macos_permissions::SignatureKind::AppleDevelopment => {
                "Apple development signed".to_string()
            }
            platform::macos_permissions::SignatureKind::AppleSigned => "Apple signed".to_string(),
            platform::macos_permissions::SignatureKind::AdHoc => "Ad-hoc local build".to_string(),
            platform::macos_permissions::SignatureKind::UnsignedOrRejected => {
                "Unsigned or rejected".to_string()
            }
            platform::macos_permissions::SignatureKind::Unknown => "Unknown signing".to_string(),
        };
        let warning = diagnostics
            .tcc_identity
            .repair_hint
            .clone()
            .or_else(|| macos_signature_permission_note().map(|note| note.trim().to_string()));
        let detail = diagnostics.codesign.format.clone().or_else(|| {
            diagnostics
                .codesign
                .signature
                .as_ref()
                .map(|signature| format!("Signature={signature}"))
        });

        Some(AppSigningStatus {
            status,
            authority,
            team_identifier: diagnostics.tcc_identity.team_identifier,
            identifier: diagnostics.tcc_identity.bundle_id,
            path: diagnostics.bundle_path.or(diagnostics.executable_path),
            detail,
            warning,
            trusted: Some(diagnostics.accessibility_trusted),
            stable_tcc_identity: Some(diagnostics.tcc_identity.stable_for_tcc),
            notarized: None,
        })
    }

    #[cfg(not(target_os = "macos"))]
    {
        None
    }
}

#[cfg(target_os = "macos")]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum MacosMicrophoneAuthorization {
    NotDetermined,
    Restricted,
    Denied,
    Authorized,
    Unknown(i64),
}

#[cfg(target_os = "macos")]
impl MacosMicrophoneAuthorization {
    fn is_granted(self) -> bool {
        matches!(self, MacosMicrophoneAuthorization::Authorized)
    }

    fn label(self) -> &'static str {
        match self {
            MacosMicrophoneAuthorization::NotDetermined => "not requested",
            MacosMicrophoneAuthorization::Restricted => "restricted",
            MacosMicrophoneAuthorization::Denied => "denied",
            MacosMicrophoneAuthorization::Authorized => "allowed",
            MacosMicrophoneAuthorization::Unknown(_) => "unknown",
        }
    }
}

#[cfg(target_os = "macos")]
fn macos_microphone_authorization_status() -> MacosMicrophoneAuthorization {
    use objc2::msg_send;
    use objc2_foundation::NSString;

    let Some(class) = objc_class(b"AVCaptureDevice\0") else {
        return MacosMicrophoneAuthorization::Unknown(-1);
    };
    let media_type = NSString::from_str("soun");
    let raw: i64 = unsafe { msg_send![class, authorizationStatusForMediaType: &*media_type] };
    match raw {
        0 => MacosMicrophoneAuthorization::NotDetermined,
        1 => MacosMicrophoneAuthorization::Restricted,
        2 => MacosMicrophoneAuthorization::Denied,
        3 => MacosMicrophoneAuthorization::Authorized,
        other => MacosMicrophoneAuthorization::Unknown(other),
    }
}

#[cfg(target_os = "macos")]
fn request_macos_microphone_access() -> Result<bool, String> {
    use block2::{DynBlock, RcBlock};
    use objc2::msg_send;
    use objc2::runtime::Bool;
    use objc2_foundation::NSString;

    let Some(class) = objc_class(b"AVCaptureDevice\0") else {
        return Err("AVCaptureDevice class is unavailable".to_string());
    };
    let media_type = NSString::from_str("soun");
    let (tx, rx) = std::sync::mpsc::sync_channel(1);
    let block = RcBlock::new(move |granted: Bool| {
        let _ = tx.send(granted.as_bool());
    });
    let block: &DynBlock<dyn Fn(Bool) + 'static> = &block;
    let _: () = unsafe {
        msg_send![class, requestAccessForMediaType: &*media_type, completionHandler: block]
    };
    rx.recv_timeout(std::time::Duration::from_secs(60))
        .map_err(|_| "timed out waiting for macOS microphone permission prompt".to_string())
}

#[cfg(target_os = "macos")]
fn prompt_for_microphone_permission_if_needed() -> bool {
    match macos_microphone_authorization_status() {
        MacosMicrophoneAuthorization::Authorized => true,
        MacosMicrophoneAuthorization::NotDetermined => {
            std::thread::spawn(|| {
                if let Err(e) = request_macos_microphone_access() {
                    native_debug_log(format!("microphone permission request failed error={e}"));
                }
            });
            false
        }
        _ => false,
    }
}

#[cfg(target_os = "macos")]
#[link(name = "AVFoundation", kind = "framework")]
extern "C" {}

fn input_permission_status() -> InputPermissionStatus {
    #[cfg(target_os = "macos")]
    {
        let granted = accessibility_is_trusted();
        let detail = if granted {
            "Zerm can control the focused app for the hotkey and auto-paste.".to_string()
        } else {
            format!(
                "Zerm needs macOS Accessibility permission for the hotkey and auto-paste. Click Open Accessibility Settings, then enable /Applications/Zerm.app and return to Zerm.{}",
                macos_signature_permission_note().unwrap_or_default()
            )
        };
        InputPermissionStatus {
            required: true,
            granted,
            title: "Allow Accessibility".to_string(),
            detail,
            settings_label: "Open Accessibility Settings".to_string(),
        }
    }

    #[cfg(target_os = "windows")]
    {
        InputPermissionStatus {
            required: false,
            granted: true,
            title: "Input permissions ready".to_string(),
            detail: "Windows does not require an extra app-level input permission for Zerm's current hotkey setup.".to_string(),
            settings_label: "Open Settings".to_string(),
        }
    }

    #[cfg(target_os = "linux")]
    {
        InputPermissionStatus {
            required: false,
            granted: true,
            title: "Input permissions ready".to_string(),
            detail: "Linux does not require an extra app-level input permission for Zerm's current hotkey setup.".to_string(),
            settings_label: "Open Settings".to_string(),
        }
    }

    #[cfg(not(any(target_os = "macos", target_os = "windows", target_os = "linux")))]
    {
        InputPermissionStatus {
            required: false,
            granted: true,
            title: "Input permissions ready".to_string(),
            detail: "This platform does not require an extra app-level input permission for Zerm's current input setup.".to_string(),
            settings_label: "Open Settings".to_string(),
        }
    }
}

fn microphone_permission_status() -> InputPermissionStatus {
    #[cfg(target_os = "macos")]
    {
        let status = macos_microphone_authorization_status();
        let granted = status.is_granted();
        let detail = if granted {
            "Zerm can read audio from the selected microphone.".to_string()
        } else {
            format!(
                "Zerm needs macOS Microphone permission before speech can be captured. Current status: {}. Open Microphone Settings, enable /Applications/Zerm.app, then retry.",
                status.label()
            )
        };
        InputPermissionStatus {
            required: true,
            granted,
            title: "Allow Microphone".to_string(),
            detail,
            settings_label: "Open Microphone Settings".to_string(),
        }
    }

    #[cfg(not(target_os = "macos"))]
    {
        InputPermissionStatus {
            required: false,
            granted: true,
            title: "Microphone ready".to_string(),
            detail: "No extra app-level microphone permission is reported for this platform."
                .to_string(),
            settings_label: "Open Settings".to_string(),
        }
    }
}

#[cfg(target_os = "macos")]
fn focus_is_target(expected: &FocusIdentity) -> bool {
    matches!(
        frontmost_focus_identity(),
        Some(current) if current.pid == expected.pid && current.bundle_id == expected.bundle_id
    )
}

#[cfg(not(target_os = "macos"))]
fn focus_is_target(_expected: &FocusIdentity) -> bool {
    false
}

#[cfg(target_os = "macos")]
fn activate_paste_target(expected: &FocusIdentity) -> bool {
    use objc2_app_kit::{NSApplicationActivationOptions, NSRunningApplication};
    use std::time::{Duration, Instant};

    if focus_is_target(expected) {
        return true;
    }

    let Some(app) = NSRunningApplication::runningApplicationWithProcessIdentifier(expected.pid)
    else {
        log::warn!(
            "auto-paste: original target app is no longer running: {:?}",
            expected
        );
        return false;
    };

    // Use both documented activation bits without referencing the deprecated
    // constant directly. On current macOS it still improves reliability for
    // LSUIElement/menu-bar style apps returning focus to a normal app.
    if app.activateWithOptions(NSApplicationActivationOptions(0b11)) {
        let deadline = Instant::now() + Duration::from_millis(900);
        while Instant::now() < deadline {
            if focus_is_target(expected) {
                return true;
            }
            std::thread::sleep(Duration::from_millis(50));
        }
    }

    if focus_is_target(expected) {
        true
    } else {
        log::warn!("auto-paste: could not restore focus to {:?}", expected);
        false
    }
}

/// Send a Cmd+V keystroke to the currently focused application via
/// CoreGraphics. We never grab focus ourselves (the pill has `focus: false`),
/// so the previously focused app is still the recipient. If nothing is focused
/// for text input the keystroke is a no-op.
#[cfg(target_os = "macos")]
fn send_paste_via_core_graphics() -> bool {
    use core_graphics::event::{CGEvent, CGEventFlags, CGEventTapLocation, KeyCode};
    use core_graphics::event_source::{CGEventSource, CGEventSourceStateID};
    use std::time::Duration;

    let source = match CGEventSource::new(CGEventSourceStateID::HIDSystemState) {
        Ok(source) => source,
        Err(()) => {
            log::warn!("auto-paste: could not create CoreGraphics event source");
            native_debug_log(
                "paste Cmd+V CoreGraphics sent=false error=\"could not create event source\"",
            );
            return false;
        }
    };

    let command_flag = CGEventFlags::CGEventFlagCommand;
    let key_down = match CGEvent::new_keyboard_event(source.clone(), KeyCode::ANSI_V, true) {
        Ok(event) => event,
        Err(()) => {
            log::warn!("auto-paste: could not create Cmd+V key-down event");
            native_debug_log(
                "paste Cmd+V CoreGraphics sent=false error=\"could not create key-down event\"",
            );
            return false;
        }
    };
    let key_up = match CGEvent::new_keyboard_event(source.clone(), KeyCode::ANSI_V, false) {
        Ok(event) => event,
        Err(()) => {
            log::warn!("auto-paste: could not create Cmd+V key-up event");
            native_debug_log(
                "paste Cmd+V CoreGraphics sent=false error=\"could not create key-up event\"",
            );
            return false;
        }
    };

    key_down.set_flags(command_flag);
    key_up.set_flags(command_flag);

    key_down.post(CGEventTapLocation::HID);
    std::thread::sleep(Duration::from_millis(20));
    key_up.post(CGEventTapLocation::HID);
    native_debug_log("paste Cmd+V CoreGraphics sent=true");
    true
}

#[cfg(target_os = "macos")]
fn send_paste_via_system_events() -> bool {
    let script = r#"tell application "System Events" to keystroke "v" using command down"#;
    match std::process::Command::new("/usr/bin/osascript")
        .args(["-e", script])
        .output()
    {
        Ok(out) if out.status.success() => {
            native_debug_log("paste Cmd+V SystemEvents sent=true");
            true
        }
        Ok(out) => {
            let stdout = String::from_utf8_lossy(&out.stdout);
            let stderr = String::from_utf8_lossy(&out.stderr);
            log::warn!(
                "auto-paste: System Events paste failed: {}{}",
                stdout,
                stderr
            );
            native_debug_log(format!(
                "paste Cmd+V SystemEvents sent=false status={:?} stdout={:?} stderr={:?}",
                out.status.code(),
                stdout,
                stderr
            ));
            false
        }
        Err(e) => {
            log::warn!("auto-paste: failed to launch System Events paste: {e}");
            native_debug_log(format!(
                "paste Cmd+V SystemEvents sent=false launch_error={e}"
            ));
            false
        }
    }
}

#[cfg(target_os = "macos")]
fn insertion_plan_for_target(expected: &FocusIdentity, text: &str) -> InsertionPlan {
    let mut context = InsertionAppContext::new(InsertionPlatform::Macos)
        .with_app_id(expected.bundle_id.clone())
        .with_focused_text_input(true);
    if let Some(app_name) = expected.app_name.clone() {
        context = context.with_app_name(app_name);
    }
    let request = InsertionRequest::new(text, Some(context));
    StrategySelector::default().select_plan(&request)
}

#[cfg(target_os = "macos")]
fn execute_macos_insertion_strategy(
    strategy: InsertionStrategy,
    target: &CapturedPasteTarget,
    text: &str,
) -> Result<(), String> {
    match strategy {
        InsertionStrategy::MacAccessibilityFocusedValue
        | InsertionStrategy::MacAccessibilitySelectedText => {
            insert_text_via_captured_accessibility(target, text)
        }
        InsertionStrategy::MacClipboardKeystroke => {
            verified_clipboard_paste_to_captured_target(target, text, send_paste_via_core_graphics)
        }
        InsertionStrategy::MacSystemEventsKeystroke => {
            verified_clipboard_paste_to_captured_target(target, text, send_paste_via_system_events)
        }
        other => Err(format!("strategy {other:?} is not implemented on macOS")),
    }
}

#[cfg(target_os = "macos")]
fn verified_clipboard_paste_to_captured_target(
    target: &CapturedPasteTarget,
    text: &str,
    paste: fn() -> bool,
) -> Result<(), String> {
    use std::time::{Duration, Instant};

    let element = target.focused_element.as_ref();
    let before = element
        .and_then(ax_read_text)
        .or_else(|| target.initial_text.clone());
    if !paste() {
        return Err("paste event could not be posted".to_string());
    }

    if let Some(element) = element {
        let deadline = Instant::now() + Duration::from_millis(1_800);
        while Instant::now() < deadline {
            if let Some(after) = ax_read_text(element) {
                if ax_text_has_new_insert(before.as_deref(), &after, text) {
                    return Ok(());
                }
            }
            std::thread::sleep(Duration::from_millis(50));
        }
    }

    if macos_target_has_known_clipboard_paste(&target.identity) {
        std::thread::sleep(Duration::from_millis(500));
        let frontmost_after_paste = frontmost_focus_identity();
        if frontmost_after_paste.as_ref().is_some_and(|current| {
            current.pid == target.identity.pid && current.bundle_id == target.identity.bundle_id
        }) || frontmost_after_paste.is_none()
        {
            log::info!(
                "auto-paste: accepting clipboard paste for known macOS target {} after focus stayed on captured app",
                target.identity.bundle_id
            );
            native_debug_log(format!(
                "paste known_clipboard_target accepted target={} frontmost_after_paste={} confirmation=known_app_clipboard_paste",
                format_focus_identity(Some(&target.identity)),
                format_focus_identity(frontmost_after_paste.as_ref())
            ));
            return Ok(());
        }
        native_debug_log(format!(
            "paste known_clipboard_target rejected target={} frontmost_after_paste={}",
            format_focus_identity(Some(&target.identity)),
            format_focus_identity(frontmost_after_paste.as_ref())
        ));
        return Err(
            "paste event was posted but focus left the captured target before confirmation"
                .to_string(),
        );
    }

    Err(
        "paste event was posted but the captured AX element did not contain the inserted text"
            .to_string(),
    )
}

#[cfg(target_os = "macos")]
fn macos_target_has_known_clipboard_paste(identity: &FocusIdentity) -> bool {
    matches!(
        identity.bundle_id.as_str(),
        "com.apple.Safari"
            | "company.thebrowser.Browser"
            | "com.google.Chrome"
            | "com.microsoft.edgemac"
            | "com.brave.Browser"
            | "com.tinyspeck.slackmacgap"
            | "com.hnc.Discord"
            | "com.microsoft.VSCode"
            | "com.todesktop.230313mzl4w4u92"
            | "com.apple.Terminal"
            | "com.googlecode.iterm2"
            | "dev.warp.Warp-Stable"
            | "net.kovidgoyal.kitty"
            | "com.mitchellh.ghostty"
            | "com.github.wez.wezterm"
            | "org.alacritty"
            | "com.cmuxterm.app"
    )
}

#[cfg(target_os = "macos")]
fn macos_target_is_direct_ax_class(identity: &FocusIdentity) -> bool {
    matches!(
        identity.bundle_id.as_str(),
        "com.apple.TextEdit" | "com.apple.Notes" | "com.apple.mail" | "com.apple.iWork.Pages"
    )
}

#[cfg(target_os = "macos")]
fn direct_ax_success_or_verify(
    target: &CapturedPasteTarget,
    element: &MacAxElement,
    before: Option<&str>,
    inserted: &str,
) -> Result<(), String> {
    match ax_verify_inserted(element, before, inserted) {
        Ok(()) => Ok(()),
        Err(err) if macos_target_is_direct_ax_class(&target.identity) => {
            log::info!(
                "auto-paste: accepting direct AX insertion for known native target {} after AX set succeeded but verification was limited: {}",
                target.identity.bundle_id,
                err
            );
            Ok(())
        }
        Err(err) => Err(format!(
            "direct insertion was accepted but could not be verified; refusing paste fallback to avoid duplicate text ({err})"
        )),
    }
}

#[cfg(target_os = "macos")]
fn send_paste_to_target(
    target: CapturedPasteTarget,
    text: &str,
) -> Result<InsertionDiagnostic, String> {
    if !auto_paste_is_ready() {
        native_debug_log(format!(
            "paste aborted AXIsProcessTrusted=false target={}",
            format_focus_identity(Some(&target.identity))
        ));
        return Err(auto_paste_permission_message());
    }

    let plan = insertion_plan_for_target(&target.identity, text);
    native_debug_log(format!(
        "paste plan target={} captured_ax_role={:?} captured_ax_subrole={:?} captured_ax_value_readable={} chosen_insertion_strategies={:?} unavailable_reason={:?}",
        format_focus_identity(Some(&target.identity)),
        target.role.as_deref(),
        target.subrole.as_deref(),
        target.ax_value_readable,
        plan.strategies,
        plan.unavailable_reason
    ));
    if !plan.available() {
        return Err(format!(
            "Auto-paste could not choose an insertion strategy: {:?}",
            plan.unavailable_reason
        ));
    }

    if !activate_paste_target(&target.identity) {
        native_debug_log(format!(
            "paste focus_restore_failed target={} frontmost_before_paste={}",
            format_focus_identity(Some(&target.identity)),
            format_focus_identity(frontmost_focus_identity().as_ref())
        ));
        return Err(format!(
            "Auto-paste could not refocus the app that was active when recording started ({:?}).",
            target.identity
        ));
    }

    let mut failures = Vec::new();
    for strategy in plan.strategies {
        native_debug_log(format!(
            "paste strategy begin strategy={strategy:?} target={} frontmost_immediately_before_paste={}",
            format_focus_identity(Some(&target.identity)),
            format_focus_identity(frontmost_focus_identity().as_ref())
        ));
        match execute_macos_insertion_strategy(strategy, &target, text) {
            Ok(()) => {
                log::info!("auto-paste strategy {strategy:?} completed");
                native_debug_log(format!(
                    "paste strategy success strategy={strategy:?} target={} frontmost_immediately_after_paste={}",
                    format_focus_identity(Some(&target.identity)),
                    format_focus_identity(frontmost_focus_identity().as_ref())
                ));
                return Ok(InsertionDiagnostic::pasted(
                    &target.identity,
                    format!("{strategy:?}"),
                ));
            }
            Err(e) => {
                log::warn!("auto-paste strategy {strategy:?} failed: {e}");
                native_debug_log(format!(
                    "paste strategy failure strategy={strategy:?} target={} error={e} frontmost_immediately_after_paste={}",
                    format_focus_identity(Some(&target.identity)),
                    format_focus_identity(frontmost_focus_identity().as_ref())
                ));
                if e.contains("refusing paste fallback") {
                    return Err(e);
                }
                failures.push(format!("{strategy:?}: {e}"));
            }
        }
    }

    let message = format!(
        "Auto-paste failed after trying planned strategies. {}",
        failures.join(" | ")
    );
    native_debug_log(format!(
        "paste failed target={} failures={failures:?} frontmost_immediately_after_paste={}",
        format_focus_identity(Some(&target.identity)),
        format_focus_identity(frontmost_focus_identity().as_ref())
    ));
    Err(message)
}

#[cfg(not(target_os = "macos"))]
fn send_paste_to_target(
    _target: CapturedPasteTarget,
    _text: &str,
) -> Result<InsertionDiagnostic, String> {
    // TODO: cross-platform keystroke synthesis (Win: SendInput; Linux: xdotool/wtype)
    log::debug!("auto-paste: not implemented on this platform yet");
    Err("Auto-paste keystroke synthesis is not implemented on this platform yet.".to_string())
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

fn show_pill(app: &AppHandle) {
    let Some(window) = app.get_webview_window("main") else {
        return;
    };
    let pipeline = app
        .try_state::<Arc<Pipeline>>()
        .map(|state| state.inner().clone());
    let dispatch_window = window.clone();
    let pill_window = window.clone();
    let dispatch_pipeline = pipeline.clone();
    if let Err(e) = dispatch_window.run_on_main_thread(move || {
        present_pill_window(&pill_window, dispatch_pipeline.as_deref());
    }) {
        log::warn!("pill: could not dispatch presentation to main thread: {e:#}");
        present_pill_window(&window, pipeline.as_deref());
    }
}

fn raise_pill(app: &AppHandle) {
    let Some(window) = app.get_webview_window("main") else {
        return;
    };
    let dispatch_window = window.clone();
    let pill_window = window.clone();
    if let Err(e) = dispatch_window.run_on_main_thread(move || {
        #[cfg(target_os = "macos")]
        {
            if native_pill_panel_enabled() {
                raise_native_pill_panel(&pill_window);
            } else {
                raise_pill_window(&pill_window);
            }
        }
        #[cfg(not(target_os = "macos"))]
        raise_pill_window(&pill_window);
    }) {
        log::warn!("pill: could not dispatch raise to main thread: {e:#}");
        #[cfg(target_os = "macos")]
        {
            if native_pill_panel_enabled() {
                raise_native_pill_panel(&window);
            } else {
                raise_pill_window(&window);
            }
        }
        #[cfg(not(target_os = "macos"))]
        raise_pill_window(&window);
    }
}

fn present_pill_window(window: &WebviewWindow, pipeline: Option<&Pipeline>) {
    native_debug_log(format!(
        "pill show begin window_frame_before_show=\"{}\" frontmost_before_showing_pill={}",
        window_frame_string(window),
        format_focus_identity(frontmost_focus_identity().as_ref())
    ));
    let placement = position_pill_if_needed(window, pipeline);
    #[cfg(target_os = "macos")]
    {
        if native_pill_panel_enabled() {
            present_native_pill_panel(window, placement.as_ref());
            native_debug_log(format!(
                "pill show end window_frame_after_show=\"{}\" frontmost_after_showing_pill={} target_screen=\"{}\" pill_screen=\"{}\" macos_visible_overlay=native_NSPanel",
                window_frame_string(window),
                format_focus_identity(frontmost_focus_identity().as_ref()),
                target_screen_string(window, pipeline),
                pill_screen_string(window)
            ));
        } else {
            raise_pill_window(window);
            let _ = window.show();
            raise_pill_window(window);
            native_debug_log(format!(
                "pill show end window_frame_after_show=\"{}\" frontmost_after_showing_pill={} target_screen=\"{}\" pill_screen=\"{}\" macos_visible_overlay=tauri_NSWindow {}",
                window_frame_string(window),
                format_focus_identity(frontmost_focus_identity().as_ref()),
                target_screen_string(window, pipeline),
                pill_screen_string(window),
                macos_window_debug_info(window)
            ));
        }
    }

    #[cfg(not(target_os = "macos"))]
    {
        raise_pill_window(window);
        let _ = window.show();
        raise_pill_window(window);
        native_debug_log(format!(
        "pill show end window_frame_after_show=\"{}\" frontmost_after_showing_pill={} target_screen=\"{}\" pill_screen=\"{}\" {}",
        window_frame_string(window),
        format_focus_identity(frontmost_focus_identity().as_ref()),
        target_screen_string(window, pipeline),
        pill_screen_string(window),
        macos_window_debug_info(window)
    ));
    }
}

fn raise_pill_window(window: &WebviewWindow) {
    let _ = window.set_visible_on_all_workspaces(true);
    let _ = window.set_always_on_top(true);
    configure_pill_window(window);
    order_pill_front(window);
}

#[cfg(target_os = "macos")]
fn native_pill_panel_enabled() -> bool {
    std::env::var("ZERM_USE_NATIVE_PILL_PANEL")
        .map(|value| {
            matches!(
                value.trim().to_ascii_lowercase().as_str(),
                "1" | "true" | "yes" | "on"
            )
        })
        .unwrap_or(false)
}

#[cfg(not(target_os = "macos"))]
fn native_pill_panel_enabled() -> bool {
    false
}

#[cfg(target_os = "macos")]
fn configure_native_pill_panel(panel: *mut objc2::runtime::AnyObject) {
    use objc2::msg_send;

    if panel.is_null() {
        return;
    }
    unsafe {
        let collection_behavior: u64 = (1 << 0) | (1 << 3) | (1 << 4) | (1 << 6) | (1 << 8);
        let overlay_window_level: i64 = 1000;
        let _: () = msg_send![panel, setCollectionBehavior: collection_behavior];
        let _: () = msg_send![panel, setLevel: overlay_window_level];
        let _: () = msg_send![panel, setHidesOnDeactivate: false];
        let _: () = msg_send![panel, setCanHide: false];
        let _: () = msg_send![panel, setMovable: true];
        let _: () = msg_send![panel, setMovableByWindowBackground: true];
        let _: () = msg_send![panel, setReleasedWhenClosed: false];
        let _: () = msg_send![panel, setOpaque: false];
        if let Some(color_class) = objc_class(b"NSColor\0") {
            let clear_color: *mut objc2::runtime::AnyObject = msg_send![color_class, clearColor];
            let _: () = msg_send![panel, setBackgroundColor: clear_color];
        }
    }
}

#[cfg(target_os = "macos")]
fn native_pill_panel_for_window(
    window: &WebviewWindow,
    placement: Option<&PillPlacement>,
) -> Option<*mut objc2::runtime::AnyObject> {
    use objc2::msg_send;
    use objc2::runtime::AnyObject;

    if let Some(existing) = *NATIVE_PILL_PANEL
        .lock()
        .expect("native pill panel lock poisoned")
    {
        if let Some(placement) = placement {
            native_debug_log(format!(
                "native pill panel reuse step=sync_frame_skipped reason=\"frame sync intentionally skipped after webview reparent; source ns_window/frame reads and NSPanel setFrame are crash-prone\" desired_position={:?} target_monitor=\"{}\"",
                placement.position,
                monitor_string(&placement.monitor)
            ));
        }
        return Some(existing.panel as *mut AnyObject);
    }

    let source = window.ns_window().ok()?;
    if source.is_null() {
        return None;
    }
    let source_window: *mut AnyObject = source.cast();
    let panel_class = objc_class(b"NSPanel\0")?;

    unsafe {
        let source_frame: objc2_foundation::NSRect = msg_send![source_window, frame];
        let frame = placement
            .map(|placement| {
                appkit_panel_frame_for_physical_top_left(
                    placement.position,
                    &placement.monitor,
                    source_frame.size.width,
                    source_frame.size.height,
                )
            })
            .unwrap_or(source_frame);
        let style_mask: u64 = (1 << 7) | (1 << 13);
        let panel_alloc: *mut AnyObject = msg_send![panel_class, alloc];
        if panel_alloc.is_null() {
            return None;
        }
        let panel: *mut AnyObject = msg_send![
            panel_alloc,
            initWithContentRect: frame,
            styleMask: style_mask,
            backing: 2_u64,
            defer: false
        ];
        if panel.is_null() {
            return None;
        }

        configure_native_pill_panel(panel);

        let content_view: *mut AnyObject = msg_send![source_window, contentView];
        if !content_view.is_null() {
            let _: () = msg_send![panel, setContentView: content_view];
            native_debug_log("native pill panel reparented Tauri webview contentView into NSPanel");
        } else {
            native_debug_log(
                "native pill panel created without Tauri contentView; source contentView was null",
            );
        }

        *NATIVE_PILL_PANEL
            .lock()
            .expect("native pill panel lock poisoned") = Some(NativePillPanel {
            panel: panel as usize,
        });
        native_debug_log(format!(
            "native pill panel created at initial frame desired_position={:?} target_monitor=\"{}\" {} {} source_window=\"{}\" source_frame=\"{}\"",
            placement.map(|placement| placement.position),
            placement
                .map(|placement| monitor_string(&placement.monitor))
                .unwrap_or_else(|| "<none>".to_string()),
            appkit_window_debug_info("native_panel", panel),
            appkit_window_frame_info("native_panel", panel),
            appkit_window_debug_info("tauri_source", source_window),
            appkit_window_frame_info("tauri_source", source_window)
        ));
        Some(panel)
    }
}

#[cfg(target_os = "macos")]
fn present_native_pill_panel(window: &WebviewWindow, placement: Option<&PillPlacement>) {
    use objc2::msg_send;

    let Some(panel) = native_pill_panel_for_window(window, placement) else {
        native_debug_log("native pill panel show failed; could not create NSPanel");
        return;
    };
    if let Some(placement) = placement {
        native_debug_log(format!(
            "native pill panel show step=sync_frame_skipped reason=\"frame sync intentionally skipped after webview reparent; panel was created at initial frame and live NSPanel reposition is crash-prone\" desired_position={:?} target_monitor=\"{}\"",
            placement.position,
            monitor_string(&placement.monitor)
        ));
    } else {
        native_debug_log(
            "native pill panel show step=sync_frame_skipped reason=\"no placement available\"",
        );
    }
    native_debug_log("native pill panel show step=configure_begin");
    configure_native_pill_panel(panel);
    native_debug_log("native pill panel show step=configure_end");
    native_debug_log("native pill panel show step=order_front_begin");
    unsafe {
        let _: () = msg_send![panel, orderFrontRegardless];
    }
    native_debug_log("native pill panel show step=order_front_end");
    native_debug_log("native pill panel show step=source_order_out_skipped reason=\"orderOut crashed after webview reparent\"");
    native_debug_log(format!(
        "native pill panel show complete visible_overlay=native_NSPanel {} {}",
        appkit_window_debug_info("native_panel", panel),
        appkit_window_frame_info("native_panel", panel)
    ));
}

#[cfg(not(target_os = "macos"))]
fn present_native_pill_panel(_window: &WebviewWindow) {}

#[cfg(target_os = "macos")]
fn raise_native_pill_panel(window: &WebviewWindow) {
    use objc2::msg_send;

    let Some(panel) = native_pill_panel_for_window(window, None) else {
        return;
    };
    native_debug_log("native pill panel raise step=sync_frame_skipped reason=\"frame sync intentionally skipped after webview reparent; raise must not reposition visible pill\"");
    native_debug_log("native pill panel raise step=configure_begin");
    configure_native_pill_panel(panel);
    native_debug_log("native pill panel raise step=configure_end");
    native_debug_log("native pill panel raise step=order_front_begin");
    unsafe {
        let _: () = msg_send![panel, orderFrontRegardless];
    }
    native_debug_log("native pill panel raise step=order_front_end");
    native_debug_log(format!(
        "native pill panel raise {} {}",
        appkit_window_debug_info("native_panel", panel),
        appkit_window_frame_info("native_panel", panel)
    ));
}

#[cfg(not(target_os = "macos"))]
fn raise_native_pill_panel(_window: &WebviewWindow) {}

#[cfg(target_os = "macos")]
fn hide_native_pill_panel() {
    use objc2::msg_send;
    use objc2::runtime::AnyObject;

    let Some(panel) = *NATIVE_PILL_PANEL
        .lock()
        .expect("native pill panel lock poisoned")
    else {
        return;
    };
    let panel = panel.panel as *mut AnyObject;
    unsafe {
        let _: () = msg_send![panel, orderOut: std::ptr::null_mut::<AnyObject>()];
    }
    native_debug_log(format!(
        "native pill panel hide {} {}",
        appkit_window_debug_info("native_panel", panel),
        appkit_window_frame_info("native_panel", panel)
    ));
}

#[cfg(not(target_os = "macos"))]
fn hide_native_pill_panel() {}

fn position_pill_if_needed(
    window: &WebviewWindow,
    pipeline: Option<&Pipeline>,
) -> Option<PillPlacement> {
    let Some(target_monitor) = pill_target_monitor(window, pipeline) else {
        native_debug_log("pill position set_position_called=false skipped_reason=\"no target/current/primary monitor available\"");
        return None;
    };
    let target_monitor_key = monitor_key(&target_monitor);
    let (legacy_saved, per_monitor_saved) = pipeline
        .map(|state| {
            let persistent = state.persistent.lock();
            (
                persistent.pill_position,
                persistent
                    .pill_positions_by_monitor
                    .get(&target_monitor_key)
                    .copied(),
            )
        })
        .unwrap_or((None, None));

    let (pos, reason) = (
        default_pill_position_for_monitor(&target_monitor),
        "primary-monitor fail-safe position",
    );

    let pos = clamp_pill_position_to_monitor(pos, &target_monitor);
    let placement = PillPlacement {
        position: pos,
        monitor: target_monitor.clone(),
    };
    #[cfg(target_os = "macos")]
    {
        if native_pill_panel_enabled() {
            native_debug_log(format!(
                "pill position set_position_called=false skipped_reason=\"macos native NSPanel owns frame; moving Tauri source window crashes after webview reparent\" reason=\"{reason}\" target_monitor=\"{}\" saved_for_target_monitor={per_monitor_saved:?} legacy_saved={legacy_saved:?} desired_position={pos:?} coordinate_space=tauri_physical_pixels",
                monitor_string(&target_monitor)
            ));
            Some(placement)
        } else {
            if current_pill_position(window) == Some(pos) {
                native_debug_log(format!(
                    "pill position set_position_called=false skipped_reason=\"already at desired position\" reason=\"{reason}\" target_monitor=\"{}\" saved_for_target_monitor={per_monitor_saved:?} legacy_saved={legacy_saved:?} desired_position={pos:?} coordinate_space=tauri_physical_pixels macos_visible_overlay=tauri_NSWindow",
                    monitor_string(&target_monitor)
                ));
            } else {
                let result = window.set_position(tauri::Position::Physical(PhysicalPosition {
                    x: pos.x,
                    y: pos.y,
                }));
                native_debug_log(format!(
                    "pill position set_position_called=true reason=\"{reason}\" target_monitor=\"{}\" requested_position={pos:?} coordinate_space=tauri_physical_pixels saved_for_target_monitor={per_monitor_saved:?} legacy_saved={legacy_saved:?} result={result:?} macos_visible_overlay=tauri_NSWindow",
                    monitor_string(&target_monitor)
                ));
            }
            Some(placement)
        }
    }

    #[cfg(not(target_os = "macos"))]
    {
        if current_pill_position(window) == Some(pos) {
            native_debug_log(format!(
                "pill position set_position_called=false skipped_reason=\"already at desired position\" reason=\"{reason}\" target_monitor=\"{}\" saved_for_target_monitor={per_monitor_saved:?} legacy_saved={legacy_saved:?} desired_position={pos:?} coordinate_space=tauri_physical_pixels",
                monitor_string(&target_monitor)
            ));
        } else {
            let result = window.set_position(tauri::Position::Physical(PhysicalPosition {
                x: pos.x,
                y: pos.y,
            }));
            native_debug_log(format!(
                "pill position set_position_called=true reason=\"{reason}\" target_monitor=\"{}\" requested_position={pos:?} coordinate_space=tauri_physical_pixels saved_for_target_monitor={per_monitor_saved:?} legacy_saved={legacy_saved:?} result={result:?}",
                monitor_string(&target_monitor)
            ));
        }
        Some(placement)
    }
}

fn current_pill_position(window: &WebviewWindow) -> Option<PillPosition> {
    let pos = window.outer_position().ok()?;
    Some(PillPosition { x: pos.x, y: pos.y })
}

fn pill_target_monitor(window: &WebviewWindow, pipeline: Option<&Pipeline>) -> Option<Monitor> {
    #[cfg(target_os = "macos")]
    {
        if let Some(monitor) = window.primary_monitor().ok().flatten() {
            native_debug_log(format!(
                "pill target monitor source=primary_monitor_fail_safe monitor=\"{}\"",
                monitor_string(&monitor)
            ));
            return Some(monitor);
        }
        native_debug_log(format!(
            "pill target monitor source=primary_monitor_fail_safe monitor=<none> fallback_to_current_or_captured pipeline_present={}",
            pipeline.is_some()
        ));
    }

    window
        .current_monitor()
        .ok()
        .flatten()
        .or_else(|| window.primary_monitor().ok().flatten())
}

fn pill_position_is_visible_on_monitor(pos: PillPosition, monitor: &Monitor) -> bool {
    let origin = monitor.position();
    let size = monitor.size();
    let max_x = origin.x + size.width as i32;
    let max_y = origin.y + size.height as i32;
    pos.x + PILL_WIDTH > origin.x
        && pos.x < max_x
        && pos.y + PILL_HEIGHT > origin.y
        && pos.y < max_y
}

fn pill_position_is_visible(window: &WebviewWindow, pos: PillPosition) -> bool {
    let Ok(monitors) = window.available_monitors() else {
        return false;
    };

    monitors
        .iter()
        .any(|monitor| pill_position_is_visible_on_monitor(pos, monitor))
}

fn default_pill_position_for_monitor(monitor: &Monitor) -> PillPosition {
    let origin = monitor.position();
    let size = monitor.size();
    let min_x = origin.x;
    let min_y = origin.y;
    let max_x = (origin.x + size.width as i32 - PILL_WIDTH).max(min_x);
    let max_y = (origin.y + size.height as i32 - PILL_HEIGHT).max(min_y);

    PillPosition {
        x: (min_x + ((size.width as i32 - PILL_WIDTH) / 2).max(0)).clamp(min_x, max_x),
        y: (min_y + 28.min((size.height as i32 - PILL_HEIGHT).max(0))).clamp(min_y, max_y),
    }
}

fn clamp_pill_position_to_monitor(pos: PillPosition, monitor: &Monitor) -> PillPosition {
    let origin = monitor.position();
    let size = monitor.size();
    let max_x = (origin.x + size.width as i32 - PILL_WIDTH).max(origin.x);
    let max_y = (origin.y + size.height as i32 - PILL_HEIGHT).max(origin.y);
    PillPosition {
        x: pos.x.clamp(origin.x, max_x),
        y: pos.y.clamp(origin.y, max_y),
    }
}

#[cfg(target_os = "macos")]
fn configure_pill_window(window: &WebviewWindow) {
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
        // The default macOS path uses the Tauri NSWindow directly. The old
        // native NSPanel path remains opt-in because reparenting WebKit views
        // has caused AppKit aborts on recent macOS builds.
        let collection_behavior: u64 = (1 << 0) | (1 << 3) | (1 << 4) | (1 << 6) | (1 << 8);
        let overlay_window_level: i64 = 1000;
        let _: () = msg_send![obj, setCollectionBehavior: collection_behavior];
        let _: () = msg_send![obj, setLevel: overlay_window_level];
        let _: () = msg_send![obj, setHidesOnDeactivate: false];
        let _: () = msg_send![obj, setCanHide: false];
        let _: () = msg_send![obj, setMovable: true];
        let _: () = msg_send![obj, setMovableByWindowBackground: true];
        let _: () = msg_send![obj, setOpaque: false];
        if let Some(color_class) = objc_class(b"NSColor\0") {
            let clear_color: *mut AnyObject = msg_send![color_class, clearColor];
            let _: () = msg_send![obj, setBackgroundColor: clear_color];
        }
    }
}

#[cfg(not(target_os = "macos"))]
fn configure_pill_window(_window: &WebviewWindow) {}

#[cfg(target_os = "macos")]
fn order_pill_front(window: &WebviewWindow) {
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
        let _: () = msg_send![obj, orderFrontRegardless];
    }
}

#[cfg(not(target_os = "macos"))]
fn order_pill_front(_window: &WebviewWindow) {}

fn hide_pill(app: &AppHandle) {
    hide_native_pill_panel();
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
    let action = {
        let mut lifecycle = pipeline.lifecycle.lock();
        request_toggle_transition(&mut lifecycle)
    };

    match action {
        RecordingAction::Start => {
            log::info!("toggle → start");
            native_debug_log("recording lifecycle -> starting source=\"toggle\"");
            handle_press(app, pipeline);
        }
        RecordingAction::Stop => {
            log::info!("toggle → stop");
            native_debug_log("recording lifecycle -> stopping source=\"toggle\"");
            handle_release(app, pipeline);
        }
        RecordingAction::PendingStop => native_debug_log(
            "toggle stop deferred reason=\"capture is still starting\" lifecycle=starting",
        ),
        RecordingAction::KeepRecording => native_debug_log(
            "toggle release ignored reason=\"short tap means keep recording\" lifecycle=starting",
        ),
        RecordingAction::Ignore => {
            native_debug_log("toggle ignored reason=\"recording lifecycle busy\"")
        }
    }
}

fn handle_hotkey_press(app: &AppHandle, pipeline: &Pipeline) {
    let action = {
        let mut lifecycle = pipeline.lifecycle.lock();
        request_press_transition(&mut lifecycle)
    };
    match action {
        RecordingAction::Start => {
            native_debug_log("recording lifecycle -> starting source=\"hotkey_press\"");
            handle_press(app, pipeline);
        }
        RecordingAction::Stop => {
            native_debug_log("recording lifecycle -> stopping source=\"hotkey_press_toggle\"");
            handle_release(app, pipeline);
        }
        _ => native_debug_log("hotkey press ignored reason=\"recording lifecycle busy\""),
    }
}

fn handle_hotkey_release(app: &AppHandle, pipeline: &Pipeline) {
    let action = {
        let mut lifecycle = pipeline.lifecycle.lock();
        request_release_transition(&mut lifecycle)
    };

    match action {
        RecordingAction::Stop => {
            native_debug_log("recording lifecycle -> stopping source=\"hotkey_release\"");
            handle_release(app, pipeline);
        }
        RecordingAction::PendingStop => native_debug_log(
            "hotkey release deferred reason=\"capture is still starting\" lifecycle=starting",
        ),
        RecordingAction::KeepRecording => native_debug_log(
            "hotkey release ignored reason=\"short tap keeps recording; press hotkey again to stop\"",
        ),
        _ => native_debug_log("hotkey release ignored reason=\"recording was not active\""),
    }
}

fn handle_press(app: &AppHandle, pipeline: &Pipeline) {
    let frontmost_before_press = frontmost_focus_identity();
    native_debug_log(format!(
        "recording cycle begin app_bundle_id={} binary_path=\"{}\" AXIsProcessTrusted={} frontmost_app_before_hotkey_press={} frontmost_app_before_showing_pill={}",
        app.config().identifier.as_str(),
        current_binary_path_string(),
        accessibility_is_trusted(),
        format_focus_identity(frontmost_before_press.as_ref()),
        format_focus_identity(frontmost_focus_identity().as_ref())
    ));
    let input_permission = input_permission_status();
    if input_permission.required && !input_permission.granted {
        pipeline.set_idle("input permission missing");
        native_debug_log(format!(
            "recording cycle aborted reason=\"input permission missing\" detail={:?}",
            input_permission.detail
        ));
        emit_error(app, input_permission.detail);
        open_dashboard_window(app);
        #[cfg(target_os = "macos")]
        {
            prompt_for_input_permission_if_needed();
            let _ = open_accessibility_settings();
        }
        return;
    }
    let mut microphone_permission = microphone_permission_status();
    if microphone_permission.required && !microphone_permission.granted {
        #[cfg(target_os = "macos")]
        {
            if prompt_for_microphone_permission_if_needed() {
                microphone_permission = microphone_permission_status();
            }
        }
    }
    if microphone_permission.required && !microphone_permission.granted {
        pipeline.set_idle("microphone permission missing");
        native_debug_log(format!(
            "recording cycle aborted reason=\"microphone permission missing\" detail={:?}",
            microphone_permission.detail
        ));
        emit_error(app, microphone_permission.detail);
        open_dashboard_window(app);
        #[cfg(target_os = "macos")]
        {
            let _ = open_microphone_settings();
        }
        return;
    }
    let target_at_press = capture_paste_target();
    if target_at_press.is_none() {
        native_debug_log(
            "capture target=<none> focused_element_captured=false ax_value_readable=false",
        );
    }
    *pipeline.paste_target.lock() = target_at_press.clone();
    show_pill(app);
    native_debug_log(format!(
        "recording cycle after_showing_pill frontmost_app_after_showing_pill={}",
        format_focus_identity(frontmost_focus_identity().as_ref())
    ));
    if pipeline.whisper.lock().is_none() {
        pipeline.set_idle("whisper not loaded");
        *pipeline.paste_target.lock() = None;
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

    let (vad_enabled, input_device_name) = {
        let settings = &pipeline.persistent.lock().settings;
        (settings.vad_enabled, settings.input_device_name.clone())
    };
    let app_for_stop = app.clone();

    let result = audio::start_capture(
        pipeline.audio_buffer.clone(),
        input_device_name,
        move |reason| {
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
        },
    );

    match result {
        Ok(handle) => {
            native_debug_log(format!(
                "audio capture started device=\"{}\" sample_rate={} channels={} sample_format={}",
                handle.device_name, handle.sample_rate, handle.channels, handle.sample_format
            ));
            let level = handle.level.clone();
            let stop_requested = {
                let mut lifecycle = pipeline.lifecycle.lock();
                match *lifecycle {
                    RecordingLifecycle::Starting { stop_requested, .. } => {
                        *pipeline.capture.lock() = Some(handle);
                        if stop_requested {
                            *lifecycle = RecordingLifecycle::Stopping;
                        } else {
                            *lifecycle = RecordingLifecycle::Recording {
                                started_at: Instant::now(),
                            };
                        }
                        stop_requested
                    }
                    other => {
                        native_debug_log(format!(
                            "audio capture started after lifecycle moved away from starting lifecycle={}",
                            other.label()
                        ));
                        let _ = handle.stop.send(());
                        return;
                    }
                }
            };
            if stop_requested {
                native_debug_log(
                    "recording lifecycle -> stopping reason=\"release arrived during capture startup\"",
                );
                handle_release(app, pipeline);
                return;
            }
            show_pill(app);
            let _ = app.emit(RECORDING_EVENT, ());

            // Spawn audio-level emitter at ~30fps while recording
            let app_for_level = app.clone();
            let lifecycle = pipeline.lifecycle.clone();
            tauri::async_runtime::spawn(async move {
                let mut interval = tokio::time::interval(std::time::Duration::from_millis(33));
                let mut ticks = 0_u32;
                while lifecycle.lock().audio_level_active() {
                    interval.tick().await;
                    ticks = ticks.wrapping_add(1);
                    if ticks.is_multiple_of(30) {
                        raise_pill(&app_for_level);
                    }
                    let lvl = *level.lock();
                    let _ = app_for_level.emit(AUDIO_LEVEL_EVENT, lvl);
                }
                // One last "0" to settle the bars
                let _ = app_for_level.emit(AUDIO_LEVEL_EVENT, 0.0_f32);
            });
        }
        Err(e) => {
            pipeline.set_idle("audio capture failed");
            *pipeline.paste_target.lock() = None;
            native_debug_log(format!("audio capture failed error={e:#}"));
            emit_error(app, format!("audio capture failed: {e:#}"));
        }
    }
}

fn handle_release(app: &AppHandle, pipeline: &Pipeline) {
    let capture = pipeline.capture.lock().take();
    let (sample_rate, channels, device_name, sample_format, peak_rms) =
        if let Some(handle) = capture {
            let sr = handle.sample_rate;
            let ch = handle.channels;
            let device_name = handle.device_name.clone();
            let sample_format = handle.sample_format.clone();
            let peak_rms = *handle.peak_level.lock();
            let _ = handle.stop.send(());
            (
                sr,
                ch,
                Some(device_name),
                Some(sample_format),
                Some(peak_rms),
            )
        } else {
            pipeline.set_idle("release without active capture");
            *pipeline.paste_target.lock() = None;
            native_debug_log("recording release ignored reason=\"capture handle was unavailable\"");
            return;
        };

    let _ = app.emit(PROCESSING_EVENT, ());

    // Job id was allocated at press time. Processing keeps that id; an
    // intervening press bumped CURRENT_JOB_ID past ours, so auto-paste
    // will self-cancel when process() compares.
    let job_id = pipeline.active_job_id.load(Ordering::SeqCst);

    let raw = std::mem::take(&mut *pipeline.audio_buffer.lock());
    let peak = peak_rms.unwrap_or(0.0);
    let silent_detail = if raw.len() >= (sample_rate as usize) / 4 && peak < 0.003 {
        Some(format!(
            "The selected microphone produced almost no signal (peak RMS {peak:.4}). Check macOS microphone input, selected device, mute state, or input level."
        ))
    } else {
        None
    };
    *pipeline.last_capture.lock() = Some(CaptureDiagnostic {
        status: if silent_detail.is_some() {
            "silent".to_string()
        } else {
            "captured".to_string()
        },
        raw_samples: raw.len(),
        sample_rate,
        channels,
        approx_seconds: raw.len() as f64 / (sample_rate as f64 * channels.max(1) as f64),
        device_name: device_name.clone(),
        sample_format: sample_format.clone(),
        peak_rms,
        detail: silent_detail,
    });
    native_debug_log(format!(
        "audio capture stopped raw_samples={} sample_rate={} channels={} approx_seconds={:.3} device=\"{}\" sample_format=\"{}\" peak_rms={:.6}",
        raw.len(),
        sample_rate,
        channels,
        raw.len() as f64 / (sample_rate as f64 * channels.max(1) as f64),
        device_name.as_deref().unwrap_or("<unknown>"),
        sample_format.as_deref().unwrap_or("<unknown>"),
        peak_rms.unwrap_or(0.0)
    ));
    let app_clone = app.clone();
    let whisper = pipeline.whisper.clone();
    let pipeline_for_model = Arc::clone(
        // `pipeline: &Pipeline` is behind Tauri's state::<Arc<Pipeline>>()
        // so the caller side gives us an Arc to re-clone.
        &app.state::<Arc<Pipeline>>().inner().clone(),
    );
    let profile_context = pipeline
        .paste_target
        .lock()
        .as_ref()
        .map(context_from_paste_target);
    let (prompt_mode, vocabulary, allow_unverified_ollama, matched_profile_name) = {
        let p = pipeline.persistent.lock();
        let resolution = p.settings.resolve_prompt_mode(profile_context.as_ref());
        (
            resolution.prompt_mode,
            p.settings.vocabulary.join(", "),
            p.settings.allow_unverified_ollama,
            resolution.profile_name,
        )
    };
    if let Some(profile_name) = matched_profile_name {
        native_debug_log(format!(
            "context profile matched name=\"{}\" prompt_mode={:?}",
            profile_name, prompt_mode
        ));
    }

    let job = ProcessJob {
        raw,
        sample_rate,
        channels,
        prompt_mode,
        vocabulary,
        allow_unverified_ollama,
        job_id,
    };

    *pipeline.lifecycle.lock() = RecordingLifecycle::Processing { job_id };
    native_debug_log(format!("recording lifecycle -> processing job_id={job_id}"));

    let pipeline_for_finish = pipeline_for_model.clone();
    tauri::async_runtime::spawn(async move {
        let result = process(&app_clone, whisper, pipeline_for_model, job).await;
        if let Err(e) = result {
            emit_error(&app_clone, format!("processing failed: {e:#}"));
        }
        pipeline_for_finish.finish_processing_job(job_id);
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
        if let Some(last) = pipeline.last_capture.lock().as_mut() {
            if last.raw_samples == raw.len()
                && last.sample_rate == sample_rate
                && last.channels == channels
            {
                last.status = "too_short".to_string();
                last.detail =
                    Some("Recording was shorter than the minimum STT window.".to_string());
            }
        }
        native_debug_log(format!(
            "audio processing skipped reason=too_short raw_samples={} sample_rate={} channels={} min_samples={}",
            raw.len(),
            sample_rate,
            channels,
            (sample_rate as usize) / 4
        ));
        let _ = app.emit(
            DONE_EVENT,
            DonePayload {
                transcript: String::new(),
                output: String::new(),
                copied: false,
                pasted: false,
                state: "ready".to_string(),
                message: None,
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
                copied: false,
                pasted: false,
                state: "ready".to_string(),
                message: None,
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

    let (auto_paste, save_history) = app
        .try_state::<Arc<Pipeline>>()
        .map(|s| {
            let p = s.persistent.lock();
            (p.settings.auto_paste, p.settings.save_history)
        })
        .unwrap_or((false, true));

    let clipboard_snapshot = if auto_paste && !output.is_empty() {
        Some(snapshot_text_clipboard().map_err(|e| {
            anyhow!("clipboard snapshot failed; skipping auto-paste/history/done: {e:#}")
        })?)
    } else {
        None
    };

    copy_to_clipboard(&output)
        .map_err(|e| anyhow!("clipboard write failed; skipping auto-paste/history/done: {e:#}"))?;
    pipeline.set_last_insertion(InsertionDiagnostic::copied(
        "Transcript output was copied to the clipboard.",
    ));

    let mut pasted = false;
    let mut paste_failed_message: Option<String> = None;
    if auto_paste && !output.is_empty() {
        if !auto_paste_is_ready() {
            let message = auto_paste_permission_message();
            pipeline.set_last_insertion(InsertionDiagnostic::failed(
                "auto_paste_permission",
                message.clone(),
            ));
            emit_error(app, message);
            paste_failed_message = Some(auto_paste_permission_message());
        } else {
            tokio::time::sleep(std::time::Duration::from_millis(70)).await;
            // Re-check inside the delay window — user may have Cmd-tabbed
            // during the 70ms and triggered another recording.
            if CURRENT_JOB_ID.load(Ordering::SeqCst) == job_id {
                let captured_target = pipeline.paste_target.lock().clone();
                let output_for_paste = output.clone();
                let app_for_paste = app.clone();
                match tauri::async_runtime::spawn_blocking(move || {
                    let target = captured_target.ok_or_else(|| {
                            "Auto-paste needs another app focused before recording starts. Focus the text field you want to paste into, then press the hotkey.".to_string()
                        })?;
                    let diagnostic = send_paste_to_target(target, &output_for_paste)?;
                    Ok::<InsertionDiagnostic, String>(diagnostic)
                })
                .await
                {
                    Ok(Ok(diagnostic)) => {
                        pasted = diagnostic.confirmed;
                        if diagnostic.confirmed {
                            if let Some(snapshot) = clipboard_snapshot.clone() {
                                if let Err(e) = restore_text_clipboard(snapshot) {
                                    log::warn!(
                                        "clipboard preservation: failed to restore previous clipboard after paste: {e:#}"
                                    );
                                }
                            }
                        }
                        pipeline.set_last_insertion(diagnostic.clone());
                        if diagnostic.confirmed {
                            let _ = app_for_paste.emit(PASTED_EVENT, diagnostic);
                        }
                    }
                    Ok(Err(msg)) => {
                        pipeline.set_last_insertion(InsertionDiagnostic::failed(
                            "auto_paste",
                            msg.clone(),
                        ));
                        emit_error(&app_for_paste, msg);
                        paste_failed_message = Some(
                            "Auto-paste failed. The text was copied, but it was not inserted."
                                .to_string(),
                        );
                    }
                    Err(e) => {
                        let message = format!("auto-paste task failed: {e:#}");
                        pipeline.set_last_insertion(InsertionDiagnostic::failed(
                            "auto_paste_task",
                            message.clone(),
                        ));
                        emit_error(&app_for_paste, message);
                        paste_failed_message = Some(
                            "Auto-paste failed. The text was copied, but it was not inserted."
                                .to_string(),
                        );
                    }
                }
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

    let _ = app.emit(
        DONE_EVENT,
        DonePayload {
            transcript,
            output,
            copied: true,
            pasted,
            state: if pasted {
                "pasted"
            } else if paste_failed_message.is_some() {
                "failed"
            } else {
                "copied"
            }
            .to_string(),
            message: paste_failed_message,
        },
    );
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

    if pill_position_is_visible(window, pos) {
        return pos;
    }

    let monitor = monitor_from_physical_point(
        window,
        pos.x as f64 + PILL_WIDTH as f64 / 2.0,
        pos.y as f64 + PILL_HEIGHT as f64 / 2.0,
    )
    .or_else(|| monitors.first().cloned());

    if let Some(monitor) = monitor {
        clamp_pill_position_to_monitor(pos, &monitor)
    } else {
        pos
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
    if enabled {
        #[cfg(target_os = "macos")]
        {
            if !auto_paste_is_ready() {
                prompt_for_input_permission_if_needed();
                let _ = open_accessibility_settings();
                return Err(auto_paste_permission_message());
            }
        }

        #[cfg(not(target_os = "macos"))]
        {
            return Err(auto_paste_permission_message());
        }
    }
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

fn validate_context_profile(mut profile: PowerModeProfile) -> Result<PowerModeProfile, String> {
    profile.id = profile.id.trim().to_string();
    profile.name = profile.name.trim().to_string();

    if profile.id.is_empty() {
        return Err("profile id cannot be empty".to_string());
    }
    if profile.id == "default" {
        return Err("the default profile cannot be replaced".to_string());
    }
    if !profile
        .id
        .chars()
        .all(|ch| ch.is_ascii_alphanumeric() || ch == '-' || ch == '_')
    {
        return Err("profile id may only contain letters, numbers, dashes, and underscores".into());
    }
    if profile.name.is_empty() {
        return Err("profile name cannot be empty".to_string());
    }
    if profile.name.len() > 80 {
        return Err("profile name is too long".to_string());
    }

    profile.triggers = profile
        .triggers
        .into_iter()
        .map(|mut trigger| {
            trigger.pattern = trigger.pattern.trim().to_string();
            trigger
        })
        .filter(|trigger| !trigger.pattern.is_empty())
        .collect();
    if profile.triggers.is_empty() {
        return Err("add at least one app trigger".to_string());
    }
    if profile.triggers.len() > 5 {
        return Err("profiles can have at most 5 triggers".to_string());
    }
    if profile
        .triggers
        .iter()
        .any(|trigger| trigger.pattern.len() > 160)
    {
        return Err("trigger pattern is too long".to_string());
    }
    if profile.prompt_mode.is_none() {
        return Err("choose a prompt mode for this profile".to_string());
    }

    profile.auto_paste = None;
    profile.auto_send = false;
    profile.transcription_model_id = None;
    profile.rewrite_model_id = None;
    profile.language_hint = None;
    profile.vocabulary_replacement_ids.clear();
    profile.privacy = Default::default();

    Ok(profile)
}

#[tauri::command]
fn upsert_context_profile(
    window: tauri::WebviewWindow,
    profile: PowerModeProfile,
    app: AppHandle,
    state: tauri::State<'_, Arc<Pipeline>>,
) -> Result<(), String> {
    require_dashboard(&window)?;
    let profile = validate_context_profile(profile)?;
    let mut persistent = state.persistent.lock();
    let existing_custom_profiles = persistent
        .settings
        .profiles
        .iter()
        .filter(|existing| existing.id != "default" && existing.id != profile.id)
        .count();
    if existing_custom_profiles >= 20 {
        return Err("context profiles are limited to 20".to_string());
    }
    persistent
        .settings
        .profiles
        .retain(|existing| existing.id != profile.id);
    persistent.settings.profiles.push(profile);
    drop(persistent);
    state.save_persistent();
    emit_dashboard_update(&app);
    Ok(())
}

#[tauri::command]
fn set_context_profile_enabled(
    window: tauri::WebviewWindow,
    profile_id: String,
    enabled: bool,
    app: AppHandle,
    state: tauri::State<'_, Arc<Pipeline>>,
) -> Result<(), String> {
    require_dashboard(&window)?;
    if profile_id == "default" {
        return Err("the default profile cannot be toggled".to_string());
    }
    let mut persistent = state.persistent.lock();
    let Some(profile) = persistent
        .settings
        .profiles
        .iter_mut()
        .find(|profile| profile.id == profile_id)
    else {
        return Err("profile not found".to_string());
    };
    profile.enabled = enabled;
    drop(persistent);
    state.save_persistent();
    emit_dashboard_update(&app);
    Ok(())
}

#[tauri::command]
fn delete_context_profile(
    window: tauri::WebviewWindow,
    profile_id: String,
    app: AppHandle,
    state: tauri::State<'_, Arc<Pipeline>>,
) -> Result<(), String> {
    require_dashboard(&window)?;
    if profile_id == "default" {
        return Err("the default profile cannot be deleted".to_string());
    }
    let mut persistent = state.persistent.lock();
    let before = persistent.settings.profiles.len();
    persistent
        .settings
        .profiles
        .retain(|profile| profile.id != profile_id);
    if persistent.settings.profiles.len() == before {
        return Err("profile not found".to_string());
    }
    if persistent.settings.active_profile_id.as_deref() == Some(profile_id.as_str()) {
        persistent.settings.active_profile_id = None;
    }
    drop(persistent);
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
fn list_audio_input_devices(
    window: tauri::WebviewWindow,
) -> Result<Vec<audio::AudioInputDevice>, String> {
    require_dashboard(&window)?;
    audio::input_devices().map_err(|e| e.to_string())
}

#[tauri::command]
fn set_input_device(
    window: tauri::WebviewWindow,
    device_id: Option<String>,
    app: AppHandle,
    state: tauri::State<'_, Arc<Pipeline>>,
) -> Result<(), String> {
    require_dashboard(&window)?;
    let normalized = device_id
        .as_deref()
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(str::to_string);

    if let Some(selected) = normalized.as_deref() {
        let devices = audio::input_devices().map_err(|e| e.to_string())?;
        if !devices.iter().any(|device| device.id == selected) {
            return Err(format!("input device is not available: {selected}"));
        }
    }

    state.persistent.lock().settings.input_device_name = normalized;
    state.save_persistent();
    emit_dashboard_update(&app);
    Ok(())
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
    let monitor = monitor_containing_physical_point(
        &window,
        pos.x as f64 + PILL_WIDTH as f64 / 2.0,
        pos.y as f64 + PILL_HEIGHT as f64 / 2.0,
    );
    {
        let mut persistent = state.persistent.lock();
        persistent.pill_position = Some(pos);
        if let Some(monitor) = monitor.as_ref() {
            persistent
                .pill_positions_by_monitor
                .insert(monitor_key(monitor), pos);
        }
    }
    state.save_persistent();
    native_debug_log(format!(
        "pill drag position_persisted requested=({}, {}) saved={pos:?} coordinate_space=tauri_physical_pixels saved_monitor=\"{}\" pill_screen=\"{}\"",
        x,
        y,
        monitor
            .as_ref()
            .map(monitor_string)
            .unwrap_or_else(|| "<none>".to_string()),
        pill_screen_string(&window)
    ));
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
fn log_pill_drag_error(window: tauri::WebviewWindow, error: String) -> Result<(), String> {
    require_pill(&window)?;
    native_debug_log(format!("pill drag startDragging_error_exact={error:?}"));
    Ok(())
}

#[tauri::command]
fn open_dashboard(app: AppHandle) {
    // Allowed from any window — opening the dashboard is how users recover
    // if something goes weird. Not gated.
    open_dashboard_window(&app);
}

#[tauri::command]
fn toggle_recording_from_dashboard(
    window: tauri::WebviewWindow,
    app: AppHandle,
    state: tauri::State<'_, Arc<Pipeline>>,
) -> Result<(), String> {
    require_dashboard(&window)?;
    handle_toggle(&app, &state);
    Ok(())
}

#[tauri::command]
fn open_input_permission_settings(window: tauri::WebviewWindow) -> Result<(), String> {
    require_dashboard(&window)?;
    #[cfg(target_os = "macos")]
    {
        open_accessibility_settings()?;
    }
    Ok(())
}

#[tauri::command]
fn open_microphone_permission_settings(window: tauri::WebviewWindow) -> Result<(), String> {
    require_dashboard(&window)?;
    #[cfg(target_os = "macos")]
    {
        open_microphone_settings()?;
    }
    Ok(())
}

#[tauri::command]
fn repair_macos_input_permissions(window: tauri::WebviewWindow) -> Result<(), String> {
    require_dashboard(&window)?;
    #[cfg(target_os = "macos")]
    {
        let report = platform::macos_permissions::reset_tcc_entries(
            platform::macos_permissions::TccRepairRequest {
                bundle_id: "com.arcusis.zerm".to_string(),
                reset_accessibility: true,
                reset_apple_events: true,
            },
        )?;
        native_debug_log(format!("macOS input permission repair report={report:?}"));
        open_accessibility_settings()?;
        Ok(())
    }

    #[cfg(not(target_os = "macos"))]
    {
        Err("macOS input permission repair is only available on macOS".to_string())
    }
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
    input_permission: InputPermissionStatus,
    microphone_permission: InputPermissionStatus,
    auto_paste_ready: bool,
    app_signing: Option<AppSigningStatus>,
    last_insertion: Option<InsertionDiagnostic>,
    recording_lifecycle: String,
    last_capture: Option<CaptureDiagnostic>,
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

    let last_insertion = app
        .try_state::<Arc<Pipeline>>()
        .and_then(|state| state.last_insertion.lock().clone());
    let (recording_lifecycle, last_capture) = app
        .try_state::<Arc<Pipeline>>()
        .map(|state| (state.lifecycle_label(), state.last_capture.lock().clone()))
        .unwrap_or_else(|| ("unavailable".to_string(), None));

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
        input_permission: input_permission_status(),
        microphone_permission: microphone_permission_status(),
        auto_paste_ready: auto_paste_is_ready(),
        app_signing: app_signing_status(),
        last_insertion,
        recording_lifecycle,
        last_capture,
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

#[cfg(target_os = "windows")]
fn system32_path(parts: &[&str]) -> std::path::PathBuf {
    let root = std::env::var_os("SystemRoot").unwrap_or_else(|| "C:\\Windows".into());
    let mut path = std::path::PathBuf::from(root);
    path.push("System32");
    for part in parts {
        path.push(part);
    }
    path
}

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
    let verify = std::process::Command::new("/usr/bin/codesign")
        .args(["--verify", "--deep", "--strict", "--verbose=2", app_path])
        .output()
        .map_err(|e| format!("codesign verify: {e}"))?;
    if !verify.status.success() {
        return Err(format!(
            "codesign verify failed: {}",
            String::from_utf8_lossy(&verify.stderr)
        ));
    }

    let details = std::process::Command::new("/usr/bin/codesign")
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

    let gatekeeper = std::process::Command::new("/usr/sbin/spctl")
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
    let powershell = system32_path(&["WindowsPowerShell", "v1.0", "powershell.exe"]);
    let out = std::process::Command::new(powershell)
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
        std::process::Command::new("/usr/bin/xdg-open")
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
            let status = std::process::Command::new("/usr/bin/unzip")
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
            let status = std::process::Command::new("/usr/bin/ditto")
                .args([extracted_app_str, "/Applications/Ollama.app.zerm-new"])
                .status()
                .map_err(|e| format!("ditto: {e}"))?;
            if !status.success() {
                return Err(format!("ditto exited {status}"));
            }
            verify_macos_app_signature("/Applications/Ollama.app.zerm-new")?;
            let backup_path = std::path::Path::new("/Applications/Ollama.app.zerm-backup");
            if backup_path.exists() {
                std::fs::remove_dir_all(backup_path)
                    .map_err(|e| format!("remove stale Ollama.app backup: {e}"))?;
            }
            let had_existing = install_path.exists();
            if had_existing {
                std::fs::rename(install_path, backup_path)
                    .map_err(|e| format!("backup existing Ollama.app: {e}"))?;
            }
            if let Err(e) = std::fs::rename(staged_path, install_path) {
                if had_existing {
                    let _ = std::fs::rename(backup_path, install_path);
                }
                return Err(format!("install verified Ollama.app: {e}"));
            }
            if let Err(e) = verify_macos_app_signature("/Applications/Ollama.app") {
                let _ = std::fs::remove_dir_all(install_path);
                if had_existing {
                    let _ = std::fs::rename(backup_path, install_path);
                }
                return Err(e);
            }
            if had_existing && backup_path.exists() {
                std::fs::remove_dir_all(backup_path)
                    .map_err(|e| format!("remove Ollama.app backup: {e}"))?;
            }
            let _ = std::process::Command::new("/usr/bin/open")
                .arg("/Applications/Ollama.app")
                .spawn();
        }

        #[cfg(target_os = "windows")]
        {
            let _ = app.emit("zerm://ollama-install-progress", "verifying");
            verify_windows_installer_signature(&installer_path)?;
            let cmd = system32_path(&["cmd.exe"]);
            std::process::Command::new(cmd)
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
    #[cfg(target_os = "macos")]
    maybe_run_auto_paste_self_test();

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
            upsert_context_profile,
            set_context_profile_enabled,
            delete_context_profile,
            set_hotkey,
            list_audio_input_devices,
            set_input_device,
            add_vocabulary_term,
            remove_vocabulary_term,
            clear_vocabulary,
            clear_history,
            copy_history_entry,
            quit_app,
            open_dashboard,
            toggle_recording_from_dashboard,
            open_input_permission_settings,
            open_microphone_permission_settings,
            repair_macos_input_permissions,
            set_pill_position,
            get_pill_position,
            log_pill_drag_error,
            check_setup,
            download_whisper_model,
            install_ollama,
            pull_ollama_model,
        ])
        .setup(move |app| {
            let app_handle = app.handle().clone();
            native_debug_log(format!(
                "app launch app_bundle_id={} binary_path=\"{}\" AXIsProcessTrusted={} log_path=\"{}\"",
                app_handle.config().identifier.as_str(),
                current_binary_path_string(),
                accessibility_is_trusted(),
                native_debug_log_path()
                    .map(|path| path.display().to_string())
                    .unwrap_or_else(|| "<unavailable>".to_string())
            ));

            // Load persistent state from app data dir
            if let Ok(dir) = app.path().app_data_dir() {
                let path = dir.join(STATE_FILE);
                let loaded = PersistentState::load_with_backup(&path);
                *pipeline_for_setup.persistent.lock() = loaded;
                *pipeline_for_setup.state_path.lock() = Some(path);
                log::info!("state dir: {dir:?}");
            }

            #[cfg(target_os = "macos")]
            {
                prompt_for_input_permission_if_needed();
            }

            // Apply saved hotkey choice
            let hotkey_choice = pipeline_for_setup.persistent.lock().settings.hotkey;
            hotkey::set_hotkey(hotkey_choice.key_code(), hotkey_choice.flag_bit());

            if let Err(e) = build_tray(app, pipeline_for_setup.clone()) {
                log::error!("failed to build tray: {e:#}");
            }

            // Apply native window traits, then restore the saved pill position.
            // Frontend pointer handling starts cross-platform dragging.
            if let Some(window) = app.get_webview_window("main") {
                configure_pill_window(&window);
                #[cfg(target_os = "macos")]
                {
                    if native_pill_panel_enabled() {
                        native_debug_log("startup pill source position restore skipped on macOS; native NSPanel owns visible pill frame");
                    } else if let Some(primary) = window.primary_monitor().ok().flatten() {
                        let pos = default_pill_position_for_monitor(&primary);
                        let _ = window.set_position(tauri::Position::Physical(
                            PhysicalPosition { x: pos.x, y: pos.y },
                        ));
                        {
                            let mut persistent = pipeline_for_setup.persistent.lock();
                            persistent.pill_position = Some(pos);
                            persistent
                                .pill_positions_by_monitor
                                .insert(monitor_key(&primary), pos);
                        }
                        pipeline_for_setup.save_persistent();
                        native_debug_log(format!(
                            "startup pill source position reset on macOS via primary monitor fail-safe position={pos:?} monitor=\"{}\"",
                            monitor_string(&primary)
                        ));
                    }
                }
                #[cfg(not(target_os = "macos"))]
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
            let installed = hotkey::install(move |event| {
                native_debug_log(format!(
                    "hotkey event pressed={} backend={} key_code={} app_bundle_id={} AXIsProcessTrusted={} frontmost_app={}",
                    event.pressed,
                    event.backend,
                    event.key_code,
                    app_for_hotkey.config().identifier.as_str(),
                    accessibility_is_trusted(),
                    format_focus_identity(frontmost_focus_identity().as_ref())
                ));
                let app = app_for_hotkey.clone();
                let pipeline = pipeline_for_hotkey.clone();
                tauri::async_runtime::spawn(async move {
                    if event.pressed {
                        handle_hotkey_press(&app, &pipeline);
                    } else {
                        handle_hotkey_release(&app, &pipeline);
                    }
                });
            });
            if installed.installed {
                INPUT_MONITOR_READY.store(true, Ordering::SeqCst);
                native_debug_log(format!(
                    "hotkey monitor installed=true nsevent={} cgeventtap={} hotkey_label=\"{}\" app_bundle_id={} AXIsProcessTrusted={}",
                    installed.nsevent,
                    installed.cgeventtap,
                    hotkey_choice.label(),
                    app_handle.config().identifier.as_str(),
                    accessibility_is_trusted()
                ));
                log::info!(
                    "zerm started. Tap {} to record. Click tray icon for dashboard.",
                    hotkey_choice.label()
                );
            } else if cfg!(target_os = "macos") {
                native_debug_log(format!(
                    "hotkey monitor installed=false nsevent={} cgeventtap={} hotkey_label=\"{}\" app_bundle_id={} AXIsProcessTrusted={}",
                    installed.nsevent,
                    installed.cgeventtap,
                    hotkey_choice.label(),
                    app_handle.config().identifier.as_str(),
                    accessibility_is_trusted()
                ));
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

            let input_permission = input_permission_status();
            if input_permission.required && !input_permission.granted {
                emit_error(&app_handle, input_permission.detail.clone());
            }
            let should_open_dashboard =
                (input_permission.required && !input_permission.granted)
                    || !whisper_model_path(&app_handle).exists();
            if should_open_dashboard {
                let app_for_dash = app_handle.clone();
                tauri::async_runtime::spawn(async move {
                    tokio::time::sleep(std::time::Duration::from_millis(400)).await;
                    open_dashboard_window(&app_for_dash);
                });
            }

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
    fn short_tap_during_starting_keeps_recording_for_toggle_mode() {
        let mut lifecycle = RecordingLifecycle::Idle;

        assert_eq!(
            request_press_transition(&mut lifecycle),
            RecordingAction::Start
        );
        assert_eq!(
            request_release_transition(&mut lifecycle),
            RecordingAction::KeepRecording
        );
        assert!(matches!(
            lifecycle,
            RecordingLifecycle::Starting {
                stop_requested: false,
                ..
            }
        ));
    }

    #[test]
    fn long_hold_release_during_starting_is_deferred() {
        let mut lifecycle = RecordingLifecycle::Starting {
            stop_requested: false,
            started_at: Instant::now() - std::time::Duration::from_millis(300),
        };

        assert_eq!(
            request_release_transition(&mut lifecycle),
            RecordingAction::PendingStop
        );
        assert!(matches!(
            lifecycle,
            RecordingLifecycle::Starting {
                stop_requested: true,
                ..
            }
        ));
    }

    #[test]
    fn recording_release_moves_to_stopping_once() {
        let mut lifecycle = RecordingLifecycle::Recording {
            started_at: Instant::now() - std::time::Duration::from_millis(300),
        };

        assert_eq!(
            request_release_transition(&mut lifecycle),
            RecordingAction::Stop
        );
        assert_eq!(lifecycle, RecordingLifecycle::Stopping);
        assert_eq!(
            request_release_transition(&mut lifecycle),
            RecordingAction::Ignore
        );
    }

    #[test]
    fn new_recording_can_start_while_previous_job_processes() {
        let mut lifecycle = RecordingLifecycle::Processing { job_id: 7 };

        assert_eq!(
            request_press_transition(&mut lifecycle),
            RecordingAction::Start
        );
        assert!(matches!(
            lifecycle,
            RecordingLifecycle::Starting {
                stop_requested: false,
                ..
            }
        ));
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
