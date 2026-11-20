using System;
using System.IO;
using System.Net;
using System.Net.Http;
using System.Security.Cryptography;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace Hako.Core;

internal interface IAgentUpdateSource
{
    Task<AgentUpdateCandidate?> LatestAsync(CancellationToken token);
}

internal sealed record GitHubAgentRelease(string Version, long BuildId, string Sha256, long Size,
    DateTimeOffset PublishedAt, string ExecutableUrl);

internal sealed class GitHubAgentUpdates(string repository, string cache, HttpMessageHandler? handler = null) : IAgentUpdateSource, IDisposable
{
    private readonly HttpClient http = CreateClient(handler);
    private static HttpClient CreateClient(HttpMessageHandler? handler)
    {
        var client = handler is null ? new HttpClient() : new HttpClient(handler);
        client.Timeout = TimeSpan.FromMinutes(5);
        client.MaxResponseContentBufferSize = 2 * 1024 * 1024;
        client.DefaultRequestHeaders.UserAgent.ParseAdd("Kage-Agent-Guardian/1.0");
        client.DefaultRequestHeaders.Accept.ParseAdd("application/vnd.github+json");
        return client;
    }
    internal async Task<GitHubAgentRelease?> LatestReleaseAsync(CancellationToken token)
    {
        using var response = await http.GetAsync($"https://api.github.com/repos/{repository}/releases?per_page=30", token);
        response.EnsureSuccessStatusCode();
        using var releases = JsonDocument.Parse(await response.Content.ReadAsByteArrayAsync(token));
        foreach (var release in releases.RootElement.EnumerateArray())
        {
            var tag = release.GetProperty("tag_name").GetString() ?? "";
            if (!tag.StartsWith("windows-agent-", StringComparison.Ordinal) || release.GetProperty("draft").GetBoolean() || release.GetProperty("prerelease").GetBoolean()) continue;
            string? manifestUrl = null, executableUrl = null;
            foreach (var asset in release.GetProperty("assets").EnumerateArray())
            {
                var name = asset.GetProperty("name").GetString();
                if (name == "agent-update.json") manifestUrl = asset.GetProperty("browser_download_url").GetString();
                if (name == "Kage.exe") executableUrl = asset.GetProperty("browser_download_url").GetString();
            }
            if (manifestUrl is null || executableUrl is null) continue;
            ValidateAsset(manifestUrl, tag); ValidateAsset(executableUrl, tag);
            var manifest = await http.GetByteArrayAsync(manifestUrl, token);
            using var document = JsonDocument.Parse(manifest);
            var data = document.RootElement;
            var hash = data.GetProperty("sha256").GetString() ?? "";
            var build = data.GetProperty("buildId").GetInt64();
            var version = data.GetProperty("version").GetString() ?? "";
            var size = data.GetProperty("size").GetInt64();
            if (data.GetProperty("schema").GetInt32() != 1 || data.GetProperty("tag").GetString() != tag ||
                !System.Text.RegularExpressions.Regex.IsMatch(hash, "\\A[a-f0-9]{64}\\z") || build <= 0 ||
                !System.Version.TryParse(version, out _) || size is < 1024 or > 268435456)
                throw new InvalidDataException("Invalid Agent release manifest.");
            return new(version, build, hash, size, data.GetProperty("publishedAt").GetDateTimeOffset(), executableUrl);
        }
        return null;
    }
    public async Task<AgentUpdateCandidate?> LatestAsync(CancellationToken token)
    {
        var release = await LatestReleaseAsync(token);
        if (release is null) return null;
        var (version, build, hash, size, publishedAt, executableUrl) = release;
        Directory.CreateDirectory(cache);
        var destination = System.IO.Path.Combine(cache, hash + ".exe");
        if (!File.Exists(destination) || AgentGuardian.Hash(destination) != hash)
        {
            var temporary = destination + ".download";
            try
            {
                using var download = await http.GetAsync(executableUrl, HttpCompletionOption.ResponseHeadersRead, token);
                download.EnsureSuccessStatusCode();
                if (download.Content.Headers.ContentLength is long length && length != size) throw new InvalidDataException("Agent release length mismatch.");
                await using (var source = await download.Content.ReadAsStreamAsync(token))
                await using (var output = new FileStream(temporary, FileMode.Create, FileAccess.Write, FileShare.None))
                {
                    var buffer = new byte[65536]; long total = 0; int count;
                    while ((count = await source.ReadAsync(buffer, token)) > 0)
                    {
                        total += count;
                        if (total > size) throw new InvalidDataException("Agent release exceeds declared size.");
                        await output.WriteAsync(buffer.AsMemory(0, count), token);
                    }
                    if (total != size) throw new InvalidDataException("Agent release download is incomplete.");
                    output.Flush(true);
                }
                if (AgentGuardian.Hash(temporary) != hash) throw new InvalidDataException("Agent release hash mismatch.");
                File.Move(temporary, destination, true);
            }
            finally { if (File.Exists(temporary)) File.Delete(temporary); }
        }
        return new AgentUpdateCandidate(destination, hash, build, version, publishedAt);
    }
    private void ValidateAsset(string address, string tag)
    {
        var uri = new Uri(address);
        var prefix = "/" + repository + "/releases/download/" + Uri.EscapeDataString(tag) + "/";
        if (uri.Scheme != "https" || uri.Host != "github.com" || !uri.AbsolutePath.StartsWith(prefix, StringComparison.Ordinal) ||
            uri.UserInfo.Length != 0 || uri.Query.Length != 0) throw new InvalidDataException("Untrusted Agent release URL.");
    }
    public void Dispose() => http.Dispose();
}
