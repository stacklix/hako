using System;
using System.IO;
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
    public static async Task RunAsync(AgentDispatcher real)
    {
        using var empty = JsonDocument.Parse("{}");
        var samples = 0;
        real.MetricsReceived += _ => samples++;
        var data = (QueryData)(await real.InvokeAsync("query.all", 1, empty.RootElement, CancellationToken.None))!;
        if (samples != 1 || data.Data.Count != 1 || data.Data["query.system.metrics"].Result?.Deserialize<Metrics>(AgentConnection.Json) is not Metrics)
            throw new Exception("query.all must sample system metrics once");
        var json = JsonSerializer.SerializeToElement(data, AgentConnection.Json).GetProperty("data");
        if (json.GetProperty("query.system.metrics").TryGetProperty("error", out _) || json.TryGetProperty("action.network.http.check", out _))
            throw new Exception("Query result alternatives/actions are invalid");
        var nullResult = JsonSerializer.SerializeToElement(new CapabilityData(1, JsonSerializer.SerializeToElement<object?>(null)), AgentConnection.Json);
        if (nullResult.GetProperty("result").ValueKind != JsonValueKind.Null || nullResult.TryGetProperty("error", out _))
            throw new Exception("Null query result was lost");
        foreach (var method in new[] { "query.all", "query.system.metrics", "action.network.http.check" })
        {
            try { await real.InvokeAsync(method, 2, empty.RootElement, CancellationToken.None); throw new Exception("Unsupported version accepted"); }
            catch (AgentActionException e) when (e.Code == "unsupported_method") { }
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
            var dispatcher = new AgentDispatcher(new SystemMetrics(), probe);
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
