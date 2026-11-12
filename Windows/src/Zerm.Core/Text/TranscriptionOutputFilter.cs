using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;

namespace Zerm.Core.Text;

public enum PunctuationCleanupMode
{
    Keep,
    RemoveAll,
    RemoveTrailingPeriod,
}

/// <summary>
/// Port of TranscriptionOutputFilter.swift: strips model hallucination tokens and
/// filler words, and applies the user's punctuation / lowercase preferences.
/// </summary>
public static class TranscriptionOutputFilter
{
    public static readonly IReadOnlyList<string> DefaultFillerWords =
    [
        "uh", "um", "uhm", "umm", "uhh", "uhhh",
        "hmm", "hm", "mmm", "mm", "mh", "ehh",
    ];

    // Whisper/model hallucination tokens only — never strip legitimate
    // parenthetical content like "the total (about five hundred)".
    private static readonly string[] HallucinationTokens =
    [
        "[BLANK_AUDIO]", "[BLANK AUDIO]", "[Music]", "[Silence]", "[Applause]", "[Laughter]",
        "[INAUDIBLE]", "[NOISE]", "[SOUND]", "[CLICK]", "[BEEP]",
        "(blank_audio)", "(music)", "(silence)", "(inaudible)",
        "♪", "♫", "<|nospeech|>", "<|notimestamps|>",
    ];

    private static readonly Regex EmptyBrackets = new(@"\[\s*\]|\(\s*\)|\{\s*\}", RegexOptions.Compiled);
    private static readonly Regex MultiWhitespace = new(@"\s{2,}", RegexOptions.Compiled);
    private const string ApostropheLike = "'‘’ʼ＇";

    public static string Filter(string text, bool removeFillerWords, IEnumerable<string>? fillerWords = null)
    {
        var filtered = text;
        foreach (var token in HallucinationTokens)
            filtered = filtered.Replace(token, "", StringComparison.OrdinalIgnoreCase);

        filtered = EmptyBrackets.Replace(filtered, "");

        if (removeFillerWords)
        {
            foreach (var word in fillerWords ?? DefaultFillerWords)
            {
                if (string.IsNullOrWhiteSpace(word)) continue;
                var pattern = $@"\b{Regex.Escape(word.Trim())}\b[,.]?";
                filtered = Regex.Replace(filtered, pattern, "", RegexOptions.IgnoreCase);
            }
        }

        filtered = MultiWhitespace.Replace(filtered, " ");
        return filtered.Trim();
    }

    public static string ApplyCleanupPreferences(string text, PunctuationCleanupMode mode, bool lowercase)
    {
        if (mode == PunctuationCleanupMode.Keep && !lowercase) return text;
        var cleaned = mode switch
        {
            PunctuationCleanupMode.RemoveAll => RemovePunctuation(text),
            PunctuationCleanupMode.RemoveTrailingPeriod => RemoveTrailingPeriod(text),
            _ => text,
        };
        return lowercase ? cleaned.ToLower(CultureInfo.CurrentCulture) : cleaned;
    }

    public static string RemoveTrailingPeriod(string text)
    {
        if (string.IsNullOrEmpty(text)) return text;
        var end = text.Length;
        while (end > 0 && char.IsWhiteSpace(text[end - 1])) end--;
        if (end == 0) return text;
        var last = end - 1;
        if (text[last] != '.') return text;
        if (last > 0 && text[last - 1] == '.') return text;
        return text.Remove(last, 1);
    }

    public static string RemovePunctuation(string text)
    {
        if (string.IsNullOrEmpty(text)) return text;
        var sb = new StringBuilder(text.Length);
        foreach (var ch in text)
        {
            if (ApostropheLike.Contains(ch)) continue;
            sb.Append(char.IsPunctuation(ch) ? ' ' : ch);
        }
        var s = sb.ToString();
        s = Regex.Replace(s, @"[^\S\r\n]{2,}", " ");
        s = Regex.Replace(s, @"[ \t]+\n", "\n");
        s = Regex.Replace(s, @"\n[ \t]+", "\n");
        return s.Trim();
    }
}
