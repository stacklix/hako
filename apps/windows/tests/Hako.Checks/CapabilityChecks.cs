using System;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Hako.Core;
using Hako.Platform;

internal static class CapabilityChecks
{
    private sealed class Handler(Func<HttpRequestMessage, CancellationToken, Task<HttpResponseMessage>> send) : HttpMessageHandler
    {
        public int Calls;
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token)
        { Calls++; return send(request, token); }
    }
    private sealed class UnreadBody : HttpContent
    {
        protected override Task SerializeToStreamAsync(Stream stream, TransportContext? context) => throw new Exception("Response body was read");
        protected override bool TryComputeLength(out long length) { length = 0; return false; }
    }
    public static async Task RunAsync()
    {
        // Aggregate checks must not scan the developer's live Codex logs under an
        // eight-second request budget. Use known input for both aggregate queries.
        var directory = Path.Combine(Path.GetTempPath(), "hako-capability-check-" + Guid.NewGuid().ToString("N"));
        var home = Path.Combine(directory, "codex");
        var sessions = Path.Combine(home, "sessions");
        Directory.CreateDirectory(sessions);
        try
        {
            var now = DateTimeOffset.Parse("2026-10-28T12:00:00Z");
            var path = Path.Combine(sessions, "test.jsonl");
            await File.WriteAllTextAsync(path, """
                {"timestamp":"2026-10-28T12:00:00Z","type":"response_item","payload":{"type":"message","role":"user","id":"test-human","internal_chat_message_metadata_passthrough":{"turn_id":"test-turn","content_item_kinds":["user.text"]}}}
                {"timestamp":"2026-10-28T12:00:00Z","type":"token_usage_record","payload":{"response_id":"test-response","turn_id":"test-turn","usage":{"input_tokens":100,"output_tokens":10,"total_tokens":110}}}
                """ + "\n");
            File.SetLastWriteTimeUtc(path, now.UtcDateTime);
            await using var codex = new CodexUsage(home, zone: TimeZoneInfo.Utc, clock: () => now);
            await RunAsync(new AgentDispatcher(new SystemMetrics(), codexUsage: codex), codex);

            // Missing local Codex data is a valid seven-day unavailable result.
            await using var missing = new CodexUsage(Path.Combine(directory, "missing"));
            using var empty = JsonDocument.Parse("{}");
            var data = (QueryData)(await new AgentDispatcher(new SystemMetrics(), codexUsage: missing)
                .InvokeAsync("query.all", 1, empty.RootElement, CancellationToken.None))!;
            var usage = data.Data["query.codex.usage"].Result?.Deserialize<CodexUsageSnapshot>(AgentConnection.Json);
            if (data.Data["query.system.metrics"].Error is not null || usage is not { Available: false, Days.Count: 7 }
                || usage.Days.Any(day => day.RequestCount != 0 || day.TotalTokens != 0))
                throw new Exception("Missing Codex logs must not break query.all or fabricate usage");
        }
        finally
        {
            if (!Path.GetFullPath(directory).StartsWith(Path.GetFullPath(Path.GetTempPath()) + "hako-capability-check-", StringComparison.OrdinalIgnoreCase))
                throw new Exception("Unsafe capability fixture cleanup path");
            Directory.Delete(directory, true);
        }
    }

    private static async Task RunAsync(AgentDispatcher real, CodexUsage codexUsage)
    {
        using var empty = JsonDocument.Parse("{}");
        var samples = 0;
        real.MetricsReceived += _ => samples++;
        var data = (QueryData)(await real.InvokeAsync("query.all", 1, empty.RootElement, CancellationToken.None))!;
        if (samples != 1)
            throw new Exception($"query.all must sample system metrics once; observed {samples}, error={data.Data["query.system.metrics"].Error?.Code}");
        if (data.Data.Count != 3 || data.Data["query.system.metrics"].Result?.Deserialize<Metrics>(AgentConnection.Json) is not Metrics
            || data.Data["query.network.listeners"].Result?.Deserialize<ListenerSnapshot>(AgentConnection.Json) is not ListenerSnapshot)
            throw new Exception("query.all did not return all three queries with system metrics and listeners");
        var usage = data.Data["query.codex.usage"].Result?.Deserialize<CodexUsageSnapshot>(AgentConnection.Json);
        if (usage is not { Available: true, Days.Count: 7 })
            throw new Exception($"query.all did not return seven Codex usage days; error={data.Data["query.codex.usage"].Error?.Code}");
        if (usage.Days.Sum(day => day.RequestCount) != 1 || usage.Days.Sum(day => day.TotalTokens) != 110)
            throw new Exception("query.all did not return the known fixture's user count and token usage");
        var json = JsonSerializer.SerializeToElement(data, AgentConnection.Json).GetProperty("data");
        if (json.GetProperty("query.system.metrics").TryGetProperty("error", out _) || json.TryGetProperty("action.network.http.check", out _))
            throw new Exception("Query result alternatives/actions are invalid");
        var nullResult = JsonSerializer.SerializeToElement(new CapabilityData(1, JsonSerializer.SerializeToElement<object?>(null)), AgentConnection.Json);
        if (nullResult.GetProperty("result").ValueKind != JsonValueKind.Null || nullResult.TryGetProperty("error", out _))
            throw new Exception("Null query result was lost");
        foreach (var method in new[] { "query.all", "query.system.metrics", "query.codex.usage", "query.network.listeners", "action.network.http.check" })
        {
            try { await real.InvokeAsync(method, 2, empty.RootElement, CancellationToken.None); throw new Exception("Unsupported version accepted"); }
            catch (AgentActionException e) when (e.Code == "unsupported_method") { }
        }
        using (var extra = JsonDocument.Parse("{\"path\":\"C:/other\"}"))
        {
            try { await real.InvokeAsync("query.codex.usage", 1, extra.RootElement, CancellationToken.None); throw new Exception("Codex query accepted arbitrary paths"); }
            catch (AgentActionException e) when (e.Code == "invalid_params") { }
        }
        foreach (var status in new[] { 200, 204, 301, 401, 404, 500 })
        {
            var handler = new Handler((request, _) =>
            {
                if (request.Method != HttpMethod.Get || request.Headers.Authorization != null)
                    throw new Exception("Incorrect probe request");
                return Task.FromResult(new HttpResponseMessage((HttpStatusCode)status) { Content = new UnreadBody() });
            });
            var probe = new HttpConnectivity(handler);
            using var parameters = JsonDocument.Parse("{\"url\":\"https://example.com/path?q=1\"}");
            var result = await probe.CheckAsync(parameters.RootElement, CancellationToken.None);
            if (!result.Reachable || result.StatusCode != status || result.HttpSuccess != (status < 300) || result.Failure != null || handler.Calls != 1)
                throw new Exception("HTTP status classification failed");
            var dispatcher = new AgentDispatcher(new SystemMetrics(), probe, codexUsage);
            await dispatcher.InvokeAsync("query.all", 1, empty.RootElement, CancellationToken.None);
            if (handler.Calls != 1) throw new Exception("query.all executed an action");
        }
        foreach (var (error, code) in new[] {
            (HttpRequestError.NameResolutionError, "dns_failed"), (HttpRequestError.ConnectionError, "connect_failed"),
            (HttpRequestError.SecureConnectionError, "tls_failed"), (HttpRequestError.InvalidResponse, "request_failed") })
        {
            var probe = new HttpConnectivity(new Handler((_, _) => throw new HttpRequestException(error)));
            using var parameters = JsonDocument.Parse("{\"url\":\"https://example.com/\"}");
            var result = await probe.CheckAsync(parameters.RootElement, CancellationToken.None);
            if (result.Reachable || result.HttpSuccess || result.StatusCode != null || result.Failure?.Code != code)
                throw new Exception("Network failure classification failed");
        }
        foreach (var url in new[] { "", "example.com", "ftp://example.com", "https://user:pass@example.com", "https://example.com/" + new string('x', 2048) })
        {
            using var parameters = JsonDocument.Parse(JsonSerializer.Serialize(new { url }));
            try { await new HttpConnectivity().CheckAsync(parameters.RootElement, CancellationToken.None); throw new Exception("Invalid URL accepted"); }
            catch (AgentActionException e) when (e.Code == "invalid_params") { }
        }
        using var valid = JsonDocument.Parse("{\"url\":\"http://localhost/\"}");
        var waiting = new HttpConnectivity(new Handler(async (_, token) => { await Task.Delay(Timeout.Infinite, token); return new HttpResponseMessage(); }));
        var timeout = await waiting.CheckAsync(valid.RootElement, CancellationToken.None);
        if (timeout.Failure?.Code != "timeout" || timeout.ElapsedMs < 4500 || timeout.ElapsedMs > 7000)
            throw new Exception("Probe timeout budget failed");
        using var cancellation = new CancellationTokenSource(); cancellation.Cancel();
        try { await waiting.CheckAsync(valid.RootElement, cancellation.Token); throw new Exception("Connection cancellation swallowed"); }
        catch (OperationCanceledException) { }
        Console.WriteLine("PASS: aggregate/single queries, exact versions, query/action separation, HTTP statuses, header-only response, URL validation, network errors and cancellation");
    }
}
