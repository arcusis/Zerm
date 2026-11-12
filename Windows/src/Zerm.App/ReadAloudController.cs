using System.Diagnostics;
using Zerm.App.Localization;
using Zerm.App.Platform;
using Zerm.Core;
using Zerm.Core.Data;
using Zerm.Core.Dictation;
using Zerm.Core.LocalLlm;
using Zerm.Core.Settings;
using Zerm.Core.Text;
using Zerm.Core.TextToSpeech;

namespace Zerm.App;

/// <summary>Port of TTSController.swift.</summary>
public sealed class ReadAloudController : IDisposable
{
    private readonly AppHost _host;
    private readonly SpeechPlayer _player = new();
    private readonly WindowsVoicesProvider _windows = new();
    private readonly KokoroProvider _kokoro = new();
    private readonly Dictionary<string, CloudTtsProvider> _cloud = new();
    private CancellationTokenSource? _cts;
    private int _generation;

    public bool IsActive { get; private set; }
    public float Level => _player.Level;
    public string? LastPrepared { get; private set; }
    public event Action? Changed;

    public ReadAloudController(AppHost host) => _host = host;

    public ITtsProvider Provider(string name) => name switch
    {
        "Windows" => _windows,
        "Kokoro" => _kokoro,
        _ => _cloud.TryGetValue(name, out var p) ? p : _cloud[name] = new CloudTtsProvider(name, () => _host.Secrets.ApiKey(name)),
    };

    public string VoiceFor(ITtsProvider provider)
    {
        var saved = _host.Settings.TtsVoiceFor(provider.Name);
        var voices = provider.Voices;
        return saved != null && voices.Any(v => v.Id == saved) ? saved : voices.FirstOrDefault()?.Id ?? "";
    }

    public async Task ToggleAsync()
    {
        if (!_host.Settings.TtsEnabled) return;
        if (IsActive)
        {
            Stop();
            return;
        }
        if (_host.Dictation.RecorderVisible)
        {
            _host.Ui.Toast(Loc.T("Finish or cancel dictation before using Read Aloud"), ToastKind.Info);
            return;
        }
        var generation = ++_generation;
        Begin(RecorderState.PreparingSpeech);
        var text = await SelectedTextService.GetSelectedTextAsync();
        if (generation != _generation) return;
        if (string.IsNullOrWhiteSpace(text))
        {
            Native.MessageBeep(0);
            _host.Ui.Toast(Loc.T("No text selected"), ToastKind.Info);
            End();
            return;
        }
        await SpeakAsync(text, generation);
    }

    public async Task SpeakTextAsync(string text)
    {
        if (IsActive) Stop();
        var generation = ++_generation;
        Begin(RecorderState.PreparingSpeech);
        await SpeakAsync(text, generation);
    }

    private void Begin(RecorderState state)
    {
        IsActive = true;
        _cts = new CancellationTokenSource();
        _host.Hotkeys.RecorderVisible = true;
        Views.RecorderOverlay.ShowRecorder();
        _host.Ui.SetState(state);
        Changed?.Invoke();
    }

    private async Task SpeakAsync(string raw, int generation)
    {
        var ct = _cts!.Token;
        var s = _host.Settings;
        var provider = Provider(s.TtsProvider);
        if (provider.RequiresApiKey && string.IsNullOrWhiteSpace(_host.Secrets.ApiKey(provider.Name)))
        {
            _host.Ui.Toast(Loc.F("Add an API key for {0} in Read Aloud settings", provider.Name), ToastKind.Warning);
            End();
            return;
        }
        if (provider is KokoroProvider && !KokoroProvider.IsDownloaded)
        {
            provider = _windows;
            _host.Ui.Toast(Loc.T("Kokoro is not downloaded — reading with a Windows voice"), ToastKind.Info);
        }
        var voice = VoiceFor(provider);

        var mode = s.TtsReadingMode;
        var trimmed = raw.Trim();
        string prepared;
        if (mode != ReadAloudMode.Exact && LocalLlmCatalog.ResolveForReading(s.ModelFor("Reading")) is { } pkg)
        {
            _host.Ui.SetState(RecorderState.GeneratingSpeech);
            try
            {
                var naturalizer = new TtsNaturalizer(_host.LocalLlm, () => LocalLlmCatalog.PathFor(pkg));
                prepared = await Task.Run(() => naturalizer.TransformAsync(trimmed, mode, ct), ct);
            }
            catch (OperationCanceledException) { return; }
            catch (Exception ex)
            {
                Log.Warn($"Read Aloud rewrite failed: {ex.Message}");
                _host.Ui.Toast(Loc.T("AI rewrite unavailable — reading the selection exactly"), ToastKind.Info);
                prepared = Exact(trimmed);
            }
        }
        else
        {
            if (mode != ReadAloudMode.Exact)
                _host.Ui.Toast(Loc.T("No on-device model downloaded — reading the selection exactly"), ToastKind.Info);
            prepared = Exact(trimmed);
        }
        if (generation != _generation) return;

        // Language routing: an English-only voice can't read Hebrew (TTSLanguageRouter.swift).
        if (!provider.IsMultilingual && TtsNaturalizer.IsPredominantlyHebrew(prepared))
        {
            var hebrewVoice = _windows.Voices.FirstOrDefault(v => v.Language == "he");
            if (hebrewVoice != null)
            {
                _host.Ui.Toast(Loc.F("{0} speaks English only — reading with {1}", provider.Name, hebrewVoice.Name), ToastKind.Info);
                provider = _windows;
                voice = hebrewVoice.Id;
            }
            else
            {
                _host.Ui.Toast(Loc.T("No Hebrew voice is installed. Add one in Windows Settings › Time & language › Speech."), ToastKind.Warning, TimeSpan.FromSeconds(6));
                End();
                return;
            }
        }
        else if (provider is WindowsVoicesProvider && TtsNaturalizer.IsPredominantlyHebrew(prepared)
                 && _windows.Voices.FirstOrDefault(v => v.Id == voice)?.Language != "he"
                 && _windows.Voices.FirstOrDefault(v => v.Language == "he") is { } he)
        {
            voice = he.Id;
        }

        LastPrepared = prepared;
        Changed?.Invoke();
        var sw = Stopwatch.StartNew();
        try
        {
            _player.Begin();
            var first = true;
            foreach (var chunk in TtsTextNormalizer.SentenceChunks(prepared))
            {
                ct.ThrowIfCancellationRequested();
                var audio = await Task.Run(() => provider.SynthesizeAsync(chunk, voice, s.TtsSpeed, ct), ct);
                if (generation != _generation) return;
                _player.Enqueue(audio);
                if (first)
                {
                    first = false;
                    Log.Info($"Read Aloud first audio after {sw.ElapsedMilliseconds} ms ({provider.Name})");
                    _host.Ui.SetState(RecorderState.Speaking);
                }
            }
            _player.FinishQueueing();
            await _player.Completion;
            if (generation != _generation) return;
            var words = DictationTextProcessing.WordCount(prepared);
            _host.History.RecordUsage(DateTime.Now, readAloudWords: words, readAloudSessions: 1);
            _host.History.AddReadAloud(new ReadAloudEntry
            {
                Mode = mode.ToString(),
                SourceText = trimmed,
                SpokenText = prepared,
                Provider = provider.Name,
                Voice = provider.Voices.FirstOrDefault(v => v.Id == voice)?.Name ?? voice,
                Model = mode == ReadAloudMode.Exact ? null : LocalLlmCatalog.ResolveForReading(s.ModelFor("Reading"))?.DisplayName,
            });
        }
        catch (OperationCanceledException) { }
        catch (Exception ex)
        {
            Log.Error("Read Aloud failed", ex);
            _host.Ui.Toast(Loc.F("Read Aloud failed: {0}", ex.Message), ToastKind.Error);
        }
        finally
        {
            if (generation == _generation) End();
        }
    }

    private string Exact(string text)
    {
        if (!_host.Settings.TtsSmartCleanup) return text;
        var normalized = TtsTextNormalizer.Normalize(text);
        return normalized.Length == 0 ? text : normalized;
    }

    public void Stop()
    {
        _generation++;
        _cts?.Cancel();
        _player.Stop();
        End();
    }

    private void End()
    {
        if (!IsActive) return;
        IsActive = false;
        _player.Stop();
        if (!_host.Dictation.RecorderVisible)
        {
            _host.Hotkeys.RecorderVisible = false;
            Views.RecorderOverlay.HideRecorder();
            _host.Ui.SetState(RecorderState.Idle);
        }
        Changed?.Invoke();
    }

    /// <summary>Synthesizes a single sentence (preview / key verification).</summary>
    public async Task PreviewAsync(string providerName, string? voiceId = null)
    {
        var provider = Provider(providerName);
        await SpeakWith(provider, voiceId ?? VoiceFor(provider), Loc.T("This is how the selected voice sounds in Zerm."));
    }

    private async Task SpeakWith(ITtsProvider provider, string voice, string text)
    {
        if (IsActive) Stop();
        var generation = ++_generation;
        Begin(RecorderState.PreparingSpeech);
        try
        {
            var audio = await Task.Run(() => provider.SynthesizeAsync(text, voice, _host.Settings.TtsSpeed, _cts!.Token));
            if (generation != _generation) return;
            _player.Begin();
            _player.Enqueue(audio);
            _player.FinishQueueing();
            _host.Ui.SetState(RecorderState.Speaking);
            await _player.Completion;
        }
        catch (OperationCanceledException) { }
        catch (Exception ex)
        {
            _host.Ui.Toast(Loc.F("Read Aloud failed: {0}", ex.Message), ToastKind.Error);
        }
        finally
        {
            if (generation == _generation) End();
        }
    }

    public async Task<(bool Ok, string Message)> VerifyKeyAsync(string providerName)
    {
        try
        {
            var provider = Provider(providerName);
            var audio = await provider.SynthesizeAsync("Test.", provider.Voices[0].Id, 1.0, CancellationToken.None);
            return audio.Samples.Length > 0 ? (true, Loc.T("Key verified")) : (false, Loc.T("The provider returned no audio."));
        }
        catch (Exception ex)
        {
            return (false, ex.Message);
        }
    }

    public void Dispose()
    {
        _player.Dispose();
        _kokoro.Dispose();
    }
}
