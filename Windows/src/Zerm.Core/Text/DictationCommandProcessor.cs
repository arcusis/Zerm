using System.Text.RegularExpressions;

namespace Zerm.Core.Text;

/// <summary>
/// Deterministic offline dictation commands. Runs after transcription so
/// "new line", "scratch that", and spoken punctuation work without the LLM.
/// </summary>
public static class DictationCommandProcessor
{
    private static readonly (Regex Pattern, string Replacement)[] Replacements =
    [
        (R(@"\bnew\s+line\b"), "\n"),
        (R(@"\bnew\s+paragraph\b"), "\n\n"),
        (R(@"\bnext\s+line\b"), "\n"),
        (R(@"\bcomma\b"), ","),
        (R(@"\bperiod\b"), "."),
        (R(@"\bfull\s+stop\b"), "."),
        (R(@"\bquestion\s+mark\b"), "?"),
        (R(@"\bexclamation\s+(?:mark|point)\b"), "!"),
        (R(@"\bcolon\b"), ":"),
        (R(@"\bsemicolon\b"), ";"),
        (R(@"\bopen\s+(?:quote|quotes)\b"), "\""),
        (R(@"\bclose\s+(?:quote|quotes)\b"), "\""),
        (R(@"\bopen\s+paren(?:thesis)?\b"), "("),
        (R(@"\bclose\s+paren(?:thesis)?\b"), ")"),
        (R(@"\bdash\b"), "—"),
        (R(@"\bellipsis\b"), "…"),
    ];

    private static readonly Regex ScratchThat = R(@"(?:^|\s)(?:scratch that|delete that|undo that)\b");

    private static Regex R(string pattern) => new(pattern, RegexOptions.IgnoreCase | RegexOptions.Compiled);

    public static string Process(string text)
    {
        if (string.IsNullOrEmpty(text)) return text;
        var result = text;

        var matches = ScratchThat.Matches(result);
        if (matches.Count > 0)
        {
            var match = matches[^1];
            var cut = match.Index;
            var prefix = result[..cut];
            var after = result[(match.Index + match.Length)..];
            var lastBreak = prefix.LastIndexOfAny(['.', '!', '?', '\n']);
            if (lastBreak >= 0)
            {
                var keep = prefix[..(lastBreak + 1)].Trim(' ', '\t');
                result = (keep + " " + after).Trim();
            }
            else
            {
                result = after.Trim();
            }
        }

        foreach (var (pattern, replacement) in Replacements)
            result = pattern.Replace(result, replacement);

        // Tidy spacing around inserted punctuation / newlines (preserve newlines).
        result = Regex.Replace(result, @"[^\S\n]+([,.:;!?])", "$1");
        result = Regex.Replace(result, @"[^\S\n]{2,}", " ");
        result = Regex.Replace(result, @" *\n *", "\n");
        result = Regex.Replace(result, @"\n{3,}", "\n\n");
        return result.Trim();
    }
}
