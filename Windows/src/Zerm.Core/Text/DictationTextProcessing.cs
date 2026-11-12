namespace Zerm.Core.Text;

public sealed record TextCleanupOptions(
    bool RemoveFillerWords,
    IReadOnlyList<string> FillerWords,
    bool FormatText,
    IReadOnlyList<WordReplacementRule> Replacements,
    PunctuationCleanupMode PunctuationMode,
    bool Lowercase);

/// <summary>The deterministic post-transcription pipeline (TranscriptionPipeline.clean + applyPreferences).</summary>
public static class DictationTextProcessing
{
    /// <summary>Filter → trim → paragraph format → word replacements → spoken commands.</summary>
    public static string Clean(string transcript, TextCleanupOptions o)
    {
        var text = TranscriptionOutputFilter.Filter(transcript, o.RemoveFillerWords, o.FillerWords).Trim();
        if (o.FormatText) text = TextFormatter.Format(text);
        text = WordReplacer.Apply(text, o.Replacements);
        return DictationCommandProcessor.Process(text);
    }

    public static string ApplyPreferences(string text, TextCleanupOptions o) =>
        TranscriptionOutputFilter.ApplyCleanupPreferences(text, o.PunctuationMode, o.Lowercase);

    public static int WordCount(string text) =>
        text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries).Length;
}
