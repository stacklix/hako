using System;
using System.Runtime.InteropServices;
using System.Threading;
using System.Threading.Tasks;

namespace Hako.Platform;

public sealed record Metrics(double CpuUsagePercent, double MemoryUsagePercent, ulong MemoryUsedBytes,
    ulong MemoryTotalBytes, string SampledAt, int SampleWindowMs, NetworkMetrics? Network = null);

public sealed class SystemMetrics
{
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
            Check(PdhCollectQueryData(query));
            var start = System.Diagnostics.Stopwatch.StartNew();
            var networkBefore = NetworkTraffic.Capture();
            await Task.Delay(1000, token);
            var networkAfter = NetworkTraffic.Capture();
            Check(PdhCollectQueryData(query));
            Check(PdhGetFormattedCounterValue(counter, 0x200, out _, out var cpu));
            if (cpu.Status != 0 && cpu.Status != 1) throw new InvalidOperationException("CPU 计数器尚未就绪。");
            var memory = new MemoryStatus { Length = (uint)Marshal.SizeOf<MemoryStatus>() };
            if (!GlobalMemoryStatusEx(ref memory) || memory.TotalPhysical == 0) throw new InvalidOperationException("无法读取物理内存。");
            var used = memory.TotalPhysical - memory.AvailablePhysical;
            return new Metrics(Math.Clamp(cpu.Value, 0, 100), used * 100.0 / memory.TotalPhysical, used,
                memory.TotalPhysical, DateTimeOffset.UtcNow.ToString("O"), (int)start.ElapsedMilliseconds,
                NetworkTraffic.Measure(networkBefore, networkAfter));
        }
        finally { if (query != IntPtr.Zero) PdhCloseQuery(query); sampling.Release(); }
    }
    private static void Check(uint status) { if (status != 0) throw new InvalidOperationException($"系统性能计数器读取失败：0x{status:X8}"); }
}
