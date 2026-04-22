use serde::{Deserialize, Serialize};
use std::error::Error;
use std::fmt::{self, Display, Formatter};

/// Shared result type for native platform services.
pub type PlatformResult<T> = Result<T, PlatformError>;

/// High-level category for a platform-layer failure.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum PlatformErrorKind {
    Unsupported,
    PermissionDenied,
    PermissionUnknown,
    NoFocusedTarget,
    TargetChanged,
    ClipboardUnavailable,
    HotkeyUnavailable,
    AudioDeviceUnavailable,
    Timeout,
    OsFailure,
    InvalidRequest,
}

/// Structured error type used by all native platform abstractions.
///
/// Keep this error serializable. The dashboard and diagnostics export should be
/// able to show actionable native failures without parsing platform-specific
/// error strings.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PlatformError {
    pub kind: PlatformErrorKind,
    pub message: String,
    pub remediation: Option<String>,
    pub platform_code: Option<String>,
}

impl PlatformError {
    pub fn new(kind: PlatformErrorKind, message: impl Into<String>) -> Self {
        Self {
            kind,
            message: message.into(),
            remediation: None,
            platform_code: None,
        }
    }

    pub fn with_remediation(mut self, remediation: impl Into<String>) -> Self {
        self.remediation = Some(remediation.into());
        self
    }

    pub fn with_platform_code(mut self, platform_code: impl Into<String>) -> Self {
        self.platform_code = Some(platform_code.into());
        self
    }

    pub fn unsupported(message: impl Into<String>) -> Self {
        Self::new(PlatformErrorKind::Unsupported, message)
    }

    pub fn permission_denied(message: impl Into<String>) -> Self {
        Self::new(PlatformErrorKind::PermissionDenied, message)
    }

    pub fn no_focused_target() -> Self {
        Self::new(
            PlatformErrorKind::NoFocusedTarget,
            "no focused text target was available",
        )
    }
}

impl Display for PlatformError {
    fn fmt(&self, f: &mut Formatter<'_>) -> fmt::Result {
        match &self.platform_code {
            Some(code) => write!(f, "{:?}: {} ({code})", self.kind, self.message),
            None => write!(f, "{:?}: {}", self.kind, self.message),
        }
    }
}

impl Error for PlatformError {}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn platform_error_is_actionable_and_serializable() {
        let error = PlatformError::permission_denied("Accessibility is disabled")
            .with_remediation("Enable Zerm in Privacy & Security > Accessibility")
            .with_platform_code("AXIsProcessTrusted=false");

        let json = serde_json::to_string(&error).expect("serialize platform error");

        assert!(json.contains("permissionDenied"));
        assert!(json.contains("Accessibility is disabled"));
        assert!(json.contains("AXIsProcessTrusted=false"));
    }
}
