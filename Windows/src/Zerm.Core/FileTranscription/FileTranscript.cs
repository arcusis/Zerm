using System.Text;
using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace Zerm.Core.FileTranscription;

public sealed class FileSegment
{
    public double Start { get; set; }
    public double End { get; set; }
    public int? SpeakerIndex { get; set; }
    public string Text { get; set; } = "";
}

public sealed record Paragraph(double Start, double End, int? SpeakerIndex, string Text);

/// <summary>Port of FileTranscript.swift (speakers, renaming, paragraphs, timestamps).</summary>
public sealed class FileTranscript
{
    public string SourceFileName { get; set; } = "";
    public double Duration { get; set; }
    public string ModelName { get; set; } = "";
    public string LanguageCode { get; set; } = "auto";
    public List<FileSegment> Segments { get; set; } = [];
    public Dictionary<int, string> SpeakerNames { get; set; } = new();

    public IEnumerable<int> Speakers => Segments.Where(s => s.SpeakerIndex != null).Select(s => s.SpeakerIndex!.Value).Distinct().OrderBy(i => i);

    public string Name(int speaker) =>
        SpeakerNames.TryGetValue(speaker, out var n) && !string.IsNullOrWhiteSpace(n) ? n : $"Speaker {speaker + 1}";

    public void Rename(int speaker, string name)
    {
        var trimmed = name.Trim();
        if (trimmed.Length == 0) SpeakerNames.Remove(speaker);
        else SpeakerNames[speaker] = trimmed;
    }

    /// <summary>Renumbers speakers in order of first appearance.</summary>
    public void NormalizeSpeakers()
    {
        var map = new Dictionary<int, int>();
        foreach (var s in Segments.OrderBy(s => s.Start))
            if (s.SpeakerIndex is { } i && !map.ContainsKey(i)) map[i] = map.Count;
        foreach (var s in Segments)
            if (s.SpeakerIndex is { } i) s.SpeakerIndex = map[i];
    }

    /// <summary>Adjacent same-speaker segments merge while the paragraph spans ≤ 90 s.</summary>
    public List<Paragraph> Paragraphs
    {
        get
        {
            var result = new List<Paragraph>();
            foreach (var s in Segments.OrderBy(s => s.Start))
            {
                var text = s.Text.Trim();
                if (text.Length == 0) continue;
                if (result.Count > 0 && result[^1].SpeakerIndex == s.SpeakerIndex && s.End - result[^1].Start <= 90)
                {
                    var last = result[^1];
                    result[^1] = last with { End = s.End, Text = last.Text + " " + text };
                }
                else
                {
                    result.Add(new Paragraph(s.Start, s.End, s.SpeakerIndex, text));
                }
            }
            return result;
        }
    }

    public string Timestamp(double seconds)
    {
        var t = TimeSpan.FromSeconds(Math.Max(0, Math.Floor(seconds)));
        return Duration >= 3600 ? $"{(int)t.TotalHours}:{t.Minutes:00}:{t.Seconds:00}" : $"{(int)t.TotalMinutes}:{t.Seconds:00}";
    }

    public string PlainText => string.Join("\n\n", Paragraphs.Select(p =>
        p.SpeakerIndex is { } i ? BidiText.Labelled(Name(i), p.Text) : p.Text));

    public string ToJson() => JsonSerializer.Serialize(this);
    public static FileTranscript? FromJson(string? json) => string.IsNullOrEmpty(json) ? null : JsonSerializer.Deserialize<FileTranscript>(json);
}

public static class BidiText
{
    public static bool IsRtl(char c) => c is >= '\u0590' and <= '\u08FF' or >= '\uFB1D' and <= '\uFDFF' or >= '\uFE70' and <= '\uFEFF';

    private static bool? Direction(string s)
    {
        foreach (var c in s)
        {
            if (IsRtl(c)) return true;
            if (char.IsLetter(c)) return false;
        }
        return null;
    }

    /// <summary>"label: text", isolating the text (U+2068…U+2069) when label and text run in different directions.</summary>
    public static string Labelled(string label, string text)
    {
        var l = Direction(label);
        var t = Direction(text);
        return l != null && t != null && l != t ? $"{label}: \u2068{text}\u2069" : $"{label}: {text}";
    }
}

public enum ExportFormat { Text, Markdown, Srt, Vtt, Json }

/// <summary>Port of FileTranscriptExporter.swift.</summary>
public static class FileTranscriptExporter
{
    public const double MaximumCueDuration = 7;
    public const int MaximumLineLength = 42;

    public static string Extension(ExportFormat f) => f switch
    {
        ExportFormat.Text => "txt",
        ExportFormat.Markdown => "md",
        ExportFormat.Srt => "srt",
        ExportFormat.Vtt => "vtt",
        _ => "json",
    };

    public static string DefaultFileName(FileTranscript t, ExportFormat f)
    {
        var name = Path.GetFileNameWithoutExtension(t.SourceFileName);
        return (string.IsNullOrWhiteSpace(name) ? "Transcription" : name) + "." + Extension(f);
    }

    public static string Export(FileTranscript t, ExportFormat f) => f switch
    {
        ExportFormat.Text => string.Join("\n\n", t.Paragraphs.Select(p =>
            $"[{t.Timestamp(p.Start)}] " + (p.SpeakerIndex is { } i ? BidiText.Labelled(t.Name(i), p.Text) : p.Text))) + "\n",
        ExportFormat.Markdown => Markdown(t),
        ExportFormat.Srt => string.Join("\n\n", Cues(t).Select((c, n) =>
            $"{n + 1}\n{Time(c.Start, ",")} --> {Time(c.End, ",")}\n" + string.Join("\n", c.Lines))) + "\n",
        ExportFormat.Vtt => string.Join("\n\n", new[] { "WEBVTT" }.Concat(Cues(t).Select(c =>
            $"{Time(c.Start, ".")} --> {Time(c.End, ".")}\n" + string.Join("\n", c.Lines.Select(EscapeVtt))))) + "\n",
        _ => Json(t),
    };

    private static string Markdown(FileTranscript t)
    {
        var blocks = new List<string> { $"# {t.SourceFileName}" };
        foreach (var p in t.Paragraphs)
        {
            blocks.Add(p.SpeakerIndex is { } i ? $"**{t.Name(i)}** · {t.Timestamp(p.Start)}" : $"**{t.Timestamp(p.Start)}**");
            blocks.Add(p.Text);
        }
        return string.Join("\n\n", blocks) + "\n";
    }

    public sealed record Cue(double Start, double End, List<string> Lines);

    public static List<Cue> Cues(FileTranscript t)
    {
        var cues = new List<Cue>();
        foreach (var segment in t.Segments.OrderBy(s => s.Start))
        {
            var words = segment.Text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);
            if (words.Length == 0) continue;
            var label = segment.SpeakerIndex is { } i ? t.Name(i) : null;
            var totalChars = (double)words.Sum(w => w.Length + 1) - 1;
            double TimeAt(int offset) => segment.Start + (segment.End - segment.Start) * Math.Min(1, offset / Math.Max(1, totalChars));

            var cueWords = new List<string>();
            var cueStart = 0;
            var offset = 0;
            void Emit()
            {
                var start = TimeAt(cueStart);
                var end = Math.Min(TimeAt(offset - 1), start + MaximumCueDuration);
                cues.Add(new Cue(start, end, Lines(label, cueWords)));
                cueWords = [];
                cueStart = offset;
            }

            foreach (var word in words)
            {
                if (cueWords.Count > 0)
                {
                    var wrapped = Wrap(label == null ? 0 : label.Length + 2, [.. cueWords, word]);
                    if (wrapped.Count > 2 || TimeAt(offset + word.Length) - TimeAt(cueStart) > MaximumCueDuration) Emit();
                }
                cueWords.Add(word);
                offset += word.Length + 1;
            }
            Emit();
        }
        return cues;
    }

    private static List<string> Lines(string? label, List<string> words)
    {
        var lines = Wrap(label == null ? 0 : label.Length + 2, words);
        if (label != null) lines[0] = BidiText.Labelled(label, lines[0]);
        return lines;
    }

    private static List<string> Wrap(int labelLength, IEnumerable<string> words)
    {
        var lines = new List<string>();
        var current = "";
        var limit = MaximumLineLength - labelLength;
        foreach (var w in words)
        {
            if (current.Length == 0) current = w;
            else if (current.Length + 1 + w.Length <= limit) current += " " + w;
            else
            {
                lines.Add(current);
                current = w;
                limit = MaximumLineLength;
            }
        }
        lines.Add(current);
        return lines;
    }

    public static string Time(double seconds, string separator)
    {
        var ms = Math.Max(0, (long)Math.Round(seconds * 1000));
        return $"{ms / 3_600_000:00}:{ms / 60_000 % 60:00}:{ms / 1000 % 60:00}{separator}{ms % 1000:000}";
    }

    private static string EscapeVtt(string line) => line.Replace("&", "&amp;").Replace("<", "&lt;").Replace(">", "&gt;");

    private static string Json(FileTranscript t)
    {
        static double R(double v) => Math.Round(v * 1000) / 1000;
        // Keys sorted alphabetically, slashes not escaped, matching the macOS exporter.
        var doc = new JsonObject
        {
            ["duration"] = R(t.Duration),
            ["language"] = t.LanguageCode,
            ["model"] = t.ModelName,
            ["segments"] = new JsonArray(t.Segments.OrderBy(s => s.Start).Select(s =>
            {
                var o = new JsonObject { ["end"] = R(s.End) };
                if (s.SpeakerIndex is { } i) o["speaker"] = t.Name(i);
                o["start"] = R(s.Start);
                o["text"] = s.Text;
                return (JsonNode)o;
            }).ToArray()),
            ["source"] = t.SourceFileName,
            ["speakers"] = new JsonArray(t.Speakers.Select(i => (JsonNode)t.Name(i)!).ToArray()),
        };
        return doc.ToJsonString(new JsonSerializerOptions { WriteIndented = true, Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping }) + "\n";
    }
}
