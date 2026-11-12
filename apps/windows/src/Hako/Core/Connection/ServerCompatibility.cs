using System;
using System.Net;
using System.Net.Http;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;

namespace Hako.Core;

internal static class ServerCompatibility
{
    private const string MinimumServerVersion = "0.3.1";
    private const string InvalidMetadata = "服务端返回的版本信息无效，请检查 Hako 服务端版本。";
    private static readonly string AgentVersion = typeof(AgentConnection).Assembly.GetName().Version!.ToString(3);
    private static readonly HttpClient Client = new(new SocketsHttpHandler
    {
        AllowAutoRedirect = false,
        UseCookies = false
    })
    {
        Timeout = TimeSpan.FromSeconds(5),
        MaxResponseContentBufferSize = 8192
    };

    private sealed record Versions(string? ServerVersion, string? MinimumAgentVersion);

    public static async Task<string?> CheckAsync(Uri origin, CancellationToken token)
    {
        using var response = await Client.GetAsync(new Uri(origin, "/api/v1/version"), token);
        if (response.StatusCode is HttpStatusCode.NotFound or HttpStatusCode.MethodNotAllowed)
            return $"服务端未提供版本信息，请确认服务器地址并检查是否已升级到 Hako 服务端 {MinimumServerVersion} 或更高版本。";
        if (response.StatusCode != HttpStatusCode.OK)
            throw new HttpRequestException("无法获取 Hako 服务端版本信息。", null, response.StatusCode);
        var body = await response.Content.ReadAsByteArrayAsync(token);
        return WarningFor(body, AgentVersion);
    }

    internal static string? WarningFor(ReadOnlySpan<byte> json, string agentVersion)
    {
        Versions? versions;
        try { versions = JsonSerializer.Deserialize<Versions>(json, JsonSerializerOptions.Web); }
        catch (JsonException) { return InvalidMetadata; }
        if (versions is null || Parse(versions.ServerVersion) is not Version server ||
            Parse(versions.MinimumAgentVersion) is not Version minimumAgent)
            return InvalidMetadata;
        if (Parse(agentVersion) is not Version agent)
            return "无法读取 Hako Agent 版本，请重新安装 Hako。";

        var agentWarning = Mismatch(agent, minimumAgent, "Hako Agent", "服务端");
        var serverWarning = Mismatch(server, Version.Parse(MinimumServerVersion), "服务端", "Hako Agent");
        return agentWarning is not null && serverWarning is not null
            ? agentWarning + "\n\n" + serverWarning
            : agentWarning ?? serverWarning;
    }

    private static string? Mismatch(Version current, Version minimum, string component, string requiredBy)
    {
        var line = $"{minimum.Major}.{minimum.Minor}.x";
        if (current < minimum)
            return $"{component} 当前为 {current}，{requiredBy} 要求 {line} 版本且至少为 {minimum}。请升级 {component}。";
        if (current.Major != minimum.Major || current.Minor != minimum.Minor)
            return $"{component} 当前为 {current}，超出了 {requiredBy} 支持的 {line} 版本。请升级 {requiredBy}。";
        return null;
    }

    private static Version? Parse(string? text) =>
        text is not null && Regex.IsMatch(text, @"\A[0-9]+\.[0-9]+\.[0-9]+\z") &&
        Version.TryParse(text, out var version) ? version : null;
}
