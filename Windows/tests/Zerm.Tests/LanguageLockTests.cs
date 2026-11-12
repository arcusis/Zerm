using Zerm.Core.Settings;
using Zerm.Core.Transcription;

namespace Zerm.Tests;

/// <summary>Forcing a language on a Hebrew-tuned Whisper model must not leak Hebrew or drop words.</summary>
public class LanguageLockTests
{
    [Theory]
    [InlineData("en", true)]
    [InlineData("fr", true)]
    [InlineData("ru", true)]
    [InlineData("he", false)]
    [InlineData("iw", false)]
    [InlineData("yi", false)]
    [InlineData("auto", false)]
    [InlineData("", false)]
    [InlineData(null, false)]
    public void HebrewIsBlockedOnlyWhenAnotherLanguageIsForced(string? language, bool expected) =>
        Assert.Equal(expected, WhisperTranscriber.SuppressesHebrew(language));

    [Theory]
    [InlineData("�, and sometimes", false, ", and sometimes")]
    [InlineData("�ימים. Thank you", false, "ימים. Thank you")]
    [InlineData("‫‫-", true, "")]
    [InlineData(" ‏.", true, "")]
    [InlineData(" Hello ‏world", true, " Hello world")]
    [InlineData(" ‫-", false, " ‫-")]
    [InlineData(" Plain English.", true, " Plain English.")]
    public void SegmentTextIsCleaned(string raw, bool hebrewBlocked, string expected) =>
        Assert.Equal(expected, WhisperTranscriber.CleanSegmentText(raw, hebrewBlocked));

    [Fact]
    public void HebrewTokenRegexTargetsHebrewLeadBytes() =>
        Assert.Equal(@"[\s\S]*[\xD6\xD7][\s\S]*", WhisperTranscriber.HebrewTokenRegex);

    [Fact]
    public void BuiltInStylePromptCanBeSkippedButCustomPromptIsKept()
    {
        using var dir = new TempDir();
        var settings = AppSettings.Load(dir.File("settings.json"));
        using var service = new TranscriptionService(settings, new SecretStore(dir.File("secrets.dat")));

        Assert.NotEqual("", service.StylePrompt("en"));
        Assert.Equal("", service.StylePrompt("en", builtIn: false));

        settings.CustomLanguagePrompts["en"] = "My own prompt.";
        Assert.Equal("My own prompt.", service.StylePrompt("en", builtIn: false));
    }
}
