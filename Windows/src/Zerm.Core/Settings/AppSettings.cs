using System.ComponentModel;
using System.Text.Json;
using System.Text.Json.Serialization;
using CommunityToolkit.Mvvm.ComponentModel;
using Zerm.Core.Text;

namespace Zerm.Core.Settings;

public enum HotkeyMode { Toggle, PushToTalk, Hybrid }

/// <summary>Windows counterparts of the macOS trigger keys (side-specific modifiers or a custom combo).</summary>
public enum TriggerKey { None, RightCtrl, LeftCtrl, RightAlt, LeftAlt, RightShift, RightWin, CapsLock, ScrollLock, Pause, F13, Custom }

public enum DictationOutputMode { Instant, InstantRefine, Enhanced }

public enum AutoSendKey { None, Enter, ShiftEnter, CtrlEnter }

public enum ReadAloudMode { Exact, Retell, Summarize, Explain, Simplify }

public enum UsageRange { Week, Month, Year, AllTime }

/// <summary>A key combination, e.g. Ctrl+Shift+Space. Modifiers are Win32 MOD_* flags.</summary>
public sealed record KeyCombo(int VirtualKey, bool Ctrl, bool Alt, bool Shift, bool Win)
{
    public bool IsEmpty => VirtualKey == 0;
    public static KeyCombo Empty { get; } = new(0, false, false, false, false);
}

/// <summary>
/// All user preferences, mirroring AppDefaults.swift (Windows end state, no migrations).
/// Persisted as JSON; every property change schedules a save.
/// </summary>
public partial class AppSettings : ObservableObject
{
    // Onboarding & general
    [ObservableProperty] private bool _hasCompletedOnboarding;
    [ObservableProperty] private string _uiLanguage = "system"; // system | en | he
    [ObservableProperty] private bool _launchAtLogin;
    [ObservableProperty] private bool _startMinimized = true;
    [ObservableProperty] private bool _powerModeEnabled = true;
    [ObservableProperty] private bool _installOffered;

    // Hotkeys
    [ObservableProperty] private TriggerKey _hotkey1 = TriggerKey.RightCtrl;
    [ObservableProperty] private KeyCombo _hotkey1Custom = new(0x20, true, false, true, false); // Ctrl+Shift+Space
    [ObservableProperty] private HotkeyMode _hotkeyMode1 = HotkeyMode.Hybrid;
    [ObservableProperty] private TriggerKey _hotkey2 = TriggerKey.None;
    [ObservableProperty] private KeyCombo _hotkey2Custom = KeyCombo.Empty;
    [ObservableProperty] private HotkeyMode _hotkeyMode2 = HotkeyMode.Hybrid;
    [ObservableProperty] private bool _middleClickToggleEnabled;
    [ObservableProperty] private int _middleClickActivationDelayMs = 200;
    [ObservableProperty] private KeyCombo _cancelShortcut = KeyCombo.Empty;
    [ObservableProperty] private KeyCombo _pasteLastTranscriptionShortcut = KeyCombo.Empty;
    [ObservableProperty] private KeyCombo _pasteLastEnhancementShortcut = KeyCombo.Empty;
    [ObservableProperty] private KeyCombo _retryLastTranscriptionShortcut = KeyCombo.Empty;
    [ObservableProperty] private TriggerKey _readAloudHotkey = TriggerKey.Custom;
    [ObservableProperty] private KeyCombo _readAloudCustom = new(0x52, true, true, false, false); // Ctrl+Alt+R

    // Paste
    [ObservableProperty] private bool _restoreClipboardAfterPaste;
    [ObservableProperty] private double _clipboardRestoreDelay = 2.0;
    [ObservableProperty] private bool _appendTrailingSpace = true;

    // Audio & media
    [ObservableProperty] private string? _inputDeviceId; // null = system default
    [ObservableProperty] private bool _systemMuteEnabled = true;
    [ObservableProperty] private bool _skipMuteWithHeadphones = true;
    [ObservableProperty] private double _audioResumptionDelay;
    [ObservableProperty] private bool _soundFeedbackEnabled = true;
    [ObservableProperty] private string? _customStartSound;
    [ObservableProperty] private string? _customStopSound;

    // Recording & transcription
    [ObservableProperty] private string _currentTranscriptionModel = "ggml-base";
    [ObservableProperty] private string _selectedLanguage = "auto";
    [ObservableProperty] private bool _textFormattingEnabled = true;
    [ObservableProperty] private bool _vadEnabled = true;
    [ObservableProperty] private bool _autoStopAfterSilence = true;
    [ObservableProperty] private double _autoStopSilenceSeconds = 2.5;
    [ObservableProperty] private double _autoStopMinimumRecordingSeconds = 0.8;
    [ObservableProperty] private double _autoStopInitialSilenceSeconds = 6.0;
    [ObservableProperty] private double _autoStopLevelThreshold = 0.12;
    [ObservableProperty] private bool _removeFillerWords = true;
    [ObservableProperty] private List<string> _fillerWords = [.. TranscriptionOutputFilter.DefaultFillerWords];
    [ObservableProperty] private PunctuationCleanupMode _punctuationCleanupMode = PunctuationCleanupMode.Keep;
    [ObservableProperty] private bool _lowercaseTranscription;
    [ObservableProperty] private Dictionary<string, string> _customLanguagePrompts = new();
    [ObservableProperty] private int _cloudTranscriptionTimeoutSeconds = 60;

    // Enhancement
    [ObservableProperty] private DictationOutputMode _outputMode = DictationOutputMode.InstantRefine;
    [ObservableProperty] private DictationOutputMode _lastEnhancingOutputMode = DictationOutputMode.InstantRefine;
    [ObservableProperty] private bool _allowPromptTriggeredEnhancement;
    [ObservableProperty] private bool _useClipboardContext;
    [ObservableProperty] private bool _useScreenCaptureContext;
    [ObservableProperty] private bool _skipShortEnhancement = true;
    [ObservableProperty] private int _shortEnhancementWordThreshold = 3;
    [ObservableProperty] private int _enhancementTimeoutSeconds = 15;
    [ObservableProperty] private bool _enhancementRetryOnTimeout = true;
    [ObservableProperty] private string _selectedAIProvider = "On-Device";
    [ObservableProperty] private Dictionary<string, string> _providerSelectedModels = new();
    [ObservableProperty] private string _ollamaBaseUrl = "http://localhost:11434";
    [ObservableProperty] private string _ollamaSelectedModel = "mistral";
    [ObservableProperty] private string _customProviderBaseUrl = "";
    [ObservableProperty] private string _customProviderModel = "";
    [ObservableProperty] private string _localCliCommand = "claude -p --output-format text";
    [ObservableProperty] private int _localCliTimeoutSeconds = 45;
    [ObservableProperty] private Guid _selectedPromptId = Prompts.PredefinedPrompts.DefaultId;
    /// <summary>Use the Super Enhancement prompt unless a Power Mode, trigger word or recorder pick chooses another.</summary>
    [ObservableProperty] private bool _superEnhancement;
    [ObservableProperty] private string? _superEnhancementModel;

    // Read Aloud
    [ObservableProperty] private bool _ttsEnabled = true;
    [ObservableProperty] private string _ttsProvider = "Windows";
    [ObservableProperty] private Dictionary<string, string> _ttsVoices = new();
    [ObservableProperty] private double _ttsSpeed = 1.0;
    [ObservableProperty] private bool _ttsSmartCleanup = true;
    [ObservableProperty] private ReadAloudMode _ttsReadingMode = ReadAloudMode.Exact;

    // Retention
    [ObservableProperty] private bool _transcriptionCleanupEnabled;
    [ObservableProperty] private int _transcriptionRetentionMinutes = 1440;
    [ObservableProperty] private bool _audioCleanupEnabled = true;
    [ObservableProperty] private int _audioRetentionDays = 14;

    // UI
    [ObservableProperty] private UsageRange _dashboardUsageRange = UsageRange.Month;
    [ObservableProperty] private bool _debugLoggingEnabled;

    [JsonIgnore] public string? FilePath { get; private set; }

    private Timer? _saveTimer;
    private readonly object _saveGate = new();
    private bool _suspendSave;

    public static readonly JsonSerializerOptions JsonOptions = new()
    {
        WriteIndented = true,
        Converters = { new JsonStringEnumConverter() },
    };

    public static AppSettings Load(string? path = null)
    {
        path ??= AppPaths.SettingsFile;
        AppSettings settings;
        try
        {
            settings = File.Exists(path)
                ? JsonSerializer.Deserialize<AppSettings>(File.ReadAllText(path), JsonOptions) ?? new AppSettings()
                : new AppSettings();
        }
        catch (Exception ex)
        {
            Log.Error("Settings file unreadable; using defaults", ex);
            try { File.Copy(path, path + ".corrupt", overwrite: true); } catch { }
            settings = new AppSettings();
        }
        settings.FilePath = path;
        settings.FillerWords ??= [.. TranscriptionOutputFilter.DefaultFillerWords];
        settings.ProviderSelectedModels ??= new();
        settings.TtsVoices ??= new();
        settings.CustomLanguagePrompts ??= new();
        return settings;
    }

    protected override void OnPropertyChanged(PropertyChangedEventArgs e)
    {
        base.OnPropertyChanged(e);
        if (!_suspendSave && FilePath != null) ScheduleSave();
    }

    public void ScheduleSave()
    {
        lock (_saveGate)
        {
            _saveTimer?.Dispose();
            _saveTimer = new Timer(_ => SaveNow(), null, 300, Timeout.Infinite);
        }
    }

    public void SaveNow()
    {
        if (FilePath == null) return;
        try
        {
            lock (_saveGate)
            {
                var json = JsonSerializer.Serialize(this, JsonOptions);
                var tmp = FilePath + ".tmp";
                File.WriteAllText(tmp, json);
                File.Move(tmp, FilePath, overwrite: true);
            }
        }
        catch (Exception ex)
        {
            Log.Error("Could not save settings", ex);
        }
    }

    /// <summary>Model selected for a given AI provider (falls back to the provider's default).</summary>
    public string? ModelFor(string provider) =>
        ProviderSelectedModels.TryGetValue(provider, out var m) && !string.IsNullOrWhiteSpace(m) ? m : null;

    public void SetModelFor(string provider, string model)
    {
        ProviderSelectedModels[provider] = model;
        OnPropertyChanged(nameof(ProviderSelectedModels));
    }

    public string? TtsVoiceFor(string provider) => TtsVoices.TryGetValue(provider, out var v) ? v : null;

    public void SetTtsVoice(string provider, string voice)
    {
        TtsVoices[provider] = voice;
        OnPropertyChanged(nameof(TtsVoices));
    }

    public void ResetToDefaults()
    {
        var fresh = new AppSettings();
        _suspendSave = true;
        try
        {
            foreach (var p in typeof(AppSettings).GetProperties().Where(p => p.CanWrite && p.GetCustomAttributes(typeof(JsonIgnoreAttribute), true).Length == 0))
                p.SetValue(this, p.GetValue(fresh));
            HasCompletedOnboarding = true;
        }
        finally { _suspendSave = false; }
        ScheduleSave();
    }
}
