using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;

namespace Hako.Platform;

public sealed record NetworkMetrics(bool Available, double? DownloadBytesPerSecond, double? UploadBytesPerSecond,
    int InterfaceCount, string? Message = null);

public static class NetworkTraffic
{
    public sealed record Counters(ulong Received, ulong Sent);
    public sealed record Sample(IReadOnlyDictionary<string, Counters> Interfaces, long Timestamp, string? Error = null);

    // MIB_IF_ROW2 uses 64-bit octet counters. The hardware flag excludes virtual
    // adapters and VPN/filter layers, which otherwise count the same traffic twice.
    // Hardware flags can remain on removed USB adapters; also check OperStatus.
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct InterfaceRow
    {
        public ulong Luid;
        public uint Index;
        public Guid Guid;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 257)] public string Alias;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 257)] public string Description;
        public uint PhysicalAddressLength;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 32)] public byte[] PhysicalAddress;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 32)] public byte[] PermanentPhysicalAddress;
        public uint Mtu, Type, TunnelType, MediaType, PhysicalMediumType, AccessType, DirectionType;
        public byte Flags;
        public uint OperStatus, AdminStatus, MediaConnectState;
        public Guid NetworkGuid;
        public uint ConnectionType;
        public ulong TransmitLinkSpeed, ReceiveLinkSpeed;
        public ulong InOctets, InUcastPkts, InNUcastPkts, InDiscards, InErrors, InUnknownProtos,
            InUcastOctets, InMulticastOctets, InBroadcastOctets;
        public ulong OutOctets, OutUcastPkts, OutNUcastPkts, OutDiscards, OutErrors,
            OutUcastOctets, OutMulticastOctets, OutBroadcastOctets, OutQLen;
    }
    [StructLayout(LayoutKind.Sequential)]
    private struct InterfaceTable { public uint Count; public InterfaceRow First; }

    [DllImport("iphlpapi.dll")]
    private static extern uint GetIfTable2(out IntPtr table);
    [DllImport("iphlpapi.dll")]
    private static extern void FreeMibTable(IntPtr table);

    public static Sample Capture()
    {
        IntPtr table = IntPtr.Zero;
        try
        {
            var status = GetIfTable2(out table);
            if (status != 0) throw new Win32Exception((int)status);
            var count = Marshal.ReadInt32(table);
            if (count < 0 || count > 65536) throw new InvalidOperationException("网络接口数量无效。");
            var offset = Marshal.OffsetOf<InterfaceTable>(nameof(InterfaceTable.First)).ToInt32();
            var size = Marshal.SizeOf<InterfaceRow>();
            var interfaces = new Dictionary<string, Counters>();
            for (var i = 0; i < count; i++)
            {
                var row = Marshal.PtrToStructure<InterfaceRow>(IntPtr.Add(table, checked(offset + i * size)));
                if (!IsIncluded(row.Type, row.Flags, row.OperStatus)) continue;
                var id = row.Guid == Guid.Empty ? "luid:" + row.Luid : row.Guid.ToString("D");
                interfaces[id] = new Counters(row.InOctets, row.OutOctets);
            }
            return new Sample(interfaces, Stopwatch.GetTimestamp());
        }
        catch (Exception error) when (error is Win32Exception or InvalidOperationException or DllNotFoundException or EntryPointNotFoundException)
        {
            return new Sample(new Dictionary<string, Counters>(), Stopwatch.GetTimestamp(), "无法读取物理网卡流量，请稍后刷新。");
        }
        finally { if (table != IntPtr.Zero) FreeMibTable(table); }
    }

    public static bool IsIncluded(uint type, byte flags, uint operStatus) =>
        (flags & 1) != 0 && (flags & 2) == 0 && type is not 24 and not 131
        // IfOperStatusNotPresent = 6: hardware is absent. Down/disconnected adapters
        // still count, so unplugging a cable does not change the sampling set.
        && operStatus != 6;

    public static NetworkMetrics Measure(Sample before, Sample after)
    {
        if (before.Error is not null || after.Error is not null)
            return new(false, null, null, after.Interfaces.Count, after.Error ?? before.Error);
        if (before.Interfaces.Count == 0 || after.Interfaces.Count == 0)
            return new(false, null, null, 0, "未发现可统计的物理网卡。");
        var seconds = (after.Timestamp - before.Timestamp) / (double)Stopwatch.Frequency;
        if (!double.IsFinite(seconds) || seconds <= 0 || before.Interfaces.Count != after.Interfaces.Count)
            return Changed(after.Interfaces.Count);
        double received = 0, sent = 0;
        foreach (var (id, current) in after.Interfaces)
        {
            if (!before.Interfaces.TryGetValue(id, out var previous) || current.Received < previous.Received || current.Sent < previous.Sent)
                return Changed(after.Interfaces.Count);
            received += current.Received - previous.Received;
            sent += current.Sent - previous.Sent;
        }
        return new(true, received / seconds, sent / seconds, after.Interfaces.Count);
    }

    private static NetworkMetrics Changed(int count) => new(false, null, null, count, "采样期间网卡发生变化或计数器重置，请刷新重试。");

    public static string FormatRate(double? bytes)
    {
        if (bytes is not double value || !double.IsFinite(value) || value < 0) return "—";
        var units = new[] { "B/s", "KiB/s", "MiB/s", "GiB/s", "TiB/s" };
        var index = 0;
        while (value >= 1024 && index < units.Length - 1) { value /= 1024; index++; }
        return $"{value.ToString(index == 0 ? "F0" : "F1")} {units[index]}";
    }
}
