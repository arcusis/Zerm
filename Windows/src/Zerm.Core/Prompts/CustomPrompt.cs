namespace Zerm.Core.Prompts;

public sealed class CustomPrompt
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public string Title { get; set; } = "";
    public string PromptText { get; set; } = "";
    public string Icon { get; set; } = "doc.text.fill";
    public string? Description { get; set; }
    public bool IsPredefined { get; set; }
    public List<string> TriggerWords { get; set; } = [];
    public bool UseSystemInstructions { get; set; } = true;
    public string? ProviderOverride { get; set; }
    public string? ModelOverride { get; set; }
    public bool AllowsLanguageChange { get; set; }

    /// <summary>Prompt text wrapped in the system template when <see cref="UseSystemInstructions"/> is set.</summary>
    public string FinalPromptText =>
        UseSystemInstructions ? PromptTexts.CustomPromptTemplate.Replace("%@", PromptText) : PromptText;

    public CustomPrompt Clone()
    {
        var c = (CustomPrompt)MemberwiseClone();
        c.TriggerWords = [.. TriggerWords];
        return c;
    }
}

public static class PredefinedPrompts
{
    public static readonly Guid DefaultId = Guid.Parse("00000000-0000-0000-0000-000000000001");
    public static readonly Guid AssistantId = Guid.Parse("00000000-0000-0000-0000-000000000002");
    public static readonly Guid CodingId = Guid.Parse("00000000-0000-0000-0000-000000000003");
    public static readonly Guid ChatId = Guid.Parse("00000000-0000-0000-0000-000000000004");

    public static string Template(string title) => PromptTexts.Templates.First(t => t.Title == title).Text;

    public static IReadOnlyList<CustomPrompt> All =>
    [
        new()
        {
            Id = DefaultId, Title = "Default", PromptText = Template("System Default"), Icon = "checkmark.seal.fill",
            Description = "Default mode to improved clarity and accuracy of the transcription", IsPredefined = true,
        },
        new()
        {
            Id = AssistantId, Title = "Assistant", PromptText = PromptTexts.AssistantMode, Icon = "bubble.left.and.bubble.right.fill",
            Description = "AI assistant that provides direct answers to queries", IsPredefined = true,
            UseSystemInstructions = false, AllowsLanguageChange = true,
        },
        new()
        {
            Id = CodingId, Title = "Coding", PromptText = Template("Coding"), Icon = "curlybraces",
            Description = "Cleans dictated code and technical talk without writing or answering", IsPredefined = true,
        },
        new()
        {
            Id = ChatId, Title = "Chat", PromptText = Template("Chat"), Icon = "message.fill",
            Description = "Casual chat-style formatting for messages", IsPredefined = true,
        },
        SuperEnhancement.Prompt,
    ];

    /// <summary>
    /// Built-ins are always refreshed from source, keeping the user's trigger words and
    /// provider/model overrides (PredefinedPrompts.swift behaviour).
    /// </summary>
    public static List<CustomPrompt> Merge(IEnumerable<CustomPrompt> stored)
    {
        var list = stored.ToList();
        foreach (var builtIn in All)
        {
            var existing = list.FindIndex(p => p.Id == builtIn.Id);
            if (existing >= 0)
            {
                var old = list[existing];
                builtIn.TriggerWords = old.TriggerWords;
                builtIn.ProviderOverride = old.ProviderOverride;
                builtIn.ModelOverride = old.ProviderOverride == null ? null : old.ModelOverride;
                list[existing] = builtIn;
            }
            else
            {
                list.Insert(Math.Min(All.ToList().FindIndex(p => p.Id == builtIn.Id), list.Count), builtIn);
            }
        }
        return list;
    }
}

public static class TechnicalTerminology
{
    public static readonly IReadOnlyList<string> CanonicalTerms =
    [
        "API", "CLI", "SDK", "IDE", "HTTP", "HTTPS", "JSON", "YAML", "XML",
        "SQL", "NoSQL", "OAuth", "SSH", "TLS", "TCP", "UDP", "URL", "UUID",
        "Codex", "Claude", "Claude Code", "Gemini", "OpenAI", "Anthropic",
        "Git", "GitHub", "GitLab", "Docker", "Kubernetes", "kubectl", "Terraform",
        "DigitalOcean", "doctl", "Cloudflare", "AWS", "Azure", "Google Cloud",
        "Xcode", "Swift", "SwiftUI", "AppKit", "Core Audio", "AVFoundation",
        "macOS", "iOS", "Linux", "Homebrew", "Node.js", "npm", "pnpm",
        "Python", "NumPy", "PyTorch", "PostgreSQL", "Redis", "GraphQL", "REST",
        "gRPC", "webhook", "codec", "FFmpeg",
    ];

    public static bool IsCodingPrompt(Guid? id) => id == PredefinedPrompts.CodingId;
}
