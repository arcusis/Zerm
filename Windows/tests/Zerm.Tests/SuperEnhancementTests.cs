using System.Diagnostics;
using Xunit.Abstractions;
using Zerm.Core;
using Zerm.Core.Enhancement;
using Zerm.Core.LocalLlm;
using Zerm.Core.Prompts;

namespace Zerm.Tests;

/// <summary>Super Enhancement vs. Default on real messy speech, with the on-device model (ZERM_TEST_MODELS).</summary>
public sealed class SuperEnhancementIntegrationTests(ITestOutputHelper output)
{
    private static readonly LocalLlmEngine Llm = new();

    public static readonly (string Spoken, string[] MustKeep, string[] MustNotRepeat)[] Samples =
    [
        ("I want the super enhancement probably it will be slower so it's okay but it should know how to take the text and and it was and it was keep in mind that I was saying it and not writing it",
            ["slower", "saying"], ["and it was and it was", "and and"]),
        ("so the the deploy is is done I mean almost done we just need the the database migration from from Dana oh and also the standup tomorrow is moved to ten",
            ["Dana", "migration", "standup"], ["the the", "is is", "from from"]),
        ("I was going to say that the new onboarding looks great but the the settings page it's it's broken in Hebrew the text goes the wrong way",
            ["onboarding", "settings", "Hebrew"], ["it's it's", "the the", "going to say"]),
        ("can you can you check the the logs when you when you get a chance because yesterday no wait the day before yesterday the server crashed twice",
            ["logs", "day before yesterday", "twice"], ["can you can you", "when you when you", "no wait", "no, wait"]),
        ("אני רוצה ש ש הדוח יהיה מוכן מחר לא רגע ביום רביעי ו ו תשלח אותו גם לדנה",
            // Hebrew: meaning must survive (Wednesday is the corrected day); resolving the correction is not required.
            ["דוח", "רביעי", "דנה"], ["ש ש", "ו ו"]),
        ("so basically what I want is for the app to to remember my settings because every time I open it it it forgets the language and I have to set it again and also it was and it was the same with the microphone it keeps going back to the default one which is which is annoying and oh one more thing the dark mode sometimes flickers",
            ["settings", "language", "microphone", "dark mode", "flicker"], ["to to", "it it it", "and it was and it was", "which is which is"]),
    ];

    [SkippableFact]
    public async Task SuperEnhancementRepairsSpokenText()
    {
        var models = Environment.GetEnvironmentVariable("ZERM_TEST_MODELS");
        var file = Environment.GetEnvironmentVariable("ZERM_SUPER_MODEL_FILE") ?? "gemma-4-E2B_q4_0-it.gguf";
        var path = models == null ? null : Path.Combine(models, "LLMModels", file);
        output.WriteLine("model: " + file);
        Skip.If(path == null || !File.Exists(path), "Gemma model not available");
        var client = new EnhancementClient(Llm);
        var executor = new EnhancementExecutor(client);
        var prompts = PredefinedPrompts.All;
        var failures = new List<string>();

        foreach (var (spoken, keep, noRepeat) in Samples)
        {
            foreach (var promptId in new[] { PredefinedPrompts.DefaultId, SuperEnhancement.Id })
            {
                var snapshot = new EnhancementSettingsSnapshot
                {
                    Prompts = prompts,
                    SelectedPromptId = promptId,
                    Provider = AIProviders.OnDevice,
                    ModelForProvider = _ => "gemma-4-e2b",
                    EndpointFor = (_, _) => (new EnhancementEndpoint(ProviderKind.OnDevice, Model: "gemma-4-e2b", ModelPath: path), null),
                    TimeoutSeconds = 60,
                };
                var request = EnhancementRequestBuilder.Make(spoken, EnhancementPurpose.Enhanced, new(), snapshot).Request! with { Timeout = TimeSpan.FromSeconds(90) };
                var sw = Stopwatch.StartNew();
                var outcome = promptId == SuperEnhancement.Id
                    ? await SuperEnhancement.RunAsync(executor, request, CancellationToken.None)
                    : await executor.RunAsync(request, CancellationToken.None);
                var name = promptId == SuperEnhancement.Id ? "SUPER  " : "DEFAULT";
                output.WriteLine($"{name} [{sw.ElapsedMilliseconds} ms, {outcome.Kind}] {outcome.Text ?? outcome.Detail}");
                if (promptId != SuperEnhancement.Id) continue;
                var text = (outcome.Text ?? "").ToLowerInvariant();
                if (outcome.Kind != EnhancementOutcomeKind.Enhanced) failures.Add($"not enhanced: {outcome.Kind} {outcome.ReasonCode}");
                foreach (var k in keep) if (!text.Contains(k.ToLowerInvariant())) failures.Add($"lost '{k}'");
                foreach (var r in noRepeat) if (text.Contains(r)) failures.Add($"kept repetition '{r}'");
            }
            output.WriteLine("");
        }
        Assert.True(failures.Count == 0, string.Join("; ", failures));
    }
}
