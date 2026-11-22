using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace Hako.Core;

public sealed record ResourceSample(long Timestamp, double CpuUsagePercent, double MemoryUsagePercent);
public sealed record ResourceHistoryPoint(long Timestamp, double CpuUsagePercent, double CpuMaxPercent,
    double MemoryUsagePercent, double MemoryMaxPercent, int SampleCount);
public sealed record ResourceHistoryResult(long CollectedAt, long From, long To, int SampleIntervalSeconds,
    int RetentionDays, int BucketSeconds, long? LastSampleAt, string? SamplingError, ResourceHistoryPoint[] Points);

// Hourly fixed-size records keep a full week under 1.5 MB. No dependency on a Console subscription.
public sealed class ResourceHistory(string directory, Func<DateTimeOffset>? clock = null)
{
    public const string Command = "query.system.metrics.history";
    public const int IntervalSeconds = 10;
    private const int RecordSize = 24;
    private readonly SemaphoreSlim gate = new(1, 1);
    private DateTimeOffset Now => clock?.Invoke() ?? DateTimeOffset.UtcNow;
    public string? SamplingError { get; internal set; }

    public async Task AppendAsync(ResourceSample sample, CancellationToken token)
    {
        if (!Valid(sample)) throw new ArgumentException("无效的资源历史样本。");
        await gate.WaitAsync(token);
        try
        {
            Directory.CreateDirectory(directory);
            Prune(Now.AddDays(-7).ToUnixTimeMilliseconds());
            var path = Path.Combine(directory, DateTimeOffset.FromUnixTimeMilliseconds(sample.Timestamp).UtcDateTime.ToString("yyyyMMddHH", CultureInfo.InvariantCulture) + ".bin");
            using var stream = new FileStream(path, FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.Read);
            // A power loss may leave a partial final record; discard only that incomplete tail.
            stream.SetLength(stream.Length / RecordSize * RecordSize);
            stream.Position = stream.Length;
            using var writer = new BinaryWriter(stream);
            writer.Write(sample.Timestamp); writer.Write(sample.CpuUsagePercent); writer.Write(sample.MemoryUsagePercent);
            stream.Flush(true);
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
        foreach (var property in parameters.EnumerateObject())
        {
            if (property.Name != "rangeSeconds" || property.Value.ValueKind != JsonValueKind.Number || !property.Value.TryGetInt32(out range)
                || range is not (3600 or 21600 or 86400 or 604800))
                throw new AgentActionException("invalid_params", "rangeSeconds 必须为 3600、21600、86400 或 604800。");
        }
        var now = Now.ToUnixTimeMilliseconds();
        var from = now - range * 1000L;
        // At most 240 points, well below the device reply size limit, retaining peaks in every bucket.
        int bucketSeconds = (int)Math.Ceiling(range / 240.0 / IntervalSeconds) * IntervalSeconds;
        await gate.WaitAsync(token);
        try
        {
            Prune(now - 7 * 86400000L);
            var rows = new List<ResourceSample>();
            long? last = null;
            if (Directory.Exists(directory)) foreach (var path in Directory.EnumerateFiles(directory, "*.bin"))
            {
                token.ThrowIfCancellationRequested();
                foreach (var row in ReadFile(path))
                {
                    if (row.Timestamp > now || row.Timestamp < now - 7 * 86400000L) continue;
                    last = Math.Max(last ?? row.Timestamp, row.Timestamp);
                    if (row.Timestamp >= from) rows.Add(row);
                }
            }
            var points = rows.GroupBy(row => Math.Min(239, (row.Timestamp - from) / (bucketSeconds * 1000L)))
                .OrderBy(group => group.Key).Select(group => new ResourceHistoryPoint(
                    from + group.Key * bucketSeconds * 1000L, group.Average(row => row.CpuUsagePercent),
                    group.Max(row => row.CpuUsagePercent), group.Average(row => row.MemoryUsagePercent),
                    group.Max(row => row.MemoryUsagePercent), group.Count())).ToArray();
            return new ResourceHistoryResult(now, from, now, IntervalSeconds, 7, bucketSeconds, last, SamplingError, points);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        { throw new AgentActionException("history_unavailable", "无法读取本机资源历史记录。"); }
        finally { gate.Release(); }
    }
}

internal sealed class ResourceHistorySampler(ResourceHistory history) : IAsyncDisposable
{
    [StructLayout(LayoutKind.Sequential)] private struct MemoryStatus
    {
        public uint Length, Load;
        public ulong TotalPhysical, AvailablePhysical, TotalPageFile, AvailablePageFile, TotalVirtual, AvailableVirtual, AvailableExtendedVirtual;
    }
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool GlobalMemoryStatusEx(ref MemoryStatus status);
    [StructLayout(LayoutKind.Explicit)] private struct CounterValue { [FieldOffset(0)] public uint Status; [FieldOffset(8)] public double Value; }
    [DllImport("pdh.dll", CharSet = CharSet.Unicode)] private static extern uint PdhOpenQuery(string? source, UIntPtr data, out IntPtr query);
    [DllImport("pdh.dll", CharSet = CharSet.Unicode)] private static extern uint PdhAddEnglishCounter(IntPtr query, string path, UIntPtr data, out IntPtr counter);
    [DllImport("pdh.dll")] private static extern uint PdhCollectQueryData(IntPtr query);
    [DllImport("pdh.dll")] private static extern uint PdhGetFormattedCounterValue(IntPtr counter, uint format, out uint type, out CounterValue value);
    [DllImport("pdh.dll")] private static extern uint PdhCloseQuery(IntPtr query);
    private readonly CancellationTokenSource lifetime = new();
    private Task? worker;
    public void Start() => worker ??= Task.Run(() => RunAsync(lifetime.Token));
    private async Task RunAsync(CancellationToken token)
    {
        using var timer = new PeriodicTimer(TimeSpan.FromSeconds(ResourceHistory.IntervalSeconds));
        IntPtr query = IntPtr.Zero, counter = IntPtr.Zero;
        try
        {
            do
            {
                try
                {
                    await history.PruneAsync(token);
                    if (query == IntPtr.Zero)
                    {
                        if (PdhOpenQuery(null, UIntPtr.Zero, out query) != 0 ||
                            PdhAddEnglishCounter(query, @"\Processor Information(_Total)\% Processor Time", UIntPtr.Zero, out counter) != 0 ||
                            PdhCollectQueryData(query) != 0) throw new InvalidOperationException("CPU 计数器初始化失败。");
                        continue;
                    }
                    if (PdhCollectQueryData(query) != 0 || PdhGetFormattedCounterValue(counter, 0x200, out _, out var cpu) != 0
                        || cpu.Status is not (0 or 1) || !double.IsFinite(cpu.Value)) throw new InvalidOperationException("CPU 计数器读取失败。");
                    var memory = new MemoryStatus { Length = (uint)Marshal.SizeOf<MemoryStatus>() };
                    if (!GlobalMemoryStatusEx(ref memory) || memory.TotalPhysical == 0) throw new InvalidOperationException("内存读取失败。");
                    await history.AppendAsync(new(DateTimeOffset.UtcNow.ToUnixTimeMilliseconds(), Math.Clamp(cpu.Value, 0, 100),
                        (memory.TotalPhysical - memory.AvailablePhysical) * 100.0 / memory.TotalPhysical), token);
                    history.SamplingError = null;
                }
                catch (Exception error) when (error is not OperationCanceledException)
                {
                    history.SamplingError = "资源历史采集或写入失败，将在下次采样重试。";
                    if (query != IntPtr.Zero) PdhCloseQuery(query);
                    query = IntPtr.Zero;
                }
            } while (await timer.WaitForNextTickAsync(token));
        }
        catch (OperationCanceledException) when (token.IsCancellationRequested) { }
        finally { if (query != IntPtr.Zero) PdhCloseQuery(query); }
    }
    public async ValueTask DisposeAsync()
    {
        await lifetime.CancelAsync();
        if (worker is not null) await worker;
        lifetime.Dispose();
    }
}
