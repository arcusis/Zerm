using System.Text;
using System.Text.RegularExpressions;

namespace Zerm.Core.TextToSpeech;

/// <summary>
/// Port of TTSTextNormalizer.swift: turns raw on-screen text into something a person would
/// actually say — offline, deterministic, no paraphrasing.
/// </summary>
public static class TtsTextNormalizer
{
    private static readonly HashSet<string> SpokenAsWord =
    [
        "NASA", "NATO", "JSON", "YAML", "SQL", "GIF", "PNG", "RAM", "ROM", "SIM",
        "ASCII", "SCSI", "AJAX", "SaaS", "PaaS", "IaaS", "REST", "SOAP", "CRUD",
        "MIDI", "WYSIWYG", "FAQ", "ISO", "PDF", "URL", "OK",
    ];

    private static readonly HashSet<string> SpelledOut =
    [
        "API", "URI", "ID", "UI", "UX", "OS", "CLI", "CPU", "GPU", "SDK", "IDE",
        "HTTP", "HTTPS", "HTML", "CSS", "JS", "TS", "XML", "CSV", "UUID", "SSH",
        "DNS", "IP", "TCP", "UDP", "PR", "CI", "CD", "QA", "DB", "JWT", "CDN",
        "AWS", "GCP", "VM", "RPC", "GUI", "TTS", "STT", "LLM", "RGB", "FPS", "USB",
    ];

    private static readonly (string Code, string Spoken)[] ErrorCodes =
    [
        ("ENOENT", "file not found"), ("EACCES", "permission denied"), ("EPERM", "operation not permitted"),
        ("ECONNREFUSED", "connection refused"), ("ECONNRESET", "connection reset"), ("ETIMEDOUT", "timed out"),
        ("ENOTFOUND", "not found"), ("EADDRINUSE", "address already in use"), ("EPIPE", "broken pipe"), ("NaN", "not a number"),
    ];

    private const string FileExtensions =
        "swift|py|js|ts|tsx|jsx|json|yaml|yml|md|txt|sh|rb|go|rs|java|kt|cpp|hpp|c|h|html|css|scss|xml|csv|tsv|pdf|png|jpe?g|gif|svg|zip|tar|gz|log|cfg|conf|ini|toml|env|plist|lock|sql";

    private static readonly (string Symbol, string Word)[] SymbolWords =
    [
        ("✅", " check "), ("✔️", " check "), ("✔", " check "), ("☑️", " check "), ("☑", " check "),
        ("❌", " no "), ("✖️", " no "), ("✖", " no "), ("✗", " no "), ("✘", " no "),
        ("⚠️", " warning "), ("⚠", " warning "), ("⛔", " stop "), ("🚫", " no "),
        ("⭐", " star "), ("🌟", " star "), ("🔴", " red "), ("🟢", " green "), ("🟡", " yellow "),
        ("❗", "! "), ("‼️", "! "), ("❓", "? "), ("➡️", " to "), ("→", " to "),
    ];

    private static string R(string text, string pattern, string replacement, RegexOptions options = RegexOptions.None) =>
        Regex.Replace(text, pattern, replacement, options);

    public static string Normalize(string raw)
    {
        var text = raw.Replace("\r\n", "\n");

        text = FlattenTables(text);

        text = R(text, @"^\s*#{1,6}\s+", "", RegexOptions.Multiline);
        text = R(text, @"^\s*[-*+]\s+", "", RegexOptions.Multiline);
        text = R(text, @"^\s*>\s?", "", RegexOptions.Multiline);
        text = R(text, @"^\s*\d+[.)]\s+", "", RegexOptions.Multiline);

        foreach (var (symbol, word) in SymbolWords) text = text.Replace(symbol, word);
        text = StripUnreadable(text);

        text = R(text, @"```[A-Za-z0-9_+-]*\n?", " ");

        text = R(text, "`([^`]+)`", "$1");
        text = R(text, @"!\[([^\]]*)\]\([^)]*\)", "$1");
        text = R(text, @"\[([^\]]+)\]\([^)]*\)", "$1");

        text = Regex.Replace(text, @"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}", m => SpeakEmail(m.Value));
        text = Regex.Replace(text, @"(?:https?://|www\.)[^\s]+", m => SpeakUrl(m.Value));
        text = Regex.Replace(text, @"(?:(?<=\s)|^)/[A-Za-z0-9._/-]+", m => string.Join(" ", m.Value.Split('/', StringSplitOptions.RemoveEmptyEntries)), RegexOptions.Multiline);

        text = R(text, $@"([A-Za-z0-9_-]+)\.({FileExtensions})\b", "$1 dot $2", RegexOptions.IgnoreCase);

        text = Regex.Replace(text, @"\b[A-Za-z]{2,6}s?\b", m => SpeakAcronym(m.Value));

        text = R(text, "([A-Za-z0-9])_([A-Za-z0-9])", "$1 $2");
        text = R(text, "_+", " ");
        text = R(text, "([a-z0-9])([A-Z])", "$1 $2");

        text = R(text, "[*~]{1,3}", "");

        foreach (var (code, spoken) in ErrorCodes) text = R(text, $@"\b{code}\b", spoken);

        text = R(text, @"\be\.g\.", "for example", RegexOptions.IgnoreCase);
        text = R(text, @"\bi\.e\.", "that is", RegexOptions.IgnoreCase);
        text = R(text, @"\betc\.?", "and so on", RegexOptions.IgnoreCase);
        text = R(text, @"\bvs\.?", "versus", RegexOptions.IgnoreCase);
        text = R(text, @"\bapprox\.", "approximately", RegexOptions.IgnoreCase);

        text = R(text, @"\$(\d[\d,]*(?:\.\d+)?)", "$1 dollars");
        text = R(text, @"(\d)\s*%", "$1 percent");
        text = R(text, @"#(\d+)", "number $1");
        text = R(text, @"\s&\s", " and ");

        text = R(text, @"\n{2,}", ". ");
        text = R(text, @"\s*\n\s*", " ");
        text = R(text, @"[ \t]{2,}", " ");
        text = R(text, @"\s+([.,;:!?])", "$1");
        text = R(text, @"([.])\1{1,}", ".");
        return text.Trim();
    }

    private static string FlattenTables(string text)
    {
        if (!text.Contains('│') && !text.Contains('|')) return text;
        return string.Join("\n", text.Split('\n').Select(line =>
        {
            if (!line.Contains('│') && !line.Contains('|')) return line;
            var cells = line.Split(['│', '|'])
                .Select(c => c.Trim())
                .Where(c => c.Length > 0 && !c.All(ch => "-:= ".Contains(ch)))
                .ToList();
            return cells.Count == 0 ? "" : string.Join(", ", cells) + ".";
        }));
    }

    private static string StripUnreadable(string text)
    {
        var sb = new StringBuilder(text.Length);
        foreach (var rune in text.EnumerateRunes())
        {
            var v = rune.Value;
            var strip = v is >= 0xFE00 and <= 0xFE0F or 0x200D or >= 0x1F3FB and <= 0x1F3FF or >= 0x1F1E6 and <= 0x1F1FF
                        or >= 0x2500 and <= 0x25FF
                        or >= 0x2600 and <= 0x27BF or >= 0x2B00 and <= 0x2BFF or >= 0x1F000 and <= 0x1FAFF
                        or >= 0x231A and <= 0x231B or >= 0x23E9 and <= 0x23F3 or >= 0x23F8 and <= 0x23FA;
            if (strip) sb.Append(' ');
            else sb.Append(rune.ToString());
        }
        return sb.ToString();
    }

    private static string SpeakEmail(string email)
    {
        var at = email.IndexOf('@');
        return at < 0 ? email : email[..at] + " at " + email[(at + 1)..].Replace(".", " dot ");
    }

    private static string SpeakUrl(string url)
    {
        var host = url;
        var scheme = host.IndexOf("://", StringComparison.Ordinal);
        if (scheme >= 0) host = host[(scheme + 3)..];
        var cut = host.IndexOfAny(['/', '?', '#']);
        if (cut > 0) host = host[..cut];
        if (host.StartsWith("www.", StringComparison.OrdinalIgnoreCase)) host = host[4..];
        return host.Replace(".", " dot ");
    }

    private static string SpeakAcronym(string token)
    {
        var core = token;
        var plural = false;
        if (core.Length > 2 && core.EndsWith('s') && core[..^1].All(char.IsUpper))
        {
            core = core[..^1];
            plural = true;
        }
        if (core != core.ToUpperInvariant() || !core.All(char.IsLetter)) return token;
        if (SpokenAsWord.Contains(core) || !SpelledOut.Contains(core)) return token;
        var spelled = string.Join(" ", core.ToCharArray());
        return plural ? spelled + "s" : spelled;
    }

    /// <summary>~100-character chunks on sentence boundaries; the first sentence is its own chunk (BlueTextFrontend.sentenceChunks).</summary>
    public static List<string> SentenceChunks(string text, int target = 100)
    {
        var sentences = Regex.Matches(text, @"[^.!?]+[.!?]+\s*|[^.!?]+$")
            .Select(m => m.Value.Trim()).Where(s => s.Length > 0).ToList();
        var pieces = new List<string>();
        foreach (var s in sentences)
        {
            if (s.Length <= target)
            {
                pieces.Add(s);
                continue;
            }
            var current = new StringBuilder();
            foreach (var word in s.Split(' ', StringSplitOptions.RemoveEmptyEntries))
            {
                if (current.Length > 0 && current.Length + word.Length + 1 > target)
                {
                    pieces.Add(current.ToString());
                    current.Clear();
                }
                if (current.Length > 0) current.Append(' ');
                current.Append(word);
            }
            if (current.Length > 0) pieces.Add(current.ToString());
        }

        // The first piece stays alone so audio starts quickly; later pieces are packed up to the target.
        var chunks = new List<string>();
        foreach (var piece in pieces)
        {
            if (chunks.Count >= 2 && chunks[^1].Length + piece.Length + 1 <= target)
                chunks[^1] += " " + piece;
            else
                chunks.Add(piece);
        }
        return chunks;
    }
}
