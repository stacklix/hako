using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Hako.Platform;

namespace Hako.Core;

public sealed record ResourceSample(long Timestamp, double CpuUsagePercent, double MemoryUsagePercent);
public sealed record ResourceHistoryPoint(long Timestamp, double CpuUsagePercent, double CpuMaxPercent,
    double MemoryUsagePercent, double MemoryMaxPercent, int SampleCount,
    double CpuSmoothedMaxPercent, double MemorySmoothedMaxPercent);
public sealed record ResourceHistoryResult(long CollectedAt, long From, long To, int SampleIntervalSeconds,
    int RetentionDays, int BucketSeconds, long? LastSampleAt, string? SamplingError, ResourceHistoryPoint[] Points);

// One-second samples remain readable in memory until a five-minute durable batch.
public sealed class ResourceHistory(string directory, Func<DateTimeOffset>? clock = null)
{
    public const string Command = "query.system.metrics.history";
    public const int IntervalSeconds = 1;
    public const int FlushIntervalSeconds = 300;
    private const int RecordSize = 24;
    private readonly SemaphoreSlim gate = new(1, 1);
    private readonly object bufferGate = new();
    private readonly List<ResourceSample> pending = [];
    private DateTimeOffset Now => clock?.Invoke() ?? DateTimeOffset.UtcNow;
    public string? SamplingError { get; internal set; }
    internal string? WriteError { get; set; }

    public Task AppendAsync(ResourceSample sample, CancellationToken token)
    {
        token.ThrowIfCancellationRequested();
        if (!Valid(sample)) throw new ArgumentException("无效的资源历史样本。");
        var cutoff = Now.AddDays(-7).ToUnixTimeMilliseconds();
        lock (bufferGate)
        {
            pending.RemoveAll(row => row.Timestamp < cutoff);
            pending.Add(sample);
        }
        return Task.CompletedTask;
    }

    public async Task FlushAsync(CancellationToken token)
    {
        await gate.WaitAsync(token);
        try
        {
            var cutoff = Now.AddDays(-7).ToUnixTimeMilliseconds();
            ResourceSample[] batch;
            lock (bufferGate) { pending.RemoveAll(row => row.Timestamp < cutoff); batch = pending.ToArray(); }
            if (batch.Length > 0) Directory.CreateDirectory(directory);
            foreach (var group in batch.GroupBy(row => DateTimeOffset.FromUnixTimeMilliseconds(row.Timestamp)
                .UtcDateTime.ToString("yyyyMMddHH", CultureInfo.InvariantCulture)))
            {
                token.ThrowIfCancellationRequested();
                var path = Path.Combine(directory, group.Key + ".bin");
                var rows = (File.Exists(path) ? ReadFile(path) : []).Concat(group)
                    .Where(row => row.Timestamp >= cutoff).OrderBy(row => row.Timestamp).ToArray();
                var temporary = path + ".tmp";
                try
                {
                    using (var stream = new FileStream(temporary, FileMode.Create, FileAccess.Write, FileShare.None))
                    {
                        using var writer = new BinaryWriter(stream);
                        foreach (var row in rows) { writer.Write(row.Timestamp); writer.Write(row.CpuUsagePercent); writer.Write(row.MemoryUsagePercent); }
                        stream.Flush(true);
                    }
                    File.Move(temporary, path, true);
                }
                finally { if (File.Exists(temporary)) File.Delete(temporary); }
                var written = new HashSet<ResourceSample>(group, ReferenceEqualityComparer.Instance);
                lock (bufferGate) { pending.RemoveAll(written.Contains); }
            }
            Prune(cutoff);
            WriteError = null;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            WriteError = "历史记录写盘失败，待写入样本仍保存在内存，将在下一批次重试。";
            throw;
        }
        finally { gate.Release(); }
    }

    public async Task PruneAsync(CancellationToken token)
    {
        await gate.WaitAsync(token);
        try { Prune(Now.AddDays(-7).ToUnixTimeMilliseconds()); }
        finally { gate.Release(); }
    }

    private void Prune(long cutoff)
    {
        if (!Directory.Exists(directory)) return;
        foreach (var path in Directory.EnumerateFiles(directory, "*.bin"))
        {
            if (!DateTimeOffset.TryParseExact(Path.GetFileNameWithoutExtension(path), "yyyyMMddHH", CultureInfo.InvariantCulture,
                    DateTimeStyles.AssumeUniversal, out var hour)) continue;
            if (hour.AddHours(1).ToUnixTimeMilliseconds() <= cutoff) { File.Delete(path); continue; }
            if (hour.ToUnixTimeMilliseconds() >= cutoff) continue;
            var rows = ReadFile(path).Where(row => row.Timestamp >= cutoff).ToArray();
            // Atomically trim the boundary hour, so expired records are removed from disk too.
            var temporary = path + ".tmp";
            try
            {
                using (var stream = new FileStream(temporary, FileMode.Create, FileAccess.Write, FileShare.None))
                {
                    using var writer = new BinaryWriter(stream);
                    foreach (var row in rows) { writer.Write(row.Timestamp); writer.Write(row.CpuUsagePercent); writer.Write(row.MemoryUsagePercent); }
                    stream.Flush(true);
                }
                File.Move(temporary, path, true);
            }
            finally { if (File.Exists(temporary)) File.Delete(temporary); }
        }
    }

    private static bool Valid(ResourceSample row) => row.Timestamp >= 0 && row.Timestamp <= 253402300799999
        && double.IsFinite(row.CpuUsagePercent) && row.CpuUsagePercent is >= 0 and <= 100
        && double.IsFinite(row.MemoryUsagePercent) && row.MemoryUsagePercent is >= 0 and <= 100;

    private static IEnumerable<ResourceSample> ReadFile(string path)
    {
        using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite);
        using var reader = new BinaryReader(stream);
        while (stream.Position + RecordSize <= stream.Length)
        {
            var row = new ResourceSample(reader.ReadInt64(), reader.ReadDouble(), reader.ReadDouble());
            if (Valid(row)) yield return row;
        }
    }

    public async Task<object?> QueryAsync(JsonElement parameters, CancellationToken token)
    {
        int range = 3600;
        bool recent = false, hasRange = false;
        foreach (var property in parameters.EnumerateObject())
        {
            if (property.Name == "latestPoints" && !recent && !hasRange && property.Value.ValueKind == JsonValueKind.Number
                && property.Value.TryGetInt32(out int count) && count == 240)
                recent = true;
            else if (property.Name == "rangeSeconds" && !recent && !hasRange && property.Value.ValueKind == JsonValueKind.Number
                && property.Value.TryGetInt32(out range) && range is (900 or 1800 or 3600 or 21600 or 86400 or 604800))
                hasRange = true;
            else throw new AgentActionException("invalid_params", "请指定 latestPoints:240，或 rangeSeconds 为 900、1800、3600、21600、86400、604800；两者不能同时使用。");
        }
        var now = Now.ToUnixTimeMilliseconds();
        var from = now - range * 1000L;
        // Retain raw peaks and the highest trailing five-second mean in each display bucket.
        int bucketSeconds = (int)Math.Ceiling(range / 240.0 / IntervalSeconds) * IntervalSeconds;
        await gate.WaitAsync(token);
        try
        {
            var rows = new List<ResourceSample>();
            var recentRows = new SortedDictionary<long, ResourceSample>();
            var recentTimes = new PriorityQueue<long, long>();
            void Keep(ResourceSample row)
            {
                if (!recent) { if (row.Timestamp > from - 5000) rows.Add(row); return; }
                // Bound retained memory to the newest samples plus their five-second warmup,
                // even when daily files are enumerated out of chronological order.
                if (recentTimes.Count == 240 && row.Timestamp <= recentTimes.Peek() - 5000) return;
                if (recentRows.ContainsKey(row.Timestamp)) { recentRows[row.Timestamp] = row; return; }
                recentRows[row.Timestamp] = row;
                if (recentTimes.Count < 240) recentTimes.Enqueue(row.Timestamp, row.Timestamp);
                else if (row.Timestamp > recentTimes.Peek())
                { recentTimes.Dequeue(); recentTimes.Enqueue(row.Timestamp, row.Timestamp); }
                if (recentTimes.Count == 240)
                    while (recentRows.Count > 0 && recentRows.First().Key <= recentTimes.Peek() - 5000)
                        recentRows.Remove(recentRows.First().Key);
            }
            long? last = null;
            if (Directory.Exists(directory)) foreach (var path in Directory.EnumerateFiles(directory, "*.bin"))
            {
                token.ThrowIfCancellationRequested();
                foreach (var row in ReadFile(path))
                {
                    if (row.Timestamp > now || row.Timestamp < now - 7 * 86400000L) continue;
                    last = Math.Max(last ?? row.Timestamp, row.Timestamp);
                    Keep(row);
                }
            }
            ResourceSample[] buffered;
            lock (bufferGate) { buffered = pending.ToArray(); }
            foreach (var row in buffered)
            {
                if (row.Timestamp > now || row.Timestamp < now - 7 * 86400000L) continue;
                last = Math.Max(last ?? row.Timestamp, row.Timestamp);
                Keep(row);
            }
            if (recent)
            {
                rows = recentRows.Values.ToList();
                from = rows.Count == 0 ? now : rows[Math.Max(0, rows.Count - 240)].Timestamp;
                bucketSeconds = 1;
            }
            rows.Sort((left, right) => left.Timestamp.CompareTo(right.Timestamp));
            int start = 0;
            double cpuSum = 0, memorySum = 0;
            var smoothed = new List<(ResourceSample Sample, double Cpu, double Memory)>();
            for (int index = 0; index < rows.Count; index++)
            {
                token.ThrowIfCancellationRequested();
                var row = rows[index];
                cpuSum += row.CpuUsagePercent; memorySum += row.MemoryUsagePercent;
                // Timestamp-based (t - 5s, t], rather than the last five samples:
                // slow sampling, sleep and missing samples must not extend the window.
                while (rows[start].Timestamp <= row.Timestamp - 5000)
                {
                    cpuSum -= rows[start].CpuUsagePercent; memorySum -= rows[start].MemoryUsagePercent;
                    start++;
                }
                if (row.Timestamp >= from)
                    smoothed.Add((row, Math.Clamp(cpuSum / (index - start + 1), 0, 100),
                        Math.Clamp(memorySum / (index - start + 1), 0, 100)));
            }
            var points = recent ? smoothed.Select(row => new ResourceHistoryPoint(
                    row.Sample.Timestamp, Math.Round(row.Sample.CpuUsagePercent, 4), Math.Round(row.Sample.CpuUsagePercent, 4),
                    Math.Round(row.Sample.MemoryUsagePercent, 4), Math.Round(row.Sample.MemoryUsagePercent, 4), 1,
                    Math.Round(row.Cpu, 4), Math.Round(row.Memory, 4))).ToArray()
                : smoothed.GroupBy(row => Math.Min(239, (row.Sample.Timestamp - from) / (bucketSeconds * 1000L)))
                .OrderBy(group => group.Key).Select(group => new ResourceHistoryPoint(
                    from + group.Key * bucketSeconds * 1000L, Math.Round(group.Average(row => row.Sample.CpuUsagePercent), 4),
                    Math.Round(group.Max(row => row.Sample.CpuUsagePercent), 4), Math.Round(group.Average(row => row.Sample.MemoryUsagePercent), 4),
                    Math.Round(group.Max(row => row.Sample.MemoryUsagePercent), 4), group.Count(),
                    Math.Round(group.Max(row => row.Cpu), 4), Math.Round(group.Max(row => row.Memory), 4))).ToArray();
            return new ResourceHistoryResult(now, from, now, IntervalSeconds, 7, bucketSeconds, last, SamplingError ?? WriteError, points);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        { throw new AgentActionException("history_unavailable", "无法读取本机资源历史记录。"); }
        finally { gate.Release(); }
    }
}

internal sealed class ResourceHistorySampler(ResourceHistory history, SystemMetrics metrics) : IAsyncDisposable
{
    private readonly CancellationTokenSource lifetime = new();
    private Task? flushing;
    private bool started;
    public void Start()
    {
        if (started) return;
        started = true;
        metrics.Sampled += Record;
        metrics.SamplingFailed += Failed;
        metrics.Start();
        flushing = Task.Run(() => FlushPeriodicallyAsync(lifetime.Token));
    }
    private void Record(Metrics value)
    {
        var timestamp = DateTimeOffset.Parse(value.SampledAt, CultureInfo.InvariantCulture).ToUnixTimeMilliseconds();
        // Append only touches the in-memory buffer; live sampling never waits for disk.
        history.AppendAsync(new(timestamp, value.CpuUsagePercent, value.MemoryUsagePercent), CancellationToken.None).GetAwaiter().GetResult();
        history.SamplingError = null;
    }
    private void Failed() => history.SamplingError = "系统指标采样失败，将在下一秒重试。";
    private async Task FlushPeriodicallyAsync(CancellationToken token)
    {
        using var timer = new PeriodicTimer(TimeSpan.FromSeconds(ResourceHistory.FlushIntervalSeconds));
        try
        {
            while (await timer.WaitForNextTickAsync(token))
            {
                try { await history.FlushAsync(token); }
                catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
            }
        }
        catch (OperationCanceledException) when (token.IsCancellationRequested) { }
    }
    public async ValueTask DisposeAsync()
    {
        // Stop the producer first so the final flush includes every accepted sample.
        await metrics.DisposeAsync();
        metrics.Sampled -= Record;
        metrics.SamplingFailed -= Failed;
        await lifetime.CancelAsync();
        if (flushing is not null) await flushing;
        try { await history.FlushAsync(CancellationToken.None); }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        { System.Diagnostics.Trace.TraceError("Unable to flush resource history at shutdown: {0}", error.GetType().Name); }
        lifetime.Dispose();
    }
}
