using Zerm.Core;
using Zerm.Core.Data;
using Zerm.Core.FileTranscription;
using Zerm.Core.Settings;
using Zerm.Core.TextToSpeech;

namespace Zerm.Tests;

public sealed class TempDir : IDisposable
{
    public string Path { get; } = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "zerm-tests-" + Guid.NewGuid().ToString("N"));
    public TempDir() => Directory.CreateDirectory(Path);
    public string File(string name) => System.IO.Path.Combine(Path, name);

    public void Dispose()
    {
        Microsoft.Data.Sqlite.SqliteConnection.ClearAllPools();
        try { Directory.Delete(Path, true); } catch { }
    }
}

public class LibraryTests
{
    [Fact]
    public void SeedsGeneralPowerModeAndPersists()
    {
        using var dir = new TempDir();
        var lib = Library.Load(dir.File("lib.json"));
        Assert.Single(lib.PowerModes);
        Assert.True(lib.PowerModes[0].IsDefault);
        Assert.Equal(5, lib.Prompts.Count);
        lib.AddVocabulary("Zerm, Arcusis");
        var reloaded = Library.Load(dir.File("lib.json"));
        Assert.Equal(["Zerm", "Arcusis"], reloaded.Vocabulary.Select(v => v.Word));
    }

    [Fact]
    public void VocabularyDuplicateIsReportedOnlyForSingleWord()
    {
        using var dir = new TempDir();
        var lib = Library.Load(dir.File("lib.json"));
        Assert.Null(lib.AddVocabulary("Zerm"));
        Assert.Equal("'zerm' is already in the vocabulary", lib.AddVocabulary("zerm"));
        Assert.Null(lib.AddVocabulary("zerm, New"));
        Assert.Equal(2, lib.Vocabulary.Count);
    }

    [Fact]
    public void ReplacementTriggersMustBeUnique()
    {
        using var dir = new TempDir();
        var lib = Library.Load(dir.File("lib.json"));
        Assert.Null(lib.AddReplacement("chat gpt, chatgpt", "ChatGPT"));
        Assert.Equal("'ChatGPT' already exists in word replacements", lib.AddReplacement("ChatGPT", "x"));
        var id = lib.Replacements[0].Id;
        Assert.Null(lib.AddReplacement("chat gpt, chatgpt, chat g p t", "ChatGPT", id));
        Assert.Single(lib.Replacements);
    }

    [Fact]
    public void PowerModeResolution_UrlBeatsAppBeatsDefault()
    {
        using var dir = new TempDir();
        var lib = Library.Load(dir.File("lib.json"));
        var code = new PowerModeConfig { Name = "Code", AppConfigs = [new() { ProcessName = "Code", AppName = "VS Code" }] };
        var gh = new PowerModeConfig { Name = "GitHub", UrlConfigs = [new() { Url = "github.com" }] };
        var disabled = new PowerModeConfig { Name = "Off", IsEnabled = false, AppConfigs = [new() { ProcessName = "notepad" }] };
        lib.SavePowerMode(code);
        lib.SavePowerMode(gh);
        lib.SavePowerMode(disabled);
        Assert.Equal("Code", lib.Resolve("code", null)!.Name);
        Assert.Equal("GitHub", lib.Resolve("chrome", "https://www.GitHub.com/arcusis/Zerm")!.Name);
        Assert.Equal("General", lib.Resolve("chrome", "https://example.com")!.Name);
        Assert.Equal("General", lib.Resolve("notepad", null)!.Name);
    }

    [Fact]
    public void PowerModeValidation()
    {
        using var dir = new TempDir();
        var lib = Library.Load(dir.File("lib.json"));
        lib.SavePowerMode(new PowerModeConfig { Name = "Code", AppConfigs = [new() { ProcessName = "Code", AppName = "VS Code" }] });
        var clash = new PowerModeConfig { Name = "Code", AppConfigs = [new() { ProcessName = "code", AppName = "VS Code" }] };
        var errors = lib.Validate(clash);
        Assert.Equal(2, errors.Count);
        Assert.Contains(lib.Validate(new PowerModeConfig { Name = " " }), e => e.Contains("empty"));
    }

    [Fact]
    public void SettingsRoundTrip()
    {
        using var dir = new TempDir();
        var s = AppSettings.Load(dir.File("settings.json"));
        Assert.Equal(DictationOutputMode.InstantRefine, s.OutputMode);
        Assert.Equal(HotkeyMode.Hybrid, s.HotkeyMode1);
        s.SelectedLanguage = "he";
        s.SetModelFor("OpenAI", "gpt-5.4-mini");
        s.SaveNow();
        var r = AppSettings.Load(dir.File("settings.json"));
        Assert.Equal("he", r.SelectedLanguage);
        Assert.Equal("gpt-5.4-mini", r.ModelFor("OpenAI"));
    }

    [Fact]
    public void SecretsAreEncryptedAtRest()
    {
        using var dir = new TempDir();
        var store = new SecretStore(dir.File("s.dat"));
        store.SetApiKey("Groq", "gsk_secret_value");
        Assert.DoesNotContain("gsk_secret_value", System.Text.Encoding.UTF8.GetString(File.ReadAllBytes(dir.File("s.dat"))));
        Assert.Equal("gsk_secret_value", new SecretStore(dir.File("s.dat")).ApiKey("Groq"));
        Assert.Equal("groqAPIKey", SecretStore.KeyId("Groq"));
    }
}

public class HistoryTests
{
    [Fact]
    public void UpsertQuerySearchPageDelete()
    {
        using var dir = new TempDir();
        using var store = new HistoryStore(dir.File("h.db"));
        for (var i = 0; i < 25; i++)
            store.Upsert(new TranscriptionRecord { Text = $"note {i}", Timestamp = DateTime.Now.AddMinutes(-i), Status = TranscriptionStatus.Completed });
        store.Upsert(new TranscriptionRecord { Text = "raw", EnhancedText = "Polished 100% text", Timestamp = DateTime.Now.AddHours(1), Status = TranscriptionStatus.Completed });
        Assert.Equal(26, store.Count());
        Assert.Equal(20, store.Query().Count);
        Assert.Equal(6, store.Query(offset: 20).Count);
        Assert.Equal("Polished 100% text", store.Query()[0].DisplayText);
        Assert.Single(store.Query("100%"));
        Assert.Single(store.Query("note 13"));
        Assert.Equal("note 24", store.Query(newestFirst: false)[0].Text);
        Assert.Equal("Polished 100% text", store.Latest()!.DisplayText);
        store.Delete(store.Query("note", limit: 100).Select(r => r.Id));
        Assert.Equal(1, store.Count());
    }

    [Fact]
    public void UsageAccumulatesPerDay()
    {
        using var dir = new TempDir();
        using var store = new HistoryStore(dir.File("h.db"));
        store.RecordUsage(DateTime.Today.AddHours(9), sessions: 1, words: 70, recordedSeconds: 30);
        store.RecordUsage(DateTime.Today.AddHours(15), sessions: 1, words: 70, recordedSeconds: 30);
        store.RecordUsage(DateTime.Today.AddDays(-1), sessions: 1, words: 35, recordedSeconds: 10, readAloudWords: 12, readAloudSessions: 1);
        var days = store.UsageDays();
        Assert.Equal(2, days.Count);
        var totals = UsageMetrics.Totals(days, UsageRange.Week, DateTime.Today);
        Assert.Equal(3, totals.Sessions);
        Assert.Equal(175, totals.Words);
        Assert.Equal(175 / 35.0 * 60 - 70, totals.TimeSavedSeconds, 3);
        Assert.Equal(175 / (70 / 60.0), totals.WordsPerMinute!.Value, 3);
        Assert.Equal(875, totals.KeystrokesSaved);
        Assert.Equal(12, totals.ReadAloudWords);
    }

    [Fact]
    public void RetentionDeletesOldAudioAndTranscripts()
    {
        using var dir = new TempDir();
        using var store = new HistoryStore(dir.File("h.db"));
        var audio = dir.File("a.wav");
        File.WriteAllText(audio, "x");
        store.Upsert(new TranscriptionRecord { Text = "old", Timestamp = DateTime.Now.AddDays(-20), AudioFilePath = audio, Status = TranscriptionStatus.Completed });
        store.Upsert(new TranscriptionRecord { Text = "new", Timestamp = DateTime.Now, Status = TranscriptionStatus.Completed });
        var (t, a) = store.Cleanup(null, 14);
        Assert.Equal((0, 1), (t, a));
        Assert.False(File.Exists(audio));
        Assert.Null(store.Query("old")[0].AudioFilePath);
        (t, _) = store.Cleanup(60 * 24, null);
        Assert.Equal(1, t);
        Assert.Equal(1, store.Count());
    }

    [Fact]
    public void ReadAloudHistoryIsCapped()
    {
        using var dir = new TempDir();
        using var store = new HistoryStore(dir.File("h.db"));
        for (var i = 0; i < 505; i++)
            store.AddReadAloud(new ReadAloudEntry { SourceText = $"s{i}", SpokenText = "x", Timestamp = DateTime.Now.AddSeconds(i) });
        var all = store.ReadAloudHistory();
        Assert.Equal(500, all.Count);
        Assert.Equal("s504", all[0].SourceText);
    }

    [Fact]
    public void Streaks()
    {
        var today = new DateTime(2026, 10, 3);
        var days = new[] { -1, -2, -3, -10, -11 }.Select(o => new UsageDay { Day = today.AddDays(o), Sessions = 1 }).ToList();
        Assert.Equal((3, 3), UsageMetrics.Streaks(days, today));
        days.Add(new UsageDay { Day = today, Sessions = 2 });
        Assert.Equal((4, 4), UsageMetrics.Streaks(days, today));
        Assert.Equal(30, UsageMetrics.Buckets(days, UsageRange.Month, today).Count);
        Assert.Equal(12, UsageMetrics.Buckets(days, UsageRange.Year, today).Count);
    }
}

public class ExportTests
{
    private static FileTranscript Sample() => new()
    {
        SourceFileName = "meeting.m4a",
        Duration = 75,
        ModelName = "Large v3 Turbo",
        LanguageCode = "en",
        Segments =
        [
            new() { Start = 0, End = 4.5, SpeakerIndex = 0, Text = "Welcome everyone to the weekly sync." },
            new() { Start = 4.5, End = 9, SpeakerIndex = 0, Text = "Let's start with updates." },
            new() { Start = 9.2, End = 20, SpeakerIndex = 1, Text = "Thanks. The Windows port is almost ready and every feature has been tested end to end on real hardware." },
        ],
    };

    [Fact]
    public void TextAndMarkdown()
    {
        var t = Sample();
        t.Rename(1, "Dana");
        Assert.Equal("[0:00] Speaker 1: Welcome everyone to the weekly sync. Let's start with updates.\n\n[0:09] Dana: Thanks. The Windows port is almost ready and every feature has been tested end to end on real hardware.\n",
            FileTranscriptExporter.Export(t, ExportFormat.Text));
        var md = FileTranscriptExporter.Export(t, ExportFormat.Markdown);
        Assert.StartsWith("# meeting.m4a\n\n**Speaker 1** · 0:00\n\nWelcome everyone", md);
        Assert.Equal("meeting.srt", FileTranscriptExporter.DefaultFileName(t, ExportFormat.Srt));
    }

    [Fact]
    public void SrtAndVttCuesRespectLineAndDurationLimits()
    {
        var t = Sample();
        var cues = FileTranscriptExporter.Cues(t);
        Assert.All(cues, c =>
        {
            Assert.True(c.Lines.Count <= 2);
            Assert.True(c.End - c.Start <= 7.0001);
        });
        var srt = FileTranscriptExporter.Export(t, ExportFormat.Srt);
        Assert.Equal("1\n00:00:00,000 --> 00:00:04,500\nSpeaker 1: Welcome everyone to the weekly\nsync.", srt[..srt.IndexOf("\n\n", StringComparison.Ordinal)]);
        var vtt = FileTranscriptExporter.Export(t, ExportFormat.Vtt);
        Assert.StartsWith("WEBVTT\n\n00:00:00.000 --> ", vtt);
        Assert.EndsWith("\n", vtt);
    }

    [Fact]
    public void JsonIsSortedAndUnescaped()
    {
        var json = FileTranscriptExporter.Export(Sample(), ExportFormat.Json);
        var keys = System.Text.Json.JsonDocument.Parse(json).RootElement.EnumerateObject().Select(p => p.Name).ToList();
        Assert.Equal(keys.OrderBy(k => k, StringComparer.Ordinal), keys);
        Assert.Contains("\"speaker\": \"Speaker 2\"", json);
        Assert.Contains("Let's", json);
    }

    [Fact]
    public void BidiLabelIsolatesOppositeDirection()
    {
        Assert.Equal("Speaker 1: ⁨שלום⁩", BidiText.Labelled("Speaker 1", "שלום"));
        Assert.Equal("Speaker 1: Hello", BidiText.Labelled("Speaker 1", "Hello"));
    }

    [Fact]
    public void ParagraphsMergeUpTo90Seconds()
    {
        var t = new FileTranscript { Duration = 200, Segments = [.. Enumerable.Range(0, 10).Select(i => new FileSegment { Start = i * 20, End = i * 20 + 19, SpeakerIndex = 0, Text = $"s{i}" })] };
        Assert.Equal(3, t.Paragraphs.Count);
        Assert.Equal("1:20", new FileTranscript { Duration = 100 }.Timestamp(80.9));
        Assert.Equal("1:00:05", new FileTranscript { Duration = 4000 }.Timestamp(3605));
    }

    [Fact]
    public void OverlapReconciliation()
    {
        Assert.Equal("and then we left", FileTranscriptionService.Reconcile("we went to the store", "to the store and then we left"));
        Assert.Equal("totally new text", FileTranscriptionService.Reconcile("we went home", "totally new text"));
    }

    [Fact]
    public void SpanPlanningMergesAndFolds()
    {
        var turns = new List<SpeakerTurn> { new(0, 5, 0), new(5.5, 9, 0), new(9.1, 9.5, 1), new(9.6, 20, 1), new(20, 85, 0) };
        var spans = Diarizer.PlanSpans(turns);
        // (9.1–9.5) merges with the same speaker's next turn before short-turn folding.
        Assert.Equal(new SpeakerTurn(0, 9, 0), spans[0]);
        Assert.Equal(new SpeakerTurn(9.1, 20, 1), spans[1]);
        var folded = Diarizer.PlanSpans([new(0, 5, 0), new(5.2, 5.6, 1), new(6, 12, 0)]);
        Assert.Equal([new SpeakerTurn(0, 12, 0)], folded);
        Assert.All(spans, s => Assert.True(s.End - s.Start <= 30));
        Assert.Equal(20, spans.Where(s => s.Speaker == 0 && s.Start >= 20).Min(s => s.Start));
    }
}

public class ReadAloudTextTests
{
    [Theory]
    [InlineData("Check the API docs.", "Check the A P I docs.")]
    [InlineData("Our APIs use JSON.", "Our A P Is use JSON.")]
    [InlineData("Visit https://www.example.com/path?q=1 now", "Visit example dot com now")]
    [InlineData("Mail me at dev@arcusis.io", "Mail me at dev at arcusis dot io")]
    [InlineData("Open main.swift then run", "Open main dot swift then run")]
    [InlineData("Error: ENOENT happened", "Error: file not found happened")]
    [InlineData("It costs $1,200 or 15% e.g. today", "It costs 1,200 dollars or 15 percent for example today")]
    [InlineData("✅ done ❌ failed", "check done no failed")]
    [InlineData("## Title\n- item one\n- item two", "Title item one item two")]
    [InlineData("call getUserById with user_id", "call get User By Id with user id")]
    public void Normalize(string input, string expected) => Assert.Equal(expected, TtsTextNormalizer.Normalize(input));

    [Fact]
    public void TablesBecomeSentences() =>
        Assert.Equal("Name, Value. A, 1.", TtsTextNormalizer.Normalize("| Name | Value |\n|---|---|\n| A | 1 |"));

    [Fact]
    public void ChunksStartSmallThenPack()
    {
        var chunks = TtsTextNormalizer.SentenceChunks("First. Second sentence. Third one here. Fourth.");
        Assert.Equal("First.", chunks[0]);
        Assert.Equal(2, chunks.Count);
        var longText = string.Join(" ", Enumerable.Repeat("word", 80)) + ".";
        Assert.All(TtsTextNormalizer.SentenceChunks(longText), c => Assert.True(c.Length <= 100));
    }

    [Fact]
    public void NaturalizerGuards()
    {
        Assert.False(TtsNaturalizer.IsUsable("Hi, I am Gemma, how can I help?", "status is fine", ReadAloudMode.Retell));
        Assert.True(TtsNaturalizer.IsUsable("The build passed and the release is ready.", "Build ✅ — release ready", ReadAloudMode.Retell));
        Assert.True(TtsNaturalizer.IsPredominantlyHebrew("שלום עולם, מה נשמע"));
        Assert.False(TtsNaturalizer.IsPredominantlyHebrew("שלום world, how are you doing today"));
        Assert.Equal("Spoken text", TtsNaturalizer.Cleanup("Sure, here is the version: \"Spoken text\""));
        Assert.Contains("HEBREW OUTPUT IS REQUIRED", TtsNaturalizer.Instruction(ReadAloudMode.Summarize, true));
        Assert.Equal("Return the text unchanged.", TtsNaturalizer.Instruction(ReadAloudMode.Exact, false));
    }
}
