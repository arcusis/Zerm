using System.Diagnostics;
using Zerm.Core.Audio;
using Zerm.Core.Data;
using Zerm.Core.Enhancement;
using Zerm.Core.Models;
using Zerm.Core.Settings;
using Zerm.Core.Text;
using Zerm.Core.Transcription;

namespace Zerm.Core.Dictation;

public enum RecorderState { Idle, Starting, Recording, Transcribing, Enhancing, Busy, PreparingSpeech, GeneratingSpeech, Speaking }

public enum ToastKind { Info, Success, Warning, Error }

public sealed record ToastAction(string Label, Action Run);

/// <summary>What the pipeline needs from the platform (state display and notifications).</summary>
public interface IDictationHost
{
    void SetState(RecorderState state);
    void Toast(string message, ToastKind kind, TimeSpan? duration = null, ToastAction? action = null);
}

/// <summary>Everything resolved once when recording starts (DictationSessionConfiguration.swift).</summary>
public sealed record DictationSession(
    TranscriptionModel Model,
    string? Language,
    TextCleanupOptions Cleanup,
    DictationOutputMode OutputMode,
    EnhancementOverrides Overrides,
    string? ClipboardContext,
    Task<string?>? ScreenContext,
    PowerModeConfig? PowerMode,
    AutoSendKey AutoSend);

public sealed record PipelineResult(
    TranscriptionRecord Record,
    string? TextToPaste,
    EnhancementRequest? RefineRequest);

/// <summary>
/// Port of TranscriptionPipeline.run: transcribe → deterministic cleanup → enhancement plan →
/// (Enhanced: wait for AI) → save. Pasting and Refine-in-place are done by the platform layer.
/// </summary>
public sealed class DictationPipeline(
    AppSettings settings,
    Library library,
    HistoryStore history,
    TranscriptionService transcription,
    EnhancementService enhancement,
    IDictationHost host)
{
    public static TextCleanupOptions CleanupOptions(AppSettings s, Library lib, PowerModeConfig? pm) => new(
        s.RemoveFillerWords,
        s.FillerWords,
        pm?.TextFormatting ?? s.TextFormattingEnabled,
        lib.ReplacementRules,
        pm?.PunctuationCleanup ?? s.PunctuationCleanupMode,
        pm?.Lowercase ?? s.LowercaseTranscription);

    public async Task<PipelineResult?> RunAsync(string audioPath, float[] samples, DictationSession session, CancellationToken ct)
    {
        var duration = AudioUtil.DurationSeconds(samples.Length);
        var record = new TranscriptionRecord
        {
            AudioFilePath = audioPath,
            Duration = duration,
            TranscriptionModelName = session.Model.DisplayName,
            PowerModeName = session.PowerMode?.Name,
            PowerModeEmoji = session.PowerMode?.Emoji,
            Status = TranscriptionStatus.Pending,
        };
        history.Upsert(record);

        // 1–2. Transcribe.
        host.SetState(RecorderState.Transcribing);
        TranscriptionResult result;
        var vocabulary = VocabularyTerms.TranscriptionTerms(library.Vocabulary.Select(v => v.Word),
            session.Overrides.PromptId ?? settings.SelectedPromptId);
        try
        {
            result = await transcription.TranscribeAsync(session.Model, audioPath, samples, session.Language, vocabulary, library.CustomModels, ct);
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested)
        {
            Fail(record, "Recording saved — transcription was cancelled. Retry from History.");
            return null;
        }
        catch (Exception ex)
        {
            var reason = Describe(ex);
            Log.Error("Transcription failed", ex);
            Fail(record, $"Transcription Failed: {reason}");
            host.Toast($"Transcription failed: {Net.Http.Truncate(reason, 100)}", ToastKind.Error, TimeSpan.FromSeconds(5));
            return null;
        }
        record.TranscriptionDuration = result.Elapsed.TotalSeconds;
        Log.Info($"Transcribed {duration:F1}s of audio in {result.Elapsed.TotalMilliseconds:F0} ms with {session.Model.Name}");

        // 3. Deterministic cleanup.
        var cleaned = DictationTextProcessing.Clean(result.Text, session.Cleanup);
        if (cleaned.Length == 0)
        {
            Fail(record, "No speech was detected in this recording.");
            host.Toast(duration < 0.8
                    ? "No speech detected — hold the key a bit longer before releasing."
                    : "No speech detected — try again or switch model.",
                ToastKind.Warning, TimeSpan.FromSeconds(4));
            return null;
        }
        record.Text = DictationTextProcessing.ApplyPreferences(cleaned, session.Cleanup);
        var textToPaste = record.Text;

        // 6. Enhancement plan.
        var mode = session.OutputMode;
        var overrides = session.Overrides;
        var input = cleaned;
        var triggered = false;
        if (settings.AllowPromptTriggeredEnhancement && PromptDetection.Detect(cleaned, library.Prompts) is { } detection)
        {
            triggered = true;
            input = detection.ProcessedText;
            overrides = overrides with { PromptId = detection.PromptId };
            if (mode == DictationOutputMode.Instant) mode = DictationOutputMode.Enhanced;
        }
        if (mode == DictationOutputMode.InstantRefine && session.AutoSend != AutoSendKey.None) mode = DictationOutputMode.Enhanced;

        EnhancementRequest? request = null;
        if (mode != DictationOutputMode.Instant)
        {
            if (!triggered && settings.SkipShortEnhancement && DictationTextProcessing.WordCount(input) <= settings.ShortEnhancementWordThreshold)
            {
                record.EnhancementOutcome = EnhancementOutcomeKind.Skipped.ToString();
                record.EnhancementOutcomeReason = "shortInput";
            }
            else
            {
                string? screen = null;
                if (mode == DictationOutputMode.Enhanced && session.ScreenContext != null)
                {
                    var done = await Task.WhenAny(session.ScreenContext, Task.Delay(1000, ct));
                    if (done == session.ScreenContext) screen = await session.ScreenContext;
                }
                var purpose = mode == DictationOutputMode.Enhanced ? EnhancementPurpose.Enhanced : EnhancementPurpose.Refine;
                var build = enhancement.Build(input, purpose, overrides, session.ClipboardContext, screen);
                if (build.Request == null)
                {
                    var outcome = new EnhancementOutcome(EnhancementOutcomeKind.Skipped, Unavailable: build.Reason);
                    record.EnhancementOutcome = outcome.Kind.ToString();
                    record.EnhancementOutcomeReason = outcome.ReasonCode;
                    if (enhancement.ShouldReport(outcome, false))
                        host.Toast(EnhancementExecutor.Describe(outcome, build.Provider ?? settings.SelectedAIProvider), ToastKind.Warning, TimeSpan.FromSeconds(5));
                }
                else
                {
                    request = build.Request;
                    record.PromptName = request.PromptTitle;
                    record.AiEnhancementModelName = $"{request.Provider} · {request.Model}";
                    record.AiRequestSystemMessage = request.SystemMessage;
                    record.AiRequestUserMessage = request.UserMessage;
                }
            }
        }

        // 8. Enhanced: wait for the AI and paste once.
        EnhancementRequest? refine = null;
        if (request != null && mode == DictationOutputMode.Enhanced)
        {
            host.SetState(RecorderState.Enhancing);
            var outcome = await enhancement.RunAsync(request, ct);
            if (outcome.Kind == EnhancementOutcomeKind.Cancelled || ct.IsCancellationRequested)
            {
                Fail(record, "Recording saved — enhancement was cancelled. Retry from History.");
                return null;
            }
            ApplyOutcome(record, outcome, session.Cleanup);
            if (outcome.Kind == EnhancementOutcomeKind.Enhanced) textToPaste = record.EnhancedText!;
            else if (enhancement.ShouldReport(outcome, false))
                host.Toast(EnhancementExecutor.Describe(outcome, request.Provider), ToastKind.Warning, TimeSpan.FromSeconds(5));
        }
        else if (request != null)
        {
            refine = request;
        }

        // 9. Save and record usage.
        record.Status = TranscriptionStatus.Completed;
        try
        {
            history.Upsert(record);
            history.RecordUsage(DateTime.Now, sessions: 1, words: DictationTextProcessing.WordCount(textToPaste),
                enhancedSessions: record.HasEnhancement ? 1 : 0, recordedSeconds: duration,
                transcribeSeconds: result.Elapsed.TotalSeconds, enhanceSeconds: record.EnhancementDuration ?? 0);
        }
        catch (Exception ex)
        {
            Log.Error("Could not save transcription", ex);
            host.Toast("Could not save this transcription to History.", ToastKind.Error);
        }

        return new PipelineResult(record, textToPaste, refine);
    }

    /// <summary>Instant + Refine: runs the refinement and always persists it (10 s hard deadline).</summary>
    public async Task<string?> RefineAsync(TranscriptionRecord record, EnhancementRequest request, TextCleanupOptions cleanup, CancellationToken ct)
    {
        using var cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
        cts.CancelAfter(request.Timeout + TimeSpan.FromSeconds(2));
        var outcome = await enhancement.RunAsync(request, cts.Token);
        ApplyOutcome(record, outcome, cleanup);
        history.Upsert(record);
        if (outcome.Kind == EnhancementOutcomeKind.Enhanced)
        {
            history.RecordUsage(DateTime.Now, enhancedSessions: 1, enhanceSeconds: outcome.Duration.TotalSeconds);
            return record.EnhancedText;
        }
        if (outcome.Kind != EnhancementOutcomeKind.Cancelled && enhancement.ShouldReport(outcome, false))
            host.Toast(EnhancementExecutor.Describe(outcome, request.Provider), ToastKind.Warning, TimeSpan.FromSeconds(5));
        return null;
    }

    /// <summary>Manual re-enhancement from History (always reports).</summary>
    public async Task<EnhancementOutcome> ReEnhanceAsync(TranscriptionRecord record, Guid? promptId, CancellationToken ct)
    {
        var cleanup = CleanupOptions(settings, library, null);
        var build = enhancement.Build(record.Text, EnhancementPurpose.Manual, new EnhancementOverrides(promptId));
        if (build.Request == null)
        {
            var skipped = new EnhancementOutcome(EnhancementOutcomeKind.Skipped, Unavailable: build.Reason);
            host.Toast(EnhancementExecutor.Describe(skipped, build.Provider ?? settings.SelectedAIProvider), ToastKind.Warning);
            return skipped;
        }
        record.PromptName = build.Request.PromptTitle;
        record.AiEnhancementModelName = $"{build.Request.Provider} · {build.Request.Model}";
        record.AiRequestSystemMessage = build.Request.SystemMessage;
        record.AiRequestUserMessage = build.Request.UserMessage;
        var outcome = await enhancement.RunAsync(build.Request, ct);
        ApplyOutcome(record, outcome, cleanup);
        history.Upsert(record);
        if (outcome.Kind != EnhancementOutcomeKind.Enhanced && outcome.Kind != EnhancementOutcomeKind.Cancelled)
            host.Toast(EnhancementExecutor.Describe(outcome, build.Request.Provider), ToastKind.Warning);
        return outcome;
    }

    private static void ApplyOutcome(TranscriptionRecord record, EnhancementOutcome outcome, TextCleanupOptions cleanup)
    {
        record.EnhancementOutcome = outcome.Kind.ToString();
        record.EnhancementOutcomeReason = outcome.Kind == EnhancementOutcomeKind.Enhanced ? null : outcome.ReasonCode;
        record.EnhancementDuration = outcome.Duration.TotalSeconds;
        if (outcome.Kind == EnhancementOutcomeKind.Enhanced && outcome.Text != null)
            record.EnhancedText = DictationTextProcessing.ApplyPreferences(outcome.Text, cleanup);
    }

    private void Fail(TranscriptionRecord record, string message)
    {
        record.Status = TranscriptionStatus.Failed;
        record.Text = message;
        try { history.Upsert(record); } catch (Exception ex) { Log.Error("Could not save failed row", ex); }
    }

    public static string Describe(Exception ex) => ex switch
    {
        TranscriptionTimeoutException => ex.Message,
        MissingApiKeyException or ModelNotDownloadedException => ex.Message,
        FileNotFoundException => "The recording file could not be opened. If the audio is still in History, retry from there.",
        Net.ApiException api => api.Message,
        HttpRequestException => "No network connection.",
        _ => ex.Message,
    };
}
