use serde::Serialize;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Platform {
    Macos,
    Windows,
    LinuxX11,
    LinuxWayland,
    LinuxUnknown,
    Unknown,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum PermissionKind {
    Accessibility,
    Automation,
    Clipboard,
    InputSynthesis,
    LinuxDisplayServer,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum FailureReason {
    EmptyText,
    NoFocusedTarget,
    SecureField,
    PermissionDenied(PermissionKind),
    UnsupportedPlatform,
    ClipboardUnavailable,
    ClipboardRestoreFailed,
    DirectInsertionRejected,
    TargetChanged,
    RefocusFailed,
    PasteNotConfirmed,
    TimedOut,
    StrategyUnavailable,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum InsertionStrategy {
    MacAccessibilityFocusedValue,
    MacAccessibilitySelectedText,
    MacClipboardKeystroke,
    MacSystemEventsKeystroke,
    WindowsSendInputPaste,
    LinuxX11ClipboardPaste,
    LinuxWaylandPortalPaste,
    CopyToClipboardOnly,
}

impl InsertionStrategy {
    pub fn uses_clipboard(self) -> bool {
        matches!(
            self,
            Self::MacClipboardKeystroke
                | Self::MacSystemEventsKeystroke
                | Self::WindowsSendInputPaste
                | Self::LinuxX11ClipboardPaste
                | Self::LinuxWaylandPortalPaste
                | Self::CopyToClipboardOnly
        )
    }

    pub fn required_permission(self) -> Option<PermissionKind> {
        match self {
            Self::MacAccessibilityFocusedValue | Self::MacAccessibilitySelectedText => {
                Some(PermissionKind::Accessibility)
            }
            Self::MacClipboardKeystroke
            | Self::WindowsSendInputPaste
            | Self::LinuxX11ClipboardPaste
            | Self::LinuxWaylandPortalPaste => Some(PermissionKind::InputSynthesis),
            Self::MacSystemEventsKeystroke => Some(PermissionKind::Automation),
            Self::CopyToClipboardOnly => Some(PermissionKind::Clipboard),
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum ClipboardWriteMode {
    NotUsed,
    ReplaceWithOutput,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum ClipboardRestorePolicy {
    NotApplicable,
    RestoreAfterConfirmedInsertion,
    RestoreAfterBestEffortPaste,
    KeepOutputForUser,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
pub struct ClipboardPreservationPlan {
    pub write_mode: ClipboardWriteMode,
    pub restore_policy: ClipboardRestorePolicy,
    pub preserve_non_text: bool,
    pub max_snapshot_bytes: usize,
}

impl ClipboardPreservationPlan {
    pub const fn direct() -> Self {
        Self {
            write_mode: ClipboardWriteMode::NotUsed,
            restore_policy: ClipboardRestorePolicy::NotApplicable,
            preserve_non_text: false,
            max_snapshot_bytes: 0,
        }
    }

    pub const fn paste_preserving_existing() -> Self {
        Self {
            write_mode: ClipboardWriteMode::ReplaceWithOutput,
            restore_policy: ClipboardRestorePolicy::RestoreAfterConfirmedInsertion,
            preserve_non_text: false,
            max_snapshot_bytes: 1_048_576,
        }
    }

    pub const fn copy_only() -> Self {
        Self {
            write_mode: ClipboardWriteMode::ReplaceWithOutput,
            restore_policy: ClipboardRestorePolicy::KeepOutputForUser,
            preserve_non_text: false,
            max_snapshot_bytes: 0,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum PasteConfirmation {
    DirectApiAccepted,
    FocusedTextChanged,
    ClipboardConsumed,
    EventPostedOnly,
    UserManualPaste,
    NotConfirmed,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum RecoveryAction {
    None,
    CopyResult,
    FocusTextField,
    AskForPermission(PermissionKind),
    Retry,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum InsertionResult {
    Inserted {
        strategy: InsertionStrategy,
        confirmation: PasteConfirmation,
    },
    Copied {
        clipboard: ClipboardPreservationPlan,
    },
    Failed {
        reason: FailureReason,
        recovery: RecoveryAction,
    },
}

impl InsertionResult {
    pub fn is_success(&self) -> bool {
        matches!(self, Self::Inserted { .. } | Self::Copied { .. })
    }
}

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize)]
pub struct AppContext {
    pub platform: Option<Platform>,
    pub app_id: Option<String>,
    pub app_name: Option<String>,
    pub process_name: Option<String>,
    pub window_title: Option<String>,
    pub focused_role: Option<String>,
    pub has_focused_text_input: bool,
    pub is_secure_field: bool,
}

impl AppContext {
    pub fn new(platform: Platform) -> Self {
        Self {
            platform: Some(platform),
            ..Self::default()
        }
    }

    pub fn with_app_id(mut self, app_id: impl Into<String>) -> Self {
        self.app_id = Some(app_id.into());
        self
    }

    pub fn with_app_name(mut self, app_name: impl Into<String>) -> Self {
        self.app_name = Some(app_name.into());
        self
    }

    pub fn with_focused_text_input(mut self, has_focused_text_input: bool) -> Self {
        self.has_focused_text_input = has_focused_text_input;
        self
    }

    pub fn with_secure_field(mut self, is_secure_field: bool) -> Self {
        self.is_secure_field = is_secure_field;
        self
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct InsertionRequest {
    pub text: String,
    pub context: Option<AppContext>,
    pub preserve_clipboard: bool,
}

impl InsertionRequest {
    pub fn new(text: impl Into<String>, context: Option<AppContext>) -> Self {
        Self {
            text: text.into(),
            context,
            preserve_clipboard: true,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct InsertionPlan {
    pub strategies: Vec<InsertionStrategy>,
    pub clipboard: ClipboardPreservationPlan,
    pub expected_confirmation: PasteConfirmation,
    pub unavailable_reason: Option<FailureReason>,
    pub recovery: RecoveryAction,
    pub matched_rule: Option<&'static str>,
}

impl InsertionPlan {
    pub fn available(&self) -> bool {
        self.unavailable_reason.is_none() && !self.strategies.is_empty()
    }

    fn unavailable(reason: FailureReason, recovery: RecoveryAction) -> Self {
        Self {
            strategies: Vec::new(),
            clipboard: ClipboardPreservationPlan::direct(),
            expected_confirmation: PasteConfirmation::NotConfirmed,
            unavailable_reason: Some(reason),
            recovery,
            matched_rule: None,
        }
    }
}

#[derive(Clone, Debug)]
pub struct AppStrategyRule {
    id: &'static str,
    platforms: Vec<Platform>,
    app_ids: Vec<&'static str>,
    name_keywords: Vec<&'static str>,
    strategies: Vec<InsertionStrategy>,
    expected_confirmation: PasteConfirmation,
}

impl AppStrategyRule {
    pub fn new(
        id: &'static str,
        platforms: impl Into<Vec<Platform>>,
        app_ids: impl Into<Vec<&'static str>>,
        name_keywords: impl Into<Vec<&'static str>>,
        strategies: impl Into<Vec<InsertionStrategy>>,
        expected_confirmation: PasteConfirmation,
    ) -> Self {
        Self {
            id,
            platforms: platforms.into(),
            app_ids: app_ids.into(),
            name_keywords: name_keywords.into(),
            strategies: strategies.into(),
            expected_confirmation,
        }
    }

    fn matches(&self, context: &AppContext) -> bool {
        let Some(platform) = context.platform else {
            return false;
        };
        if !self.platforms.contains(&platform) {
            return false;
        }

        let app_id = context.app_id.as_deref().map(normalize);
        let app_name = context
            .app_name
            .as_deref()
            .or(context.process_name.as_deref())
            .map(normalize);

        app_id.as_deref().is_some_and(|id| {
            self.app_ids
                .iter()
                .any(|candidate| id == normalize(candidate))
        }) || app_name.as_deref().is_some_and(|name| {
            self.name_keywords
                .iter()
                .any(|keyword| name.contains(&normalize(keyword)))
        })
    }
}

#[derive(Clone, Debug)]
pub struct StrategySelector {
    rules: Vec<AppStrategyRule>,
}

impl Default for StrategySelector {
    fn default() -> Self {
        Self::new(default_rules())
    }
}

impl StrategySelector {
    pub fn new(rules: Vec<AppStrategyRule>) -> Self {
        Self { rules }
    }

    pub fn select_plan(&self, request: &InsertionRequest) -> InsertionPlan {
        if request.text.trim().is_empty() {
            return InsertionPlan::unavailable(FailureReason::EmptyText, RecoveryAction::None);
        }

        let Some(context) = request.context.as_ref() else {
            return InsertionPlan::unavailable(
                FailureReason::NoFocusedTarget,
                RecoveryAction::CopyResult,
            );
        };

        if context.is_secure_field {
            return InsertionPlan::unavailable(FailureReason::SecureField, RecoveryAction::None);
        }

        let Some(platform) = context.platform else {
            return InsertionPlan::unavailable(
                FailureReason::UnsupportedPlatform,
                RecoveryAction::CopyResult,
            );
        };

        if matches!(
            platform,
            Platform::LinuxWayland | Platform::LinuxUnknown | Platform::Unknown
        ) {
            return InsertionPlan::unavailable(
                FailureReason::UnsupportedPlatform,
                RecoveryAction::CopyResult,
            );
        }

        let matched = self.rules.iter().find(|rule| rule.matches(context));
        let (strategies, expected_confirmation, matched_rule) = match matched {
            Some(rule) => (
                rule.strategies.clone(),
                rule.expected_confirmation,
                Some(rule.id),
            ),
            None => default_platform_strategies(platform),
        };

        let uses_clipboard = strategies.iter().any(|strategy| strategy.uses_clipboard());
        let clipboard = if !uses_clipboard {
            ClipboardPreservationPlan::direct()
        } else if request.preserve_clipboard {
            ClipboardPreservationPlan::paste_preserving_existing()
        } else {
            ClipboardPreservationPlan {
                restore_policy: ClipboardRestorePolicy::KeepOutputForUser,
                ..ClipboardPreservationPlan::paste_preserving_existing()
            }
        };

        InsertionPlan {
            strategies,
            clipboard,
            expected_confirmation,
            unavailable_reason: None,
            recovery: RecoveryAction::Retry,
            matched_rule,
        }
    }
}

fn default_rules() -> Vec<AppStrategyRule> {
    vec![
        AppStrategyRule::new(
            "macos-native-text-controls",
            [Platform::Macos],
            [
                "com.apple.TextEdit",
                "com.apple.Notes",
                "com.apple.mail",
                "com.apple.iWork.Pages",
            ],
            ["textedit", "notes", "mail", "pages"],
            [
                InsertionStrategy::MacAccessibilityFocusedValue,
                InsertionStrategy::MacAccessibilitySelectedText,
                InsertionStrategy::MacClipboardKeystroke,
            ],
            PasteConfirmation::FocusedTextChanged,
        ),
        AppStrategyRule::new(
            "macos-browser-and-electron",
            [Platform::Macos],
            [
                "com.apple.Safari",
                "company.thebrowser.Browser",
                "com.google.Chrome",
                "com.microsoft.edgemac",
                "com.brave.Browser",
                "com.tinyspeck.slackmacgap",
                "com.hnc.Discord",
                "com.microsoft.VSCode",
                "com.todesktop.230313mzl4w4u92",
            ],
            [
                "arc",
                "chrome",
                "edge",
                "brave",
                "slack",
                "discord",
                "visual studio code",
                "cursor",
            ],
            [
                InsertionStrategy::MacClipboardKeystroke,
                InsertionStrategy::MacAccessibilityFocusedValue,
            ],
            PasteConfirmation::ClipboardConsumed,
        ),
        AppStrategyRule::new(
            "macos-terminal",
            [Platform::Macos],
            [
                "com.apple.Terminal",
                "com.googlecode.iterm2",
                "dev.warp.Warp-Stable",
                "net.kovidgoyal.kitty",
                "com.mitchellh.ghostty",
                "com.github.wez.wezterm",
                "org.alacritty",
                "com.cmuxterm.app",
            ],
            [
                "terminal",
                "iterm",
                "warp",
                "kitty",
                "ghostty",
                "wezterm",
                "alacritty",
                "cmux",
            ],
            [InsertionStrategy::MacClipboardKeystroke],
            PasteConfirmation::ClipboardConsumed,
        ),
    ]
}

fn default_platform_strategies(
    platform: Platform,
) -> (
    Vec<InsertionStrategy>,
    PasteConfirmation,
    Option<&'static str>,
) {
    match platform {
        Platform::Macos => (
            vec![
                InsertionStrategy::MacAccessibilityFocusedValue,
                InsertionStrategy::MacAccessibilitySelectedText,
                InsertionStrategy::MacClipboardKeystroke,
            ],
            PasteConfirmation::FocusedTextChanged,
            None,
        ),
        Platform::Windows => (
            vec![InsertionStrategy::WindowsSendInputPaste],
            PasteConfirmation::ClipboardConsumed,
            None,
        ),
        Platform::LinuxX11 => (
            vec![InsertionStrategy::LinuxX11ClipboardPaste],
            PasteConfirmation::ClipboardConsumed,
            None,
        ),
        Platform::LinuxWayland | Platform::LinuxUnknown | Platform::Unknown => {
            (Vec::new(), PasteConfirmation::NotConfirmed, None)
        }
    }
}

fn normalize(value: &str) -> String {
    value.trim().to_ascii_lowercase()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn selector() -> StrategySelector {
        StrategySelector::default()
    }

    #[test]
    fn selects_direct_accessibility_first_for_native_macos_text_controls() {
        let request = InsertionRequest::new(
            "hello",
            Some(
                AppContext::new(Platform::Macos)
                    .with_app_id("com.apple.TextEdit")
                    .with_focused_text_input(true),
            ),
        );

        let plan = selector().select_plan(&request);

        assert!(plan.available());
        assert_eq!(plan.matched_rule, Some("macos-native-text-controls"));
        assert_eq!(
            plan.strategies,
            vec![
                InsertionStrategy::MacAccessibilityFocusedValue,
                InsertionStrategy::MacAccessibilitySelectedText,
                InsertionStrategy::MacClipboardKeystroke,
            ]
        );
        assert_eq!(
            plan.clipboard,
            ClipboardPreservationPlan::paste_preserving_existing()
        );
    }

    #[test]
    fn selects_clipboard_first_for_macos_browsers_and_electron_apps() {
        let request = InsertionRequest::new(
            "hello",
            Some(
                AppContext::new(Platform::Macos)
                    .with_app_id("company.thebrowser.Browser")
                    .with_focused_text_input(true),
            ),
        );

        let plan = selector().select_plan(&request);

        assert!(plan.available());
        assert_eq!(plan.matched_rule, Some("macos-browser-and-electron"));
        assert_eq!(
            plan.strategies,
            vec![
                InsertionStrategy::MacClipboardKeystroke,
                InsertionStrategy::MacAccessibilityFocusedValue,
            ]
        );
        assert_eq!(
            plan.expected_confirmation,
            PasteConfirmation::ClipboardConsumed
        );
    }

    #[test]
    fn matches_app_by_name_when_bundle_id_is_missing() {
        let request = InsertionRequest::new(
            "hello",
            Some(
                AppContext::new(Platform::Macos)
                    .with_app_name("Cursor")
                    .with_focused_text_input(true),
            ),
        );

        let plan = selector().select_plan(&request);

        assert_eq!(plan.matched_rule, Some("macos-browser-and-electron"));
        assert_eq!(plan.strategies[0], InsertionStrategy::MacClipboardKeystroke);
    }

    #[test]
    fn selects_clipboard_only_for_terminal_like_macos_apps() {
        let request = InsertionRequest::new(
            "hello",
            Some(
                AppContext::new(Platform::Macos)
                    .with_app_id("com.cmuxterm.app")
                    .with_app_name("cmux")
                    .with_focused_text_input(true),
            ),
        );

        let plan = selector().select_plan(&request);

        assert!(plan.available());
        assert_eq!(plan.matched_rule, Some("macos-terminal"));
        assert_eq!(
            plan.strategies,
            vec![InsertionStrategy::MacClipboardKeystroke]
        );
        assert_eq!(
            plan.expected_confirmation,
            PasteConfirmation::ClipboardConsumed
        );
    }

    #[test]
    fn refuses_secure_fields_without_copying_sensitive_text() {
        let request = InsertionRequest::new(
            "secret",
            Some(
                AppContext::new(Platform::Macos)
                    .with_app_id("com.apple.Safari")
                    .with_secure_field(true),
            ),
        );

        let plan = selector().select_plan(&request);

        assert!(!plan.available());
        assert_eq!(plan.unavailable_reason, Some(FailureReason::SecureField));
        assert_eq!(plan.recovery, RecoveryAction::None);
        assert_eq!(plan.clipboard, ClipboardPreservationPlan::direct());
    }

    #[test]
    fn selects_sendinput_clipboard_paste_for_windows() {
        let request = InsertionRequest::new(
            "hello",
            Some(
                AppContext::new(Platform::Windows)
                    .with_app_name("Notepad")
                    .with_focused_text_input(true),
            ),
        );

        let plan = selector().select_plan(&request);

        assert!(plan.available());
        assert_eq!(
            plan.strategies,
            vec![InsertionStrategy::WindowsSendInputPaste]
        );
        assert_eq!(
            plan.clipboard.restore_policy,
            ClipboardRestorePolicy::RestoreAfterConfirmedInsertion
        );
    }

    #[test]
    fn selects_x11_clipboard_paste_for_linux_x11() {
        let request = InsertionRequest::new(
            "hello",
            Some(
                AppContext::new(Platform::LinuxX11)
                    .with_app_name("gedit")
                    .with_focused_text_input(true),
            ),
        );

        let plan = selector().select_plan(&request);

        assert!(plan.available());
        assert_eq!(
            plan.strategies,
            vec![InsertionStrategy::LinuxX11ClipboardPaste]
        );
    }

    #[test]
    fn treats_wayland_as_unsupported_until_a_specific_backend_exists() {
        let request = InsertionRequest::new(
            "hello",
            Some(
                AppContext::new(Platform::LinuxWayland)
                    .with_app_name("gedit")
                    .with_focused_text_input(true),
            ),
        );

        let plan = selector().select_plan(&request);

        assert!(!plan.available());
        assert_eq!(
            plan.unavailable_reason,
            Some(FailureReason::UnsupportedPlatform)
        );
        assert_eq!(plan.recovery, RecoveryAction::CopyResult);
    }

    #[test]
    fn returns_copy_recovery_when_no_target_was_captured() {
        let request = InsertionRequest::new("hello", None);

        let plan = selector().select_plan(&request);

        assert!(!plan.available());
        assert_eq!(
            plan.unavailable_reason,
            Some(FailureReason::NoFocusedTarget)
        );
        assert_eq!(plan.recovery, RecoveryAction::CopyResult);
    }

    #[test]
    fn can_keep_output_on_clipboard_when_preservation_is_disabled() {
        let mut request = InsertionRequest::new(
            "hello",
            Some(
                AppContext::new(Platform::Windows)
                    .with_app_name("Notepad")
                    .with_focused_text_input(true),
            ),
        );
        request.preserve_clipboard = false;

        let plan = selector().select_plan(&request);

        assert_eq!(
            plan.clipboard.restore_policy,
            ClipboardRestorePolicy::KeepOutputForUser
        );
    }
}
