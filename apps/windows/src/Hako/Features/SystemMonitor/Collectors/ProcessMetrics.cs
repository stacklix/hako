using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;

namespace Hako.Platform;

public sealed record ProcessResource(int ProcessId, string ProcessName, double? CpuUsagePercent, ulong MemoryBytes);
public sealed record ProcessResourceMetrics(string CollectedAt, int SampleWindowMs, int ProcessCount,
    ProcessResource[] CpuTop, ProcessResource[] MemoryTop);

internal sealed class ProcessMetrics
{
    internal const string Command = "query.system.processes";
    private readonly SemaphoreSlim sampling = new(1, 1);

    internal async Task<object?> SampleAsync(CancellationToken token)
    {
        await sampling.WaitAsync(token);
        try
        {
            var before = Capture(token);
            var watch = Stopwatch.StartNew();
            await Task.Delay(1000, token);
            var after = Capture(token);
            return Measure(before, after, watch.Elapsed, Environment.ProcessorCount, DateTimeOffset.UtcNow);
        }
        finally { sampling.Release(); }
    }

    private static IReadOnlyDictionary<int, ProcessSnapshot.ResourceInfo> Capture(CancellationToken token) =>
        ProcessSnapshot.CaptureResources(token) ?? throw new InvalidOperationException("无法读取进程资源快照。");

    internal static ProcessResourceMetrics Measure(IReadOnlyDictionary<int, ProcessSnapshot.ResourceInfo> before,
        IReadOnlyDictionary<int, ProcessSnapshot.ResourceInfo> after, TimeSpan elapsed, int processors, DateTimeOffset collectedAt)
    {
        if (elapsed <= TimeSpan.Zero || processors < 1) throw new ArgumentOutOfRangeException(nameof(elapsed));
        var rows = after.Where(entry => entry.Key > 0).Select(entry =>
        {
            var current = entry.Value;
            double? cpu = null;
            // Creation time prevents a recycled PID from inheriting another process's CPU time.
            if (current.StartedAt is not null && before.TryGetValue(entry.Key, out var previous) &&
                previous.StartedAt == current.StartedAt && current.CpuTime100ns >= previous.CpuTime100ns)
                cpu = Math.Clamp((current.CpuTime100ns - previous.CpuTime100ns) / (double)elapsed.Ticks / processors * 100, 0, 100);
            return new ProcessResource(entry.Key, string.IsNullOrWhiteSpace(current.Name) ? "PID " + entry.Key : current.Name,
                cpu, current.WorkingSetBytes);
        }).ToArray();
        return new(collectedAt.ToString("O"), (int)Math.Min(int.MaxValue, elapsed.TotalMilliseconds), rows.Length,
            rows.Where(row => row.CpuUsagePercent.HasValue).OrderByDescending(row => row.CpuUsagePercent)
                .ThenBy(row => row.ProcessId).Take(10).ToArray(),
            rows.OrderByDescending(row => row.MemoryBytes).ThenBy(row => row.ProcessId).Take(10).ToArray());
    }
}
