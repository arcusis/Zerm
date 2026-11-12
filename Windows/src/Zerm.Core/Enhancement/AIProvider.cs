namespace Zerm.Core.Enhancement;

public enum ProviderKind { OpenAICompatible, Anthropic, Ollama, LocalCli, OnDevice, Custom }

public sealed record AIProviderInfo(
    string Name,
    ProviderKind Kind,
    string? Endpoint,
    string DefaultModel,
    IReadOnlyList<string> Models,
    bool RequiresApiKey,
    string? KeyCheckUrl = null);

/// <summary>Enhancement providers and their models (AIService.swift).</summary>
public static class AIProviders
{
    public const string Cerebras = "Cerebras";
    public const string Groq = "Groq";
    public const string Gemini = "Gemini";
    public const string Anthropic = "Anthropic";
    public const string OpenAI = "OpenAI";
    public const string OpenRouter = "OpenRouter";
    public const string Mistral = "Mistral";
    public const string Ollama = "Ollama";
    public const string LocalCli = "Local CLI";
    public const string OnDevice = "On-Device";
    public const string Custom = "Custom";

    public static readonly IReadOnlyList<AIProviderInfo> All =
    [
        new(OnDevice, ProviderKind.OnDevice, null, "qwen3-4b-instruct", [], false),
        new(Ollama, ProviderKind.Ollama, null, "mistral", [], false),
        new(Cerebras, ProviderKind.OpenAICompatible, "https://api.cerebras.ai/v1/chat/completions", "gpt-oss-120b",
            ["gpt-oss-120b", "zai-glm-4.7"], true, "https://api.cerebras.ai/v1/models"),
        new(Groq, ProviderKind.OpenAICompatible, "https://api.groq.com/openai/v1/chat/completions", "openai/gpt-oss-120b",
            ["llama-3.1-8b-instant", "llama-3.3-70b-versatile", "qwen/qwen3-32b", "openai/gpt-oss-120b", "openai/gpt-oss-20b"], true,
            "https://api.groq.com/openai/v1/models"),
        new(Gemini, ProviderKind.OpenAICompatible, "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions", "gemini-2.5-flash-lite",
            ["gemini-3.5-flash", "gemini-3.1-pro-preview", "gemini-3-flash-preview", "gemini-3.1-flash-lite", "gemini-2.5-pro", "gemini-2.5-flash", "gemini-2.5-flash-lite"], true,
            "https://generativelanguage.googleapis.com/v1beta/openai/models"),
        new(Anthropic, ProviderKind.Anthropic, "https://api.anthropic.com/v1/messages", "claude-sonnet-4-6",
            ["claude-opus-4-7", "claude-opus-4-6", "claude-sonnet-4-6", "claude-opus-4-5", "claude-sonnet-4-5", "claude-haiku-4-5"], true,
            "https://api.anthropic.com/v1/models"),
        new(OpenAI, ProviderKind.OpenAICompatible, "https://api.openai.com/v1/chat/completions", "gpt-5.4",
            ["gpt-5.5", "gpt-5.4", "gpt-5.4-mini", "gpt-5.4-nano", "gpt-5.2", "gpt-4.1", "gpt-4.1-mini", "gpt-4.1-nano"], true,
            "https://api.openai.com/v1/models"),
        new(OpenRouter, ProviderKind.OpenAICompatible, "https://openrouter.ai/api/v1/chat/completions", "openai/gpt-oss-120b",
            [], true, "https://openrouter.ai/api/v1/key"),
        new(Mistral, ProviderKind.OpenAICompatible, "https://api.mistral.ai/v1/chat/completions", "mistral-large-latest",
            ["mistral-large-latest", "mistral-medium-latest", "mistral-small-latest"], true, "https://api.mistral.ai/v1/models"),
        new(LocalCli, ProviderKind.LocalCli, null, "local-cli", [], false),
        new(Custom, ProviderKind.Custom, null, "", [], false),
    ];

    public static AIProviderInfo? Find(string? name) => All.FirstOrDefault(p => p.Name == name);

    /// <summary>reasoning_effort per model (ReasoningConfig.swift).</summary>
    public static string? ReasoningEffort(string provider, string model)
    {
        string[] none = ["gemini-2.5-flash", "gemini-2.5-flash-lite", "gpt-5.5", "gpt-5.4", "gpt-5.4-mini", "gpt-5.4-nano", "gpt-5.2", "qwen/qwen3-32b"];
        string[] minimal = ["gemini-2.5-pro", "gemini-3.5-flash", "gemini-3.1-pro-preview", "gemini-3-flash-preview", "gemini-3.1-flash-lite", "gemini-3.1-flash-lite-preview", "gpt-5-mini", "gpt-5-nano"];
        if (none.Contains(model)) return "none";
        if (minimal.Contains(model)) return "minimal";
        if ((provider == Cerebras && model == "gpt-oss-120b") || (provider == Groq && model is "openai/gpt-oss-120b" or "openai/gpt-oss-20b"))
            return "low";
        return null;
    }
}
