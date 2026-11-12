using Zerm.Core.Data;
using Zerm.Core.Text;

namespace Zerm.Tests;

public class InsightsTests
{
    [Fact]
    public void DiffMarksRemovedAndAddedWords()
    {
        var d = WordDiff.Compare("so the meeting is on tuesday sorry wednesday", "The meeting is on Wednesday.");
        Assert.Equal(ChangeLevel.Wording, d.Level);
        Assert.Contains(d.Parts, p => p.Kind == DiffKind.Removed && p.Text.Contains("tuesday"));
        Assert.Contains(d.Parts, p => p.Kind == DiffKind.Added && p.Text.Contains("Wednesday."));
        // The enhanced side reassembles exactly from Same + Added parts.
        Assert.Equal("The meeting is on Wednesday.", string.Concat(d.Parts.Where(p => p.Kind != DiffKind.Removed).Select(p => p.Text)));
        Assert.Equal("so the meeting is on tuesday sorry wednesday", string.Concat(d.Parts.Where(p => p.Kind != DiffKind.Added).Select(p => p.Text)));
        Assert.InRange(d.ChangedFraction, 0.3, 1);
    }

    [Theory]
    [InlineData("Hello world.", "Hello world.", ChangeLevel.None)]
    [InlineData("hello world", "Hello, world!", ChangeLevel.PunctuationOnly)]
    [InlineData("hello world", "Hi world", ChangeLevel.Wording)]
    public void ClassifiesChanges(string a, string b, ChangeLevel expected) => Assert.Equal(expected, WordDiff.Classify(a, b));

    [Fact]
    public void HebrewDiffWorks()
    {
        var d = WordDiff.Compare("אני חושב שזה טוב", "אני חושב שזה מצוין.");
        Assert.Equal(1, d.RemovedWords);
        Assert.Equal(1, d.AddedWords);
    }

    [Fact]
    public void InsightsCountOutcomesAndVerdict()
    {
        TranscriptionRecord R(string text, string? enhanced, string? outcome, string? reason = null, double? secs = null) => new()
        {
            Text = text, EnhancedText = enhanced, EnhancementOutcome = outcome, EnhancementOutcomeReason = reason,
            EnhancementDuration = secs, Status = TranscriptionStatus.Completed, PromptName = "Default",
        };
        var records = new[]
        {
            R("hello there", "Hello there.", "Enhanced", secs: 1),
            R("ok so um the plan works", "The plan works.", "Enhanced", secs: 2),
            R("Same text.", "Same text.", "Enhanced", secs: 1),
            R("yes", null, "Skipped", "shortInput"),
            R("long text here to enhance", null, "Failed", "Timeout", 15),
            R("instant mode text", null, null),
            new TranscriptionRecord { Text = "failed rec", Status = TranscriptionStatus.Failed },
        };
        var i = EnhancementInsights.From(records);
        Assert.Equal(6, i.Dictations);
        Assert.Equal(3, i.Enhanced);
        Assert.Equal((1, 1, 1), (i.Unchanged, i.PunctuationOnly, i.Reworded));
        Assert.Equal(1, i.SkippedShort);
        Assert.Equal((1, 1), (i.Failed, i.TimedOut));
        Assert.Equal(1, i.NotAttempted);
        Assert.Equal(19.0 / 4, i.AverageSeconds, 3);
        Assert.Equal(1 / 3.0, i.UsefulRate, 3);
        Assert.Equal((3, 1), i.ByPrompt["Default"]);
        Assert.Contains("some dictations", i.Verdict());
    }
}

public class GpuMemoryTests(Xunit.Abstractions.ITestOutputHelper output)
{
    [Fact]
    public void QueriesFreeVideoMemoryWithoutThrowing()
    {
        var free = Zerm.Core.GpuMemory.AvailableBytes();
        output.WriteLine($"free VRAM: {(free == null ? "unknown" : $"{free / (1024 * 1024)} MB")}");
        Assert.True(free == null || free > 0);
    }
}
