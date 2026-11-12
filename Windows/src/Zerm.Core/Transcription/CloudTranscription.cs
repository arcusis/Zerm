using System.Net.Http.Headers;
using System.Text;
using System.Text.Json.Nodes;
using Zerm.Core.Models;
using Zerm.Core.Net;

namespace Zerm.Core.Transcription;

public sealed class NoTranscriptionReturnedException() : Exception("The provider returned no transcription.");

public sealed record CloudRequest(
    TranscriptionModel Model,
    string AudioPath,
    double DurationSeconds,
    string? Language,
    string? Prompt,
    IReadOnlyList<string> Vocabulary,
    string ApiKey,
    TimeSpan Timeout);

/// <summary>Port of Transcription/Cloud/*: one method per provider wire format.</summary>
public static class CloudTranscription
{
    public static TimeSpan EffectiveTimeout(int configuredSeconds, double durationSeconds) =>
        TimeSpan.FromSeconds(Math.Min(Math.Max(configuredSeconds, 30 + durationSeconds * 0.5), 3 * 3600));

    public static async Task<string> TranscribeAsync(CloudRequest r, CancellationToken ct)
    {
        using var cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
        cts.CancelAfter(r.Timeout);
        var token = cts.Token;
        var text = r.Model.Provider switch
        {
            ModelProvider.OpenAI => await OpenAI(r, token),
            ModelProvider.Groq => await OpenAICompatible(r, "https://api.groq.com/openai/v1/audio/transcriptions", r.Model.Name, token),
            ModelProvider.Custom => await OpenAICompatible(r, r.Model.CustomEndpoint!, r.Model.CustomModelId!, token),
            ModelProvider.ElevenLabs => await ElevenLabs(r, token),
            ModelProvider.Deepgram => await Deepgram(r, token),
            ModelProvider.Mistral => await Mistral(r, token),
            ModelProvider.XAI => await XAI(r, token),
            ModelProvider.Soniox => await Soniox(r, token),
            ModelProvider.AssemblyAI => await AssemblyAI(r, token),
            ModelProvider.Gladia => await Gladia(r, token),
            ModelProvider.Gemini => await Gemini(r, token),
            ModelProvider.Speechmatics => await Speechmatics(r, token),
            _ => throw new NotSupportedException($"{r.Model.Provider} is not a cloud provider"),
        };
        if (string.IsNullOrWhiteSpace(text)) throw new NoTranscriptionReturnedException();
        return text.Trim();
    }

    // MARK: - Vocabulary helpers (CloudVocabulary.swift)

    public static List<string> Terms(IEnumerable<string> vocabulary, int max = 100, int? maxChars = null, int? maxWords = null, string forbidden = "")
    {
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var list = new List<string>();
        foreach (var raw in vocabulary)
        {
            var t = raw.Trim();
            if (t.Length == 0 || t.Contains('\n') || t.IndexOfAny(forbidden.ToCharArray()) >= 0) continue;
            if (maxChars != null && t.Length > maxChars) continue;
            if (maxWords != null && t.Split(' ', StringSplitOptions.RemoveEmptyEntries).Length > maxWords) continue;
            if (seen.Add(t)) list.Add(t);
            if (list.Count >= max) break;
        }
        return list;
    }

    /// <summary>"&lt;style prompt (≤300)&gt; Vocabulary: a, b, c." capped at 300 characters.</summary>
    public static string WhisperPrompt(string? outputFormat, IEnumerable<string> vocabulary)
    {
        var p = (outputFormat ?? "").Trim();
        if (p.Length > 300) p = p[..300];
        var terms = Terms(vocabulary);
        if (terms.Count > 0)
        {
            var suffix = " Vocabulary: " + string.Join(", ", terms) + ".";
            p = (p + suffix).Trim();
        }
        return p.Length > 300 ? p[..300] : p;
    }

    private static async Task<byte[]> Bytes(CloudRequest r, CancellationToken ct) => await File.ReadAllBytesAsync(r.AudioPath, ct);

    private static MultipartFormDataContent Multipart() => new($"Boundary-{Guid.NewGuid()}");

    private static void Field(MultipartFormDataContent m, string name, string value) => m.Add(new StringContent(value), name);

    private static async Task<string> TextFrom(HttpRequestMessage req, CancellationToken ct, int retries = 2) =>
        (await Http.WithRetries(async t => await Http.SendForJsonAsync(await Clone(req), t), ct, retries))["text"]?.GetValue<string>() ?? "";

    // HttpRequestMessage can only be sent once; WithRetries needs a fresh copy per attempt.
    private static async Task<HttpRequestMessage> Clone(HttpRequestMessage req)
    {
        var clone = new HttpRequestMessage(req.Method, req.RequestUri);
        foreach (var h in req.Headers) clone.Headers.TryAddWithoutValidation(h.Key, h.Value);
        if (req.Content != null)
        {
            var bytes = await req.Content.ReadAsByteArrayAsync();
            clone.Content = new ByteArrayContent(bytes);
            foreach (var h in req.Content.Headers) clone.Content.Headers.TryAddWithoutValidation(h.Key, h.Value);
        }
        return clone;
    }

    // MARK: - Providers

    private static async Task<string> OpenAI(CloudRequest r, CancellationToken ct)
    {
        var m = Multipart();
        Field(m, "model", r.Model.Name);
        Field(m, "response_format", "json");
        if (r.Language != null) Field(m, "languages[]", r.Language);
        if (!string.IsNullOrWhiteSpace(r.Prompt)) Field(m, "prompt", r.Prompt);
        foreach (var t in Terms(r.Vocabulary, forbidden: "<>")) Field(m, "keywords[]", t);
        m.Add(Http.FileContent(await Bytes(r, ct), r.AudioPath), "file", Path.GetFileName(r.AudioPath));
        return await TextFrom(new HttpRequestMessage(HttpMethod.Post, "https://api.openai.com/v1/audio/transcriptions") { Content = m }.Bearer(r.ApiKey), ct);
    }

    private static async Task<string> OpenAICompatible(CloudRequest r, string endpoint, string model, CancellationToken ct)
    {
        var m = Multipart();
        Field(m, "model", model);
        Field(m, "response_format", "json");
        Field(m, "temperature", "0");
        if (r.Language != null) Field(m, "language", r.Language);
        var prompt = WhisperPrompt(r.Prompt, r.Vocabulary);
        if (prompt.Length > 0) Field(m, "prompt", prompt);
        m.Add(Http.FileContent(await Bytes(r, ct), r.AudioPath), "file", Path.GetFileName(r.AudioPath));
        var req = new HttpRequestMessage(HttpMethod.Post, endpoint) { Content = m }.Bearer(r.ApiKey);

        return await Http.WithRetries(async t =>
        {
            using var response = await Http.Client.SendAsync(await Clone(req), t);
            var body = await response.Content.ReadAsStringAsync(t);
            if (!response.IsSuccessStatusCode)
                throw new ApiException(response.StatusCode, $"HTTP {(int)response.StatusCode}: {Http.Truncate(Http.ExtractError(body), 300)}", body);
            var contentType = response.Content.Headers.ContentType?.MediaType ?? "";
            var trimmed = body.TrimStart();
            if (contentType.Contains("json") || trimmed.StartsWith('{'))
                return JsonNode.Parse(body)?["text"]?.GetValue<string>() ?? "";
            if (contentType.Contains("html") || trimmed.StartsWith('<'))
                throw new ApiException(response.StatusCode, "The endpoint returned an HTML page instead of a transcript. Check the URL.");
            return body;
        }, ct);
    }

    private static async Task<string> ElevenLabs(CloudRequest r, CancellationToken ct)
    {
        var m = Multipart();
        Field(m, "model_id", r.Model.Name);
        Field(m, "temperature", "0.0");
        Field(m, "tag_audio_events", "false");
        Field(m, "no_verbatim", "true");
        if (r.Language != null) Field(m, "language_code", r.Language);
        foreach (var t in Terms(r.Vocabulary, 100, 49, 5, "<>{}[]\\")) Field(m, "keyterms", t);
        m.Add(Http.FileContent(await Bytes(r, ct), r.AudioPath), "file", Path.GetFileName(r.AudioPath));
        var req = new HttpRequestMessage(HttpMethod.Post, "https://api.elevenlabs.io/v1/speech-to-text") { Content = m }
            .Header("xi-api-key", r.ApiKey).Header("Accept", "application/json");
        return await TextFrom(req, ct);
    }

    private static async Task<string> Deepgram(CloudRequest r, CancellationToken ct)
    {
        var q = new StringBuilder($"https://api.deepgram.com/v1/listen?model={r.Model.Name}&smart_format=true&punctuate=true&mip_opt_out=true");
        if (r.Model.Name == "nova-3") q.Append("&language=").Append(Uri.EscapeDataString(r.Language ?? "multi"));
        else if (r.Language != null) q.Append("&language=").Append(Uri.EscapeDataString(r.Language));
        var total = 0;
        foreach (var t in Terms(r.Vocabulary))
        {
            if ((total += t.Length) > 1500) break;
            q.Append("&keyterm=").Append(Uri.EscapeDataString(t));
        }
        var content = Http.FileContent(await Bytes(r, ct), r.AudioPath);
        var req = new HttpRequestMessage(HttpMethod.Post, q.ToString()) { Content = content }.Header("Authorization", "Token " + r.ApiKey);
        var json = await Http.WithRetries(async t => await Http.SendForJsonAsync(await Clone(req), t), ct);
        return json["results"]?["channels"]?[0]?["alternatives"]?[0]?["transcript"]?.GetValue<string>() ?? "";
    }

    private static async Task<string> Mistral(CloudRequest r, CancellationToken ct)
    {
        var m = Multipart();
        Field(m, "model", r.Model.Name);
        if (r.Language != null) Field(m, "language", r.Language);
        foreach (var t in Terms(r.Vocabulary)) Field(m, "context_bias", t);
        m.Add(Http.FileContent(await Bytes(r, ct), r.AudioPath), "file", Path.GetFileName(r.AudioPath));
        return await TextFrom(new HttpRequestMessage(HttpMethod.Post, "https://api.mistral.ai/v1/audio/transcriptions") { Content = m }.Bearer(r.ApiKey), ct);
    }

    private static async Task<string> XAI(CloudRequest r, CancellationToken ct)
    {
        var m = Multipart();
        if (r.Language != null)
        {
            Field(m, "language", r.Language);
            Field(m, "format", "true");
        }
        foreach (var t in Terms(r.Vocabulary, 100, 50)) Field(m, "keyterm", t);
        m.Add(Http.FileContent(await Bytes(r, ct), r.AudioPath), "file", Path.GetFileName(r.AudioPath));
        var req = new HttpRequestMessage(HttpMethod.Post, "https://api.x.ai/v1/stt") { Content = m }.Bearer(r.ApiKey).Header("Accept", "application/json");
        return await TextFrom(req, ct);
    }

    private static async Task<string> Soniox(CloudRequest r, CancellationToken ct)
    {
        const string b = "https://api.soniox.com/v1";
        var m = Multipart();
        m.Add(Http.FileContent(await Bytes(r, ct), r.AudioPath), "file", Path.GetFileName(r.AudioPath));
        var upload = await Http.SendForJsonAsync(new HttpRequestMessage(HttpMethod.Post, $"{b}/files") { Content = m }.Bearer(r.ApiKey), ct);
        var fileId = upload["id"]!.GetValue<string>();
        try
        {
            var body = new JsonObject
            {
                ["file_id"] = fileId,
                ["model"] = r.Model.Name,
                ["enable_language_identification"] = true,
            };
            if (r.Language != null) body["language_hints"] = new JsonArray(r.Language);
            var context = new JsonObject();
            if (!string.IsNullOrWhiteSpace(r.Prompt)) context["text"] = r.Prompt;
            var terms = Terms(r.Vocabulary);
            if (terms.Count > 0) context["terms"] = new JsonArray(terms.Select(t => (JsonNode)t!).ToArray());
            if (context.Count > 0) body["context"] = context;
            var job = await Http.SendForJsonAsync(Http.Json(HttpMethod.Post, $"{b}/transcriptions", body).Bearer(r.ApiKey), ct);
            var id = job["id"]!.GetValue<string>();
            while (true)
            {
                await Task.Delay(1000, ct);
                var status = await Http.SendForJsonAsync(new HttpRequestMessage(HttpMethod.Get, $"{b}/transcriptions/{id}").Bearer(r.ApiKey), ct);
                var s = status["status"]?.GetValue<string>();
                if (s == "completed") break;
                if (s == "error") throw new ApiException(null, status["error_message"]?.GetValue<string>() ?? "Soniox transcription failed");
            }
            var transcript = await Http.SendForJsonAsync(new HttpRequestMessage(HttpMethod.Get, $"{b}/transcriptions/{id}/transcript").Bearer(r.ApiKey), ct);
            return transcript["text"]?.GetValue<string>() ?? "";
        }
        finally
        {
            try { await Http.Client.SendAsync(new HttpRequestMessage(HttpMethod.Delete, $"{b}/files/{fileId}").Bearer(r.ApiKey), CancellationToken.None); } catch { }
        }
    }

    private static async Task<string> AssemblyAI(CloudRequest r, CancellationToken ct)
    {
        var content = new ByteArrayContent(await Bytes(r, ct));
        content.Headers.ContentType = new MediaTypeHeaderValue("application/octet-stream");
        var upload = await Http.SendForJsonAsync(new HttpRequestMessage(HttpMethod.Post, "https://api.assemblyai.com/v2/upload") { Content = content }
            .Header("authorization", r.ApiKey), ct);
        var body = new JsonObject
        {
            ["audio_url"] = upload["upload_url"]!.GetValue<string>(),
            ["speech_models"] = r.Model.Name == "universal-3-5-pro" ? new JsonArray("universal-3-5-pro", "universal-2") : new JsonArray(r.Model.Name),
        };
        if (r.Language != null) body["language_code"] = r.Language;
        else body["language_detection"] = true;
        var terms = Terms(r.Vocabulary, 100, null, 6);
        if (terms.Count > 0) body["keyterms_prompt"] = new JsonArray(terms.Select(t => (JsonNode)t!).ToArray());
        var job = await Http.SendForJsonAsync(Http.Json(HttpMethod.Post, "https://api.assemblyai.com/v2/transcript", body).Header("authorization", r.ApiKey), ct);
        var id = job["id"]!.GetValue<string>();
        while (true)
        {
            await Task.Delay(2000, ct);
            var status = await Http.SendForJsonAsync(new HttpRequestMessage(HttpMethod.Get, $"https://api.assemblyai.com/v2/transcript/{id}").Header("authorization", r.ApiKey), ct);
            var s = status["status"]?.GetValue<string>();
            if (s == "completed") return status["text"]?.GetValue<string>() ?? "";
            if (s == "error") throw new ApiException(null, status["error"]?.GetValue<string>() ?? "AssemblyAI transcription failed");
        }
    }

    private static async Task<string> Gladia(CloudRequest r, CancellationToken ct)
    {
        const string b = "https://api.gladia.io/v2";
        var m = Multipart();
        m.Add(Http.FileContent(await Bytes(r, ct), r.AudioPath), "audio", Path.GetFileName(r.AudioPath));
        var upload = await Http.SendForJsonAsync(new HttpRequestMessage(HttpMethod.Post, $"{b}/upload") { Content = m }.Header("x-gladia-key", r.ApiKey), ct);
        var body = new JsonObject
        {
            ["audio_url"] = upload["audio_url"]!.GetValue<string>(),
            ["model"] = r.Model.Name,
            ["language_config"] = r.Language != null
                ? new JsonObject { ["languages"] = new JsonArray(r.Language), ["code_switching"] = false }
                : new JsonObject { ["languages"] = new JsonArray(), ["code_switching"] = true },
        };
        var job = await Http.SendForJsonAsync(Http.Json(HttpMethod.Post, $"{b}/pre-recorded", body).Header("x-gladia-key", r.ApiKey), ct);
        var id = job["id"]!.GetValue<string>();
        try
        {
            while (true)
            {
                await Task.Delay(2000, ct);
                var status = await Http.SendForJsonAsync(new HttpRequestMessage(HttpMethod.Get, $"{b}/pre-recorded/{id}").Header("x-gladia-key", r.ApiKey), ct);
                var s = status["status"]?.GetValue<string>();
                if (s == "done") return status["result"]?["transcription"]?["full_transcript"]?.GetValue<string>() ?? "";
                if (s == "error") throw new ApiException(null, "Gladia transcription failed");
            }
        }
        finally
        {
            try { await Http.Client.SendAsync(new HttpRequestMessage(HttpMethod.Delete, $"{b}/pre-recorded/{id}").Header("x-gladia-key", r.ApiKey), CancellationToken.None); } catch { }
        }
    }

    private static async Task<string> Gemini(CloudRequest r, CancellationToken ct)
    {
        var instruction = new StringBuilder("Transcribe this audio verbatim. Output only the transcript text, with no timestamps, labels or commentary. Never translate: keep every word in the language it was spoken.");
        if (r.Language != null) instruction.Append($" The audio language is {Languages.DisplayName(r.Language)} ({r.Language}).");
        var terms = Terms(r.Vocabulary);
        if (terms.Count > 0) instruction.Append(" Spell these terms exactly when they occur: ").Append(string.Join(", ", terms)).Append('.');
        var body = new JsonObject
        {
            ["contents"] = new JsonArray(new JsonObject
            {
                ["parts"] = new JsonArray(
                    new JsonObject { ["text"] = instruction.ToString() },
                    new JsonObject { ["inline_data"] = new JsonObject { ["mime_type"] = Http.AudioMime(r.AudioPath), ["data"] = Convert.ToBase64String(await Bytes(r, ct)) } }),
            }),
            ["generationConfig"] = new JsonObject { ["temperature"] = 0 },
        };
        var url = $"https://generativelanguage.googleapis.com/v1beta/models/{r.Model.Name}:generateContent";
        var req = Http.Json(HttpMethod.Post, url, body).Header("x-goog-api-key", r.ApiKey);
        var json = await Http.WithRetries(async t => await Http.SendForJsonAsync(await Clone(req), t), ct);
        var sb = new StringBuilder();
        foreach (var part in json["candidates"]?[0]?["content"]?["parts"]?.AsArray() ?? [])
            sb.Append(part?["text"]?.GetValue<string>());
        return sb.ToString();
    }

    private static async Task<string> Speechmatics(CloudRequest r, CancellationToken ct)
    {
        const string b = "https://asr.api.speechmatics.com/v2";
        var config = new JsonObject
        {
            ["type"] = "transcription",
            ["transcription_config"] = new JsonObject
            {
                ["language"] = r.Language ?? "auto",
                ["operating_point"] = "enhanced",
            },
        };
        var terms = Terms(r.Vocabulary);
        if (terms.Count > 0)
            config["transcription_config"]!["additional_vocab"] = new JsonArray(terms.Select(t => (JsonNode)new JsonObject { ["content"] = t }).ToArray());
        if (r.Language == null) config["language_identification_config"] = new JsonObject();
        var m = Multipart();
        Field(m, "config", config.ToJsonString());
        m.Add(Http.FileContent(await Bytes(r, ct), r.AudioPath), "data_file", Path.GetFileName(r.AudioPath));
        var job = await Http.SendForJsonAsync(new HttpRequestMessage(HttpMethod.Post, $"{b}/jobs") { Content = m }.Bearer(r.ApiKey), ct);
        var id = job["id"]!.GetValue<string>();
        while (true)
        {
            await Task.Delay(1500, ct);
            var status = await Http.SendForJsonAsync(new HttpRequestMessage(HttpMethod.Get, $"{b}/jobs/{id}").Bearer(r.ApiKey), ct);
            var s = status["job"]?["status"]?.GetValue<string>();
            if (s == "done") break;
            if (s is "rejected" or "deleted" or "expired") throw new ApiException(null, $"Speechmatics job {s}");
        }
        return await Http.SendForStringAsync(new HttpRequestMessage(HttpMethod.Get, $"{b}/jobs/{id}/transcript?format=txt").Bearer(r.ApiKey), ct);
    }

    // MARK: - Key verification

    public static async Task<(bool Ok, string Message)> VerifyKeyAsync(ModelProvider provider, string key, CancellationToken ct)
    {
        var (url, configure) = provider switch
        {
            ModelProvider.OpenAI => ("https://api.openai.com/v1/models", (Action<HttpRequestMessage>)(r => r.Bearer(key))),
            ModelProvider.Groq => ("https://api.groq.com/openai/v1/models", r => r.Bearer(key)),
            ModelProvider.ElevenLabs => ("https://api.elevenlabs.io/v1/user", r => r.Header("xi-api-key", key)),
            ModelProvider.Deepgram => ("https://api.deepgram.com/v1/projects", r => r.Header("Authorization", "Token " + key)),
            ModelProvider.Mistral => ("https://api.mistral.ai/v1/models", r => r.Bearer(key)),
            ModelProvider.XAI => ("https://api.x.ai/v1/api-key", r => r.Bearer(key)),
            ModelProvider.Soniox => ("https://api.soniox.com/v1/files", r => r.Bearer(key)),
            ModelProvider.AssemblyAI => ("https://api.assemblyai.com/v2/transcript?limit=1", r => r.Header("authorization", key)),
            ModelProvider.Gladia => ("https://api.gladia.io/v2/pre-recorded?limit=1", r => r.Header("x-gladia-key", key)),
            ModelProvider.Gemini => ("https://generativelanguage.googleapis.com/v1beta/models", r => r.Header("x-goog-api-key", key)),
            ModelProvider.Speechmatics => ("https://asr.api.speechmatics.com/v2/jobs?limit=1", r => r.Bearer(key)),
            _ => (null, null),
        };
        if (url == null || configure == null) return (true, "");
        return await VerifyGet(url, configure, ct);
    }

    public static async Task<(bool Ok, string Message)> VerifyGet(string url, Action<HttpRequestMessage> configure, CancellationToken ct)
    {
        try
        {
            using var cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
            cts.CancelAfter(TimeSpan.FromSeconds(15));
            var req = new HttpRequestMessage(HttpMethod.Get, url);
            configure(req);
            using var resp = await Http.Client.SendAsync(req, cts.Token);
            if (resp.IsSuccessStatusCode) return (true, "Key verified");
            var body = await resp.Content.ReadAsStringAsync(cts.Token);
            return (false, $"HTTP {(int)resp.StatusCode}: {Http.Truncate(Http.ExtractError(body), 160)}");
        }
        catch (OperationCanceledException) when (!ct.IsCancellationRequested)
        {
            return (false, "The request timed out.");
        }
        catch (Exception ex)
        {
            return (false, ex.Message);
        }
    }

    /// <summary>Verifies a custom OpenAI-compatible endpoint by posting a 1 s 440 Hz tone (CustomModel verification).</summary>
    public static async Task<(bool Ok, string Message)> VerifyCustomEndpointAsync(string endpoint, string modelId, string? key, CancellationToken ct)
    {
        var path = Path.Combine(Path.GetTempPath(), "zerm-verify.wav");
        var tone = new float[Audio.AudioUtil.SampleRate];
        for (var i = 0; i < tone.Length; i++) tone[i] = (float)(1000.0 / 32767 * Math.Sin(2 * Math.PI * 440 * i / Audio.AudioUtil.SampleRate));
        Audio.AudioUtil.WriteWav16k(path, tone);
        try
        {
            var model = TranscriptionModelRegistry.CustomModel(Guid.Empty, "verify", endpoint, modelId);
            await OpenAICompatible(new CloudRequest(model, path, 1, null, null, [], key ?? "", TimeSpan.FromSeconds(30)), endpoint, modelId, ct);
            return (true, "Endpoint verified");
        }
        catch (ApiException ex)
        {
            var code = (int?)ex.Status;
            return (false, code switch
            {
                401 or 403 => "Unauthorized — check the API key.",
                404 or 405 => "Not found — check the endpoint URL.",
                415 => "The endpoint rejected the audio format.",
                429 => "Rate limited — try again shortly.",
                >= 500 => "The server had an error.",
                _ => ex.Message,
            });
        }
        catch (Exception ex)
        {
            return (false, ex.Message);
        }
        finally
        {
            try { File.Delete(path); } catch { }
        }
    }
}
