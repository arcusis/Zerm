using Zerm.Core.Prompts;

namespace Zerm.Core.Enhancement;

public enum EnhancementPurpose { Enhanced, Refine, Manual }

public enum EnhancementUnavailable
{
    OnDeviceModelMissing,
    ApiKeyMissing,
    ModelMissing,
    EndpointInvalid,
    CommandMissing,
    PromptMissing,
}

public sealed record EnhancementEndpoint(
    ProviderKind Kind,
    string? Url = null,
    string? ApiKey = null,
    string Model = "",
    string? Command = null,
    TimeSpan? CommandTimeout = null,
    string? ModelPath = null);

public sealed record EnhancementRequest(
    EnhancementPurpose Purpose,
    string InputText,
    string SystemMessage,
    string UserMessage,
    Guid PromptId,
    string PromptTitle,
    string Provider,
    string Model,
    EnhancementEndpoint Endpoint,
    TimeSpan Timeout,
    bool RetriesOnTimeout,
    bool MayChangeLanguage,
    int MaxOutputTokens);

public sealed record EnhancementOverrides(Guid? PromptId = null, string? Provider = null, string? Model = null);

public sealed class EnhancementSettingsSnapshot
{
    public required IReadOnlyList<CustomPrompt> Prompts { get; init; }
    public Guid? SelectedPromptId { get; init; }
    public required string Provider { get; init; }
    public required Func<string, string> ModelForProvider { get; init; }
    public required Func<string, string, (EnhancementEndpoint? Endpoint, EnhancementUnavailable? Reason)> EndpointFor { get; init; }
    public string CustomVocabulary { get; init; } = "";
    public double TimeoutSeconds { get; init; } = 15;
    public bool RetriesOnTimeout { get; init; } = true;
    /// <summary>Preferred local model for Super Enhancement (null = strongest downloaded).</summary>
    public string? SuperModel { get; init; }
}

public sealed record BuildResult(EnhancementRequest? Request, EnhancementUnavailable? Reason, string? Provider = null);

/// <summary>Port of EnhancementRequestBuilder (EnhancementRequest.swift).</summary>
public static class EnhancementRequestBuilder
{
    public static readonly TimeSpan RefineTimeout = TimeSpan.FromSeconds(8);
    public static readonly TimeSpan SuperRefineTimeout = TimeSpan.FromSeconds(20);

    public static BuildResult Make(
        string input,
        EnhancementPurpose purpose,
        EnhancementOverrides overrides,
        EnhancementSettingsSnapshot settings,
        string? clipboardContext = null,
        string? screenContext = null)
    {
        var prompt = ResolvePrompt(overrides.PromptId ?? settings.SelectedPromptId, settings.Prompts);
        if (prompt == null) return new(null, EnhancementUnavailable.PromptMissing);

        // Super Enhancement always runs on this PC with the strongest downloaded model — never a cloud API.
        var (provider, model) = prompt.Id == SuperEnhancement.Id
            ? (AIProviders.OnDevice, LocalLlm.LocalLlmCatalog.ResolveForSuper(settings.SuperModel)?.Id ?? LocalLlm.LocalLlmCatalog.DefaultId)
            : ResolveProviderAndModel(overrides, prompt, settings.Provider, settings.ModelForProvider);
        var (endpoint, reason) = settings.EndpointFor(provider, model);
        if (endpoint == null) return new(null, reason ?? EnhancementUnavailable.EndpointInvalid, provider);

        var timeout = purpose == EnhancementPurpose.Refine ? RefineTimeout : TimeSpan.FromSeconds(settings.TimeoutSeconds);
        if (endpoint.Kind == ProviderKind.LocalCli && purpose != EnhancementPurpose.Refine && endpoint.CommandTimeout is { } ct && ct > timeout)
            timeout = ct;
        // Super Enhancement reasons about the whole dictation: it gets a longer budget in both modes.
        if (prompt.Id == SuperEnhancement.Id)
            timeout = purpose == EnhancementPurpose.Refine ? SuperRefineTimeout : TimeSpan.FromSeconds(Math.Max(settings.TimeoutSeconds, 30));
        // On-device inference on a CPU is slower than a cloud call; give it room outside Refine.
        if (endpoint.Kind == ProviderKind.OnDevice && purpose != EnhancementPurpose.Refine && timeout < TimeSpan.FromSeconds(30))
            timeout = TimeSpan.FromSeconds(30);

        return new(new EnhancementRequest(
            purpose,
            input,
            SystemMessage(prompt, clipboardContext, screenContext, settings.CustomVocabulary),
            $"\n<TRANSCRIPT>\n{input}\n</TRANSCRIPT>",
            prompt.Id,
            prompt.Title,
            provider,
            model,
            endpoint,
            timeout,
            purpose != EnhancementPurpose.Refine && settings.RetriesOnTimeout,
            prompt.AllowsLanguageChange,
            prompt.AllowsLanguageChange ? 512 : TokenBudget(input)), null, provider);
    }

    public static CustomPrompt? ResolvePrompt(Guid? id, IReadOnlyList<CustomPrompt> prompts) =>
        prompts.FirstOrDefault(p => p.Id == id)
        ?? prompts.FirstOrDefault(p => p.Id == PredefinedPrompts.DefaultId)
        ?? prompts.FirstOrDefault();

    public static (string Provider, string Model) ResolveProviderAndModel(
        EnhancementOverrides overrides, CustomPrompt prompt, string globalProvider, Func<string, string> modelForProvider)
    {
        if (!string.IsNullOrEmpty(overrides.Provider))
            return (overrides.Provider, NonEmpty(overrides.Model) ?? modelForProvider(overrides.Provider));
        if (AIProviders.Find(prompt.ProviderOverride) is { } p)
            return (p.Name, NonEmpty(prompt.ModelOverride) ?? modelForProvider(p.Name));
        return (globalProvider, modelForProvider(globalProvider));
    }

    private static string? NonEmpty(string? s) => string.IsNullOrEmpty(s) ? null : s;

    public static int TokenBudget(string input) => Math.Min(512, Math.Max(64, input.Length / 3));

    public static string SystemMessage(CustomPrompt prompt, string? clipboard, string? screen, string customVocabulary)
    {
        var sections = "";
        if (!string.IsNullOrEmpty(clipboard))
            sections += $"\n\n<CLIPBOARD_CONTEXT>\n{clipboard}\n</CLIPBOARD_CONTEXT>";
        if (!string.IsNullOrEmpty(screen))
            sections += $"\n\n<CURRENT_WINDOW_CONTEXT>\n{screen}\n</CURRENT_WINDOW_CONTEXT>";
        if (!string.IsNullOrEmpty(customVocabulary))
            sections += "\n\nThe following are important vocabulary words, proper nouns, and technical terms. When these words or similar-sounding words appear in the <TRANSCRIPT>, ensure they are spelled EXACTLY as shown below:\n" +
                        $"<CUSTOM_VOCABULARY>\n{customVocabulary}\n</CUSTOM_VOCABULARY>";
        if (TechnicalTerminology.IsCodingPrompt(prompt.Id))
            sections += "\n\nThe Coding profile includes the following canonical terminology. Apply it only when\n" +
                        "pronunciation and surrounding context support the correction; ordinary words with a\n" +
                        "different meaning must remain ordinary words.\n" +
                        $"<BUILT_IN_TECHNICAL_VOCABULARY>\n{string.Join(", ", TechnicalTerminology.CanonicalTerms)}\n</BUILT_IN_TECHNICAL_VOCABULARY>\n\n" +
                        PromptTexts.TechnicalPhoneticGuidance;
        return prompt.FinalPromptText + sections;
    }

    /// <summary>"Important Vocabulary: a, b, c" (CustomVocabularyService), empty when there are no words.</summary>
    public static string VocabularyString(IEnumerable<string> words)
    {
        var list = words.Where(w => !string.IsNullOrWhiteSpace(w)).OrderBy(w => w, StringComparer.CurrentCultureIgnoreCase).ToList();
        return list.Count == 0 ? "" : "Important Vocabulary: " + string.Join(", ", list);
    }
}
