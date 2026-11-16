using System;
using System.IO;
using System.Net.Http;
using System.Reflection;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace Hako.Core;

internal sealed record AgentVersionSnapshot(string CurrentVersion, string CurrentBuild, string MinimumServerVersion,
    string? LatestVersion, long? LatestBuildId, DateTimeOffset LatestCheckedAt, string LatestCheckState);

// Version administration belongs to the guardian and never depends on the main process.
internal sealed class AgentVersions(string profile, Func<CancellationToken, Task<GitHubAgentRelease?>>? lookup = null) : IDisposable
{
    internal const string Command = "admin.agent.versions";
    private readonly SemaphoreSlim gate = new(1, 1);
    private AgentVersionSnapshot? snapshot;
    private DateTimeOffset expires;

    internal async Task<AgentVersionSnapshot> ReadAsync(CancellationToken token)
    {
        await gate.WaitAsync(token);
        try
        {
            if (snapshot is not null && DateTimeOffset.UtcNow < expires) return snapshot;
            GitHubAgentRelease? release = null;
            var state = "available";
            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(token);
            timeout.CancelAfter(TimeSpan.FromSeconds(8));
            try
            {
                if (lookup is not null) release = await lookup(timeout.Token);
                else
                {
                    var options = AgentGuardianControl.Read<AgentGuardianOptions>(AgentGuardianControl.FileFor(profile, "config.json"))
                        ?? throw new InvalidDataException("Guardian configuration missing.");
                    options.Validate();
                    using var source = new GitHubAgentUpdates(options.Repository, AgentGuardianControl.FileFor(profile, "downloads"));
                    release = await source.LatestReleaseAsync(timeout.Token);
                }
                if (release is null) state = "no_release";
            }
            catch (Exception error) when (!token.IsCancellationRequested && error is
                IOException or HttpRequestException or JsonException or InvalidOperationException or
                UnauthorizedAccessException or OperationCanceledException or FormatException or ArgumentException or
                System.Collections.Generic.KeyNotFoundException)
            { state = "unavailable"; }
            token.ThrowIfCancellationRequested();
            var assembly = typeof(AgentConnection).Assembly;
            snapshot = new(ServerCompatibility.AgentVersion,
                assembly.GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion ?? ServerCompatibility.AgentVersion,
                ServerCompatibility.MinimumServerVersion, release?.Version, release?.BuildId, DateTimeOffset.UtcNow, state);
            expires = snapshot.LatestCheckedAt.AddSeconds(state == "unavailable" ? 30 : 300);
            return snapshot;
        }
        finally { gate.Release(); }
    }
    public void Dispose() => gate.Dispose();
}
