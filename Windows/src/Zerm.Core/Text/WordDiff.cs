using System.Globalization;
using System.Text;

namespace Zerm.Core.Text;

public enum DiffKind { Same, Removed, Added }

public sealed record DiffPart(DiffKind Kind, string Text);

public enum ChangeLevel { None, PunctuationOnly, Wording }

/// <summary>Word-level diff between the raw transcript and the AI-enhanced text.</summary>
public sealed record WordDiffResult(IReadOnlyList<DiffPart> Parts, int OriginalWords, int RemovedWords, int AddedWords, ChangeLevel Level)
{
    /// <summary>Share of the original words that were removed or replaced (0–1, capped).</summary>
    public double ChangedFraction => OriginalWords == 0
        ? (AddedWords > 0 ? 1 : 0)
        : Math.Min(1, Math.Max(RemovedWords, AddedWords) / (double)OriginalWords);
}

public static class WordDiff
{
    private const int MaxTokens = 4000;

    /// <summary>Words with their trailing whitespace, so the parts reassemble into the original text.</summary>
    public static List<string> Tokenize(string text)
    {
        var tokens = new List<string>();
        var sb = new StringBuilder();
        var i = 0;
        while (i < text.Length)
        {
            sb.Clear();
            while (i < text.Length && !char.IsWhiteSpace(text[i])) sb.Append(text[i++]);
            while (i < text.Length && char.IsWhiteSpace(text[i])) sb.Append(text[i++]);
            if (sb.Length > 0) tokens.Add(sb.ToString());
        }
        return tokens;
    }

    private static string Key(string token) => token.TrimEnd();

    /// <summary>Lowercase letters and digits only — "Hello," and "hello" compare equal.</summary>
    public static string Normalize(string text)
    {
        var sb = new StringBuilder(text.Length);
        foreach (var c in text.Normalize(NormalizationForm.FormC))
            if (char.IsLetterOrDigit(c)) sb.Append(char.ToLower(c, CultureInfo.InvariantCulture));
            else if (char.IsWhiteSpace(c) && sb.Length > 0 && sb[^1] != ' ') sb.Append(' ');
        return sb.ToString().Trim();
    }

    public static ChangeLevel Classify(string original, string enhanced)
    {
        if (original.Trim() == enhanced.Trim()) return ChangeLevel.None;
        return Normalize(original) == Normalize(enhanced) ? ChangeLevel.PunctuationOnly : ChangeLevel.Wording;
    }

    public static WordDiffResult Compare(string original, string enhanced)
    {
        var a = Tokenize(original);
        var b = Tokenize(enhanced);
        var level = Classify(original, enhanced);
        if (a.Count > MaxTokens || b.Count > MaxTokens)
            return new WordDiffResult([new(DiffKind.Removed, original), new(DiffKind.Added, enhanced)], a.Count, a.Count, b.Count, level);

        // Longest common subsequence on whole words (punctuation attached, so "go" vs "go." differ).
        var lcs = new int[a.Count + 1, b.Count + 1];
        for (var i = a.Count - 1; i >= 0; i--)
            for (var j = b.Count - 1; j >= 0; j--)
                lcs[i, j] = Key(a[i]) == Key(b[j]) ? lcs[i + 1, j + 1] + 1 : Math.Max(lcs[i + 1, j], lcs[i, j + 1]);

        var parts = new List<DiffPart>();
        int removed = 0, added = 0, x = 0, y = 0;
        void Push(DiffKind kind, string text)
        {
            if (parts.Count > 0 && parts[^1].Kind == kind) parts[^1] = parts[^1] with { Text = parts[^1].Text + text };
            else parts.Add(new DiffPart(kind, text));
        }
        while (x < a.Count && y < b.Count)
        {
            if (Key(a[x]) == Key(b[y]))
            {
                Push(DiffKind.Same, b[y]);
                x++;
                y++;
            }
            else if (lcs[x + 1, y] >= lcs[x, y + 1])
            {
                Push(DiffKind.Removed, a[x++]);
                removed++;
            }
            else
            {
                Push(DiffKind.Added, b[y++]);
                added++;
            }
        }
        while (x < a.Count) { Push(DiffKind.Removed, a[x++]); removed++; }
        while (y < b.Count) { Push(DiffKind.Added, b[y++]); added++; }
        return new WordDiffResult(parts, a.Count, removed, added, level);
    }
}
