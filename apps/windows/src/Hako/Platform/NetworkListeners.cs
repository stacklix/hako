using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.Globalization;
using System.Linq;
using System.Net;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Hako.Core;

namespace Hako.Platform;

public sealed record ListenerProcess(int ProcessId, string? ProcessName, string? StartedAt, long? UptimeSeconds,
    string[] Addresses, string? Category = null);
public sealed record ListenerPort(string Protocol, int Port, ListenerProcess[] Processes);
public sealed record ListenerSnapshot(string CollectedAt, ListenerPort[] Ports, string[] Warnings)
{
    // Unknown/exited owners stay visible under User with a classification notice.
    public ListenerPort[] PortsForCategory(string category) => Ports
        .Select(port => port with { Processes = port.Processes.Where(process =>
            (process.Category == "system" ? "system" : "user") == category).ToArray() })
        .Where(port => port.Processes.Length > 0).ToArray();
}

public sealed class NetworkListeners
{
    public sealed record Endpoint(string Protocol, int Port, string Address, int ProcessId);
    public sealed record ProcessInfo(string? Name, DateTimeOffset? StartedAt, int? SessionId = null)
    {
        public string? Category => SessionId switch { 0 => "system", > 0 => "user", _ => null };
    }

    [DllImport("iphlpapi.dll")]
    private static extern uint GetExtendedTcpTable(IntPtr table, ref int size, [MarshalAs(UnmanagedType.Bool)] bool order,
        uint family, int tableClass, uint reserved);
    [DllImport("iphlpapi.dll")]
    private static extern uint GetExtendedUdpTable(IntPtr table, ref int size, [MarshalAs(UnmanagedType.Bool)] bool order,
        uint family, int tableClass, uint reserved);

    public Task<ListenerSnapshot> ReadAsync(CancellationToken token) => Task.Run(() => Capture(token), token);

    private static ListenerSnapshot Capture(CancellationToken token)
    {
        var endpoints = new List<Endpoint>();
        var warnings = new List<string>();
        var succeeded = 0;
        foreach (var protocol in new[] { "TCP", "UDP" })
        foreach (var family in new uint[] { 2, 23 }) // AF_INET / AF_INET6
        {
            token.ThrowIfCancellationRequested();
            try { endpoints.AddRange(ReadTable(protocol, family, token)); succeeded++; }
            catch (Exception e) when (e is Win32Exception or InvalidOperationException)
            { warnings.Add($"{protocol} IPv{(family == 2 ? 4 : 6)} 端口读取失败，结果可能不完整。"); }
        }
        if (succeeded == 0) throw new AgentActionException("sample_failed", "无法读取本机监听端口。");
        var processSnapshot = ProcessSnapshot.Capture(token);
        var snapshot = Merge(endpoints, pid => processSnapshot is not null && processSnapshot.TryGetValue(pid, out var process)
            ? process : ReadProcess(pid), DateTimeOffset.UtcNow, token);
        if (snapshot.Ports.SelectMany(port => port.Processes).Any(process => process.ProcessName is null || process.StartedAt is null))
            warnings.Add("部分进程信息不可读取（权限受限或进程已退出），名称或运行时长暂不可用。");
        if (snapshot.Ports.SelectMany(port => port.Processes).Any(process => process.Category is null))
            warnings.Add("部分进程分类暂不可用，已暂列于用户页签。");
        snapshot = snapshot with { Warnings = warnings.ToArray() };
        // Never silently truncate ports or exceed the WebSocket message budget.
        if (JsonSerializer.SerializeToUtf8Bytes(snapshot, AgentConnection.Json).Length > 48 * 1024)
            throw new AgentActionException("result_too_large", "监听端口数据超出消息大小限制。");
        return snapshot;
    }

    public static ListenerSnapshot Merge(IEnumerable<Endpoint> endpoints, Func<int, ProcessInfo> readProcess,
        DateTimeOffset collectedAt, CancellationToken token = default)
    {
        var cache = new Dictionary<int, ProcessInfo>();
        var ports = endpoints.GroupBy(endpoint => (endpoint.Protocol, endpoint.Port))
            .OrderBy(group => group.Key.Port).ThenBy(group => group.Key.Protocol, StringComparer.Ordinal)
            .Select(group => new ListenerPort(group.Key.Protocol, group.Key.Port,
                group.GroupBy(endpoint => endpoint.ProcessId).OrderBy(owner => owner.Key).Select(owner =>
                {
                    token.ThrowIfCancellationRequested();
                    if (!cache.TryGetValue(owner.Key, out var process)) cache.Add(owner.Key, process = readProcess(owner.Key));
                    var started = process.StartedAt is { } start && start <= collectedAt ? start : (DateTimeOffset?)null;
                    return new ListenerProcess(owner.Key, process.Name, started?.ToString("O", CultureInfo.InvariantCulture),
                        started is { } at ? (long)(collectedAt - at).TotalSeconds : null,
                        owner.Select(endpoint => endpoint.Address).Distinct(StringComparer.Ordinal).Order(StringComparer.Ordinal).ToArray(), process.Category);
                }).ToArray())).ToArray();
        return new(collectedAt.ToString("O", CultureInfo.InvariantCulture), ports, []);
    }

    private static ProcessInfo ReadProcess(int pid)
    {
        string? name = null;
        DateTimeOffset? started = null;
        int? sessionId = null;
        try
        {
            using var process = Process.GetProcessById(pid);
            // Name may be readable even when the process start time is protected.
            try { name = process.ProcessName; }
            catch (Exception e) when (e is Win32Exception or InvalidOperationException or NotSupportedException) { }
            try { started = new DateTimeOffset(process.StartTime.ToUniversalTime()); }
            catch (Exception e) when (e is Win32Exception or InvalidOperationException or NotSupportedException) { }
            try { sessionId = process.SessionId; }
            catch (Exception e) when (e is Win32Exception or InvalidOperationException or NotSupportedException) { }
        }
        catch (Exception e) when (e is ArgumentException or Win32Exception or InvalidOperationException) { }
        return new(name, started, sessionId);
    }

    private static Endpoint[] ReadTable(string protocol, uint family, CancellationToken token)
    {
        var tcp = protocol == "TCP";
        var ipv6 = family == 23;
        uint Read(IntPtr table, ref int bytes) => tcp
            ? GetExtendedTcpTable(table, ref bytes, false, family, 3, 0) // TCP_TABLE_OWNER_PID_LISTENER
            : GetExtendedUdpTable(table, ref bytes, false, family, 1, 0); // UDP_TABLE_OWNER_PID
        var size = 0;
        var status = Read(IntPtr.Zero, ref size);
        if (status != 0 && status != 122) throw new Win32Exception((int)status);
        for (var attempt = 0; attempt < 5; attempt++)
        {
            token.ThrowIfCancellationRequested();
            if (size < 4 || size > 32 * 1024 * 1024) throw new InvalidOperationException("端口表大小无效。");
            var allocated = size;
            var buffer = Marshal.AllocHGlobal(allocated);
            try
            {
                status = Read(buffer, ref size);
                if (status == 122) continue; // Listeners can change between calls.
                if (status != 0) throw new Win32Exception((int)status);
                // All OWNER_PID row fields are DWORDs or byte arrays, aligned to 4 bytes.
                var rowSize = ipv6 ? (tcp ? 56 : 28) : (tcp ? 24 : 12);
                var count = Marshal.ReadInt32(buffer);
                if (count < 0 || count > (allocated - 4) / rowSize) throw new InvalidOperationException("端口表行数无效。");
                var result = new List<Endpoint>();
                for (var i = 0; i < count; i++)
                {
                    token.ThrowIfCancellationRequested();
                    var row = IntPtr.Add(buffer, 4 + i * rowSize);
                    // Defensive check: only TCP LISTEN, never established/outbound connections.
                    if (tcp && Marshal.ReadInt32(row, ipv6 ? 48 : 0) != 2) continue;
                    var addressBytes = new byte[ipv6 ? 16 : 4];
                    Marshal.Copy(IntPtr.Add(row, !ipv6 && tcp ? 4 : 0), addressBytes, 0, addressBytes.Length);
                    var address = ipv6 ? new IPAddress(addressBytes, (uint)Marshal.ReadInt32(row, 16)) : new IPAddress(addressBytes);
                    var portOffset = ipv6 ? 20 : (tcp ? 8 : 4);
                    var port = (Marshal.ReadByte(row, portOffset) << 8) | Marshal.ReadByte(row, portOffset + 1);
                    var pid = Marshal.ReadInt32(row, rowSize - 4);
                    result.Add(new(protocol, port, address.ToString(), pid));
                }
                return result.ToArray();
            }
            finally { Marshal.FreeHGlobal(buffer); }
        }
        throw new InvalidOperationException("端口表持续变化，请重试。");
    }
}
