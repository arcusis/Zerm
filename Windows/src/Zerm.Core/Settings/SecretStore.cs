using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace Zerm.Core.Settings;

/// <summary>
/// API keys, encrypted with Windows DPAPI (current user scope) — the Windows
/// counterpart of the macOS Keychain store in APIKeyManager.swift.
/// </summary>
public sealed class SecretStore
{
    private static readonly byte[] Entropy = Encoding.UTF8.GetBytes("com.arcusis.zerm");
    private readonly string _path;
    private readonly object _gate = new();
    private Dictionary<string, string> _values;

    public SecretStore(string? path = null)
    {
        _path = path ?? AppPaths.SecretsFile;
        _values = Load();
    }

    public event Action<string>? Changed;

    public string? Get(string key)
    {
        lock (_gate) return _values.TryGetValue(key, out var v) ? v : null;
    }

    public bool Has(string key) => !string.IsNullOrWhiteSpace(Get(key));

    public void Set(string key, string? value)
    {
        lock (_gate)
        {
            if (string.IsNullOrWhiteSpace(value)) _values.Remove(key);
            else _values[key] = value.Trim();
            Save();
        }
        Changed?.Invoke(key);
    }

    /// <summary>Key id naming matches APIKeyManager.swift (e.g. "groqAPIKey").</summary>
    public static string KeyId(string provider) => provider.ToLowerInvariant() switch
    {
        "groq" => "groqAPIKey",
        "deepgram" => "deepgramAPIKey",
        "gemini" => "geminiAPIKey",
        "mistral" => "mistralAPIKey",
        "elevenlabs" => "elevenLabsAPIKey",
        "soniox" => "sonioxAPIKey",
        "speechmatics" => "speechmaticsAPIKey",
        "xai" => "xaiAPIKey",
        "openai" => "openAIAPIKey",
        "assemblyai" => "assemblyAIAPIKey",
        "gladia" => "gladiaAPIKey",
        "anthropic" => "anthropicAPIKey",
        "openrouter" => "openRouterAPIKey",
        "cerebras" => "cerebrasAPIKey",
        var other => other + "APIKey",
    };

    public string? ApiKey(string provider) => Get(KeyId(provider));
    public void SetApiKey(string provider, string? value) => Set(KeyId(provider), value);

    private Dictionary<string, string> Load()
    {
        try
        {
            if (!File.Exists(_path)) return new();
            var plain = ProtectedData.Unprotect(File.ReadAllBytes(_path), Entropy, DataProtectionScope.CurrentUser);
            return JsonSerializer.Deserialize<Dictionary<string, string>>(plain) ?? new();
        }
        catch (Exception ex)
        {
            Log.Error("Could not read secrets", ex);
            return new();
        }
    }

    private void Save()
    {
        var plain = JsonSerializer.SerializeToUtf8Bytes(_values);
        var tmp = _path + ".tmp";
        File.WriteAllBytes(tmp, ProtectedData.Protect(plain, Entropy, DataProtectionScope.CurrentUser));
        File.Move(tmp, _path, overwrite: true);
    }
}
