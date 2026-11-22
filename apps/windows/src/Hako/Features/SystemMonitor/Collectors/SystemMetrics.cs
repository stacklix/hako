using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;
using System.Threading.Tasks;

namespace Hako.Platform;

public sealed record Metrics(double CpuUsagePercent, double MemoryUsagePercent, ulong MemoryUsedBytes,
    ulong MemoryTotalBytes, string SampledAt, int SampleWindowMs, NetworkMetrics? Network = null, DiskMetrics? Disk = null);
public sealed record DiskMetrics(DiskVolume[] Volumes, double? ReadBytesPerSecond, double? WriteBytesPerSecond);
public sealed record DiskVolume(string Name, ulong UsedBytes, ulong TotalBytes);

public sealed class SystemMetrics : IAsyncDisposable
{
    private const uint PdhFormatDouble = 0x200;
    private const uint PdhFormatNoScale = 0x1000;
    private const uint PdhFormatNoCap100 = 0x8000;
    private readonly object gate = new();
    private readonly CancellationTokenSource lifetime = new();
    private readonly Func<CancellationToken, Task<Metrics>> collect;
    private TaskCompletionSource<Metrics> next = NewCompletion();
    private Task? worker;
    private Metrics? latest;
    private long receivedAt;
    private bool disposed;
    internal event Action<Metrics>? Sampled;
    internal event Action? SamplingFailed;

    public SystemMetrics() { collect = CollectAsync; }
    internal SystemMetrics(Func<CancellationToken, Task<Metrics>> collector) { collect = collector; }
    private static TaskCompletionSource<Metrics> NewCompletion() => new(TaskCreationOptions.RunContinuationsAsynchronously);

    public void Start()
    {
        lock (gate)
        {
            ObjectDisposedException.ThrowIf(disposed, this);
            worker ??= Task.Run(() => RunAsync(lifetime.Token));
        }
    }

    // All live consumers read the same autonomous one-second sample.
    public Task<Metrics> SampleAsync(CancellationToken token)
    {
        token.ThrowIfCancellationRequested();
        Start();
        lock (gate)
        {
            if (latest is not null && Environment.TickCount64 - receivedAt < 2000) return Task.FromResult(latest);
            return next.Task.WaitAsync(token);
        }
    }

    private async Task RunAsync(CancellationToken token)
    {
        try
        {
            while (!token.IsCancellationRequested)
            {
                try
                {
                    var value = await collect(token);
                    token.ThrowIfCancellationRequested();
                    Sampled?.Invoke(value);
                    TaskCompletionSource<Metrics> ready;
                    lock (gate) { latest = value; receivedAt = Environment.TickCount64; ready = next; next = NewCompletion(); }
                    ready.TrySetResult(value);
                }
                catch (Exception error) when (error is not OperationCanceledException)
                {
                    TaskCompletionSource<Metrics> ready;
                    lock (gate) { latest = null; ready = next; next = NewCompletion(); }
                    ready.TrySetException(error);
                    _ = ready.Task.Exception;
                    SamplingFailed?.Invoke();
                    await Task.Delay(1000, token);
                }
            }
        }
        catch (OperationCanceledException) when (token.IsCancellationRequested) { }
    }

    public async ValueTask DisposeAsync()
    {
        Task? running;
        lock (gate)
        {
            if (disposed) return;
            disposed = true; running = worker;
            lifetime.Cancel(); next.TrySetCanceled();
        }
        if (running is not null) await running;
        lifetime.Dispose();
    }
    [StructLayout(LayoutKind.Sequential)]
    private struct MemoryStatus
    {
        public uint Length, Load;
        public ulong TotalPhysical, AvailablePhysical, TotalPageFile, AvailablePageFile, TotalVirtual, AvailableVirtual, AvailableExtendedVirtual;
    }
    [StructLayout(LayoutKind.Explicit)]
    private struct CounterValue { [FieldOffset(0)] public uint Status; [FieldOffset(8)] public double Value; }
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GlobalMemoryStatusEx(ref MemoryStatus status);
    [DllImport("pdh.dll", CharSet = CharSet.Unicode)]
    private static extern uint PdhOpenQuery(string? dataSource, UIntPtr userData, out IntPtr query);
    [DllImport("pdh.dll", CharSet = CharSet.Unicode)]
    private static extern uint PdhAddEnglishCounter(IntPtr query, string path, UIntPtr userData, out IntPtr counter);
    [DllImport("pdh.dll")]
    private static extern uint PdhCollectQueryData(IntPtr query);
    [DllImport("pdh.dll")]
    private static extern uint PdhGetFormattedCounterValue(IntPtr counter, uint format, out uint type, out CounterValue value);
    [DllImport("pdh.dll")]
    private static extern uint PdhCloseQuery(IntPtr query);

    private async Task<Metrics> CollectAsync(CancellationToken token)
    {
        IntPtr query = IntPtr.Zero;
        try
        {
            Check(PdhOpenQuery(null, UIntPtr.Zero, out query));
            // English counter lookup works on localized Windows; Processor Information covers processor groups.
            Check(PdhAddEnglishCounter(query, @"\Processor Information(_Total)\% Processor Time", UIntPtr.Zero, out var counter));
            var diskRead = AddOptionalCounter(query, @"\PhysicalDisk(_Total)\Disk Read Bytes/sec");
            var diskWrite = AddOptionalCounter(query, @"\PhysicalDisk(_Total)\Disk Write Bytes/sec");
            Check(PdhCollectQueryData(query));
            var start = System.Diagnostics.Stopwatch.StartNew();
            var networkBefore = NetworkTraffic.Capture();
            await Task.Delay(1000, token);
            var networkAfter = NetworkTraffic.Capture();
            Check(PdhCollectQueryData(query));
            Check(PdhGetFormattedCounterValue(counter, PdhFormatDouble, out _, out var cpu));
            if (cpu.Status != 0 && cpu.Status != 1) throw new InvalidOperationException("CPU 计数器尚未就绪。");
            var memory = new MemoryStatus { Length = (uint)Marshal.SizeOf<MemoryStatus>() };
            if (!GlobalMemoryStatusEx(ref memory) || memory.TotalPhysical == 0) throw new InvalidOperationException("无法读取物理内存。");
            var used = memory.TotalPhysical - memory.AvailablePhysical;
            return new Metrics(Math.Clamp(cpu.Value, 0, 100), used * 100.0 / memory.TotalPhysical, used,
                memory.TotalPhysical, DateTimeOffset.UtcNow.ToString("O"), (int)start.ElapsedMilliseconds,
                NetworkTraffic.Measure(networkBefore, networkAfter),
                new DiskMetrics(ReadDiskVolumes(), ReadDiskRate(diskRead), ReadDiskRate(diskWrite)));
        }
        finally { if (query != IntPtr.Zero) PdhCloseQuery(query); }
    }
    private static IntPtr AddOptionalCounter(IntPtr query, string path) =>
        PdhAddEnglishCounter(query, path, UIntPtr.Zero, out var counter) == 0 ? counter : IntPtr.Zero;

    private static double? ReadDiskRate(IntPtr counter) =>
        counter != IntPtr.Zero &&
        PdhGetFormattedCounterValue(counter, PdhFormatDouble | PdhFormatNoScale | PdhFormatNoCap100, out _, out var rate) == 0 &&
        rate.Status is 0 or 1 && double.IsFinite(rate.Value) && rate.Value >= 0 ? rate.Value : null;

    private static DiskVolume[] ReadDiskVolumes()
    {
        DriveInfo[] drives;
        try { drives = DriveInfo.GetDrives(); }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { return []; }
        var volumes = new List<DiskVolume>();
        foreach (var drive in drives)
        {
            try
            {
                if (drive.DriveType != DriveType.Fixed || !drive.IsReady) continue;
                var total = drive.TotalSize;
                var free = drive.TotalFreeSpace;
                if (total > 0 && free >= 0 && free <= total)
                    volumes.Add(new(drive.Name.TrimEnd('\\', '/'), (ulong)(total - free), (ulong)total));
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
        }
        return volumes.ToArray();
    }

    private static void Check(uint status) { if (status != 0) throw new InvalidOperationException($"系统性能计数器读取失败：0x{status:X8}"); }
}
