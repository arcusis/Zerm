use anyhow::Result;
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

pub const HISTORY_LIMIT: usize = 100;

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct Stats {
    pub words_transcribed: u64,
    pub words_generated: u64,
    pub generation_count: u64,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct HistoryEntry {
    pub timestamp: u64,
    pub transcript: String,
    pub output: String,
}

#[derive(Clone, Copy, Debug, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum PromptMode {
    Off,
    #[serde(alias = "agent")]
    #[default]
    Developer,
    Conversational,
    Professional,
}

#[derive(Clone, Copy, Debug, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum HotkeyChoice {
    #[default]
    RightOption,
    LeftOption,
    RightCommand,
    RightShift,
    RightControl,
    CapsLock,
    Fn,
}

impl HotkeyChoice {
    pub fn key_code(self) -> u16 {
        match self {
            HotkeyChoice::RightOption => 61,
            HotkeyChoice::LeftOption => 58,
            HotkeyChoice::RightCommand => 54,
            HotkeyChoice::RightShift => 60,
            HotkeyChoice::RightControl => 62,
            HotkeyChoice::CapsLock => 57,
            HotkeyChoice::Fn => 63,
        }
    }

    pub fn flag_bit(self) -> usize {
        match self {
            HotkeyChoice::RightOption | HotkeyChoice::LeftOption => 1 << 19,
            HotkeyChoice::RightCommand => 1 << 20,
            HotkeyChoice::RightShift => 1 << 17,
            HotkeyChoice::RightControl => 1 << 18,
            HotkeyChoice::CapsLock => 1 << 16,
            HotkeyChoice::Fn => 1 << 23,
        }
    }

    pub fn label(self) -> &'static str {
        match self {
            HotkeyChoice::RightOption => "Right Option",
            HotkeyChoice::LeftOption => "Left Option",
            HotkeyChoice::RightCommand => "Right Command",
            HotkeyChoice::RightShift => "Right Shift",
            HotkeyChoice::RightControl => "Right Control",
            HotkeyChoice::CapsLock => "Caps Lock",
            HotkeyChoice::Fn => "Fn",
        }
    }

    pub fn from_key(key: &str) -> Option<Self> {
        match key {
            "right_option" => Some(HotkeyChoice::RightOption),
            "left_option" => Some(HotkeyChoice::LeftOption),
            "right_command" => Some(HotkeyChoice::RightCommand),
            "right_shift" => Some(HotkeyChoice::RightShift),
            "right_control" => Some(HotkeyChoice::RightControl),
            "caps_lock" => Some(HotkeyChoice::CapsLock),
            "fn" => Some(HotkeyChoice::Fn),
            _ => None,
        }
    }
}

#[derive(Clone, Copy, Debug, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum ProfileTriggerKind {
    #[default]
    BundleId,
    AppName,
    WindowTitle,
    BrowserDomain,
    UrlPrefix,
    Language,
}

#[derive(Clone, Copy, Debug, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum ProfileMatchMode {
    #[default]
    Exact,
    Contains,
    Prefix,
    Suffix,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq, Eq)]
pub struct ProfileTrigger {
    #[serde(default)]
    pub kind: ProfileTriggerKind,
    #[serde(default)]
    pub pattern: String,
    #[serde(default)]
    pub match_mode: ProfileMatchMode,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq, Eq)]
pub struct ProfilePrivacyOverrides {
    #[serde(default)]
    pub capture_app_context: Option<bool>,
    #[serde(default)]
    pub capture_window_title: Option<bool>,
    #[serde(default)]
    pub capture_browser_url: Option<bool>,
    #[serde(default)]
    pub capture_selected_text: Option<bool>,
    #[serde(default)]
    pub capture_field_text: Option<bool>,
    #[serde(default)]
    pub save_history: Option<bool>,
    #[serde(default)]
    pub allow_auto_send: Option<bool>,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct PowerModeProfile {
    #[serde(default)]
    pub id: String,
    #[serde(default)]
    pub name: String,
    #[serde(default = "default_true")]
    pub enabled: bool,
    #[serde(default)]
    pub priority: i32,
    #[serde(default)]
    pub triggers: Vec<ProfileTrigger>,
    #[serde(default)]
    pub prompt_mode: Option<PromptMode>,
    #[serde(default)]
    pub transcription_model_id: Option<String>,
    #[serde(default)]
    pub rewrite_model_id: Option<String>,
    #[serde(default)]
    pub language_hint: Option<String>,
    #[serde(default)]
    pub auto_paste: Option<bool>,
    #[serde(default)]
    pub auto_send: bool,
    #[serde(default)]
    pub vocabulary_replacement_ids: Vec<String>,
    #[serde(default)]
    pub privacy: ProfilePrivacyOverrides,
}

impl Default for PowerModeProfile {
    fn default() -> Self {
        Self {
            id: "default".to_string(),
            name: "Default".to_string(),
            enabled: true,
            priority: 0,
            triggers: Vec::new(),
            prompt_mode: None,
            transcription_model_id: None,
            rewrite_model_id: None,
            language_hint: None,
            auto_paste: None,
            auto_send: false,
            vocabulary_replacement_ids: Vec::new(),
            privacy: ProfilePrivacyOverrides::default(),
        }
    }
}

#[derive(Clone, Copy, Debug, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum ModelProvider {
    #[default]
    WhisperCpp,
    Ollama,
    Native,
    External,
}

#[derive(Clone, Copy, Debug, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum ModelRole {
    #[default]
    Transcription,
    Rewrite,
    Cleanup,
    Vad,
}

#[derive(Clone, Copy, Debug, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum ModelCapabilityLevel {
    Low,
    #[default]
    Medium,
    High,
    VeryHigh,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq, Eq)]
pub struct ModelDescriptor {
    #[serde(default)]
    pub id: String,
    #[serde(default)]
    pub display_name: String,
    #[serde(default)]
    pub provider: ModelProvider,
    #[serde(default)]
    pub role: ModelRole,
    #[serde(default)]
    pub default_model: bool,
    #[serde(default)]
    pub recommended: bool,
    #[serde(default)]
    pub multilingual: bool,
    #[serde(default)]
    pub languages: Vec<String>,
    #[serde(default)]
    pub speed: ModelCapabilityLevel,
    #[serde(default)]
    pub accuracy: ModelCapabilityLevel,
    #[serde(default)]
    pub memory_mb: Option<u32>,
    #[serde(default)]
    pub disk_mb: Option<u32>,
    #[serde(default)]
    pub download_url: Option<String>,
    #[serde(default)]
    pub sha256: Option<String>,
    #[serde(default)]
    pub local_filename: Option<String>,
    #[serde(default)]
    pub ollama_name: Option<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct ModelCatalog {
    #[serde(default)]
    pub transcription: Vec<ModelDescriptor>,
    #[serde(default)]
    pub rewrite: Vec<ModelDescriptor>,
}

impl Default for ModelCatalog {
    fn default() -> Self {
        Self {
            transcription: vec![ModelDescriptor {
                id: "whisper-small".to_string(),
                display_name: "Whisper small".to_string(),
                provider: ModelProvider::WhisperCpp,
                role: ModelRole::Transcription,
                default_model: true,
                recommended: true,
                multilingual: true,
                languages: Vec::new(),
                speed: ModelCapabilityLevel::Medium,
                accuracy: ModelCapabilityLevel::Medium,
                memory_mb: Some(1024),
                disk_mb: Some(466),
                download_url: None,
                sha256: None,
                local_filename: Some("ggml-small.bin".to_string()),
                ollama_name: None,
            }],
            rewrite: vec![
                ModelDescriptor {
                    id: "gemma3-4b".to_string(),
                    display_name: "Gemma 3 4B".to_string(),
                    provider: ModelProvider::Ollama,
                    role: ModelRole::Rewrite,
                    default_model: true,
                    recommended: true,
                    multilingual: false,
                    languages: vec!["en".to_string()],
                    speed: ModelCapabilityLevel::Medium,
                    accuracy: ModelCapabilityLevel::Medium,
                    memory_mb: Some(4096),
                    disk_mb: None,
                    download_url: None,
                    sha256: None,
                    local_filename: None,
                    ollama_name: Some("gemma3:4b".to_string()),
                },
                ModelDescriptor {
                    id: "aya-expanse-8b".to_string(),
                    display_name: "Aya Expanse 8B".to_string(),
                    provider: ModelProvider::Ollama,
                    role: ModelRole::Rewrite,
                    default_model: false,
                    recommended: true,
                    multilingual: true,
                    languages: vec![
                        "he".to_string(),
                        "ru".to_string(),
                        "ja".to_string(),
                        "ko".to_string(),
                        "zh".to_string(),
                    ],
                    speed: ModelCapabilityLevel::Low,
                    accuracy: ModelCapabilityLevel::High,
                    memory_mb: Some(8192),
                    disk_mb: None,
                    download_url: None,
                    sha256: None,
                    local_filename: None,
                    ollama_name: Some("aya-expanse:8b".to_string()),
                },
            ],
        }
    }
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct VocabularyReplacementEntry {
    #[serde(default)]
    pub id: String,
    #[serde(default = "default_true")]
    pub enabled: bool,
    #[serde(default)]
    pub find: String,
    #[serde(default)]
    pub replace: String,
    #[serde(default)]
    pub case_sensitive: bool,
    #[serde(default = "default_true")]
    pub whole_word: bool,
    #[serde(default)]
    pub profile_ids: Vec<String>,
    #[serde(default)]
    pub notes: Option<String>,
}

impl Default for VocabularyReplacementEntry {
    fn default() -> Self {
        Self {
            id: String::new(),
            enabled: true,
            find: String::new(),
            replace: String::new(),
            case_sensitive: false,
            whole_word: true,
            profile_ids: Vec::new(),
            notes: None,
        }
    }
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct PrivacyFlags {
    #[serde(default = "default_true")]
    pub capture_app_context: bool,
    #[serde(default)]
    pub capture_window_title: bool,
    #[serde(default)]
    pub capture_browser_url: bool,
    #[serde(default)]
    pub capture_selected_text: bool,
    #[serde(default)]
    pub capture_field_text: bool,
    #[serde(default = "default_true")]
    pub allow_auto_profile_matching: bool,
    #[serde(default)]
    pub allow_auto_learn_vocabulary: bool,
    #[serde(default)]
    pub include_transcripts_in_diagnostics: bool,
    #[serde(default)]
    pub allow_secure_field_context: bool,
}

impl Default for PrivacyFlags {
    fn default() -> Self {
        Self {
            capture_app_context: true,
            capture_window_title: false,
            capture_browser_url: false,
            capture_selected_text: false,
            capture_field_text: false,
            allow_auto_profile_matching: true,
            allow_auto_learn_vocabulary: false,
            include_transcripts_in_diagnostics: false,
            allow_secure_field_context: false,
        }
    }
}

fn default_true() -> bool {
    true
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Settings {
    pub llm_model: String,
    pub vad_enabled: bool,
    #[serde(default)]
    pub prompt_mode: PromptMode,
    #[serde(default)]
    pub hotkey: HotkeyChoice,
    #[serde(default, deserialize_with = "deserialize_vocabulary")]
    pub vocabulary: Vec<String>,
    // Auto-paste defaults to FALSE for both fresh installs and migrations.
    // Using a plain `#[serde(default)]` (which falls back to bool::default()
    // i.e. false) so an old state file that predates the field doesn't
    // silently opt users into the dangerous behavior.
    #[serde(default)]
    pub auto_paste: bool,

    /// Allow sending transcripts/model-pull requests to a localhost Ollama
    /// listener whose process identity could not be fully verified.
    #[serde(default)]
    pub allow_unverified_ollama: bool,

    /// Whether to save dictations to the history log. Defaults to false:
    /// dictation can contain secrets, client data, or private messages, so
    /// users must opt in before transcript/output text is persisted.
    #[serde(default)]
    pub save_history: bool,

    /// App-aware power-mode profiles. These are scaffolded for native
    /// integration; existing runtime behavior continues to use the legacy
    /// top-level settings until the pipeline opts into profile resolution.
    #[serde(default = "default_power_profiles")]
    pub profiles: Vec<PowerModeProfile>,
    #[serde(default)]
    pub active_profile_id: Option<String>,
    #[serde(default)]
    pub model_catalog: ModelCatalog,
    #[serde(default)]
    pub vocabulary_replacements: Vec<VocabularyReplacementEntry>,
    #[serde(default)]
    pub privacy: PrivacyFlags,
}

// Migrate from old String-typed vocabulary to Vec<String> seamlessly
fn deserialize_vocabulary<'de, D>(deserializer: D) -> Result<Vec<String>, D::Error>
where
    D: serde::Deserializer<'de>,
{
    use serde::de::Error;
    let value = serde_json::Value::deserialize(deserializer)?;
    match value {
        serde_json::Value::Array(arr) => arr
            .into_iter()
            .map(|v| match v {
                serde_json::Value::String(s) => Ok(s),
                _ => Err(D::Error::custom("vocabulary entry must be a string")),
            })
            .collect(),
        serde_json::Value::String(s) => Ok(s
            .split(',')
            .map(|t| t.trim().to_string())
            .filter(|t| !t.is_empty())
            .collect()),
        serde_json::Value::Null => Ok(Vec::new()),
        _ => Err(D::Error::custom("vocabulary must be an array of strings")),
    }
}

impl Default for Settings {
    fn default() -> Self {
        Self {
            llm_model: "gemma3:4b".to_string(),
            vad_enabled: true,
            prompt_mode: PromptMode::Developer,
            hotkey: HotkeyChoice::RightOption,
            vocabulary: Vec::new(),
            // Auto-paste is OPT-IN. It can paste into the wrong window if the
            // user tabs away during the async Whisper+Ollama round trip.
            auto_paste: false,
            allow_unverified_ollama: false,
            save_history: false,
            profiles: default_power_profiles(),
            active_profile_id: None,
            model_catalog: ModelCatalog::default(),
            vocabulary_replacements: Vec::new(),
            privacy: PrivacyFlags::default(),
        }
    }
}

fn default_power_profiles() -> Vec<PowerModeProfile> {
    vec![PowerModeProfile::default()]
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct PillPosition {
    pub x: i32,
    pub y: i32,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct PersistentState {
    #[serde(default)]
    pub stats: Stats,
    #[serde(default)]
    pub history: Vec<HistoryEntry>,
    #[serde(default)]
    pub settings: Settings,
    #[serde(default)]
    pub pill_position: Option<PillPosition>,
    #[serde(default)]
    pub pill_positions_by_monitor: BTreeMap<String, PillPosition>,
}

#[derive(Clone, Debug, Serialize)]
pub struct DashboardData {
    pub stats: Stats,
    pub history: Vec<HistoryEntry>,
    pub settings: Settings,
}

impl PersistentState {
    #[cfg(test)]
    pub fn load(path: &Path) -> Self {
        match std::fs::read_to_string(path) {
            Ok(s) => serde_json::from_str(&s).unwrap_or_default(),
            Err(_) => Self::default(),
        }
    }

    /// Atomic save: write to a sibling `.tmp` file, fsync, rename over the
    /// target. Prevents corruption if the process dies mid-write or two
    /// concurrent saves interleave. A `.bak` of the previous good file is
    /// kept so we can recover if the parse at load time ever fails.
    pub fn save(&self, path: &Path) -> Result<()> {
        use std::io::Write;
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let mut disk_state = self.clone();
        if !disk_state.settings.save_history {
            disk_state.history.clear();
        }
        let serialized = serde_json::to_string_pretty(&disk_state)?;
        let tmp = path.with_extension("json.tmp");
        {
            let mut f = std::fs::File::create(&tmp)?;
            f.write_all(serialized.as_bytes())?;
            f.sync_all()?;
        }
        // Preserve the prior good copy as a `.bak` before clobbering. On
        // Windows `rename` refuses to overwrite, so we have to remove any
        // pre-existing `.bak` first; otherwise the `.bak` stays forever and
        // every subsequent save fails to back up.
        if path.exists() {
            let bak = path.with_extension("json.bak");
            let _ = std::fs::remove_file(&bak);
            let _ = std::fs::rename(path, &bak);
        }
        // Same reason — make sure the final rename of `.tmp` into place
        // always succeeds. `path` was either never there, or we just moved
        // it to `.bak` above, but we also defensively remove.
        let _ = std::fs::remove_file(path);
        std::fs::rename(&tmp, path)?;
        Ok(())
    }

    pub fn backup_path(path: &Path) -> PathBuf {
        path.with_extension("json.bak")
    }

    pub fn remove_backup(path: &Path) -> Result<()> {
        let bak = Self::backup_path(path);
        match std::fs::remove_file(&bak) {
            Ok(()) => Ok(()),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
            Err(e) => Err(e.into()),
        }
    }

    pub fn load_with_backup(path: &Path) -> Self {
        if let Ok(s) = std::fs::read_to_string(path) {
            if let Ok(state) = serde_json::from_str::<Self>(&s) {
                return state;
            }
            log::warn!("state file at {path:?} failed to parse; trying .bak");
        }
        let bak = Self::backup_path(path);
        if let Ok(s) = std::fs::read_to_string(&bak) {
            if let Ok(state) = serde_json::from_str::<Self>(&s) {
                log::info!("recovered state from {bak:?}");
                return state;
            }
        }
        Self::default()
    }

    pub fn record(&mut self, transcript: String, output: String) {
        let words_t = transcript.split_whitespace().count() as u64;
        let words_g = output.split_whitespace().count() as u64;
        self.stats.words_transcribed += words_t;
        self.stats.words_generated += words_g;
        self.stats.generation_count += 1;
        self.history.insert(
            0,
            HistoryEntry {
                timestamp: now_millis(),
                transcript,
                output,
            },
        );
        if self.history.len() > HISTORY_LIMIT {
            self.history.truncate(HISTORY_LIMIT);
        }
    }

    pub fn dashboard(&self) -> DashboardData {
        DashboardData {
            stats: self.stats.clone(),
            history: self.history.clone(),
            settings: self.settings.clone(),
        }
    }
}

fn now_millis() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

pub fn strip_whisper_tokens(text: &str) -> String {
    // Strip whisper-emitted control tokens like [BLANK_AUDIO], [_BEG_], [_TT_123]
    let mut out = String::with_capacity(text.len());
    let mut chars = text.chars().peekable();
    while let Some(c) = chars.next() {
        if c == '[' {
            let mut buf = String::new();
            let mut closed = false;
            while let Some(&next) = chars.peek() {
                chars.next();
                if next == ']' {
                    closed = true;
                    break;
                }
                buf.push(next);
            }
            // A whisper control token requires at least one letter or underscore
            // and only uppercase/digit/underscore characters (so `[0]` is preserved).
            let is_token = closed
                && !buf.is_empty()
                && buf.chars().any(|ch| ch.is_ascii_uppercase() || ch == '_')
                && buf
                    .chars()
                    .all(|ch| ch.is_ascii_uppercase() || ch.is_ascii_digit() || ch == '_');
            if !is_token {
                out.push('[');
                out.push_str(&buf);
                if closed {
                    out.push(']');
                }
            }
        } else {
            out.push(c);
        }
    }
    out.split_whitespace().collect::<Vec<_>>().join(" ")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn strips_blank_audio() {
        assert_eq!(
            strip_whisper_tokens("Hello world. [BLANK_AUDIO]"),
            "Hello world."
        );
    }

    #[test]
    fn strips_multiple_tokens() {
        assert_eq!(
            strip_whisper_tokens("[_BEG_] hi [BLANK_AUDIO] there [_TT_42]"),
            "hi there"
        );
    }

    #[test]
    fn preserves_real_brackets() {
        assert_eq!(
            strip_whisper_tokens("Use array[0] for the first item."),
            "Use array[0] for the first item."
        );
    }

    #[test]
    fn record_increments_stats() {
        let mut s = PersistentState::default();
        s.record("one two three".to_string(), "ONE TWO".to_string());
        assert_eq!(s.stats.words_transcribed, 3);
        assert_eq!(s.stats.words_generated, 2);
        assert_eq!(s.stats.generation_count, 1);
        assert_eq!(s.history.len(), 1);
    }

    #[test]
    fn history_capped() {
        let mut s = PersistentState::default();
        for i in 0..(HISTORY_LIMIT + 10) {
            s.record(format!("t{i}"), format!("o{i}"));
        }
        assert_eq!(s.history.len(), HISTORY_LIMIT);
    }

    #[test]
    fn save_omits_history_when_history_disabled() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("zerm-state.json");
        let mut s = PersistentState::default();
        s.record("secret transcript".to_string(), "secret output".to_string());
        s.settings.save_history = false;

        s.save(&path).unwrap();

        let raw = std::fs::read_to_string(&path).unwrap();
        assert!(!raw.contains("secret transcript"));
        assert!(!raw.contains("secret output"));
        let loaded = PersistentState::load(&path);
        assert!(loaded.history.is_empty());
    }

    #[test]
    fn backup_can_be_removed_after_privacy_erase() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("zerm-state.json");
        let mut s = PersistentState::default();
        s.settings.save_history = true;
        s.record("secret transcript".to_string(), "secret output".to_string());
        s.save(&path).unwrap();

        s.history.clear();
        s.settings.save_history = false;
        s.save(&path).unwrap();
        assert!(PersistentState::backup_path(&path).exists());

        PersistentState::remove_backup(&path).unwrap();
        assert!(!PersistentState::backup_path(&path).exists());
    }

    #[test]
    fn legacy_settings_load_with_new_profile_defaults() {
        let raw = r#"{
            "stats": {
                "words_transcribed": 0,
                "words_generated": 0,
                "generation_count": 0
            },
            "history": [],
            "settings": {
                "llm_model": "gemma3:4b",
                "vad_enabled": true,
                "prompt_mode": "developer",
                "hotkey": "right_option",
                "vocabulary": "Zerm, Arc browser",
                "auto_paste": false,
                "allow_unverified_ollama": false,
                "save_history": false
            }
        }"#;

        let state: PersistentState = serde_json::from_str(raw).unwrap();

        assert_eq!(
            state.settings.vocabulary,
            vec!["Zerm".to_string(), "Arc browser".to_string()]
        );
        assert_eq!(state.settings.profiles.len(), 1);
        assert_eq!(state.settings.profiles[0].id, "default");
        assert!(state
            .settings
            .model_catalog
            .transcription
            .iter()
            .any(|model| model.id == "whisper-small" && model.default_model));
        assert!(state
            .settings
            .model_catalog
            .rewrite
            .iter()
            .any(|model| model.ollama_name.as_deref() == Some("gemma3:4b")));
        assert!(state.settings.vocabulary_replacements.is_empty());
        assert!(state.settings.privacy.capture_app_context);
        assert!(!state.settings.privacy.capture_field_text);
    }

    #[test]
    fn profile_scaffold_round_trips() {
        let mut state = PersistentState::default();
        state.settings.active_profile_id = Some("slack".to_string());
        state.settings.profiles.push(PowerModeProfile {
            id: "slack".to_string(),
            name: "Slack".to_string(),
            enabled: true,
            priority: 20,
            triggers: vec![ProfileTrigger {
                kind: ProfileTriggerKind::BundleId,
                pattern: "com.tinyspeck.slackmacgap".to_string(),
                match_mode: ProfileMatchMode::Exact,
            }],
            prompt_mode: Some(PromptMode::Conversational),
            transcription_model_id: Some("whisper-small".to_string()),
            rewrite_model_id: Some("gemma3-4b".to_string()),
            language_hint: None,
            auto_paste: Some(true),
            auto_send: false,
            vocabulary_replacement_ids: vec!["zerm-brand".to_string()],
            privacy: ProfilePrivacyOverrides {
                capture_app_context: Some(true),
                capture_window_title: Some(false),
                capture_browser_url: None,
                capture_selected_text: Some(false),
                capture_field_text: Some(false),
                save_history: Some(false),
                allow_auto_send: Some(false),
            },
        });
        state
            .settings
            .vocabulary_replacements
            .push(VocabularyReplacementEntry {
                id: "zerm-brand".to_string(),
                enabled: true,
                find: "zerm".to_string(),
                replace: "Zerm".to_string(),
                case_sensitive: false,
                whole_word: true,
                profile_ids: vec!["slack".to_string()],
                notes: Some("Brand capitalization".to_string()),
            });

        let json = serde_json::to_string(&state).unwrap();
        let round_tripped: PersistentState = serde_json::from_str(&json).unwrap();

        let profile = round_tripped
            .settings
            .profiles
            .iter()
            .find(|profile| profile.id == "slack")
            .unwrap();
        assert_eq!(profile.prompt_mode, Some(PromptMode::Conversational));
        assert_eq!(profile.auto_paste, Some(true));
        assert_eq!(profile.triggers[0].kind, ProfileTriggerKind::BundleId);
        assert_eq!(
            round_tripped.settings.vocabulary_replacements[0].replace,
            "Zerm"
        );
    }

    #[test]
    fn partial_profile_and_replacement_json_uses_defaults() {
        let profile: PowerModeProfile = serde_json::from_str(r#"{"id":"code","name":"Code"}"#)
            .expect("partial profile should load");
        let replacement: VocabularyReplacementEntry =
            serde_json::from_str(r#"{"find":"api","replace":"API"}"#)
                .expect("partial replacement should load");

        assert!(profile.enabled);
        assert!(profile.triggers.is_empty());
        assert_eq!(profile.privacy, ProfilePrivacyOverrides::default());
        assert!(replacement.enabled);
        assert!(replacement.whole_word);
        assert!(!replacement.case_sensitive);
    }

    #[test]
    fn privacy_defaults_are_local_first() {
        let privacy = PrivacyFlags::default();

        assert!(privacy.capture_app_context);
        assert!(privacy.allow_auto_profile_matching);
        assert!(!privacy.capture_window_title);
        assert!(!privacy.capture_browser_url);
        assert!(!privacy.capture_selected_text);
        assert!(!privacy.capture_field_text);
        assert!(!privacy.allow_auto_learn_vocabulary);
        assert!(!privacy.include_transcripts_in_diagnostics);
        assert!(!privacy.allow_secure_field_context);
    }
}
