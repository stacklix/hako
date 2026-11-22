using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Hako.Core;

namespace Hako.Platform;

internal static class HttpProxy
{
    internal const string Command = "action.network.http.proxy";
    internal const int RequestLimit = 512 * 1024;
    internal const int ResponseLimit = 8 * 1024 * 1024;
    private static readonly SemaphoreSlim Slots = new(4, 4);
    private static readonly HttpClient Client = new(new SocketsHttpHandler {
        AllowAutoRedirect = false, UseCookies = false, UseProxy = false,
        AutomaticDecompression = DecompressionMethods.All
    }) { Timeout = Timeout.InfiniteTimeSpan };
    private static readonly HashSet<string> HopHeaders = new(StringComparer.OrdinalIgnoreCase) {
        "Connection", "Keep-Alive", "Proxy-Authenticate", "Proxy-Authorization", "TE", "Trailer",
        "Transfer-Encoding", "Upgrade", "X-Proxy", "Host", "Content-Length"
    };
    private sealed record Input(string Url, string Target, string Method, Dictionary<string, string> Headers, string Body, int TimeoutMs);
    internal sealed record Output(int Status, Dictionary<string, string> Headers, string Body);

    internal static async Task<object?> SendAsync(JsonElement parameters, CancellationToken token)
    {
        if (!await Slots.WaitAsync(0, token)) throw new AgentActionException("agent_busy", "代理正在处理其他请求，请稍后重试。");
        try { return await ForwardAsync(parameters, token); }
        finally { Slots.Release(); }
    }

    private static async Task<object?> ForwardAsync(JsonElement parameters, CancellationToken token)
    {
        Input input;
        try { input = parameters.Deserialize<Input>(AgentConnection.Json) ?? throw new JsonException(); }
        catch (JsonException) { throw Invalid(); }
        if (!Uri.TryCreate(input.Url, UriKind.Absolute, out var original) || original.Scheme is not ("http" or "https") ||
            original.UserInfo.Length != 0 || input.Headers is null || input.Body is null ||
            string.IsNullOrEmpty(input.Method) || !input.Method.All(IsToken) || input.Method.ToUpperInvariant() is "CONNECT" or "TRACE" ||
            input.TimeoutMs is < 1 or > 8000) throw Invalid();
        // Accept an IP and an explicit port only; never a URL, path, userinfo or hostname.
        if (string.IsNullOrWhiteSpace(input.Target) || input.Target.Any(char.IsWhiteSpace) ||
            !Uri.TryCreate("http://" + input.Target, UriKind.Absolute, out var destination) ||
            destination.UserInfo.Length != 0 || destination.AbsolutePath != "/" || destination.Query.Length != 0 || destination.Fragment.Length != 0 ||
            !IPAddress.TryParse(destination.Host.Trim('[', ']'), out _) || destination.Port is < 1 or > 65535 ||
            !HasExplicitPort(input.Target)) throw Invalid();
        if (parameters.EnumerateObject().Any(p => p.Name is not ("url" or "target" or "method" or "headers" or "body" or "timeoutMs"))) throw Invalid();
        byte[] body;
        try { if (input.Body.Length > (RequestLimit + 2) / 3 * 4) throw Invalid(); body = Convert.FromBase64String(input.Body.Replace('-', '+').Replace('_', '/')); }
        catch (FormatException) { throw Invalid(); }
        if (body.Length > RequestLimit) throw new AgentActionException("request_too_large", "代理请求体不能超过 512 KiB。");
        var target = new UriBuilder(original) { Host = destination.Host, Port = destination.Port, Fragment = "" }.Uri;
        using var request = new HttpRequestMessage(new HttpMethod(input.Method), target) { Content = new ByteArrayContent(body) };
        var blocked = new HashSet<string>(HopHeaders, StringComparer.OrdinalIgnoreCase);
        foreach (var header in input.Headers.Where(h => h.Key.Equals("Connection", StringComparison.OrdinalIgnoreCase)))
            foreach (var name in header.Value.Split(',')) blocked.Add(name.Trim());
        var headerSize = 0;
        foreach (var (name, value) in input.Headers)
        {
            if (string.IsNullOrEmpty(name) || !name.All(IsToken) || value is null || value.Any(c => char.IsControl(c) && c != '\t')) throw Invalid();
            headerSize += System.Text.Encoding.UTF8.GetByteCount(name) + System.Text.Encoding.UTF8.GetByteCount(value);
            if (headerSize > 16 * 1024) throw Invalid();
            if (blocked.Contains(name)) continue;
            if (!request.Headers.TryAddWithoutValidation(name, value) && !request.Content.Headers.TryAddWithoutValidation(name, value)) throw Invalid();
        }
        using var budget = CancellationTokenSource.CreateLinkedTokenSource(token);
        budget.CancelAfter(input.TimeoutMs);
        try
        {
            using var response = await Client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, budget.Token);
            if (response.Content.Headers.ContentLength > ResponseLimit) throw TooLarge();
            await using var stream = await response.Content.ReadAsStreamAsync(budget.Token);
            using var data = new MemoryStream();
            var buffer = new byte[16384];
            int count;
            while ((count = await stream.ReadAsync(buffer, budget.Token)) != 0)
            {
                if (data.Length + count > ResponseLimit) throw TooLarge();
                data.Write(buffer, 0, count);
            }
            var responseBlocked = new HashSet<string>(HopHeaders, StringComparer.OrdinalIgnoreCase);
            foreach (var name in response.Headers.Connection) responseBlocked.Add(name);
            var headers = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            headerSize = 0;
            foreach (var header in response.Headers.Concat(response.Content.Headers))
            {
                if (responseBlocked.Contains(header.Key)) continue;
                var value = string.Join(header.Key.Equals("Set-Cookie", StringComparison.OrdinalIgnoreCase) ? "\n" : ", ", header.Value);
                headerSize += System.Text.Encoding.UTF8.GetByteCount(header.Key) + System.Text.Encoding.UTF8.GetByteCount(value);
                if (headerSize > 16 * 1024) throw TooLarge();
                headers[header.Key] = value;
            }
            headers["Content-Length"] = data.Length.ToString(System.Globalization.CultureInfo.InvariantCulture);
            return new Output((int)response.StatusCode, headers, EncodeBody(data.ToArray()));
        }
        catch (OperationCanceledException) when (!token.IsCancellationRequested)
        { throw new AgentActionException("proxy_timeout", "目标服务器响应超时；请求可能已执行，请先确认结果。"); }
        catch (HttpRequestException)
        { throw new AgentActionException("proxy_connect_failed", "Agent 无法连接目标服务器，或目标 HTTPS 证书校验失败。"); }
    }
    private static bool HasExplicitPort(string target)
    {
        var split = target.LastIndexOf(':');
        return split > 0 && target[(split + 1)..].Length > 0 && target[(split + 1)..].All(char.IsAsciiDigit);
    }
    internal static string EncodeBody(byte[] bytes) => Convert.ToBase64String(bytes).Replace('+', '-').Replace('/', '_');
    private static bool IsToken(char c) => char.IsAsciiLetterOrDigit(c) || "!#$%&'*+-.^_`|~".Contains(c);
    private static AgentActionException Invalid() => new("invalid_params", "代理请求无效；X-Proxy 必须为 IP:端口，IPv6 使用 [IP]:端口。");
    private static AgentActionException TooLarge() => new("result_too_large", "代理响应不能超过 8 MiB，响应头不能超过 16 KiB。");
}
