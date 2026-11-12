using System.Text.Json;
using System.Text.Json.Serialization;
using Zerm.Core.Models;
using Zerm.Core.Prompts;
using Zerm.Core.Settings;
using Zerm.Core.Text;

namespace Zerm.Core.Data;

public sealed class VocabularyWord
{
    public string Word { get; set; } = "";
    public DateTime DateAdded { get; set; } = DateTime.Now;
}

public sealed class WordReplacement
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public string OriginalText { get; set; } = "";
    public string ReplacementText { get; set; } = "";
    public DateTime DateAdded { get; set; } = DateTime.Now;
    public bool IsEnabled { get; set; } = true;
}

public sealed class PowerModeApp
{
    public Guid Id { get; set; } = Guid.NewGuid();
    /// <summary>Process executable name without extension, e.g. "chrome", "WINWORD" (the Windows counterpart of a bundle id).</summary>
    public string ProcessName { get; set; } = "";
    public string AppName { get; set; } = "";
}

public sealed class PowerModeUrl
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public string Url { get; set; } = "";
}

/// <summary>Port of PowerModeConfig: every override is optional — null means "use the global setting".</summary>
public sealed class PowerModeConfig
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public string Name { get; set; } = "";
    public string Emoji { get; set; } = "⚡";
    public List<PowerModeApp> AppConfigs { get; set; } = [];
    public List<PowerModeUrl> UrlConfigs { get; set; } = [];
    public string? SelectedTranscriptionModelName { get; set; }
    public string? SelectedLanguage { get; set; }
    public bool? TextFormatting { get; set; }
    public PunctuationCleanupMode? PunctuationCleanup { get; set; }
    public bool? Lowercase { get; set; }
    public DictationOutputMode? OutputMode { get; set; }
    public string? SelectedAIProvider { get; set; }
    public string? SelectedAIModel { get; set; }
    public Guid? SelectedPrompt { get; set; }
    public bool? ContextAwareness { get; set; }
    public AutoSendKey AutoSendKey { get; set; } = AutoSendKey.None;
    public bool IsDefault { get; set; }
    public bool IsEnabled { get; set; } = true;
    public KeyCombo? Hotkey { get; set; }

    public PowerModeConfig Clone()
    {
        var json = JsonSerializer.Serialize(this, Library.JsonOptions);
        return JsonSerializer.Deserialize<PowerModeConfig>(json, Library.JsonOptions)!;
    }

    /// <summary>Lowercase, strip scheme and "www." (PowerModeConfig.cleanURL).</summary>
    public static string CleanUrl(string url)
    {
        var s = url.Trim().ToLowerInvariant();
        foreach (var prefix in new[] { "https://", "http://" })
            if (s.StartsWith(prefix)) s = s[prefix.Length..];
        if (s.StartsWith("www.")) s = s[4..];
        return s.Trim();
    }
}

public sealed class CustomCloudModel
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public string DisplayName { get; set; } = "";
    public string Endpoint { get; set; } = "";
    public string ModelId { get; set; } = "";
    public bool IsMultilingual { get; set; } = true;
    public bool Verified { get; set; }

    public TranscriptionModel ToModel() => TranscriptionModelRegistry.CustomModel(Id, DisplayName, Endpoint, ModelId, IsMultilingual);
    public string ApiKeyId => $"customModel_{Id}_APIKey";
}

/// <summary>
/// The user's library (prompts, Power Modes, dictionary, custom models), saved as one JSON file.
/// Built-in prompts are refreshed from source on load.
/// </summary>
public sealed class Library
{
    public List<CustomPrompt> Prompts { get; set; } = [];
    public List<PowerModeConfig> PowerModes { get; set; } = [];
    public List<VocabularyWord> Vocabulary { get; set; } = [];
    public List<WordReplacement> Replacements { get; set; } = [];
    public List<CustomCloudModel> CustomModels { get; set; } = [];

    [JsonIgnore] public string? FilePath { get; private set; }
    public event Action? Changed;

    public static readonly JsonSerializerOptions JsonOptions = new()
    {
        WriteIndented = true,
        Converters = { new JsonStringEnumConverter() },
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
    };

    public static readonly Guid SeededGeneralId = Guid.Parse("5EED0000-0000-0000-0000-000000000001");

    public static Library Load(string? path = null)
    {
        path ??= AppPaths.DataFile;
        Library lib;
        try
        {
            lib = File.Exists(path) ? JsonSerializer.Deserialize<Library>(File.ReadAllText(path), JsonOptions) ?? new() : new();
        }
        catch (Exception ex)
        {
            Log.Error("Library unreadable; starting fresh", ex);
            try { File.Copy(path, path + ".corrupt", overwrite: true); } catch { }
            lib = new();
        }
        lib.FilePath = path;
        lib.Prompts = PredefinedPrompts.Merge(lib.Prompts ?? []);
        lib.PowerModes ??= [];
        lib.Vocabulary ??= [];
        lib.Replacements ??= [];
        lib.CustomModels ??= [];
        if (lib.PowerModes.Count == 0)
            lib.PowerModes.Add(new PowerModeConfig { Id = SeededGeneralId, Name = "General", Emoji = "⚡", IsDefault = true });
        return lib;
    }

    private readonly object _gate = new();

    public void Save()
    {
        if (FilePath == null) return;
        lock (_gate)
        {
            var tmp = FilePath + ".tmp";
            File.WriteAllText(tmp, JsonSerializer.Serialize(this, JsonOptions));
            File.Move(tmp, FilePath, overwrite: true);
        }
        Changed?.Invoke();
    }

    public IReadOnlyList<WordReplacementRule> ReplacementRules =>
        Replacements.Select(r => new WordReplacementRule(r.OriginalText, r.ReplacementText, r.IsEnabled)).ToList();

    public IEnumerable<TranscriptionModel> CustomTranscriptionModels => CustomModels.Select(c => c.ToModel());

    // MARK: - Dictionary operations (DictionaryService.swift)

    /// <summary>Adds comma-separated words; returns an error message for a single duplicate, else null.</summary>
    public string? AddVocabulary(string input)
    {
        var words = input.Split(',').Select(w => w.Trim()).Where(w => w.Length > 0).ToList();
        if (words.Count == 0) return null;
        var added = 0;
        foreach (var w in words)
        {
            if (Vocabulary.Any(v => string.Equals(v.Word, w, StringComparison.OrdinalIgnoreCase)))
            {
                if (words.Count == 1) return $"'{w}' is already in the vocabulary";
                continue;
            }
            Vocabulary.Add(new VocabularyWord { Word = w });
            added++;
        }
        if (added > 0) Save();
        return null;
    }

    /// <summary>Adds a replacement; returns an error if any trigger already exists.</summary>
    public string? AddReplacement(string original, string replacement, Guid? editing = null)
    {
        if (string.IsNullOrWhiteSpace(original) || string.IsNullOrWhiteSpace(replacement)) return "Both fields are required.";
        var tokens = original.Split(',').Select(t => t.Trim()).Where(t => t.Length > 0).ToList();
        foreach (var token in tokens)
        {
            var clash = Replacements.Where(r => r.Id != editing)
                .Any(r => r.OriginalText.Split(',').Select(t => t.Trim()).Any(t => string.Equals(t, token, StringComparison.OrdinalIgnoreCase)));
            if (clash) return $"'{token}' already exists in word replacements";
        }
        if (editing is { } id && Replacements.FirstOrDefault(r => r.Id == id) is { } existing)
        {
            existing.OriginalText = original.Trim();
            existing.ReplacementText = replacement;
        }
        else
        {
            Replacements.Add(new WordReplacement { OriginalText = original.Trim(), ReplacementText = replacement });
        }
        Save();
        return null;
    }

    /// <summary>Power Mode validation (PowerModeValidator.swift). Returns a list of problems.</summary>
    public List<string> Validate(PowerModeConfig mode)
    {
        var errors = new List<string>();
        if (string.IsNullOrWhiteSpace(mode.Name)) errors.Add("The name cannot be empty.");
        var others = PowerModes.Where(m => m.Id != mode.Id).ToList();
        if (others.Any(m => m.Name == mode.Name.Trim())) errors.Add($"A Power Mode named '{mode.Name}' already exists.");
        foreach (var app in mode.AppConfigs)
            if (others.FirstOrDefault(m => m.AppConfigs.Any(a => string.Equals(a.ProcessName, app.ProcessName, StringComparison.OrdinalIgnoreCase))) is { } owner)
                errors.Add($"{app.AppName} is already used by '{owner.Name}'.");
        foreach (var url in mode.UrlConfigs)
            if (others.FirstOrDefault(m => m.UrlConfigs.Any(u => u.Url == url.Url)) is { } owner)
                errors.Add($"{url.Url} is already used by '{owner.Name}'.");
        return errors;
    }

    public void SavePowerMode(PowerModeConfig mode)
    {
        if (mode.IsDefault)
            foreach (var m in PowerModes.Where(m => m.Id != mode.Id)) m.IsDefault = false;
        var i = PowerModes.FindIndex(m => m.Id == mode.Id);
        if (i >= 0) PowerModes[i] = mode;
        else PowerModes.Add(mode);
        Save();
    }

    /// <summary>
    /// Finds the active Power Mode: a URL match wins over an app match, which wins over the default
    /// (ActiveWindowService.resolveConfiguration).
    /// </summary>
    public PowerModeConfig? Resolve(string? processName, string? url)
    {
        var enabled = PowerModes.Where(m => m.IsEnabled).ToList();
        if (!string.IsNullOrEmpty(url))
        {
            var clean = PowerModeConfig.CleanUrl(url);
            var byUrl = enabled.FirstOrDefault(m => m.UrlConfigs.Any(u => u.Url.Length > 0 && clean.Contains(PowerModeConfig.CleanUrl(u.Url))));
            if (byUrl != null) return byUrl;
        }
        if (!string.IsNullOrEmpty(processName))
        {
            var byApp = enabled.FirstOrDefault(m => m.AppConfigs.Any(a => string.Equals(a.ProcessName, processName, StringComparison.OrdinalIgnoreCase)));
            if (byApp != null) return byApp;
        }
        return enabled.FirstOrDefault(m => m.IsDefault);
    }
}
