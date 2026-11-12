using System.Diagnostics;
using System.Globalization;
using System.Text;
using Zerm.Core.Audio;
using Zerm.Core.Models;
using Zerm.Core.Prompts;
using Zerm.Core.Settings;

namespace Zerm.Core.Transcription;

public sealed class TranscriptionTimeoutException() : Exception("Transcription timed out after 120 seconds. The audio was kept — retry from History.");

public sealed class MissingApiKeyException(string provider) : Exception($"Add an API key for {provider} in Models to use this model.")
{
    public string Provider { get; } = provider;
}

public sealed class ModelNotDownloadedException(string model) : Exception($"{model} is not downloaded yet. Download it in Models.");

/// <summary>Vocabulary used to bias transcription (VocabularyTerms.swift).</summary>
public static class VocabularyTerms
{
    public static List<string> TranscriptionTerms(IEnumerable<string> userWords, Guid? promptId)
    {
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var words = userWords.Select(w => w.Trim()).Where(w => w.Length > 0 && seen.Add(w))
            .OrderBy(w => w, StringComparer.CurrentCultureIgnoreCase).Take(100).ToList();
        if (TechnicalTerminology.IsCodingPrompt(promptId)) words.AddRange(TechnicalTerminology.CanonicalTerms);
        var folded = new HashSet<string>();
        return words.Where(w => folded.Add(Fold(w))).Take(100).ToList();
    }

    private static string Fold(string s)
    {
        var normalized = s.ToLowerInvariant().Normalize(NormalizationForm.FormD);
        return new string(normalized.Where(c => CharUnicodeInfo.GetUnicodeCategory(c) != UnicodeCategory.NonSpacingMark).ToArray());
    }

    /// <summary>" Vocabulary: t1, t2, …." — at most 80 terms and 400 characters.</summary>
    public static string WhisperSuffix(IReadOnlyList<string> terms)
    {
        if (terms.Count == 0) return "";
        var sb = new StringBuilder(" Vocabulary: ");
        var first = true;
        foreach (var t in terms.Take(80))
        {
            var piece = (first ? "" : ", ") + t;
            if (sb.Length + piece.Length + 1 > 400) break;
            sb.Append(piece);
            first = false;
        }
        return first ? "" : sb.Append('.').ToString();
    }
}

public sealed record TranscriptionResult(string Text, IReadOnlyList<TranscriptSegment> Segments, TimeSpan Elapsed, string ModelName);

/// <summary>Runs a transcription on whichever engine the model needs; keeps one local engine warm.</summary>
public sealed class TranscriptionService(AppSettings settings, SecretStore secrets) : IDisposable
{
    private readonly SemaphoreSlim _engineGate = new(1, 1);
    private ILocalTranscriber? _engine;
    private string? _engineModel;

    public static readonly TimeSpan Timeout = TimeSpan.FromSeconds(120);

    public string? LoadedModel => _engineModel;

    public string StylePrompt(string? language)
    {
        var code = string.IsNullOrEmpty(language) ? "auto" : language;
        if (settings.CustomLanguagePrompts.TryGetValue(code, out var custom) && !string.IsNullOrWhiteSpace(custom)) return custom;
        return code == "auto" ? "" : Languages.WhisperStylePrompts.GetValueOrDefault(code, "");
    }

    public async Task<ILocalTranscriber> GetEngineAsync(TranscriptionModel model, CancellationToken ct = default)
    {
        await _engineGate.WaitAsync(ct);
        try
        {
            if (_engine != null && _engineModel == model.Name) return _engine;
            if (!model.IsDownloaded) throw new ModelNotDownloadedException(model.DisplayName);
            _engine?.Dispose();
            _engine = null;
            _engineModel = null;
            var sw = Stopwatch.StartNew();
            _engine = await Task.Run(() => model.Provider == ModelProvider.Whisper
                ? (ILocalTranscriber)new WhisperTranscriber(model.LocalPath)
                : new SherpaTranscriber(model), ct);
            _engineModel = model.Name;
            Log.Info($"Loaded {model.Name} in {sw.ElapsedMilliseconds} ms");
            return _engine;
        }
        finally
        {
            _engineGate.Release();
        }
    }

    /// <summary>Loads the model and runs one silent inference so the first dictation is fast.</summary>
    public async Task PrewarmAsync(TranscriptionModel model, CancellationToken ct = default)
    {
        if (!model.IsLocal || !model.IsDownloaded) return;
        var engine = await GetEngineAsync(model, ct);
        var sw = Stopwatch.StartNew();
        if (engine is WhisperTranscriber w) await w.WarmUpAsync(ct);
        Log.Info($"Warm-up of {model.Name} took {sw.ElapsedMilliseconds} ms ({WhisperTranscriber.LoadedRuntime})");
    }

    public void Unload()
    {
        _engineGate.Wait();
        try
        {
            _engine?.Dispose();
            _engine = null;
            _engineModel = null;
        }
        finally { _engineGate.Release(); }
    }

    public string? ApiKeyFor(TranscriptionModel model, IEnumerable<Data.CustomCloudModel> customModels)
    {
        if (model.Provider == ModelProvider.Custom)
        {
            var custom = customModels.FirstOrDefault(c => c.ToModel().Name == model.Name);
            return custom == null ? null : secrets.Get(custom.ApiKeyId);
        }
        return secrets.ApiKey(model.ProviderKey);
    }

    public async Task<TranscriptionResult> TranscribeAsync(
        TranscriptionModel model,
        string audioPath,
        float[]? samples,
        string? selectedLanguage,
        IReadOnlyList<string> vocabulary,
        IEnumerable<Data.CustomCloudModel> customModels,
        CancellationToken ct,
        TimeSpan? timeout = null,
        bool? useVad = null)
    {
        using var cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
        if (timeout != System.Threading.Timeout.InfiniteTimeSpan) cts.CancelAfter(timeout ?? Timeout);
        var sw = Stopwatch.StartNew();
        try
        {
            if (model.IsLocal)
            {
                samples ??= AudioUtil.LoadAs16kMono(audioPath);
                var engine = await GetEngineAsync(model, cts.Token);
                var language = model.TranscriptionLanguage(selectedLanguage);
                var prompt = model.Provider == ModelProvider.Whisper
                    ? (StylePrompt(language) + VocabularyTerms.WhisperSuffix(vocabulary)).Trim()
                    : null;
                var vad = useVad ?? settings.VadEnabled;
                var segments = await engine.TranscribeAsync(samples, new TranscriptionOptions(language, prompt, vad), cts.Token);
                var text = Join(segments);
                // Whisper returns nothing when VAD misjudges quiet speech; retry once without it.
                if (text.Length == 0 && vad && AudioUtil.DurationSeconds(samples.Length) >= 0.6 && AudioUtil.Peak(samples) > 0.01f)
                {
                    Log.Info("Empty result with VAD; retrying without VAD");
                    segments = await engine.TranscribeAsync(samples, new TranscriptionOptions(language, prompt, false), cts.Token);
                    text = Join(segments);
                }
                return new TranscriptionResult(text, segments, sw.Elapsed, model.Name);
            }

            var key = ApiKeyFor(model, customModels);
            if (string.IsNullOrWhiteSpace(key) && model.Provider != ModelProvider.Custom) throw new MissingApiKeyException(model.ProviderKey);
            var duration = samples != null ? AudioUtil.DurationSeconds(samples.Length) : 0;
            var lang = model.Capabilities.HasFlag(ModelCapabilities.LanguageHint) ? model.RequestLanguage(selectedLanguage) : null;
            var request = new CloudRequest(
                model, audioPath, duration, lang,
                model.Capabilities.HasFlag(ModelCapabilities.Prompt) ? StylePrompt(lang) : null,
                model.Capabilities.HasFlag(ModelCapabilities.Vocabulary) ? vocabulary : [],
                key ?? "",
                CloudTranscription.EffectiveTimeout(settings.CloudTranscriptionTimeoutSeconds, duration));
            string cloudText;
            try
            {
                cloudText = await CloudTranscription.TranscribeAsync(request, cts.Token);
            }
            catch (NoTranscriptionReturnedException)
            {
                cloudText = "";
            }
            return new TranscriptionResult(cloudText, [new TranscriptSegment(0, duration, cloudText)], sw.Elapsed, model.Name);
        }
        catch (OperationCanceledException) when (!ct.IsCancellationRequested)
        {
            throw new TranscriptionTimeoutException();
        }
    }

    public static string Join(IEnumerable<TranscriptSegment> segments) =>
        string.Join(" ", segments.Select(s => s.Text.Trim()).Where(t => t.Length > 0)).Trim();

    public void Dispose() => _engine?.Dispose();
}
