using System.Text.RegularExpressions;
using Zerm.Core.Prompts;

namespace Zerm.Core.Enhancement;

public enum EnhancementRejection { SelfIntroduction, LanguageChanged, TooLong }

/// <summary>Port of AIEnhancementOutputFilter.swift.</summary>
public static class EnhancementOutputFilter
{
    private static readonly Regex ControlTokens = new(
        @"(?:<\s*/?\s*(?:start_of_turn|end_of_turn|eos|bos)\s*>|<\|(?:im_start|im_end|endoftext|assistant|user|system)\|>|\[/?INST\])",
        RegexOptions.IgnoreCase | RegexOptions.Compiled);

    private static readonly Regex SectionTags = new(
        @"</?\s*(?:TRANSCRIPT|SYSTEM_INSTRUCTIONS|CLIPBOARD_CONTEXT|CURRENT_WINDOW_CONTEXT|CURRENTLY_SELECTED_TEXT|CUSTOM_VOCABULARY|BUILT_IN_TECHNICAL_VOCABULARY)\s*>",
        RegexOptions.IgnoreCase | RegexOptions.Compiled);

    public static string Filter(string text)
    {
        var s = text;
        foreach (var tag in new[] { "thinking", "think", "reasoning" })
            s = Regex.Replace(s, $"<{tag}>(.*?)</{tag}>", "", RegexOptions.Singleline);
        foreach (var opener in new[] { "<thinking>", "<think>", "<reasoning>" })
        {
            var i = s.IndexOf(opener, StringComparison.OrdinalIgnoreCase);
            if (i >= 0) s = s[..i];
        }
        s = SectionTags.Replace(s, "");
        s = ControlTokens.Replace(s, "");
        return s.Trim();
    }
}

/// <summary>Port of EnhancementLanguageGuard.swift.</summary>
public static class EnhancementLanguageGuard
{
    public enum Script { Latin, Hebrew, Arabic, Cyrillic, Cjk, Other }

    private static readonly string[] Markers =
    [
        "i am gemma", "i'm gemma", "i am a gemma", "an ai model", "i am an ai",
        "as an ai", "from deepmind", "open weights model", "open-weights model",
        "how can i help", "i'm here to help", "i am here to help",
        "as a large language", "ai assistant", "how can i assist",
        "i am qwen", "i'm qwen",
    ];

    public static EnhancementRejection? Rejection(string original, string enhanced, bool mayChangeLanguage)
    {
        if (mayChangeLanguage) return null;
        if (LooksLikeSelfIntroduction(enhanced, original)) return EnhancementRejection.SelfIntroduction;
        if (!Accept(original, enhanced)) return EnhancementRejection.LanguageChanged;
        var src = Words(original);
        var outW = Words(enhanced);
        if (src >= 2 && outW > Math.Max(src * 4, src + 30)) return EnhancementRejection.TooLong;
        return null;
    }

    private static int Words(string s) => s.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries).Length;

    public static bool LooksLikeSelfIntroduction(string text, string original)
    {
        var lower = text.ToLowerInvariant();
        var source = original.ToLowerInvariant();
        if (Markers.Any(m => lower.Contains(m) && !source.Contains(m))) return true;
        return new[] { "gemma", "deepmind", "qwen" }.Any(w => lower.Contains(w) && !source.Contains(w));
    }

    public static bool Accept(string original, string enhanced)
    {
        var a = Histogram(original);
        var b = Histogram(enhanced);
        if (a.Total == 0 || b.Total == 0) return true;
        foreach (var script in Enum.GetValues<Script>())
        {
            var inR = a.Ratio(script);
            var outR = b.Ratio(script);
            if (inR < 0.05 && outR >= 0.08) return false;
            if (inR >= 0.15 && outR < 0.05) return false;
        }
        var dominant = a.Dominant;
        if (dominant != null && a.Ratio(dominant.Value) >= 0.40 && b.Ratio(dominant.Value) < 0.20) return false;
        return true;
    }

    public sealed class ScriptHistogram
    {
        public Dictionary<Script, int> Counts { get; } = new();
        public int Total { get; set; }
        public Script? Dominant => Counts.Count == 0 ? null : Counts.MaxBy(kv => kv.Value).Key;
        public double Ratio(Script s) => Total == 0 ? 0 : (Counts.TryGetValue(s, out var c) ? c : 0) / (double)Total;
    }

    public static ScriptHistogram Histogram(string text)
    {
        var h = new ScriptHistogram();
        foreach (var rune in text.EnumerateRunes())
        {
            if (!System.Text.Rune.IsLetter(rune)) continue;
            var script = ScriptOf(rune.Value);
            h.Counts[script] = (h.Counts.TryGetValue(script, out var c) ? c : 0) + 1;
            h.Total++;
        }
        return h;
    }

    public static Script ScriptOf(int v)
    {
        if (v is >= 0x0590 and <= 0x05FF or >= 0xFB1D and <= 0xFB4F) return Script.Hebrew;
        if (v is >= 0x0600 and <= 0x06FF or >= 0x0750 and <= 0x077F or >= 0x08A0 and <= 0x08FF
            or >= 0xFB50 and <= 0xFDFF or >= 0xFE70 and <= 0xFEFF) return Script.Arabic;
        if (v is >= 0x0400 and <= 0x052F) return Script.Cyrillic;
        if (v is >= 0x3040 and <= 0x30FF or >= 0x31F0 and <= 0x31FF or >= 0x3400 and <= 0x4DBF
            or >= 0x4E00 and <= 0x9FFF or >= 0xF900 and <= 0xFAFF or >= 0xAC00 and <= 0xD7AF) return Script.Cjk;
        if (v is >= 0x41 and <= 0x5A or >= 0x61 and <= 0x7A or >= 0xC0 and <= 0x24F or >= 0x1E00 and <= 0x1EFF
            or >= 0x2C60 and <= 0x2C7F or >= 0xA720 and <= 0xA7FF) return Script.Latin;
        return Script.Other;
    }
}

/// <summary>Port of PromptDetectionService.swift (spoken trigger words select a prompt).</summary>
public static class PromptDetection
{
    public sealed record Detection(Guid PromptId, string TriggerWord, string ProcessedText);

    public static Detection? Detect(string text, IEnumerable<CustomPrompt> prompts)
    {
        foreach (var prompt in prompts.Where(p => p.TriggerWords.Count > 0))
        {
            var hit = DetectAndStrip(text, prompt.TriggerWords);
            if (hit != null) return new Detection(prompt.Id, hit.Value.Word, hit.Value.Text);
        }
        return null;
    }

    private static (string Word, string Text)? DetectAndStrip(string text, IEnumerable<string> triggerWords)
    {
        var sorted = triggerWords.Select(w => w.Trim()).Where(w => w.Length > 0).OrderByDescending(w => w.Length).ToList();
        foreach (var w in sorted)
        {
            var afterTrailing = StripTrailing(text, w);
            if (afterTrailing != null) return (w, StripLeading(afterTrailing, w) ?? afterTrailing);
        }
        foreach (var w in sorted)
        {
            var afterLeading = StripLeading(text, w);
            if (afterLeading != null) return (w, StripTrailing(afterLeading, w) ?? afterLeading);
        }
        return null;
    }

    private static string CapitalizeFirst(string s) => s.Length == 0 ? s : char.ToUpper(s[0]) + s[1..];

    private static string? StripLeading(string text, string trigger)
    {
        var t = text.Trim();
        if (!t.StartsWith(trigger, StringComparison.OrdinalIgnoreCase)) return null;
        if (trigger.Length < t.Length && char.IsLetterOrDigit(t[trigger.Length])) return null;
        if (trigger.Length >= t.Length) return "";
        var rest = Regex.Replace(t[trigger.Length..], @"^[,\.!\?;:\s]+", "").Trim();
        return CapitalizeFirst(rest);
    }

    private static string? StripTrailing(string text, string trigger)
    {
        var t = text.Trim().TrimEnd(',', '.', '!', '?', ';', ':');
        if (!t.EndsWith(trigger, StringComparison.OrdinalIgnoreCase)) return null;
        var start = t.Length - trigger.Length;
        if (start > 0 && char.IsLetterOrDigit(t[start - 1])) return null;
        var rest = Regex.Replace(t[..start], @"[,\.!\?;:\s]+$", "").Trim();
        return CapitalizeFirst(rest);
    }
}
