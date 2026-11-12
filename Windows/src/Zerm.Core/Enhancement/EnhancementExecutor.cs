using System.Diagnostics;
using System.Net;
using Zerm.Core.Net;

namespace Zerm.Core.Enhancement;

public enum EnhancementOutcomeKind { Enhanced, Skipped, Failed, Rejected, Cancelled }

public enum EnhancementFailure { Timeout, Network, Server, RateLimited, EmptyResponse, ProviderUnreachable, Other }

public sealed record EnhancementOutcome(
    EnhancementOutcomeKind Kind,
    string? Text = null,
    EnhancementFailure? Failure = null,
    EnhancementRejection? Rejection = null,
    EnhancementUnavailable? Unavailable = null,
    string? Detail = null,
    TimeSpan Duration = default)
{
    public string ReasonCode => Kind switch
    {
        EnhancementOutcomeKind.Failed => Failure?.ToString() ?? "failed",
        EnhancementOutcomeKind.Rejected => Rejection?.ToString() ?? "rejected",
        EnhancementOutcomeKind.Skipped => Unavailable?.ToString() ?? Detail ?? "skipped",
        _ => Kind.ToString(),
    };
}

/// <summary>
/// Port of EnhancementExecutor.swift: up to 3 attempts; network/5xx/429 retry after 1 s then 2 s;
/// a timeout retries immediately only when the request allows it. Output is filtered and
/// checked by the language guard before it is accepted.
/// </summary>
public sealed class EnhancementExecutor(EnhancementClient client)
{
    public Func<EnhancementRequest, CancellationToken, Task<string>>? OverrideTransport { get; set; }

    public async Task<EnhancementOutcome> RunAsync(EnhancementRequest request, CancellationToken ct)
    {
        var sw = Stopwatch.StartNew();
        var timeoutRetried = false;
        for (var attempt = 0; attempt < 3; attempt++)
        {
            if (ct.IsCancellationRequested) return new(EnhancementOutcomeKind.Cancelled, Duration: sw.Elapsed);
            using var cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
            cts.CancelAfter(request.Timeout);
            try
            {
                var raw = OverrideTransport != null
                    ? await OverrideTransport(request, cts.Token)
                    : await client.CompleteAsync(request, cts.Token);
                var text = EnhancementOutputFilter.Filter(raw);
                if (text.Length == 0)
                    return new(EnhancementOutcomeKind.Failed, Failure: EnhancementFailure.EmptyResponse, Duration: sw.Elapsed);
                var rejection = EnhancementLanguageGuard.Rejection(request.InputText, text, request.MayChangeLanguage);
                if (rejection != null)
                    return new(EnhancementOutcomeKind.Rejected, Rejection: rejection, Detail: text, Duration: sw.Elapsed);
                return new(EnhancementOutcomeKind.Enhanced, text, Duration: sw.Elapsed);
            }
            catch (OperationCanceledException) when (ct.IsCancellationRequested)
            {
                return new(EnhancementOutcomeKind.Cancelled, Duration: sw.Elapsed);
            }
            catch (OperationCanceledException)
            {
                // Our own deadline fired.
                if (request.RetriesOnTimeout && !timeoutRetried)
                {
                    timeoutRetried = true;
                    Log.Warn($"Enhancement timed out after {request.Timeout.TotalSeconds}s; retrying once");
                    continue;
                }
                return new(EnhancementOutcomeKind.Failed, Failure: EnhancementFailure.Timeout, Duration: sw.Elapsed);
            }
            catch (Exception ex)
            {
                var failure = Classify(ex);
                Log.Warn($"Enhancement attempt {attempt + 1} failed: {failure} {ex.Message}");
                var retryable = failure is EnhancementFailure.Network or EnhancementFailure.Server or EnhancementFailure.RateLimited;
                if (retryable && attempt < 2)
                {
                    try { await Task.Delay(TimeSpan.FromSeconds(attempt + 1), ct); }
                    catch (OperationCanceledException) { return new(EnhancementOutcomeKind.Cancelled, Duration: sw.Elapsed); }
                    continue;
                }
                return new(EnhancementOutcomeKind.Failed, Failure: failure, Detail: Http.Truncate(ex.Message, 80), Duration: sw.Elapsed);
            }
        }
        return new(EnhancementOutcomeKind.Failed, Failure: EnhancementFailure.Other, Duration: sw.Elapsed);
    }

    public static EnhancementFailure Classify(Exception ex) => ex switch
    {
        ProviderUnreachableException => EnhancementFailure.ProviderUnreachable,
        EmptyResponseException => EnhancementFailure.EmptyResponse,
        ApiException { Status: HttpStatusCode.TooManyRequests } => EnhancementFailure.RateLimited,
        ApiException { Status: { } s } when (int)s >= 500 => EnhancementFailure.Server,
        ApiException => EnhancementFailure.Other,
        HttpRequestException => EnhancementFailure.Network,
        _ => EnhancementFailure.Other,
    };

    /// <summary>User-facing toast text (EnhancementNotifier.swift).</summary>
    public static string Describe(EnhancementOutcome o, string provider) => o.Kind switch
    {
        EnhancementOutcomeKind.Failed when o.Failure == EnhancementFailure.ProviderUnreachable =>
            $"Enhancement failed: {provider} is not running or cannot be reached. Your original text was kept.",
        EnhancementOutcomeKind.Failed when o.Failure == EnhancementFailure.Timeout =>
            "Enhancement timed out. Your original text was kept.",
        EnhancementOutcomeKind.Failed => $"Enhancement failed: {o.Failure switch
        {
            EnhancementFailure.EmptyResponse => "the AI returned no text",
            EnhancementFailure.Network => "no network connection",
            EnhancementFailure.Server => "the provider had a server error",
            EnhancementFailure.RateLimited => "the provider's rate limit was reached",
            _ => o.Detail ?? "unknown error",
        }}. Your original text was kept.",
        EnhancementOutcomeKind.Rejected =>
            "Enhancement discarded because it changed the language or the wording too much. Your original text was kept.",
        EnhancementOutcomeKind.Skipped => DescribeUnavailable(o.Unavailable, provider),
        _ => "",
    };

    public static string DescribeUnavailable(EnhancementUnavailable? reason, string provider) => reason switch
    {
        EnhancementUnavailable.OnDeviceModelMissing => "Enhancement skipped: download the on-device model in Enhancement settings.",
        EnhancementUnavailable.ApiKeyMissing => $"Enhancement skipped: add an API key for {provider} in Enhancement settings.",
        EnhancementUnavailable.ModelMissing => $"Enhancement skipped: choose a model for {provider} in Enhancement settings.",
        EnhancementUnavailable.EndpointInvalid => $"Enhancement skipped: check the server address for {provider} in Enhancement settings.",
        EnhancementUnavailable.CommandMissing => "Enhancement skipped: set up the Local CLI command in Enhancement settings.",
        EnhancementUnavailable.PromptMissing => "Enhancement skipped: no enhancement prompt is available.",
        _ => "Enhancement skipped.",
    };
}
