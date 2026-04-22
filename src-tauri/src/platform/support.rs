use serde::{Deserialize, Serialize};

/// OS family currently running the native platform service.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum PlatformKind {
    MacOS,
    Windows,
    Linux,
    Unknown,
}

impl PlatformKind {
    pub fn current() -> Self {
        if cfg!(target_os = "macos") {
            Self::MacOS
        } else if cfg!(target_os = "windows") {
            Self::Windows
        } else if cfg!(target_os = "linux") {
            Self::Linux
        } else {
            Self::Unknown
        }
    }
}

/// Linux display server family. Text insertion and global hotkeys differ
/// substantially between X11 and Wayland, so the platform layer must not hide
/// this distinction.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum LinuxSessionKind {
    X11,
    Wayland,
    Unknown,
}

/// Capability flag for a platform service.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum SupportLevel {
    Supported,
    Partial,
    Unsupported,
    Unknown,
}

impl SupportLevel {
    pub fn is_available(self) -> bool {
        matches!(self, Self::Supported | Self::Partial)
    }
}

/// Platform capability snapshot used by setup, diagnostics, and feature gates.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PlatformSupport {
    pub platform: PlatformKind,
    pub linux_session: Option<LinuxSessionKind>,
    pub text_injection: SupportLevel,
    pub app_context: SupportLevel,
    pub global_hotkey: SupportLevel,
    pub clipboard: SupportLevel,
    pub permissions: SupportLevel,
    pub audio_devices: SupportLevel,
    pub notes: Vec<String>,
}

impl PlatformSupport {
    pub fn current_scaffold() -> Self {
        Self {
            platform: PlatformKind::current(),
            linux_session: None,
            text_injection: SupportLevel::Unknown,
            app_context: SupportLevel::Unknown,
            global_hotkey: SupportLevel::Unknown,
            clipboard: SupportLevel::Unknown,
            permissions: SupportLevel::Unknown,
            audio_devices: SupportLevel::Unknown,
            notes: Vec::new(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn current_platform_is_known_on_supported_targets() {
        let current = PlatformKind::current();

        #[cfg(target_os = "macos")]
        assert_eq!(current, PlatformKind::MacOS);
        #[cfg(target_os = "windows")]
        assert_eq!(current, PlatformKind::Windows);
        #[cfg(target_os = "linux")]
        assert_eq!(current, PlatformKind::Linux);
    }

    #[test]
    fn partial_support_counts_as_available() {
        assert!(SupportLevel::Supported.is_available());
        assert!(SupportLevel::Partial.is_available());
        assert!(!SupportLevel::Unsupported.is_available());
        assert!(!SupportLevel::Unknown.is_available());
    }
}
