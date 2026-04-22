use super::support::PlatformKind;
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::time::Duration;

/// Identity for the app/window that should receive inserted text.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AppIdentity {
    pub platform: Option<PlatformKind>,
    pub pid: Option<u32>,
    pub app_name: Option<String>,
    pub bundle_id: Option<String>,
    pub executable_path: Option<String>,
    pub window_title: Option<String>,
}

impl AppIdentity {
    pub fn is_same_process_as(&self, other: &Self) -> bool {
        self.pid.is_some() && self.pid == other.pid
    }
}

/// Privacy-gated snapshot of the focused UI target captured before recording.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AppContext {
    pub identity: AppIdentity,
    pub browser_url_or_domain: Option<String>,
    pub focused_role: Option<String>,
    pub focused_subrole: Option<String>,
    pub selected_text: Option<String>,
    pub field_text_before_cursor: Option<String>,
    pub field_text_after_cursor: Option<String>,
    pub cursor_position: Option<usize>,
    pub secure_field: bool,
    pub input_language: Option<String>,
    pub metadata: BTreeMap<String, String>,
}

/// Text insertion strategy selected by the platform implementation.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum TextInsertionStrategy {
    NativeAccessibility,
    ClipboardPaste,
    SyntheticKeystrokes,
    Portal,
    ManualCopyOnly,
}

/// Request passed to a platform text injector.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TextInjectionRequest {
    pub text: String,
    pub target: Option<AppIdentity>,
    pub context: Option<AppContext>,
    pub preferred_strategy: Option<TextInsertionStrategy>,
    pub preserve_clipboard: bool,
    pub verify_consumed: bool,
    pub timeout_ms: u64,
}

impl TextInjectionRequest {
    pub fn new(text: impl Into<String>) -> Self {
        Self {
            text: text.into(),
            target: None,
            context: None,
            preferred_strategy: None,
            preserve_clipboard: true,
            verify_consumed: true,
            timeout_ms: 2_000,
        }
    }

    pub fn timeout(&self) -> Duration {
        Duration::from_millis(self.timeout_ms)
    }
}

/// Result of a text insertion attempt.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TextInjectionOutcome {
    pub strategy: TextInsertionStrategy,
    pub delivered: bool,
    pub verified: bool,
    pub target: Option<AppIdentity>,
    pub message: Option<String>,
}

/// Current clipboard state captured before an insertion attempt.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ClipboardSnapshot {
    pub text: Option<String>,
    pub has_rich_content: bool,
    pub sequence: Option<u64>,
}

/// Global hotkey declaration.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct HotkeyDescriptor {
    pub display_label: String,
    pub key_code: Option<u32>,
    pub modifiers: Vec<HotkeyModifier>,
    pub press_and_hold: bool,
}

/// Modifier keys used by the hotkey provider.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum HotkeyModifier {
    Shift,
    Control,
    OptionAlt,
    CommandMeta,
    Fn,
}

/// Event emitted by a hotkey provider.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct HotkeyEvent {
    pub kind: HotkeyEventKind,
    pub timestamp_ms: u64,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum HotkeyEventKind {
    Pressed,
    Released,
    Cancelled,
}

/// Native permission families Zerm needs to reason about explicitly.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum PermissionKind {
    Accessibility,
    Automation,
    InputMonitoring,
    Microphone,
    Clipboard,
    GlobalHotkey,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum PermissionState {
    Granted,
    Denied,
    PromptRequired,
    Unknown,
    Unsupported,
}

/// Native permission state plus diagnostics for supportability.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PermissionStatus {
    pub kind: PermissionKind,
    pub state: PermissionState,
    pub can_prompt: bool,
    pub remediation: Option<String>,
    pub diagnostic: Option<String>,
}

impl PermissionStatus {
    pub fn granted(kind: PermissionKind) -> Self {
        Self {
            kind,
            state: PermissionState::Granted,
            can_prompt: false,
            remediation: None,
            diagnostic: None,
        }
    }

    pub fn is_granted(&self) -> bool {
        self.state == PermissionState::Granted
    }
}

/// Direction of an audio device.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum AudioDeviceDirection {
    Input,
    Output,
}

/// Stable audio device description for settings and diagnostics.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AudioDeviceInfo {
    pub id: String,
    pub name: String,
    pub direction: AudioDeviceDirection,
    pub is_default: bool,
    pub sample_rates: Vec<u32>,
    pub channel_counts: Vec<u16>,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn text_request_defaults_to_safe_paste_behavior() {
        let request = TextInjectionRequest::new("hello");

        assert_eq!(request.text, "hello");
        assert!(request.preserve_clipboard);
        assert!(request.verify_consumed);
        assert_eq!(request.timeout(), Duration::from_millis(2_000));
    }

    #[test]
    fn permission_status_granted_is_easy_to_query() {
        let status = PermissionStatus::granted(PermissionKind::Accessibility);

        assert!(status.is_granted());
        assert_eq!(status.state, PermissionState::Granted);
    }
}
