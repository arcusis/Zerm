using Zerm.Core.Text;

namespace Zerm.Core.Data;

/// <summary>Measures what AI enhancement actually did over a set of dictations.</summary>
public sealed record EnhancementInsights(
    int Dictations,
    int Enhanced,
    int Unchanged,
    int PunctuationOnly,
    int Reworded,
    int SkippedShort,
    int SkippedSetup,
    int Failed,
    int TimedOut,
    int Rejected,
    int Cancelled,
    int NotAttempted,
    double AverageChangedFraction,
    double AverageSeconds,
    double TotalSeconds,
    IReadOnlyDictionary<string, int> FailureReasons,
    IReadOnlyDictionary<string, (int Count, int Reworded)> ByPrompt)
{
    public int Attempted => Enhanced + Failed + Rejected + Cancelled;

    /// <summary>Share of enhanced dictations where the AI changed the wording (not just punctuation).</summary>
    public double UsefulRate => Enhanced == 0 ? 0 : Reworded / (double)Enhanced;

    public double FailureRate => Attempted == 0 ? 0 : (Failed + Rejected) / (double)Attempted;

    public static EnhancementInsights From(IEnumerable<TranscriptionRecord> records)
    {
        int dictations = 0, enhanced = 0, unchanged = 0, punct = 0, reworded = 0, skippedShort = 0, skippedSetup = 0,
            failed = 0, timedOut = 0, rejected = 0, cancelled = 0, notAttempted = 0;
        double changeSum = 0, secondsSum = 0;
        var reasons = new Dictionary<string, int>();
        var byPrompt = new Dictionary<string, (int, int)>();

        foreach (var r in records)
        {
            // File transcriptions and failed recordings are not dictations the AI could improve.
            if (r.Status != TranscriptionStatus.Completed || r.SegmentsJson != null) continue;
            dictations++;
            switch (r.EnhancementOutcome)
            {
                case null:
                    notAttempted++;
                    break;
                case "Enhanced" when r.EnhancedText != null:
                    enhanced++;
                    var diff = WordDiff.Compare(r.Text, r.EnhancedText);
                    changeSum += diff.Level == ChangeLevel.Wording ? diff.ChangedFraction : 0;
                    switch (diff.Level)
                    {
                        case ChangeLevel.None: unchanged++; break;
                        case ChangeLevel.PunctuationOnly: punct++; break;
                        default: reworded++; break;
                    }
                    var prompt = r.PromptName ?? "—";
                    var (c, w) = byPrompt.GetValueOrDefault(prompt);
                    byPrompt[prompt] = (c + 1, w + (diff.Level == ChangeLevel.Wording ? 1 : 0));
                    break;
                case "Skipped":
                    if (r.EnhancementOutcomeReason == "shortInput") skippedShort++;
                    else
                    {
                        skippedSetup++;
                        Count(reasons, r.EnhancementOutcomeReason ?? "setup");
                    }
                    break;
                case "Failed":
                    failed++;
                    if (r.EnhancementOutcomeReason == "Timeout") timedOut++;
                    Count(reasons, r.EnhancementOutcomeReason ?? "failed");
                    break;
                case "Rejected":
                    rejected++;
                    Count(reasons, r.EnhancementOutcomeReason ?? "rejected");
                    break;
                case "Cancelled":
                    cancelled++;
                    break;
            }
            if (r.EnhancementDuration is { } d && r.EnhancementOutcome is "Enhanced" or "Failed" or "Rejected")
                secondsSum += d;
        }

        var attempted = enhanced + failed + rejected + cancelled;
        return new EnhancementInsights(dictations, enhanced, unchanged, punct, reworded, skippedShort, skippedSetup, failed, timedOut, rejected,
            cancelled, notAttempted, enhanced == 0 ? 0 : changeSum / enhanced, attempted == 0 ? 0 : secondsSum / attempted, secondsSum, reasons, byPrompt);
    }

    private static void Count(Dictionary<string, int> d, string key) => d[key] = d.GetValueOrDefault(key) + 1;

    /// <summary>A plain-language summary of whether enhancement is paying off.</summary>
    public string Verdict()
    {
        if (Attempted == 0)
            return Dictations == 0 ? "No dictations in this period yet." : "AI enhancement didn't run on any dictation in this period.";
        if (Enhanced == 0) return "Every enhancement attempt failed or was discarded — check the provider in Enhancement settings.";
        var useful = UsefulRate;
        if (useful < 0.2)
            return "The AI rarely changes your wording — your dictation is already clean. Instant mode would give the same text without the wait.";
        if (useful < 0.5)
            return "The AI changes the wording in some dictations. Worth keeping for longer or messier dictation; Instant mode is fine for quick notes.";
        return "The AI improves the wording in most of your dictations — enhancement is earning its keep.";
    }
}
