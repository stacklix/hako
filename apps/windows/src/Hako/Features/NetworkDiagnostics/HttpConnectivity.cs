using System;
using System.Diagnostics;
using System.Linq;
using System.Net.Http;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Hako.Core;

namespace Hako.Platform;

public sealed record HttpCheckResult(string Url, bool Reachable, bool HttpSuccess, int? StatusCode,
    long ElapsedMs, string CheckedAt, CapabilityError? Failure);

public sealed class HttpConnectivity
{
    private readonly HttpClient client;
    public HttpConnectivity(HttpMessageHandler? handler = null)
    {
        client = new HttpClient(handler ?? new SocketsHttpHandler
        {
            AllowAutoRedirect = false, UseCookies = false, Credentials = null,
            DefaultProxyCredentials = null, ConnectTimeout = TimeSpan.FromSeconds(5)
        }) { Timeout = Timeout.InfiniteTimeSpan };
    }

    public async Task<HttpCheckResult> CheckAsync(JsonElement parameters, CancellationToken token)
    {
        if (parameters.ValueKind != JsonValueKind.Object || parameters.EnumerateObject().Count() != 1 ||
            !parameters.TryGetProperty("url", out var value) || value.ValueKind != JsonValueKind.String)
            throw new AgentActionException("invalid_params", "请提供 url 参数。");
        var text = value.GetString()!;
        if (text.Length > 2048 || text.Any(char.IsControl) || text != text.Trim() ||
            !Uri.TryCreate(text, UriKind.Absolute, out var uri) ||
            (uri.Scheme != "http" && uri.Scheme != "https") || string.IsNullOrEmpty(uri.Host) || !string.IsNullOrEmpty(uri.UserInfo))
            throw new AgentActionException("invalid_params", "请输入不含用户名密码的完整 HTTP 或 HTTPS URL（最长 2048 字符）。");
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(token);
        timeout.CancelAfter(TimeSpan.FromSeconds(5));
        var elapsed = Stopwatch.StartNew();
        CapabilityError? failure;
        try
        {
            using var request = new HttpRequestMessage(HttpMethod.Get, uri);
            using var response = await client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, timeout.Token);
            return new(text, true, response.IsSuccessStatusCode, (int)response.StatusCode,
                elapsed.ElapsedMilliseconds, DateTimeOffset.UtcNow.ToString("O"), null);
        }
        catch (OperationCanceledException) when (!token.IsCancellationRequested)
        { failure = new("timeout", "检测超时（5 秒）。"); }
        catch (HttpRequestException e)
        {
            failure = e.HttpRequestError switch
            {
                HttpRequestError.NameResolutionError => new("dns_failed", "域名解析失败。"),
                HttpRequestError.ConnectionError => new("connect_failed", "无法连接目标地址。"),
                HttpRequestError.SecureConnectionError => new("tls_failed", "HTTPS 安全连接或证书校验失败。"),
                _ => new("request_failed", "未获得有效的 HTTP 响应。")
            };
        }
        return new(text, false, false, null, elapsed.ElapsedMilliseconds, DateTimeOffset.UtcNow.ToString("O"), failure);
    }
}
