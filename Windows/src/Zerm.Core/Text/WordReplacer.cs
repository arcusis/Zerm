using System.Text.RegularExpressions;

namespace Zerm.Core.Text;

public sealed record WordReplacementRule(string OriginalText, string ReplacementText, bool IsEnabled = true);

/// <summary>Port of WordReplacementService.swift.</summary>
public static class WordReplacer
{
    // Unicode letters/marks/digits, minus scripts that are written without spaces.
    private const string WordChar =
        @"(?:(?![\p{IsHiragana}\p{IsKatakana}\p{IsCJKUnifiedIdeographs}\p{IsHangulSyllables}\p{IsThai}])[\p{L}\p{M}\p{N}])";

    public static string Apply(string text, IEnumerable<WordReplacementRule> rules)
    {
        var result = text;
        foreach (var rule in rules.Where(r => r.IsEnabled).OrderByDescending(r => r.OriginalText.Length))
        {
            var variants = rule.OriginalText
                .Split(',')
                .Select(v => v.Trim())
                .Where(v => v.Length > 0)
                .OrderByDescending(v => v.Length);

            foreach (var original in variants)
            {
                if (UsesWordBoundaries(original))
                {
                    var pattern = $"(?<!{WordChar}){Regex.Escape(original)}(?!{WordChar})";
                    // MatchEvaluator so "$" in the replacement is taken literally.
                    result = Regex.Replace(result, pattern, _ => rule.ReplacementText, RegexOptions.IgnoreCase);
                }
                else
                {
                    result = result.Replace(original, rule.ReplacementText, StringComparison.OrdinalIgnoreCase);
                }
            }
        }
        return result;
    }

    public static bool UsesWordBoundaries(string text)
    {
        foreach (var ch in text)
        {
            int v = ch;
            if (v is >= 0x3040 and <= 0x309F or >= 0x30A0 and <= 0x30FF or >= 0x4E00 and <= 0x9FFF
                or >= 0xAC00 and <= 0xD7AF or >= 0x0E00 and <= 0x0E7F)
                return false;
        }
        return true;
    }
}
