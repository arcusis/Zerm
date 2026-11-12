using System.Windows;
using System.Windows.Threading;
using Zerm.App.Localization;
using Zerm.App.Platform;
using Zerm.Core;
using Zerm.Core.Audio;
using Zerm.Core.Data;
using Zerm.Core.Dictation;
using Zerm.Core.Enhancement;
using Zerm.Core.LocalLlm;
using Zerm.Core.Settings;

namespace Zerm.App;

/// <summary>
/// The dictation state machine (ZermEngine + RecorderUIManager on macOS): hotkey modes, recording,
/// auto-stop, cancel, then the pipeline, paste, Refine-in-place and auto-send.
/// </summary>
public sealed class DictationController
{
    private readonly AppHost _host;
    private readonly AudioRecorder _recorder = new();
    private readonly Paster _paster;
    private readonly SoundPlayer _sounds;
    private readonly SystemMute _mute;
    private readonly DispatcherTimer _monitor;
    private readonly DispatcherTimer _watchdog;

    private Guid _runToken;
    private CancellationTokenSource? _runCancellation;
    private CancellationTokenSource? _refineCancellation;
    private DictationSession? _session;
    private DateTime _recordingStarted;
    private DateTime _lastSpeech;
    private bool _heardSpeech;
    private bool _cancelRequested;
    private DateTime _stateSince = DateTime.Now;
    private DateTime? _firstEscape;
    private bool _escapeHintShown;
    private string? _lastDeviceId;

    // Per-recording overrides from the recorder (Ctrl+E, Ctrl+digit, Alt+digit, overlay buttons).
    public DictationOutputMode? OutputOverride { get; set; }
    public Guid? PromptOverride { get; set; }
    public PowerModeConfig? PowerModeOverride { get; set; }
    public PowerModeConfig? ActivePowerMode { get; private set; }

    // Hotkey mode bookkeeping per slot (HotkeyManager.swift).
    private readonly Dictionary<HotkeySlot, bool> _handsFree = new();
    private HotkeySlot? _heldSlot;

    public RecorderState State { get; private set; } = RecorderState.Idle;
    public bool RecorderVisible { get; private set; }
    public float Level => _recorder.Level;
    public event Action? Changed;

    public DictationController(AppHost host)
    {
        _host = host;
        _paster = new Paster(host.Settings);
        _sounds = new SoundPlayer(host.Settings);
        _mute = new SystemMute(host.Settings);
        _monitor = new DispatcherTimer(DispatcherPriority.Normal) { Interval = TimeSpan.FromMilliseconds(200) };
        _monitor.Tick += (_, _) => MonitorTick();
        _watchdog = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(50) };
        _watchdog.Tick += (_, _) => ReleaseWatchdogTick();
        var stuck = new DispatcherTimer { Interval = TimeSpan.FromSeconds(10) };
        stuck.Tick += (_, _) => StuckStateCheck();
        stuck.Start();
        host.Ui.StateChanged += s => SetState(s);

        var hk = host.Hotkeys;
        hk.TriggerDown += OnTriggerDown;
        hk.TriggerUp += OnTriggerUp;
        hk.EscapePressed += OnEscape;
        hk.MiddleClickToggle += () => _ = ToggleAsync();
        hk.ShortcutPressed += OnShortcut;
        hk.ToggleEnhancementPressed += ToggleEnhancementForThisRecording;
        hk.PromptNumberPressed += n => SelectPrompt(n);
        hk.PowerModeNumberPressed += n => SelectPowerMode(n);
        hk.PowerModeHotkeyPressed += id =>
        {
            if (State == RecorderState.Idle)
            {
                PowerModeOverride = _host.Library.PowerModes.FirstOrDefault(m => m.Id == id);
                _ = ToggleAsync();
            }
            else if (State == RecorderState.Recording) _ = ToggleAsync();
        };
    }

    private void SetState(RecorderState state)
    {
        if (State != state) _stateSince = DateTime.Now;
        State = state;
        Changed?.Invoke();
    }

    private bool Busy => State is RecorderState.Transcribing or RecorderState.Enhancing or RecorderState.Busy or RecorderState.Starting;

    // MARK: - Hotkey modes

    private HotkeyMode ModeFor(HotkeySlot slot) => slot == HotkeySlot.Dictation2 ? _host.Settings.HotkeyMode2 : _host.Settings.HotkeyMode1;

    private void OnTriggerDown(HotkeySlot slot)
    {
        if (slot == HotkeySlot.ReadAloud)
        {
            _ = _host.ReadAloud.ToggleAsync();
            return;
        }
        if (_host.ReadAloud.IsActive)
        {
            _host.ReadAloud.Stop();
            return;
        }
        if (Busy) return;
        var mode = ModeFor(slot);
        switch (mode)
        {
            case HotkeyMode.PushToTalk:
                if (!RecorderVisible)
                {
                    _heldSlot = slot;
                    _watchdog.Start();
                    _ = StartAsync();
                }
                break;
            case HotkeyMode.Toggle:
                // Bare-modifier toggles fire on release so Ctrl+C etc. keep working.
                if (IsCustomOrSingleKey(slot)) ToggleFromKey(slot);
                break;
            case HotkeyMode.Hybrid:
                _heldSlot = slot;
                ToggleFromKey(slot);
                if (State is RecorderState.Starting or RecorderState.Recording) _watchdog.Start();
                break;
        }
    }

    private bool IsCustomOrSingleKey(HotkeySlot slot)
    {
        var key = slot == HotkeySlot.Dictation2 ? _host.Settings.Hotkey2 : _host.Settings.Hotkey1;
        return key is TriggerKey.Custom or TriggerKey.CapsLock or TriggerKey.ScrollLock or TriggerKey.Pause or TriggerKey.F13;
    }

    private void ToggleFromKey(HotkeySlot slot)
    {
        if (_handsFree.GetValueOrDefault(slot))
        {
            _handsFree[slot] = false;
            _ = ToggleAsync();
        }
        else if (!RecorderVisible)
        {
            _ = ToggleAsync();
        }
        else
        {
            // Visible from another gesture (e.g. tray menu): this press stops it.
            _ = ToggleAsync();
        }
    }

    private void OnTriggerUp(HotkeySlot slot, bool clean, TimeSpan held)
    {
        if (slot == HotkeySlot.ReadAloud) return;
        var mode = ModeFor(slot);
        if (_heldSlot == slot) _watchdog.Stop();
        switch (mode)
        {
            case HotkeyMode.PushToTalk:
                if (RecorderVisible && State is RecorderState.Recording or RecorderState.Starting) _ = StopAndTranscribeAsync();
                break;
            case HotkeyMode.Toggle:
                if (!IsCustomOrSingleKey(slot) && clean && !Busy) _ = ToggleAsync();
                break;
            case HotkeyMode.Hybrid:
                if (held >= TimeSpan.FromSeconds(0.5) && State is RecorderState.Recording or RecorderState.Starting)
                    _ = StopAndTranscribeAsync();
                else if (RecorderVisible)
                    _handsFree[slot] = true;
                break;
        }
    }

    /// <summary>Catches key releases the OS never delivered (HotkeyReleaseWatchdog.swift).</summary>
    private void ReleaseWatchdogTick()
    {
        if (_heldSlot is not { } slot) { _watchdog.Stop(); return; }
        if (!_host.Hotkeys.IsSlotDown(slot)) { _watchdog.Stop(); return; }
        if (!_host.Hotkeys.IsPhysicallyDown(slot))
        {
            _watchdog.Stop();
            Log.Info("Watchdog: synthesizing missed key release");
            _host.Hotkeys.ForceRelease(slot);
        }
    }

    // MARK: - Toggle / start / stop

    public async Task ToggleAsync()
    {
        if (_host.ReadAloud.IsActive)
        {
            _host.ReadAloud.Stop();
            return;
        }
        if (RecorderVisible)
        {
            if (State is RecorderState.Recording or RecorderState.Starting) await StopAndTranscribeAsync();
            else if (!Busy) await CancelAsync();
            return;
        }
        await StartAsync();
    }

    public async Task StartAsync()
    {
        if (RecorderVisible || Busy) return;
        var model = ResolveModelForStart();
        if (model == null)
        {
            _host.Ui.Toast(Loc.T("No transcription model is ready. Download a model or add an API key first."), ToastKind.Error,
                TimeSpan.FromSeconds(6), new ToastAction(Loc.T("Open Models"), () => _host.Navigate("Models")));
            Views.ShellWindow.ShowAndNavigate("Models");
            PowerModeOverride = null;
            return;
        }

        _refineCancellation?.Cancel();
        _cancelRequested = false;
        _runToken = Guid.NewGuid();
        var token = _runToken;
        _escapeHintShown = false;
        _firstEscape = null;
        OutputOverride = null;
        PromptOverride = null;
        SetState(RecorderState.Starting);
        RecorderVisible = true;
        _host.Hotkeys.RecorderVisible = true;
        Views.RecorderOverlay.ShowRecorder();

        // Capture the target app and its URL now (Power Mode), in parallel with the microphone.
        var (process, window, _) = ActiveWindowService.Foreground();
        var urlTask = _host.Settings.PowerModeEnabled && ActiveWindowService.IsBrowser(process)
            ? ActiveWindowService.BrowserUrlAsync(window, TimeSpan.FromMilliseconds(500))
            : Task.FromResult<string?>(null);

        try
        {
            // Off the UI thread with a deadline: a stuck audio driver must not freeze Zerm.
            var deviceId = _host.Settings.InputDeviceId;
            var opening = Task.Run(() => _recorder.Start(deviceId));
            if (await Task.WhenAny(opening, Task.Delay(TimeSpan.FromSeconds(5))) != opening)
                throw new TimeoutException(Loc.T("The microphone is not responding. Unplug and reconnect it, or pick another one in Audio Input."));
            await opening;
        }
        catch (Exception ex)
        {
            Log.Error("Microphone start failed", ex);
            _host.Ui.Toast(ex is TimeoutException ? ex.Message : Loc.T("Could not access the microphone. Check Windows Settings › Privacy & security › Microphone."), ToastKind.Error,
                TimeSpan.FromSeconds(6), new ToastAction(Loc.T("Open Settings"), () => OpenUri("ms-settings:privacy-microphone")));
            await HideAsync();
            return;
        }
        if (_lastDeviceId != null && _lastDeviceId != _recorder.DeviceId)
            _host.Ui.Toast(Loc.F("Using: {0}", _recorder.DeviceName ?? ""), ToastKind.Info);
        _lastDeviceId = _recorder.DeviceId;

        await _recorder.WaitForFirstAudio(TimeSpan.FromSeconds(1.5));
        if (token != _runToken || _cancelRequested || !RecorderVisible)
        {
            await StopRecorderAsync();
            return;
        }

        _recordingStarted = DateTime.Now;
        _lastSpeech = DateTime.Now;
        _heardSpeech = false;
        SetState(RecorderState.Recording);
        _sounds.PlayStart(() => _host.Dispatcher.BeginInvoke(() =>
        {
            if (token == _runToken && State == RecorderState.Recording) _mute.Mute();
        }));
        _monitor.Start();

        var url = await urlTask;
        BuildSession(model, process, window, url);
    }

    private Core.Models.TranscriptionModel? ResolveModelForStart()
    {
        if (PowerModeOverride?.SelectedTranscriptionModelName is { } pmModel &&
            Core.Models.TranscriptionModelRegistry.Find(pmModel, _host.Library.CustomTranscriptionModels) is { } m && _host.IsUsable(m))
            return m;
        var current = _host.CurrentModel;
        return _host.IsUsable(current) ? current : null;
    }

    private void BuildSession(Core.Models.TranscriptionModel globalModel, string? process, IntPtr window, string? url)
    {
        var s = _host.Settings;
        var pm = PowerModeOverride ?? (s.PowerModeEnabled ? _host.Library.Resolve(process, url) : null);
        ActivePowerMode = pm;
        var model = globalModel;
        if (pm?.SelectedTranscriptionModelName is { } name &&
            Core.Models.TranscriptionModelRegistry.Find(name, _host.Library.CustomTranscriptionModels) is { } pmModel && _host.IsUsable(pmModel))
            model = pmModel;
        var mode = pm?.OutputMode ?? s.OutputMode;
        var enhances = mode != DictationOutputMode.Instant || s.AllowPromptTriggeredEnhancement;
        string? clipboard = null;
        if (s.UseClipboardContext && enhances) clipboard = ClipboardService.GetText();
        Task<string?>? screen = null;
        if (mode == DictationOutputMode.Enhanced && (pm?.ContextAwareness ?? s.UseScreenCaptureContext))
            screen = ScreenContext.CaptureForegroundTextAsync(window);
        var overrides = new EnhancementOverrides(pm?.SelectedPrompt, pm?.SelectedAIProvider, pm?.SelectedAIProvider == null ? null : pm.SelectedAIModel);
        _session = new DictationSession(model, pm?.SelectedLanguage ?? s.SelectedLanguage,
            DictationPipeline.CleanupOptions(s, _host.Library, pm), mode, overrides, clipboard, screen, pm, pm?.AutoSendKey ?? AutoSendKey.None);

        // Prewarm the on-device LLM so the enhancement doesn't pay the load.
        var provider = overrides.Provider ?? s.SelectedAIProvider;
        var super = s.SuperEnhancement && overrides.PromptId == null;
        var pkg = super ? LocalLlmCatalog.ResolveForSuper(s.SuperEnhancementModel)
            : provider == AIProviders.OnDevice ? LocalLlmCatalog.ResolveForEnhancement(s.ModelFor(AIProviders.OnDevice)) : null;
        if (enhances && pkg != null)
            _ = Task.Run(() => _host.LocalLlm.PrewarmAsync(LocalLlmCatalog.PathFor(pkg)));
        Changed?.Invoke();
    }

    /// <summary>Auto-stop and microphone-drop detection, every 200 ms while recording.</summary>
    private void MonitorTick()
    {
        if (State != RecorderState.Recording)
        {
            _monitor.Stop();
            return;
        }
        var s = _host.Settings;
        var now = DateTime.Now;
        if (_recorder.HasReceivedAudio && now - _recorder.LastCallback > TimeSpan.FromSeconds(3))
        {
            _host.Ui.Toast(Loc.T("Recording stopped — microphone dropped"), ToastKind.Warning);
            _ = StopAndTranscribeAsync();
            return;
        }
        var level = Math.Max(_recorder.Level, _recorder.PeakLevel * 0.65f);
        if (level >= Math.Max(0.02, s.AutoStopLevelThreshold))
        {
            _heardSpeech = true;
            _lastSpeech = now;
        }
        if (!s.AutoStopAfterSilence || _heldSlot != null && _host.Hotkeys.IsSlotDown(_heldSlot.Value)) return;
        var elapsed = (now - _recordingStarted).TotalSeconds;
        if (_heardSpeech && elapsed >= Math.Max(0.3, s.AutoStopMinimumRecordingSeconds)
                         && (now - _lastSpeech).TotalSeconds >= Math.Max(0.6, s.AutoStopSilenceSeconds))
        {
            Log.Info("Auto-stop after silence");
            _ = StopAndTranscribeAsync();
        }
        else if (!_heardSpeech && elapsed >= Math.Max(2.0, s.AutoStopInitialSilenceSeconds))
        {
            Log.Info("Auto-stop: no speech");
            _ = StopAndTranscribeAsync();
        }
    }

    public async Task StopAndTranscribeAsync([System.Runtime.CompilerServices.CallerMemberName] string reason = "")
    {
        if (State is not (RecorderState.Recording or RecorderState.Starting)) return;
        Log.Info($"Stopping recording ({reason}, {_recorder.DurationSeconds:F1}s)");
        var token = _runToken;
        _monitor.Stop();
        _watchdog.Stop();
        _heldSlot = null;
        SetState(RecorderState.Transcribing);
        var samples = await StopRecorderAsync();
        _ = _mute.UnmuteAsync();

        if (samples.Length == 0 || AudioUtil.Peak(samples) < 0.0001f)
        {
            _host.Ui.Toast(Loc.T("Recording produced no audio — the microphone may have dropped"), ToastKind.Error, TimeSpan.FromSeconds(5));
            await HideAsync();
            return;
        }
        var session = _session;
        if (session == null)
        {
            // The recording ended before the session was built (very short press).
            var model = ResolveModelForStart();
            if (model == null) { await HideAsync(); return; }
            BuildSession(model, null, IntPtr.Zero, null);
            session = _session!;
        }
        session = session with
        {
            OutputMode = OutputOverride ?? session.OutputMode,
            Overrides = PromptOverride != null ? session.Overrides with { PromptId = PromptOverride } : session.Overrides,
        };

        var path = Path.Combine(AppPaths.Recordings, $"{Guid.NewGuid()}.wav");
        await Task.Run(() => AudioUtil.WriteWav16k(path, samples));
        _runCancellation = new CancellationTokenSource();
        PipelineResult? result;
        try
        {
            result = await Task.Run(() => _host.Pipeline.RunAsync(path, samples, session, _runCancellation.Token));
        }
        catch (Exception ex)
        {
            Log.Error("Pipeline crashed", ex);
            _host.Ui.Toast(Loc.T("Transcription failed") + ": " + ex.Message, ToastKind.Error);
            result = null;
        }
        if (token != _runToken || _cancelRequested)
        {
            await HideAsync();
            return;
        }
        if (result?.TextToPaste is { } text)
        {
            var toPaste = _host.Settings.AppendTrailingSpace ? text + " " : text;
            await HideOverlayOnly();
            await _paster.PasteAsync(toPaste);
            _sounds.PlayStop();
            _ = Pasted?.Invoke(result.Record);
            if (result.RefineRequest != null) _ = RefineInPlaceAsync(result, session, toPaste);
            if (session.AutoSend != AutoSendKey.None) await Paster.AutoSendAsync(session.AutoSend);
        }
        await HideAsync();
    }

    public Func<TranscriptionRecord, Task>? Pasted { get; set; }

    /// <summary>Stops the microphone off the UI thread; a hung driver costs at most 3 s, keeping what was captured.</summary>
    private async Task<float[]> StopRecorderAsync()
    {
        var stopping = Task.Run(_recorder.Stop);
        if (await Task.WhenAny(stopping, Task.Delay(TimeSpan.FromSeconds(3))) == stopping) return await stopping;
        Log.Warn("Microphone did not stop in time; using the audio captured so far");
        return _recorder.Snapshot();
    }

    private async Task RefineInPlaceAsync(PipelineResult result, DictationSession session, string pasted)
    {
        _refineCancellation = new CancellationTokenSource();
        var ct = _refineCancellation.Token;
        var anchor = await RefineAnchor.CaptureAsync(pasted);
        var refined = await Task.Run(() => _host.Pipeline.RefineAsync(result.Record, result.RefineRequest!, session.Cleanup, ct));
        if (ct.IsCancellationRequested || refined == null || refined.Trim() == result.TextToPaste?.Trim()) return;
        var replaced = anchor != null && await anchor.TryReplaceAsync(refined);
        Log.Info(replaced ? "Refined text written in place" : "Refined text kept in History");
        if (!replaced)
            _host.Ui.Toast(Loc.T("Zerm kept the original text. The refined version is saved in History."), ToastKind.Info, TimeSpan.FromSeconds(6),
                new ToastAction(Loc.T("Copy Refined Text"), () => ClipboardService.SetText(refined)));
    }

    public async Task CancelAsync()
    {
        if (!RecorderVisible) return;
        _cancelRequested = true;
        _sounds.PlayEscape();
        _runCancellation?.Cancel();
        _monitor.Stop();
        _watchdog.Stop();
        _heldSlot = null;
        if (State is RecorderState.Recording or RecorderState.Starting)
        {
            var samples = await StopRecorderAsync();
            _ = _mute.UnmuteAsync();
            if (samples.Length > AudioUtil.SampleRate / 2 && AudioUtil.Peak(samples) > 0.01f)
            {
                var path = Path.Combine(AppPaths.Recordings, $"{Guid.NewGuid()}.wav");
                await Task.Run(() => AudioUtil.WriteWav16k(path, samples));
                _host.History.Upsert(new TranscriptionRecord
                {
                    Text = Loc.T("Recording saved — transcription was cancelled. Retry from History."),
                    AudioFilePath = path,
                    Duration = AudioUtil.DurationSeconds(samples.Length),
                    Status = TranscriptionStatus.Failed,
                });
            }
        }
        _runToken = Guid.NewGuid();
        await HideAsync();
    }

    private Task HideOverlayOnly()
    {
        Views.RecorderOverlay.HideRecorder();
        return Task.Delay(30);
    }

    private async Task HideAsync()
    {
        _monitor.Stop();
        _watchdog.Stop();
        _heldSlot = null;
        if (State is RecorderState.Recording or RecorderState.Starting)
        {
            await StopRecorderAsync();
            await _mute.UnmuteAsync();
        }
        _session = null;
        ActivePowerMode = null;
        PowerModeOverride = null;
        RecorderVisible = false;
        _host.Hotkeys.RecorderVisible = false;
        foreach (var k in _handsFree.Keys.ToList()) _handsFree[k] = false;
        Views.RecorderOverlay.HideRecorder();
        SetState(RecorderState.Idle);
    }

    // MARK: - Escape and recorder shortcuts

    private void OnEscape()
    {
        if (_host.ReadAloud.IsActive)
        {
            _host.ReadAloud.Stop();
            return;
        }
        if (!RecorderVisible) return;
        var now = DateTime.Now;
        if (_firstEscape is { } first && now - first <= TimeSpan.FromSeconds(1.5))
        {
            _firstEscape = null;
            _ = CancelAsync();
            return;
        }
        _firstEscape = now;
        _sounds.PlayEscape();
        if (!_escapeHintShown)
        {
            _escapeHintShown = true;
            _host.Ui.Toast(Loc.T("Press ESC again to cancel recording"), ToastKind.Info, TimeSpan.FromSeconds(1.5));
        }
    }

    private void OnShortcut(ShortcutAction action)
    {
        switch (action)
        {
            case ShortcutAction.Cancel:
                if (_host.ReadAloud.IsActive) _host.ReadAloud.Stop();
                else _ = CancelAsync();
                break;
            case ShortcutAction.PasteLast:
                _ = PasteLastAsync(false);
                break;
            case ShortcutAction.PasteLastEnhanced:
                _ = PasteLastAsync(true);
                break;
            case ShortcutAction.RetryLast:
                _ = RetryLastAsync();
                break;
        }
    }

    public async Task PasteLastAsync(bool enhanced)
    {
        var last = _host.History.Latest();
        if (last == null)
        {
            _host.Ui.Toast(Loc.T("No transcription to paste yet"), ToastKind.Info);
            return;
        }
        await Task.Delay(150);
        await _paster.PasteAsync(enhanced ? last.DisplayText : last.Text);
    }

    /// <summary>Re-transcribes the last recording with the current model; the result is copied, not pasted.</summary>
    public async Task RetryLastAsync(TranscriptionRecord? record = null)
    {
        record ??= _host.History.LatestWithAudio();
        if (record?.AudioFilePath == null || !File.Exists(record.AudioFilePath))
        {
            _host.Ui.Toast(Loc.T("No recording to retry"), ToastKind.Info);
            return;
        }
        var model = _host.CurrentModel;
        if (!_host.IsUsable(model))
        {
            _host.Ui.Toast(Loc.T("No transcription model is ready. Download a model or add an API key first."), ToastKind.Error);
            return;
        }
        _host.Ui.Toast(Loc.T("Retrying transcription…"), ToastKind.Info);
        var samples = await Task.Run(() => AudioUtil.LoadAs16kMono(record.AudioFilePath));
        var session = new DictationSession(model!, _host.Settings.SelectedLanguage, DictationPipeline.CleanupOptions(_host.Settings, _host.Library, null),
            _host.Settings.OutputMode == DictationOutputMode.Instant ? DictationOutputMode.Instant : DictationOutputMode.Enhanced,
            new EnhancementOverrides(), null, null, null, AutoSendKey.None);
        var result = await Task.Run(() => _host.Pipeline.RunAsync(record.AudioFilePath, samples, session, CancellationToken.None));
        SetState(RecorderState.Idle);
        if (result?.TextToPaste is { } text)
        {
            ClipboardService.SetText(text);
            _host.Ui.Toast(Loc.T("Transcription copied to the clipboard"), ToastKind.Success);
        }
    }

    public void ToggleEnhancementForThisRecording()
    {
        if (!RecorderVisible) return;
        var current = OutputOverride ?? _session?.OutputMode ?? _host.Settings.OutputMode;
        if (current == DictationOutputMode.Instant)
        {
            var last = _host.Settings.LastEnhancingOutputMode;
            OutputOverride = last == DictationOutputMode.Instant ? DictationOutputMode.InstantRefine : last;
        }
        else
        {
            _host.Settings.LastEnhancingOutputMode = current;
            OutputOverride = DictationOutputMode.Instant;
        }
        _host.Ui.Toast(OutputOverride == DictationOutputMode.Instant ? Loc.T("AI enhancement off for this recording") : Loc.T("AI enhancement on for this recording"),
            ToastKind.Info, TimeSpan.FromSeconds(1.5));
        Changed?.Invoke();
    }

    public DictationOutputMode EffectiveOutputMode => OutputOverride ?? _session?.OutputMode ?? _host.Settings.OutputMode;
    public Guid EffectivePromptId => PromptOverride ?? _session?.Overrides.PromptId ?? _host.Settings.SelectedPromptId;

    public void SelectPrompt(int number)
    {
        var prompt = _host.Library.Prompts.ElementAtOrDefault(number - 1);
        if (prompt == null) return;
        SelectPrompt(prompt.Id);
    }

    public void SelectPrompt(Guid id)
    {
        PromptOverride = id;
        if (EffectiveOutputMode == DictationOutputMode.Instant)
            OutputOverride = _host.Settings.LastEnhancingOutputMode == DictationOutputMode.Instant ? DictationOutputMode.InstantRefine : _host.Settings.LastEnhancingOutputMode;
        var title = _host.Library.Prompts.FirstOrDefault(p => p.Id == id)?.Title ?? "";
        _host.Ui.Toast(Loc.F("Prompt: {0}", Loc.T(title)), ToastKind.Info, TimeSpan.FromSeconds(1.5));
        Changed?.Invoke();
    }

    public void SelectPowerMode(int number)
    {
        var mode = _host.Library.PowerModes.Where(m => m.IsEnabled).ElementAtOrDefault(number - 1);
        if (mode != null) SelectPowerMode(mode);
    }

    /// <summary>A Power Mode picked in the recorder changes only the enhancement side (prompt and output).</summary>
    public void SelectPowerMode(PowerModeConfig mode)
    {
        ActivePowerMode = mode;
        if (_session != null)
            _session = _session with
            {
                OutputMode = mode.OutputMode ?? _host.Settings.OutputMode,
                Overrides = new EnhancementOverrides(mode.SelectedPrompt, mode.SelectedAIProvider, mode.SelectedAIProvider == null ? null : mode.SelectedAIModel),
                PowerMode = mode,
                AutoSend = mode.AutoSendKey,
            };
        _host.Ui.Toast($"{mode.Emoji} {mode.Name}", ToastKind.Info, TimeSpan.FromSeconds(1.5));
        Changed?.Invoke();
    }

    /// <summary>Recovers from a stuck state after 3 minutes (stuck-state watchdog).</summary>
    private void StuckStateCheck()
    {
        if (State is RecorderState.Transcribing or RecorderState.Enhancing or RecorderState.Busy or RecorderState.Starting
            && DateTime.Now - _stateSince > TimeSpan.FromMinutes(3))
        {
            Log.Warn($"Stuck in {State}; recovering");
            _runCancellation?.Cancel();
            _runToken = Guid.NewGuid();
            _ = HideAsync();
            _host.Ui.Toast(Loc.T("Zerm recovered from a stuck state — try again"), ToastKind.Warning, TimeSpan.FromSeconds(4));
        }
    }

    public static void OpenUri(string uri)
    {
        try { System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(uri) { UseShellExecute = true }); }
        catch (Exception ex) { Log.Warn($"Could not open {uri}: {ex.Message}"); }
    }
}
