using System.Diagnostics;
using System.Text;
using System.Text.Json.Nodes;
using Zerm.Core.Net;

namespace Zerm.Core.Enhancement;

public interface ILocalLlm
{
    bool IsModelAvailable(string? modelPath);
    Task<string> GenerateAsync(string modelPath, string system, string user, int maxTokens, float temperature, CancellationToken ct);
}

/// <summary>Sends one enhancement request to whatever endpoint it resolved to.</summary>
public sealed class EnhancementClient(ILocalLlm? localLlm)
{
    public async Task<string> CompleteAsync(EnhancementRequest r, CancellationToken ct)
    {
        var e = r.Endpoint;
        return e.Kind switch
        {
            ProviderKind.OpenAICompatible or ProviderKind.Custom => await OpenAICompatible(r, e, ct),
            ProviderKind.Anthropic => await Anthropic(r, e, ct),
            ProviderKind.Ollama => await Ollama(r, e, ct),
            ProviderKind.LocalCli => await LocalCli(r, e, ct),
            ProviderKind.OnDevice => await (localLlm ?? throw new InvalidOperationException("On-device model is not available"))
                .GenerateAsync(e.ModelPath!, r.SystemMessage, r.UserMessage, r.MaxOutputTokens, 0.3f, ct),
            _ => throw new NotSupportedException(e.Kind.ToString()),
        };
    }

    private static async Task<string> OpenAICompatible(EnhancementRequest r, EnhancementEndpoint e, CancellationToken ct)
    {
        var body = new JsonObject
        {
            ["model"] = e.Model,
            ["messages"] = new JsonArray
            {
                new JsonObject { ["role"] = "system", ["content"] = r.SystemMessage },
                new JsonObject { ["role"] = "user", ["content"] = r.UserMessage },
            },
            ["temperature"] = e.Model.StartsWith("gpt-5") ? 1.0 : 0.3,
            ["stream"] = false,
        };
        if (AIProviders.ReasoningEffort(r.Provider, e.Model) is { } effort) body["reasoning_effort"] = effort;
        if (e.Model == "zai-glm-4.7") body["disable_reasoning"] = true;

        var req = Http.Json(HttpMethod.Post, e.Url!, body).Bearer(e.ApiKey);
        if (r.Provider == AIProviders.OpenRouter)
        {
            req.Header("HTTP-Referer", "https://arcusis.github.io/Zerm/");
            req.Header("X-Title", "Zerm");
        }
        var json = await Http.SendForJsonAsync(req, ct);
        return json["choices"]?[0]?["message"]?["content"]?.GetValue<string>() ?? "";
    }

    private static async Task<string> Anthropic(EnhancementRequest r, EnhancementEndpoint e, CancellationToken ct)
    {
        var body = new JsonObject
        {
            ["model"] = e.Model,
            ["max_tokens"] = Math.Max(1024, r.MaxOutputTokens),
            ["system"] = r.SystemMessage,
            ["messages"] = new JsonArray { new JsonObject { ["role"] = "user", ["content"] = r.UserMessage } },
            ["temperature"] = 0.3,
        };
        var req = Http.Json(HttpMethod.Post, e.Url!, body)
            .Header("x-api-key", e.ApiKey)
            .Header("anthropic-version", "2023-06-01");
        var json = await Http.SendForJsonAsync(req, ct);
        var sb = new StringBuilder();
        foreach (var block in json["content"]?.AsArray() ?? [])
            if (block?["type"]?.GetValue<string>() == "text") sb.Append(block["text"]?.GetValue<string>());
        return sb.ToString();
    }

    public static async Task<bool> OllamaReachable(string baseUrl, CancellationToken ct)
    {
        try
        {
            using var cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
            cts.CancelAfter(TimeSpan.FromSeconds(1.5));
            using var resp = await Http.Client.GetAsync(baseUrl.TrimEnd('/') + "/api/tags", cts.Token);
            return resp.IsSuccessStatusCode;
        }
        catch
        {
            return false;
        }
    }

    public static async Task<List<string>> OllamaModels(string baseUrl, CancellationToken ct)
    {
        var json = await Http.SendForJsonAsync(new HttpRequestMessage(HttpMethod.Get, baseUrl.TrimEnd('/') + "/api/tags"), ct);
        return json["models"]?.AsArray().Select(m => m?["name"]?.GetValue<string>() ?? "").Where(n => n.Length > 0).ToList() ?? [];
    }

    private static async Task<string> Ollama(EnhancementRequest r, EnhancementEndpoint e, CancellationToken ct)
    {
        if (!await OllamaReachable(e.Url!, ct))
            throw new ProviderUnreachableException(AIProviders.Ollama);
        var body = new JsonObject
        {
            ["model"] = e.Model,
            ["prompt"] = r.UserMessage,
            ["system"] = r.SystemMessage,
            ["stream"] = false,
            ["options"] = new JsonObject { ["temperature"] = 0.3 },
        };
        var json = await Http.SendForJsonAsync(Http.Json(HttpMethod.Post, e.Url!.TrimEnd('/') + "/api/generate", body), ct);
        return json["response"]?.GetValue<string>() ?? "";
    }

    /// <summary>
    /// Runs the user's command through cmd.exe. The full prompt is written to standard input (claude -p,
    /// codex exec -, ollama run … all read it from there) and is also available to scripts as
    /// ZERM_SYSTEM_PROMPT / ZERM_USER_PROMPT / ZERM_FULL_PROMPT (VOICEINK_* aliases kept for compatibility).
    /// The prompt is never expanded on the command line, where cmd would mangle quotes, &lt;, &gt; and newlines.
    /// </summary>
    public static async Task<string> LocalCli(EnhancementRequest r, EnhancementEndpoint e, CancellationToken ct)
    {
        if (string.IsNullOrWhiteSpace(e.Command)) throw new InvalidOperationException("Set up the Local CLI command in Enhancement settings.");
        var full = $"<SYSTEM_PROMPT>\n{r.SystemMessage}\n</SYSTEM_PROMPT>\n\n<USER_PROMPT>\n{r.UserMessage}\n</USER_PROMPT>";
        // /s: cmd strips only the outer quotes and runs the user's command line exactly as typed.
        var psi = new ProcessStartInfo("cmd.exe", "/d /s /c \"chcp 65001 >nul & " + e.Command + "\"")
        {
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true,
            StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8,
            StandardInputEncoding = new UTF8Encoding(false),
        };
        foreach (var prefix in new[] { "ZERM", "VOICEINK" })
        {
            psi.Environment[$"{prefix}_SYSTEM_PROMPT"] = r.SystemMessage;
            psi.Environment[$"{prefix}_USER_PROMPT"] = r.UserMessage;
            psi.Environment[$"{prefix}_FULL_PROMPT"] = full;
        }
        using var p = Process.Start(psi) ?? throw new InvalidOperationException("Could not start the command");
        await using (ct.Register(() => { try { p.Kill(entireProcessTree: true); } catch { } }))
        {
            var stdout = p.StandardOutput.ReadToEndAsync(ct);
            var stderr = p.StandardError.ReadToEndAsync(ct);
            try
            {
                await p.StandardInput.WriteAsync(full);
                p.StandardInput.Close();
            }
            catch (IOException) { }
            await p.WaitForExitAsync(ct);
            var output = (await stdout).Trim();
            var err = (await stderr).Trim();
            if (p.ExitCode == 9009 || err.Contains("is not recognized as an internal or external command"))
                throw new InvalidOperationException("The Local CLI command was not found.");
            if (p.ExitCode != 0) throw new InvalidOperationException($"The command exited with code {p.ExitCode}: {Http.Truncate(err, 200)}");
            if (output.Length == 0) throw new EmptyResponseException();
            return output;
        }
    }

    public static readonly IReadOnlyList<(string Name, string Command)> CliTemplates =
    [
        ("Claude Code", "claude -p --output-format text"),
        ("Codex", "codex exec --skip-git-repo-check -"),
        ("Ollama", "ollama run llama3.2"),
    ];
}

public sealed class ProviderUnreachableException(string provider) : Exception($"{provider} is not running or cannot be reached")
{
    public string Provider { get; } = provider;
}

public sealed class EmptyResponseException() : Exception("the AI returned no text");
