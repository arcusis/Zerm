using Zerm.Core.Data;
using Zerm.Core.LocalLlm;
using Zerm.Core.Settings;

namespace Zerm.Core.Enhancement;

/// <summary>Glue between settings, the library, API keys and the executor (AIEnhancementService.swift).</summary>
public sealed class EnhancementService(AppSettings settings, Library library, SecretStore secrets, ILocalLlm localLlm)
{
    private readonly EnhancementExecutor _executor = new(new EnhancementClient(localLlm));
    private readonly HashSet<string> _reportedSetupProblems = [];
    private readonly Dictionary<string, DateTime> _lastFailureReport = new();

    public EnhancementExecutor Executor => _executor;

    public string ModelFor(string provider)
    {
        var info = AIProviders.Find(provider);
        return provider switch
        {
            AIProviders.OnDevice => settings.ModelFor(provider) ?? LocalLlmCatalog.DefaultId,
            AIProviders.Ollama => settings.OllamaSelectedModel,
            AIProviders.Custom => settings.CustomProviderModel,
            AIProviders.LocalCli => "local-cli",
            AIProviders.OpenRouter => settings.ModelFor(provider) ?? info!.DefaultModel,
            _ => settings.ModelFor(provider) is { } m && (info == null || info.Models.Count == 0 || info.Models.Contains(m)) ? m : info?.DefaultModel ?? "",
        };
    }

    public (EnhancementEndpoint? Endpoint, EnhancementUnavailable? Reason) EndpointFor(string provider, string model)
    {
        var info = AIProviders.Find(provider);
        if (info == null) return (null, EnhancementUnavailable.EndpointInvalid);
        switch (info.Kind)
        {
            case ProviderKind.OnDevice:
                var package = LocalLlmCatalog.ResolveForEnhancement(model);
                return package == null
                    ? (null, EnhancementUnavailable.OnDeviceModelMissing)
                    : (new EnhancementEndpoint(ProviderKind.OnDevice, Model: package.Id, ModelPath: LocalLlmCatalog.PathFor(package)), null);
            case ProviderKind.Ollama:
                if (!Uri.TryCreate(settings.OllamaBaseUrl, UriKind.Absolute, out _)) return (null, EnhancementUnavailable.EndpointInvalid);
                if (string.IsNullOrWhiteSpace(model)) return (null, EnhancementUnavailable.ModelMissing);
                return (new EnhancementEndpoint(ProviderKind.Ollama, settings.OllamaBaseUrl, Model: model), null);
            case ProviderKind.LocalCli:
                return string.IsNullOrWhiteSpace(settings.LocalCliCommand)
                    ? (null, EnhancementUnavailable.CommandMissing)
                    : (new EnhancementEndpoint(ProviderKind.LocalCli, Model: "local-cli", Command: settings.LocalCliCommand,
                        CommandTimeout: TimeSpan.FromSeconds(Math.Max(5, settings.LocalCliTimeoutSeconds))), null);
            case ProviderKind.Custom:
                var url = settings.CustomProviderBaseUrl.Trim();
                if (!Uri.TryCreate(url, UriKind.Absolute, out var uri) || (uri.Scheme != "http" && uri.Scheme != "https"))
                    return (null, EnhancementUnavailable.EndpointInvalid);
                if (string.IsNullOrWhiteSpace(model)) return (null, EnhancementUnavailable.ModelMissing);
                if (!url.EndsWith("/chat/completions")) url = url.TrimEnd('/') + "/chat/completions";
                return (new EnhancementEndpoint(ProviderKind.Custom, url, secrets.ApiKey(AIProviders.Custom), model), null);
            default:
                var key = secrets.ApiKey(provider);
                if (string.IsNullOrWhiteSpace(key)) return (null, EnhancementUnavailable.ApiKeyMissing);
                if (string.IsNullOrWhiteSpace(model)) return (null, EnhancementUnavailable.ModelMissing);
                return (new EnhancementEndpoint(info.Kind, info.Endpoint, key, model), null);
        }
    }

    public bool IsConfigured(string provider) => EndpointFor(provider, ModelFor(provider)).Endpoint != null;

    public EnhancementSettingsSnapshot Snapshot() => new()
    {
        Prompts = library.Prompts,
        SelectedPromptId = settings.SuperEnhancement ? Prompts.SuperEnhancement.Id : settings.SelectedPromptId,
        Provider = settings.SelectedAIProvider,
        ModelForProvider = ModelFor,
        EndpointFor = EndpointFor,
        CustomVocabulary = EnhancementRequestBuilder.VocabularyString(library.Vocabulary.Select(v => v.Word)),
        TimeoutSeconds = settings.EnhancementTimeoutSeconds,
        RetriesOnTimeout = settings.EnhancementRetryOnTimeout,
        SuperModel = settings.SuperEnhancementModel,
    };

    public BuildResult Build(string input, EnhancementPurpose purpose, EnhancementOverrides overrides, string? clipboard = null, string? screen = null) =>
        EnhancementRequestBuilder.Make(input, purpose, overrides, Snapshot(), clipboard, screen);

    public Task<EnhancementOutcome> RunAsync(EnhancementRequest request, CancellationToken ct) =>
        request.PromptId == Prompts.SuperEnhancement.Id ? Prompts.SuperEnhancement.RunAsync(_executor, request, ct) : _executor.RunAsync(request, ct);

    /// <summary>
    /// Whether a notification for this outcome should be shown (EnhancementNotifier): setup problems once per
    /// launch per reason; other failures at most once every 120 s per kind; manual runs always report.
    /// </summary>
    public bool ShouldReport(EnhancementOutcome outcome, bool manual)
    {
        if (manual) return true;
        if (outcome.Kind is EnhancementOutcomeKind.Enhanced or EnhancementOutcomeKind.Cancelled) return false;
        if (outcome.Kind == EnhancementOutcomeKind.Skipped)
        {
            if (outcome.Unavailable == null) return false; // short-input skips are silent
            return _reportedSetupProblems.Add(outcome.Unavailable.ToString()!);
        }
        var kind = outcome.ReasonCode;
        if (_lastFailureReport.TryGetValue(kind, out var last) && DateTime.Now - last < TimeSpan.FromSeconds(120)) return false;
        _lastFailureReport[kind] = DateTime.Now;
        return true;
    }
}
