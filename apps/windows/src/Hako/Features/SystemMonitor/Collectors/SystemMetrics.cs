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

public sealed class SystemMetrics
{
    private const uint PdhFormatDouble = 0x200;
    private const uint PdhFormatNoScale = 0x1000;
    private const uint PdhFormatNoCap100 = 0x8000;
    private readonly SemaphoreSlim sampling = new(1, 1);
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

    public async Task<Metrics> SampleAsync(CancellationToken token)
    {
        await sampling.WaitAsync(token);
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
        finally { if (query != IntPtr.Zero) PdhCloseQuery(query); sampling.Release(); }
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
