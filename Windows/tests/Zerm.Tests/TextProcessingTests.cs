using Zerm.Core.Text;

namespace Zerm.Tests;

public class TextProcessingTests
{
    [Theory]
    [InlineData("[BLANK_AUDIO] Hello world", "Hello world")]
    [InlineData("Hello [music] there ♪", "Hello there")]
    [InlineData("the total (about five hundred)", "the total (about five hundred)")]
    [InlineData("um, I think uh we should go", "I think we should go")]
    [InlineData("Hmm. Okay", "Okay")]
    [InlineData("umbrella is fine", "umbrella is fine")]
    public void FilterRemovesHallucinationsAndFillers(string input, string expected) =>
        Assert.Equal(expected, TranscriptionOutputFilter.Filter(input, true));

    [Fact]
    public void FilterKeepsFillersWhenDisabled() =>
        Assert.Equal("um yes", TranscriptionOutputFilter.Filter("um  yes", false));

    [Theory]
    [InlineData("Hello world.", "Hello world")]
    [InlineData("Wait...", "Wait...")]
    [InlineData("Hello.  ", "Hello  ")]
    [InlineData("Hello?", "Hello?")]
    public void RemoveTrailingPeriod(string input, string expected) =>
        Assert.Equal(expected, TranscriptionOutputFilter.RemoveTrailingPeriod(input));

    [Fact]
    public void RemovePunctuationDropsApostrophesAndSeparatesOthers() =>
        Assert.Equal("dont stop hello world", TranscriptionOutputFilter.RemovePunctuation("don't stop, hello-world!"));

    [Fact]
    public void LowercaseApplied() =>
        Assert.Equal("hello world", TranscriptionOutputFilter.ApplyCleanupPreferences("Hello World.", PunctuationCleanupMode.RemoveTrailingPeriod, true));

    [Theory]
    [InlineData("Hello comma world period", "Hello, world.")]
    [InlineData("first new line second", "first\nsecond")]
    [InlineData("first new paragraph second", "first\n\nsecond")]
    [InlineData("Is it question mark", "Is it?")]
    [InlineData("I like cats. I like dogs scratch that", "I like cats.")]
    [InlineData("I like dogs scratch that I like cats", "I like cats")]
    [InlineData("One. Two three delete that four", "One. four")]
    [InlineData("he said open quote hi close quote", "he said \" hi \"")]
    public void SpokenCommands(string input, string expected) =>
        Assert.Equal(expected, DictationCommandProcessor.Process(input));

    [Fact]
    public void FormatterGroupsSentencesIntoParagraphs()
    {
        var sentence = "This is a sentence with exactly nine words in it.";
        var text = string.Join(" ", Enumerable.Repeat(sentence, 10));
        var formatted = TextFormatter.Format(text);
        var paragraphs = formatted.Split("\n\n");
        Assert.Equal(3, paragraphs.Length); // 4 significant sentences max per paragraph
        Assert.Equal(4, TextFormatter.SplitSentences(paragraphs[0]).Count);
        Assert.Equal(2, TextFormatter.SplitSentences(paragraphs[2]).Count);
    }

    [Fact]
    public void FormatterLeavesShortTextAlone() =>
        Assert.Equal("Hello there. How are you?", TextFormatter.Format("Hello there.  How are you?"));

    [Fact]
    public void WordReplacementsUseBoundariesAndLongestFirst()
    {
        var rules = new[]
        {
            new WordReplacementRule("gpt", "GPT"),
            new WordReplacementRule("chat gpt, chatgpt", "ChatGPT"),
            new WordReplacementRule("disabled", "nope", IsEnabled: false),
        };
        Assert.Equal("I use ChatGPT and GPT-4 but not gptx, disabled",
            WordReplacer.Apply("I use chat gpt and gpt-4 but not gptx, disabled", rules));
    }

    [Fact]
    public void WordReplacementDoesNotMatchInsideHebrewWord()
    {
        var rules = new[] { new WordReplacementRule("שלום", "Shalom") };
        Assert.Equal("Shalom, שלומי", WordReplacer.Apply("שלום, שלומי", rules));
    }

    [Fact]
    public void WordReplacementTreatsDollarLiterally() =>
        Assert.Equal("cost $1", WordReplacer.Apply("cost one dollar", [new WordReplacementRule("one dollar", "$1")]));

    [Fact]
    public void FullCleanPipeline()
    {
        var o = new TextCleanupOptions(true, TranscriptionOutputFilter.DefaultFillerWords, true,
            [new WordReplacementRule("zurm", "Zerm")], PunctuationCleanupMode.Keep, false);
        Assert.Equal("I love zerm, it works.", DictationTextProcessing.Clean("[BLANK_AUDIO] um I love zurm comma it works period", o)
            .Replace("Zerm", "zerm"));
    }
}
