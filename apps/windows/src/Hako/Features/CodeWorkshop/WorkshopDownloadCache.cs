using System;
using System.Collections.Generic;
using System.Linq;
using System.Security.Cryptography;
using System.Threading;
using System.Threading.Tasks;

namespace Hako.Platform;

// Transfer immutable, hash-verified snapshots. An edit can create a new revision
// without mixing bytes into a transfer already in progress. Memory and lifetime
// are bounded; an evicted revision is reloaded and checked by the caller.
internal sealed class WorkshopDownloadCache
{
    internal sealed record Snapshot(byte[] Data, string Revision, long Saved);
    private readonly SemaphoreSlim gate = new(1, 1);
    private readonly Dictionary<string, Snapshot> snapshots = new();

    internal async Task<Snapshot> ReadAsync(string key, string revision, Func<Task<byte[]>> load, CancellationToken token)
    {
        await gate.WaitAsync(token);
        try
        {
            foreach (var expired in snapshots.Where(entry => Environment.TickCount64 - entry.Value.Saved >= 30_000).Select(entry => entry.Key).ToArray())
                snapshots.Remove(expired);
            if (revision.Length > 0 && snapshots.TryGetValue(key, out var cached) && cached.Revision == revision) return cached;
            var data = await load();
            var snapshot = new Snapshot(data, Convert.ToHexString(SHA256.HashData(data)).ToLowerInvariant(), Environment.TickCount64);
            snapshots.Remove(key);
            while (snapshots.Count > 0 && (snapshots.Count >= 4 || snapshots.Values.Sum(value => (long)value.Data.Length) + data.Length > 24 * 1024 * 1024))
                snapshots.Remove(snapshots.MinBy(value => value.Value.Saved).Key);
            snapshots[key] = snapshot;
            return snapshot;
        }
        finally { gate.Release(); }
    }
}
