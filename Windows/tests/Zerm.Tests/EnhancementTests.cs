using System.Net;
using Zerm.Core.Enhancement;
using Zerm.Core.Net;
using Zerm.Core.Prompts;

[assembly: CollectionBehavior(DisableTestParallelization = true)]

namespace Zerm.Tests;

public class EnhancementTests
{
    private static EnhancementSettingsSnapshot Snapshot(string provider = "OpenAI", string vocab = "", double timeout = 15, bool retries = true,
        IReadOnlyList<CustomPrompt>? prompts = null, Guid? selected = null) => new()
    {
        Prompts = prompts ?? PredefinedPrompts.All,
        SelectedPromptId = selected,
        Provider = provider,
        ModelForProvider = p => p == "OpenAI" ? "gpt-5.4" : p == "Groq" ? "openai/gpt-oss-120b" : "m",
        EndpointFor = (p, m) => p == "Missing"
            ? (null, EnhancementUnavailable.ApiKeyMissing)
            : (new EnhancementEndpoint(ProviderKind.OpenAICompatible, "https://x", "k", m), null),
        CustomVocabulary = vocab,
        TimeoutSeconds = timeout,
        RetriesOnTimeout = retries,
    };

    [Fact]
    public void DefaultPromptWrapsTemplateAndAddsSectionsInOrder()
    {
        var r = EnhancementRequestBuilder.Make("hello there", EnhancementPurpose.Enhanced, new(), Snapshot(vocab: "Important Vocabulary: Zerm"),
            clipboardContext: "clip", screenContext: "screen").Request!;
        Assert.Equal(PredefinedPrompts.DefaultId, r.PromptId);
        Assert.StartsWith("<SYSTEM_INSTRUCTIONS>\nYou copy-edit dictated text.", r.SystemMessage);
        Assert.Contains("- Clean up the <TRANSCRIPT> text for clarity", r.SystemMessage);
        Assert.DoesNotContain("%@", r.SystemMessage);
        var clip = r.SystemMessage.IndexOf("<CLIPBOARD_CONTEXT>\nclip\n</CLIPBOARD_CONTEXT>", StringComparison.Ordinal);
        var screen = r.SystemMessage.IndexOf("<CURRENT_WINDOW_CONTEXT>\nscreen\n</CURRENT_WINDOW_CONTEXT>", StringComparison.Ordinal);
        var vocab = r.SystemMessage.IndexOf("<CUSTOM_VOCABULARY>\nImportant Vocabulary: Zerm\n</CUSTOM_VOCABULARY>", StringComparison.Ordinal);
        Assert.True(clip > 0 && screen > clip && vocab > screen);
        Assert.Equal("\n<TRANSCRIPT>\nhello there\n</TRANSCRIPT>", r.UserMessage);
        Assert.Equal(TimeSpan.FromSeconds(15), r.Timeout);
        Assert.True(r.RetriesOnTimeout);
        Assert.False(r.MayChangeLanguage);
        Assert.Equal(64, r.MaxOutputTokens);
    }

    [Fact]
    public void RefineUsesEightSecondsWithoutRetry()
    {
        var r = EnhancementRequestBuilder.Make("x", EnhancementPurpose.Refine, new(), Snapshot()).Request!;
        Assert.Equal(TimeSpan.FromSeconds(8), r.Timeout);
        Assert.False(r.RetriesOnTimeout);
    }

    [Fact]
    public void SuperEnhancementIsWrappedAndGetsLongerTimeouts()
    {
        var enhanced = EnhancementRequestBuilder.Make("x", EnhancementPurpose.Enhanced, new(SuperEnhancement.Id), Snapshot(timeout: 15)).Request!;
        Assert.StartsWith("<SYSTEM_INSTRUCTIONS>", enhanced.SystemMessage);
        Assert.Contains("The <TRANSCRIPT> was SPOKEN, not written.", enhanced.SystemMessage);
        Assert.Contains("NEVER TRANSLATE", enhanced.SystemMessage);
        Assert.Equal(TimeSpan.FromSeconds(30), enhanced.Timeout);
        var refine = EnhancementRequestBuilder.Make("x", EnhancementPurpose.Refine, new(SuperEnhancement.Id), Snapshot()).Request!;
        Assert.Equal(TimeSpan.FromSeconds(20), refine.Timeout);
        Assert.False(refine.MayChangeLanguage);
        // Local only: the global provider here is OpenAI, but Super runs on the device.
        Assert.Equal(AIProviders.OnDevice, enhanced.Provider);
        Assert.Equal(AIProviders.OnDevice, EnhancementRequestBuilder.Make("x", EnhancementPurpose.Enhanced,
            new(SuperEnhancement.Id, Provider: "Anthropic"), Snapshot()).Request!.Provider);
    }

    [Fact]
    public void CodingPromptAddsTechnicalVocabulary()
    {
        var r = EnhancementRequestBuilder.Make("x", EnhancementPurpose.Enhanced, new(PredefinedPrompts.CodingId), Snapshot()).Request!;
        Assert.Contains("<BUILT_IN_TECHNICAL_VOCABULARY>\nAPI, CLI, SDK", r.SystemMessage);
        Assert.Contains("Resolve technical names from pronunciation and context", r.SystemMessage);
    }

    [Fact]
    public void AssistantPromptIsUnwrappedAndMayChangeLanguage()
    {
        var r = EnhancementRequestBuilder.Make("what is two plus two", EnhancementPurpose.Enhanced, new(PredefinedPrompts.AssistantId), Snapshot()).Request!;
        Assert.StartsWith("<SYSTEM_INSTRUCTIONS>\nYou are a powerful AI assistant.", r.SystemMessage);
        Assert.True(r.MayChangeLanguage);
        Assert.Equal(512, r.MaxOutputTokens);
    }

    [Fact]
    public void ProviderPrecedence_OverrideThenPromptThenGlobal()
    {
        var prompts = PredefinedPrompts.All.Select(p => p.Clone()).ToList();
        prompts[0].ProviderOverride = "Groq";
        Assert.Equal("Groq", EnhancementRequestBuilder.Make("x", EnhancementPurpose.Enhanced, new(), Snapshot(prompts: prompts)).Request!.Provider);
        Assert.Equal("Anthropic", EnhancementRequestBuilder.Make("x", EnhancementPurpose.Enhanced, new(Provider: "Anthropic", Model: "claude-haiku-4-5"),
            Snapshot(prompts: prompts)).Request!.Provider);
        Assert.Equal("OpenAI", EnhancementRequestBuilder.Make("x", EnhancementPurpose.Enhanced, new(PredefinedPrompts.ChatId), Snapshot(prompts: prompts)).Request!.Provider);
    }

    [Fact]
    public void UnavailableEndpointIsReported()
    {
        var r = EnhancementRequestBuilder.Make("x", EnhancementPurpose.Enhanced, new(), Snapshot(provider: "Missing"));
        Assert.Null(r.Request);
        Assert.Equal(EnhancementUnavailable.ApiKeyMissing, r.Reason);
        Assert.Contains("add an API key for Missing", EnhancementExecutor.DescribeUnavailable(r.Reason, "Missing"));
    }

    [Theory]
    [InlineData("<think>reasoning</think>Hello", "Hello")]
    [InlineData("Hello <think>unterminated reasoning", "Hello")]
    [InlineData("<TRANSCRIPT>\nHello world\n</TRANSCRIPT>", "Hello world")]
    [InlineData("Hello<end_of_turn>", "Hello")]
    [InlineData("<|im_start|>Hi<|im_end|>", "Hi")]
    public void OutputFilter(string input, string expected) => Assert.Equal(expected, EnhancementOutputFilter.Filter(input));

    [Fact]
    public void LanguageGuardRejectsTranslation()
    {
        Assert.Equal(EnhancementRejection.LanguageChanged,
            EnhancementLanguageGuard.Rejection("שלום לכולם, מה שלומכם היום?", "Hello everyone, how are you today?", false));
        Assert.Null(EnhancementLanguageGuard.Rejection("שלום לכולם", "שלום לכולם.", false));
        Assert.Null(EnhancementLanguageGuard.Rejection("שלום לכולם", "Hello everyone", true));
    }

    [Fact]
    public void LanguageGuardRejectsMixedCollapse()
    {
        // Mixed Hebrew + English must stay mixed.
        Assert.False(EnhancementLanguageGuard.Accept("I need the דוח השבועי by tomorrow please", "I need the weekly report by tomorrow please"));
        Assert.True(EnhancementLanguageGuard.Accept("I need the דוח השבועי by tomorrow", "I need the דוח השבועי by tomorrow."));
    }

    [Fact]
    public void LanguageGuardRejectsSelfIntroductionAndRambling()
    {
        Assert.Equal(EnhancementRejection.SelfIntroduction,
            EnhancementLanguageGuard.Rejection("hello", "Hello! I am Gemma, an AI model. How can I help?", false));
        var longOutput = string.Join(" ", Enumerable.Repeat("word", 60));
        Assert.Equal(EnhancementRejection.TooLong, EnhancementLanguageGuard.Rejection("two words", longOutput, false));
    }

    [Theory]
    [InlineData("write this as an email, hey john the meeting moved", "Hey john the meeting moved")]
    [InlineData("hey john the meeting moved, as an email.", "Hey john the meeting moved")]
    [InlineData("as an email hey john as an email", "Hey john")]
    public void TriggerWordsSelectPromptAndStrip(string input, string expected)
    {
        var prompts = PredefinedPrompts.All.Select(p => p.Clone()).ToList();
        prompts[3].TriggerWords = ["as an email", "write this as an email"];
        var d = PromptDetection.Detect(input, prompts);
        Assert.NotNull(d);
        Assert.Equal(PredefinedPrompts.ChatId, d!.PromptId);
        Assert.Equal(expected, d.ProcessedText);
    }

    [Fact]
    public void TriggerWordNeedsWordBoundary()
    {
        var prompts = PredefinedPrompts.All.Select(p => p.Clone()).ToList();
        prompts[0].TriggerWords = ["mail"];
        Assert.Null(PromptDetection.Detect("send the email", prompts));
    }

    [Fact]
    public void PredefinedMergeKeepsUserTriggersAndRefreshesText()
    {
        var stored = new List<CustomPrompt>
        {
            new() { Id = PredefinedPrompts.DefaultId, Title = "Old", PromptText = "stale", TriggerWords = ["clean"] },
            new() { Title = "Mine", PromptText = "custom" },
        };
        var merged = PredefinedPrompts.Merge(stored);
        Assert.Equal(6, merged.Count);
        var def = merged.First(p => p.Id == PredefinedPrompts.DefaultId);
        Assert.Equal("Default", def.Title);
        Assert.Equal(["clean"], def.TriggerWords);
        Assert.Contains(merged, p => p.Title == "Mine");
    }

    private static EnhancementRequest Request(TimeSpan timeout, bool retries = true) =>
        EnhancementRequestBuilder.Make("this is a test sentence", EnhancementPurpose.Enhanced, new(), Snapshot(timeout: timeout.TotalSeconds, retries: retries)).Request!
            with { Timeout = timeout };

    [Fact]
    public async Task ExecutorRetriesRateLimitThenSucceeds()
    {
        var calls = 0;
        var ex = new EnhancementExecutor(new EnhancementClient(null))
        {
            OverrideTransport = (_, _) => ++calls < 2
                ? throw new ApiException(HttpStatusCode.TooManyRequests, "slow down")
                : Task.FromResult("This is a test sentence."),
        };
        var o = await ex.RunAsync(Request(TimeSpan.FromSeconds(5)), CancellationToken.None);
        Assert.Equal(EnhancementOutcomeKind.Enhanced, o.Kind);
        Assert.Equal("This is a test sentence.", o.Text);
        Assert.Equal(2, calls);
    }

    [Fact]
    public async Task ExecutorRetriesTimeoutOnceThenFails()
    {
        var calls = 0;
        var ex = new EnhancementExecutor(new EnhancementClient(null))
        {
            OverrideTransport = async (_, ct) => { calls++; await Task.Delay(5000, ct); return "x"; },
        };
        var o = await ex.RunAsync(Request(TimeSpan.FromMilliseconds(200)), CancellationToken.None);
        Assert.Equal(EnhancementOutcomeKind.Failed, o.Kind);
        Assert.Equal(EnhancementFailure.Timeout, o.Failure);
        Assert.Equal(2, calls);
        Assert.Equal("Enhancement timed out. Your original text was kept.", EnhancementExecutor.Describe(o, "OpenAI"));
    }

    [Fact]
    public async Task ExecutorDoesNotRetryClientErrorsAndRejectsTranslations()
    {
        var calls = 0;
        var ex = new EnhancementExecutor(new EnhancementClient(null))
        {
            OverrideTransport = (_, _) => { calls++; throw new ApiException(HttpStatusCode.Unauthorized, "HTTP 401: bad key"); },
        };
        var o = await ex.RunAsync(Request(TimeSpan.FromSeconds(5)), CancellationToken.None);
        Assert.Equal(EnhancementOutcomeKind.Failed, o.Kind);
        Assert.Equal(1, calls);
        Assert.Contains("HTTP 401", EnhancementExecutor.Describe(o, "OpenAI"));

        ex.OverrideTransport = (_, _) => Task.FromResult("זהו משפט בדיקה");
        Assert.Equal(EnhancementOutcomeKind.Rejected, (await ex.RunAsync(Request(TimeSpan.FromSeconds(5)), CancellationToken.None)).Kind);

        ex.OverrideTransport = (_, _) => Task.FromResult("  <think>only thinking</think> ");
        var empty = await ex.RunAsync(Request(TimeSpan.FromSeconds(5)), CancellationToken.None);
        Assert.Equal(EnhancementFailure.EmptyResponse, empty.Failure);
    }

    [Fact]
    public async Task ExecutorReportsCancellation()
    {
        using var cts = new CancellationTokenSource(100);
        var ex = new EnhancementExecutor(new EnhancementClient(null))
        {
            OverrideTransport = async (_, ct) => { await Task.Delay(5000, ct); return "x"; },
        };
        Assert.Equal(EnhancementOutcomeKind.Cancelled, (await ex.RunAsync(Request(TimeSpan.FromSeconds(5)), cts.Token)).Kind);
    }

    [Fact]
    public async Task LocalCliRunsCommandWithPromptInEnvironment()
    {
        var r = Request(TimeSpan.FromSeconds(10)) with
        {
            Endpoint = new EnhancementEndpoint(ProviderKind.LocalCli, Command: "echo cli-ok& findstr /c:\"TRANSCRIPT>\""),
        };
        var output = await EnhancementClient.LocalCli(r, r.Endpoint, CancellationToken.None);
        Assert.StartsWith("cli-ok", output);
        Assert.Contains("<TRANSCRIPT>", output);
        Assert.Contains("</TRANSCRIPT>", output);
    }
}
