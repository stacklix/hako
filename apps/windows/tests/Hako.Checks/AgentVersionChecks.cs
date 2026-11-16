using System;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Security.Cryptography;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Hako.Core;

internal static class AgentVersionChecks
{
    private sealed class ReleaseHandler : HttpMessageHandler
    {
        internal int Downloads;
        private readonly byte[] artifact = new byte[1024];
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token)
        {
            const string prefix = "https://github.com/fixture/agent/releases/download/windows-agent-123-1/";
            var path = request.RequestUri!.AbsolutePath;
            HttpContent content;
            if (path.EndsWith("/releases", StringComparison.Ordinal))
                content = Json(new[] { new { tag_name = "windows-agent-123-1", draft = false, prerelease = false,
                    assets = new[] { new { name = "agent-update.json", browser_download_url = prefix + "agent-update.json" },
                        new { name = "Hako.exe", browser_download_url = prefix + "Hako.exe" } } } });
            else if (path.EndsWith("/agent-update.json", StringComparison.Ordinal))
                content = Json(new { schema = 1, tag = "windows-agent-123-1", sha256 = Convert.ToHexString(SHA256.HashData(artifact)).ToLowerInvariant(),
                    buildId = 123, version = "1.3.9", size = artifact.Length, publishedAt = DateTimeOffset.UtcNow });
            else { Downloads++; content = new ByteArrayContent(artifact); }
            return Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK) { Content = content });
        }
        private static StringContent Json(object value) => new(JsonSerializer.Serialize(value));
    }
    internal static async Task RunAsync(string profile, CancellationToken token)
    {
        using var handler = new ReleaseHandler();
        var cache = Path.Combine(profile, "downloads");
        using var source = new GitHubAgentUpdates("fixture/agent", cache, handler);
        var calls = 0;
        using var versions = new AgentVersions(profile, ct => { Interlocked.Increment(ref calls); return source.LatestReleaseAsync(ct); });
        var responses = await Task.WhenAll(Enumerable.Range(0, 8).Select(_ => versions.ReadAsync(token)));
        if (calls != 1 || handler.Downloads != 0 || Directory.Exists(cache))
            throw new Exception("Version queries downloaded an update or bypassed the shared cache");
        var snapshot = responses[0];
        if (snapshot.CurrentVersion != ServerCompatibility.AgentVersion || snapshot.MinimumServerVersion != ServerCompatibility.MinimumServerVersion
            || snapshot.LatestVersion != "1.3.9" || snapshot.LatestBuildId != 123 || snapshot.LatestCheckState != "available")
            throw new Exception("Version metadata did not identify the running guardian, release and compatibility floor");
        var candidate = await source.LatestAsync(token);
        if (handler.Downloads != 1 || candidate is null || AgentGuardian.Hash(candidate.Path) != candidate.Sha256 || candidate.BuildId != 123)
            throw new Exception("Splitting release discovery broke verified update downloads");
        using var failed = new AgentVersions(profile, _ => throw new HttpRequestException("fixture unavailable"));
        var failure = await failed.ReadAsync(token);
        if (failure.LatestCheckState != "unavailable" || failure.LatestVersion is not null || failure.CurrentVersion != snapshot.CurrentVersion)
            throw new Exception("A failed release check hid the running version or invented a latest version");
        using var empty = new AgentVersions(profile, _ => Task.FromResult<GitHubAgentRelease?>(null));
        if ((await empty.ReadAsync(token)).LatestCheckState != "no_release") throw new Exception("No release was reported as current");
        using var cancelled = new CancellationTokenSource();
        cancelled.Cancel();
        try { await versions.ReadAsync(cancelled.Token); throw new Exception("Cancelled version request completed"); }
        catch (OperationCanceledException) when (cancelled.IsCancellationRequested) { }
        Console.WriteLine("PASS: guardian versions, release metadata without downloads, coalesced checks, failed/empty releases and verified update download.");
    }
}
