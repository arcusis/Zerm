using System.Net;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace Zerm.Core.Net;

public sealed class ApiException(HttpStatusCode? status, string message, string? body = null) : Exception(message)
{
    public HttpStatusCode? Status { get; } = status;
    public string? Body { get; } = body;

    public bool IsRetryable => Status is null
        || (int)Status.Value == 429
        || (int)Status.Value >= 500;
}

public static class Http
{
    /// <summary>One shared client; per-request timeouts are enforced with cancellation tokens.</summary>
    public static readonly HttpClient Client = CreateClient();

    private static HttpClient CreateClient()
    {
        var handler = new SocketsHttpHandler
        {
            PooledConnectionLifetime = TimeSpan.FromMinutes(5),
            AutomaticDecompression = DecompressionMethods.All,
        };
        var c = new HttpClient(handler) { Timeout = Timeout.InfiniteTimeSpan };
        c.DefaultRequestHeaders.UserAgent.ParseAdd("Zerm-Windows/1.0");
        return c;
    }

    public static async Task<string> SendForStringAsync(HttpRequestMessage request, CancellationToken ct)
    {
        using var response = await Client.SendAsync(request, ct).ConfigureAwait(false);
        var body = await response.Content.ReadAsStringAsync(ct).ConfigureAwait(false);
        if (!response.IsSuccessStatusCode)
            throw new ApiException(response.StatusCode, $"HTTP {(int)response.StatusCode}: {Truncate(ExtractError(body), 300)}", body);
        return body;
    }

    public static async Task<byte[]> SendForBytesAsync(HttpRequestMessage request, CancellationToken ct)
    {
        using var response = await Client.SendAsync(request, ct).ConfigureAwait(false);
        var bytes = await response.Content.ReadAsByteArrayAsync(ct).ConfigureAwait(false);
        if (!response.IsSuccessStatusCode)
        {
            var body = Encoding.UTF8.GetString(bytes);
            throw new ApiException(response.StatusCode, $"Provider error {(int)response.StatusCode}: {Truncate(body, 300)}", body);
        }
        return bytes;
    }

    public static async Task<JsonNode> SendForJsonAsync(HttpRequestMessage request, CancellationToken ct)
    {
        var body = await SendForStringAsync(request, ct).ConfigureAwait(false);
        try
        {
            return JsonNode.Parse(body) ?? throw new ApiException(null, "Empty response");
        }
        catch (JsonException)
        {
            throw new ApiException(null, "The provider returned an unreadable response.", body);
        }
    }

    /// <summary>Retries 429/5xx/network failures up to <paramref name="retries"/> times with 1 s, 2 s backoff.</summary>
    public static async Task<T> WithRetries<T>(Func<CancellationToken, Task<T>> action, CancellationToken ct, int retries = 2)
    {
        for (var attempt = 0; ; attempt++)
        {
            try
            {
                return await action(ct).ConfigureAwait(false);
            }
            catch (ApiException ex) when (attempt < retries && ex.IsRetryable && ex.Status != null)
            {
                await Task.Delay(TimeSpan.FromSeconds(attempt + 1), ct).ConfigureAwait(false);
            }
            catch (HttpRequestException) when (attempt < retries && !ct.IsCancellationRequested)
            {
                await Task.Delay(TimeSpan.FromSeconds(attempt + 1), ct).ConfigureAwait(false);
            }
        }
    }

    public static HttpRequestMessage Json(HttpMethod method, string url, object body)
    {
        var req = new HttpRequestMessage(method, url)
        {
            Content = new StringContent(JsonSerializer.Serialize(body), Encoding.UTF8, "application/json"),
        };
        return req;
    }

    public static HttpRequestMessage Bearer(this HttpRequestMessage req, string? key)
    {
        if (!string.IsNullOrEmpty(key)) req.Headers.Authorization = new AuthenticationHeaderValue("Bearer", key);
        return req;
    }

    public static HttpRequestMessage Header(this HttpRequestMessage req, string name, string? value)
    {
        if (value != null) req.Headers.TryAddWithoutValidation(name, value);
        return req;
    }

    public static string AudioMime(string path) => Path.GetExtension(path).ToLowerInvariant() switch
    {
        ".mp3" => "audio/mpeg",
        ".m4a" or ".mp4" => "audio/mp4",
        ".flac" => "audio/flac",
        ".ogg" or ".opus" => "audio/ogg",
        ".webm" => "audio/webm",
        _ => "audio/wav",
    };

    public static ByteArrayContent FileContent(byte[] bytes, string fileName)
    {
        var content = new ByteArrayContent(bytes);
        content.Headers.ContentType = new MediaTypeHeaderValue(AudioMime(fileName));
        return content;
    }

    public static string Truncate(string s, int max) => s.Length <= max ? s : s[..max] + "…";

    /// <summary>Pulls a human message out of common JSON error shapes.</summary>
    public static string ExtractError(string body)
    {
        try
        {
            var node = JsonNode.Parse(body);
            var msg = node?["error"]?["message"]?.GetValue<string>()
                      ?? (node?["error"] is JsonValue v ? v.ToString() : null)
                      ?? node?["message"]?.GetValue<string>()
                      ?? node?["detail"]?.ToString();
            if (!string.IsNullOrWhiteSpace(msg)) return msg;
        }
        catch { }
        return body;
    }
}
