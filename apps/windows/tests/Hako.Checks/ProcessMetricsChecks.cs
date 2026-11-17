using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using Hako.Platform;

internal static class ProcessMetricsChecks
{
    internal static async Task RunAsync()
    {
        var now = DateTimeOffset.UtcNow;
        var before = new Dictionary<int, ProcessSnapshot.ResourceInfo>();
        var after = new Dictionary<int, ProcessSnapshot.ResourceInfo>();
        for (var pid = 1; pid <= 12; pid++)
        {
            before[pid] = new("worker-" + pid, now.AddMinutes(-pid), 1, 100, 0);
            after[pid] = before[pid] with { CpuTime100ns = (ulong)(100 + pid * 100_000), WorkingSetBytes = (ulong)(13 - pid) * 1024 };
        }
        before[20] = new("old", now.AddMinutes(-1), 1, 10_000_000, 0);
        after[20] = new("reused", now, 1, 20_000_000, 0);
        after[21] = new(null, now, 1, 10_000_000, 0);
        before[22] = new("reset", now, 1, 20_000_000, 0);
        after[22] = before[22] with { CpuTime100ns = 0 };
        var value = ProcessMetrics.Measure(before, after, TimeSpan.FromSeconds(1), 4, now);
        if (value.ProcessCount != 15 || value.CpuTop.Length != 10 || value.MemoryTop.Length != 10 ||
            value.CpuTop[0].ProcessId != 12 || Math.Abs(value.CpuTop[0].CpuUsagePercent!.Value - 3) > 0.001 ||
            value.MemoryTop[0].ProcessId != 1 || value.MemoryTop[0].MemoryBytes != 12 * 1024 ||
            value.CpuTop.Any(row => row.ProcessId >= 20))
            throw new Exception("Process ranking, multi-core CPU normalization or PID reuse protection failed");
        var missing = ProcessMetrics.Measure(new Dictionary<int, ProcessSnapshot.ResourceInfo>(),
            new Dictionary<int, ProcessSnapshot.ResourceInfo> { [21] = after[21] }, TimeSpan.FromSeconds(1), 1, now);
        if (missing.CpuTop.Length != 0 || missing.MemoryTop[0].ProcessName != "PID 21" || missing.MemoryTop[0].CpuUsagePercent is not null)
            throw new Exception("Missing process metadata was reported as a measured zero CPU value");
        using var cancelled = new CancellationTokenSource(); cancelled.Cancel();
        try { await new ProcessMetrics().SampleAsync(cancelled.Token); throw new Exception("Process sampling ignored cancellation"); }
        catch (OperationCanceledException) { }
        var resources = ProcessSnapshot.CaptureResources(default) ?? throw new Exception("Native resource snapshot unavailable");
        if (!resources.ContainsKey(Environment.ProcessId) || resources[Environment.ProcessId].WorkingSetBytes == 0 || !resources.ContainsKey(4))
            throw new Exception("Native resource snapshot omitted self/protected System process or working set data");
        var live = (ProcessResourceMetrics)(await new ProcessMetrics().SampleAsync(default))!;
        if (live.ProcessCount < 10 || live.CpuTop.Length != 10 || live.MemoryTop.Length != 10 || live.SampleWindowMs < 500 ||
            live.CpuTop.Any(row => row.CpuUsagePercent is not >= 0 or > 100) ||
            !live.MemoryTop.Select(row => row.MemoryBytes).SequenceEqual(live.MemoryTop.Select(row => row.MemoryBytes).OrderDescending()))
            throw new Exception("Live process resource sample is invalid");
        Console.WriteLine("PASS: live CPU/memory top ten, native working sets including protected processes, core normalization, PID reuse and cancellation");
    }
}
