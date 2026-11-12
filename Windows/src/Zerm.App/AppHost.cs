using System.Windows;
using System.Windows.Threading;
using Zerm.App.Platform;
using Zerm.Core;
using Zerm.Core.Data;
using Zerm.Core.Dictation;
using Zerm.Core.Enhancement;
using Zerm.Core.FileTranscription;
using Zerm.Core.LocalLlm;
using Zerm.Core.Models;
using Zerm.Core.Settings;
using Zerm.Core.TextToSpeech;
using Zerm.Core.Transcription;

namespace Zerm.App;

/// <summary>Owns every long-lived service; created once at startup.</summary>
public sealed class AppHost : IDisposable
{
    public static AppHost Current { get; private set; } = null!;

    public AppSettings Settings { get; }
    public Library Library { get; }
    public HistoryStore History { get; }
    public SecretStore Secrets { get; }
    public LocalLlmEngine LocalLlm { get; } = new();
    public TranscriptionService Transcription { get; }
    public EnhancementService Enhancement { get; }
    public FileTranscriptionService FileTranscription { get; }
    public ModelDownloads Downloads { get; } = new();
    public HotkeyService Hotkeys { get; }
    public UiHost Ui { get; }
    public DictationPipeline Pipeline { get; }
    public DictationController Dictation { get; }
    public ReadAloudController ReadAloud { get; }
    public Dispatcher Dispatcher { get; }

    public event Action<string>? NavigationRequested;

    public AppHost(Dispatcher dispatcher)
    {
        Current = this;
        Dispatcher = dispatcher;
        Settings = AppSettings.Load();
        Log.DebugEnabled = Settings.DebugLoggingEnabled;
        Library = Library.Load();
        History = new HistoryStore();
        Secrets = new SecretStore();
        Transcription = new TranscriptionService(Settings, Secrets);
        Enhancement = new EnhancementService(Settings, Library, Secrets, LocalLlm);
        FileTranscription = new FileTranscriptionService(Settings, Library, History, Transcription)
        {
            Dispatch = a => dispatcher.BeginInvoke(a),
        };
        Hotkeys = new HotkeyService(Settings, dispatcher)
        {
            PowerModeHotkeys = () => Library.PowerModes.Where(m => m.IsEnabled && m.Hotkey is { IsEmpty: false }).Select(m => (m.Id, m.Hotkey!)),
        };
        Ui = new UiHost(this);
        Pipeline = new DictationPipeline(Settings, Library, History, Transcription, Enhancement, Ui);
        Dictation = new DictationController(this);
        ReadAloud = new ReadAloudController(this);
        Settings.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName == nameof(AppSettings.DebugLoggingEnabled)) Log.DebugEnabled = Settings.DebugLoggingEnabled;
            if (e.PropertyName == nameof(AppSettings.CurrentTranscriptionModel)) _ = PrewarmAsync();
        };
    }

    public TranscriptionModel? CurrentModel =>
        TranscriptionModelRegistry.Find(TranscriptionModelRegistry.MigrateName(Settings.CurrentTranscriptionModel), Library.CustomTranscriptionModels);

    /// <summary>Usable = downloaded (local) or has an API key (cloud).</summary>
    public bool IsUsable(TranscriptionModel? model) => model != null && (model.IsLocal
        ? model.IsDownloaded
        : model.Provider == ModelProvider.Custom || !string.IsNullOrWhiteSpace(Transcription.ApiKeyFor(model, Library.CustomModels)));

    /// <summary>Warms the on-device LLM when enhancement or AI reading will use it.</summary>
    public async Task PrewarmLlmAsync()
    {
        try
        {
            var uses = (Settings.OutputMode != DictationOutputMode.Instant && Settings.SelectedAIProvider == AIProviders.OnDevice)
                       || Library.PowerModes.Any(m => m.IsEnabled && m.SelectedAIProvider == AIProviders.OnDevice);
            var package = Settings.SuperEnhancement && Settings.OutputMode != DictationOutputMode.Instant
                ? LocalLlmCatalog.ResolveForSuper(Settings.SuperEnhancementModel)
                : uses ? LocalLlmCatalog.ResolveForEnhancement(Settings.ModelFor(AIProviders.OnDevice)) : null;
            if (package == null && Settings.TtsReadingMode != ReadAloudMode.Exact) package = LocalLlmCatalog.ResolveForReading(Settings.ModelFor("Reading"));
            if (package != null) await Task.Run(() => LocalLlm.WarmUpAsync(LocalLlmCatalog.PathFor(package)));
        }
        catch (Exception ex)
        {
            Log.Error("LLM warm-up failed", ex);
        }
    }

    public async Task PrewarmAsync()
    {
        var model = CurrentModel;
        if (model == null || !model.IsLocal || !model.IsDownloaded) return;
        try
        {
            await Task.Run(() => Transcription.PrewarmAsync(model));
        }
        catch (Exception ex)
        {
            Log.Error("Model prewarm failed", ex);
            Ui.Toast(Localization.Loc.F("Could not load {0}: {1}", model.DisplayName, ex.Message), ToastKind.Error);
        }
    }

    public void Navigate(string page) => NavigationRequested?.Invoke(page);

    public void Dispose()
    {
        Hotkeys.Dispose();
        ReadAloud.Dispose();
        Transcription.Dispose();
        LocalLlm.Dispose();
        History.Dispose();
        Settings.SaveNow();
    }
}

/// <summary>Bridges the pipeline's state/toast callbacks to the recorder overlay and toast window.</summary>
public sealed class UiHost(AppHost host) : IDictationHost
{
    public event Action<RecorderState>? StateChanged;
    public RecorderState State { get; private set; } = RecorderState.Idle;

    public void SetState(RecorderState state) => host.Dispatcher.BeginInvoke(() =>
    {
        State = state;
        StateChanged?.Invoke(state);
    });

    public void Toast(string message, ToastKind kind, TimeSpan? duration = null, ToastAction? action = null) =>
        host.Dispatcher.BeginInvoke(() => Views.ToastWindow.Show(message, kind, duration ?? TimeSpan.FromSeconds(kind == ToastKind.Error ? 5 : 3), action));
}

/// <summary>Shared download state so progress survives page navigation.</summary>
public sealed class ModelDownloads
{
    public sealed class Item : CommunityToolkit.Mvvm.ComponentModel.ObservableObject
    {
        private double _progress;
        private string _status = "";
        public double Progress { get => _progress; set => SetProperty(ref _progress, value); }
        public string Status { get => _status; set => SetProperty(ref _status, value); }
        public CancellationTokenSource Cancellation { get; } = new();
        public Task? Task { get; set; }
    }

    private readonly Dictionary<string, Item> _active = new();
    public event Action? Changed;

    public Item? Get(string key) => _active.GetValueOrDefault(key);

    /// <summary>Runs one or more downloads under a key; progress is the combined fraction.</summary>
    public Item Start(string key, IReadOnlyList<DownloadSpec> specs, Action? completed = null)
    {
        if (_active.TryGetValue(key, out var existing)) return existing;
        var item = new Item();
        _active[key] = item;
        var dispatcher = Application.Current.Dispatcher;
        var total = specs.Sum(s => s.ApproximateSize);
        item.Task = Task.Run(async () =>
        {
            long done = 0;
            try
            {
                foreach (var spec in specs)
                {
                    var progress = new Progress<DownloadProgress>(p => dispatcher.BeginInvoke(() =>
                    {
                        item.Progress = total > 0 ? Math.Clamp((done + p.Received) / (double)total, 0, 1) : p.Fraction;
                        item.Status = p.BytesPerSecond > 0
                            ? $"{Format(done + p.Received)} / {Format(total)} · {Format((long)p.BytesPerSecond)}/s"
                            : $"{Format(done + p.Received)} / {Format(total)}";
                    }));
                    await ModelDownloader.DownloadAsync(spec, progress, item.Cancellation.Token);
                    done += spec.ApproximateSize;
                }
                dispatcher.Invoke(() =>
                {
                    item.Progress = 1;
                    item.Status = "";
                    completed?.Invoke();
                });
            }
            catch (OperationCanceledException)
            {
                dispatcher.Invoke(() => item.Status = Localization.Loc.T("Paused"));
            }
            catch (Exception ex)
            {
                Log.Error($"Download {key} failed", ex);
                dispatcher.Invoke(() =>
                {
                    item.Status = Localization.Loc.T("Download failed") + ": " + ex.Message;
                    AppHost.Current.Ui.Toast(Localization.Loc.T("Download failed") + ": " + ex.Message, ToastKind.Error);
                });
            }
            finally
            {
                dispatcher.Invoke(() =>
                {
                    _active.Remove(key);
                    Changed?.Invoke();
                });
            }
        });
        Changed?.Invoke();
        return item;
    }

    public void Cancel(string key) => _active.GetValueOrDefault(key)?.Cancellation.Cancel();

    public static string Format(long bytes) => bytes switch
    {
        >= 1L << 30 => $"{bytes / (double)(1L << 30):F2} GB",
        >= 1L << 20 => $"{bytes / (double)(1L << 20):F0} MB",
        >= 1L << 10 => $"{bytes / (double)(1L << 10):F0} KB",
        _ => $"{bytes} B",
    };
}
