using System;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Hako.Core;
using Hako.Platform;

internal static class NetworkListenerChecks
{
    public static async Task RunAsync()
    {
        var now = DateTimeOffset.Parse("2026-10-31T12:00:00Z");
        CheckProcessSnapshot();
        CheckProcessOrigin();
        var reads = 0;
        var merged = NetworkListeners.Merge([
            new("TCP", 8080, "0.0.0.0", 10), new("TCP", 8080, "::", 10),
            new("TCP", 8080, "::", 10), new("TCP", 8080, "127.0.0.2", 11),
            new("UDP", 8080, "fe80::1%3", 10), new("TCP", 80, "127.0.0.1", 12)
        ], pid => { reads++; return pid == 11 ? new(null, null, 0, @"C:\Apps\worker.exe")
            : pid == 10 ? new("svchost", now.AddSeconds(-90061), 0) : new(null, now.AddSeconds(-90061)); }, now);
        var tcp = merged.Ports.Single(port => port.Protocol == "TCP" && port.Port == 8080);
        if (merged.Ports.Length != 3 || merged.Ports[0].Port != 80 || tcp.Processes.Length != 2 || reads != 3
            || !tcp.Processes[0].Addresses.SequenceEqual(new[] { "0.0.0.0", "::" })
            || tcp.Processes[0].UptimeSeconds != 90061 || tcp.Processes[1].ProcessName != null
            || tcp.Processes[1].StartedAt != null || tcp.Processes[1].UptimeSeconds != null
            || merged.Ports.Single(port => port.Protocol == "UDP").Processes[0].Addresses[0] != "fe80::1%3")
            throw new Exception("Listener merge lost addresses, owners, protocols or process timing");
        var systemPorts = merged.PortsForCategory("system");
        var userPorts = merged.PortsForCategory("user");
        if (systemPorts.Length != 2 || userPorts.Length != 2
            || systemPorts.Any(port => port.Processes.Any(process => process.Category != "system"))
            || userPorts.Any(port => port.Processes.Any(process => process.Category == "system"))
            || systemPorts.Single(port => port.Protocol == "TCP").Processes.Single().ProcessId != 10
            || userPorts.Single(port => port.Port == 8080).Processes.Single().ProcessId != 11
            || userPorts.Single(port => port.Port == 80).Processes.Single().Category != null
            || tcp.Processes.Length != 2)
            throw new Exception("System/User filtering must split mixed owners, retain unknown owners and preserve the original merged snapshot");
        var future = NetworkListeners.Merge([new("TCP", 80, "::", 1)], _ => new("reused", now.AddSeconds(1)), now);
        if (future.Ports[0].Processes[0].UptimeSeconds != null || future.Ports[0].Processes[0].StartedAt != null)
            throw new Exception("Future/reused process start time must be unavailable");
        using var cancelled = new CancellationTokenSource(); cancelled.Cancel();
        try { await new NetworkListeners().ReadAsync(cancelled.Token); throw new Exception("Listener cancellation ignored"); }
        catch (OperationCanceledException) { }

        // Test sockets are loopback-only, short-lived, and serve no HTTP content.
        using var tcp4 = new TcpListener(IPAddress.Loopback, 0);
        tcp4.Start();
        var port = ((IPEndPoint)tcp4.LocalEndpoint).Port;
        using var tcpOther = new TcpListener(IPAddress.Parse("127.0.0.2"), port);
        tcpOther.Start();
        using var tcp6 = new TcpListener(IPAddress.IPv6Loopback, port);
        tcp6.Server.DualMode = false;
        tcp6.Start();
        using var udp4 = new UdpClient(new IPEndPoint(IPAddress.Loopback, 0));
        var udpPort = ((IPEndPoint)udp4.Client.LocalEndPoint!).Port;
        using var udp6 = new UdpClient(AddressFamily.InterNetworkV6);
        udp6.Client.DualMode = false;
        udp6.Client.Bind(new IPEndPoint(IPAddress.IPv6Loopback, udpPort));
        using var client = new TcpClient();
        await client.ConnectAsync(IPAddress.Loopback, port);
        using var accepted = await tcp4.AcceptTcpClientAsync();
        var clientPort = ((IPEndPoint)client.Client.LocalEndPoint!).Port;

        var dispatcher = new AgentDispatcher(new SystemMetrics());
        using var empty = JsonDocument.Parse("{}");
        var snapshot = (ListenerSnapshot)(await dispatcher.InvokeAsync("query.network.listeners", 1, empty.RootElement, CancellationToken.None))!;
        var owner = snapshot.Ports.Single(item => item.Protocol == "TCP" && item.Port == port)
            .Processes.Single(process => process.ProcessId == Environment.ProcessId);
        using var self = Process.GetCurrentProcess();
        if (!owner.Addresses.SequenceEqual(new[] { "127.0.0.1", "127.0.0.2", "::1" })
            || owner.ProcessName != self.ProcessName || owner.UptimeSeconds is not >= 0 || owner.StartedAt == null
            || owner.Category != "user"
            || Math.Abs((DateTimeOffset.Parse(owner.StartedAt).UtcDateTime - self.StartTime.ToUniversalTime()).TotalSeconds) > 1)
            throw new Exception("Real TCP listener IP merge / PID / process start time failed");
        var udpOwner = snapshot.Ports.Single(item => item.Protocol == "UDP" && item.Port == udpPort)
            .Processes.Single(process => process.ProcessId == Environment.ProcessId);
        if (!udpOwner.Addresses.SequenceEqual(new[] { "127.0.0.1", "::1" })
            || snapshot.Ports.Any(item => item.Protocol == "TCP" && item.Port == clientPort && item.Processes.Any(process => process.ProcessId == Environment.ProcessId)))
            throw new Exception("Real UDP merge failed or established TCP connection was reported as listening");
        using var extra = JsonDocument.Parse("{\"port\":80}");
        try { await dispatcher.InvokeAsync("query.network.listeners", 1, extra.RootElement, CancellationToken.None); throw new Exception("Listener query accepted extra params"); }
        catch (AgentActionException e) when (e.Code == "invalid_params") { }
        var json = JsonSerializer.SerializeToElement(snapshot, AgentConnection.Json);
        if (!json.TryGetProperty("collectedAt", out _) || !json.TryGetProperty("ports", out _) || !json.TryGetProperty("warnings", out _))
            throw new Exception("Listener JSON contract is invalid");
        Console.WriteLine("PASS: real IPv4/IPv6 TCP/UDP listener tables, IP/owner merge, process uptime, unavailable metadata, query params and cancellation");
    }

    private static void CheckProcessSnapshot()
    {
        var now = DateTimeOffset.UtcNow;
        var real = ProcessSnapshot.Capture(CancellationToken.None)
            ?? throw new Exception("System process snapshot unavailable on Windows");
        using var self = Process.GetCurrentProcess();
        if (!real.TryGetValue(self.Id, out var current) || current.Name != self.ProcessName || current.StartedAt is not { } started
            || current.SessionId != self.SessionId
            || Math.Abs((started.UtcDateTime - self.StartTime.ToUniversalTime()).TotalMilliseconds) > 1)
            throw new Exception("System snapshot creation time does not match the current process");
        if (!real.TryGetValue(4, out var system) || system.StartedAt is not { } systemStart || systemStart > now || system.Category != "system")
            throw new Exception("System process creation time must be readable without opening the protected process");

        var headerSize = Marshal.SizeOf<ProcessSnapshot.Header>();
        var stride = (headerSize + 48 + 7) & ~7;
        var memory = Marshal.AllocHGlobal(stride * 2);
        try
        {
            var name = "worker.测试.exe";
            var nameBytes = System.Text.Encoding.Unicode.GetBytes(name);
            var first = new ProcessSnapshot.Header { NextEntryOffset = (uint)stride, ProcessId = new IntPtr(10), SessionId = 17,
                CreateTime = now.AddSeconds(-90061).UtcDateTime.ToFileTimeUtc(),
                ImageName = new() { Length = (ushort)nameBytes.Length, MaximumLength = (ushort)nameBytes.Length,
                    Buffer = IntPtr.Add(memory, headerSize) } };
            Marshal.Copy(nameBytes, 0, first.ImageName.Buffer, nameBytes.Length);
            Marshal.StructureToPtr(first, memory, false);
            Marshal.StructureToPtr(new ProcessSnapshot.Header { ProcessId = new IntPtr(11) }, IntPtr.Add(memory, stride), false);
            var parsed = ProcessSnapshot.Parse(memory, stride * 2, CancellationToken.None);
            if (parsed.Count != 2 || parsed[10].Name != "worker.测试" || parsed[10].StartedAt != now.AddSeconds(-90061)
                || parsed[10].Category != "user" || parsed[11].Category != null
                || parsed[11].StartedAt != null || parsed[11].Name != null)
                throw new Exception("Process snapshot lost Unicode names, creation times or nullable metadata");
            void RejectMalformed()
            {
                try { ProcessSnapshot.Parse(memory, stride * 2, CancellationToken.None); throw new Exception("Malformed native process snapshot accepted"); }
                catch (InvalidDataException) { }
            }
            first.NextEntryOffset = 1;
            Marshal.StructureToPtr(first, memory, false);
            RejectMalformed();
            first.NextEntryOffset = (uint)stride;
            first.ImageName.Buffer = IntPtr.Add(memory, stride * 2 - 2);
            Marshal.StructureToPtr(first, memory, false);
            RejectMalformed();
            first.ImageName.Length = 0;
            first.CreateTime = long.MaxValue;
            Marshal.StructureToPtr(first, memory, false);
            RejectMalformed();
            first.CreateTime = 0;
            first.SessionId = uint.MaxValue;
            Marshal.StructureToPtr(first, memory, false);
            RejectMalformed();
        }
        finally { Marshal.FreeHGlobal(memory); }
        Console.WriteLine("PASS: native process creation times including protected System PID 4; Unicode, nullable metadata and malformed native buffer checks");
    }

    private static void CheckProcessOrigin()
    {
        foreach (var (name, path, expected) in new (string?, string?, string?)[]
        {
            ("pythonw", null, "user"), ("verge-mihomo", null, "user"), ("verge-service", null, "user"),
            ("clash-verge", @"C:\Program Files\Clash Verge\clash-verge.exe", "user"),
            ("svchost", null, "system"), ("System", null, "system"),
            ("svchost", @"C:\Apps\svchost.exe", "user"),
            ("spoolsv", @"C:\Windows\System32\spoolsv.exe", "system"),
            ("spoolsv", @"\\?\C:\WINDOWS\System32\spoolsv.exe", "system"),
            ("worker", @"c:\windows\SysWOW64\worker.exe", "system"),
            ("python", @"C:\Windows.old\python.exe", "user"),
            ("python", @"C:\Windows\..\Tools\python.exe", "user"),
            (null, null, null)
        })
        {
            if (ProcessOrigin.Classify(name, path, @"C:\Windows") != expected)
                throw new Exception($"Process origin classification failed for {name} / {path}");
        }
        if (new NetworkListeners.ProcessInfo("pythonw", null, 0).Category != "user"
            || new NetworkListeners.ProcessInfo("verge-mihomo", null, 0).Category != "user")
            throw new Exception("Third-party programs must remain User when running as a service in Session 0");
        var currentPath = ProcessOrigin.ReadExecutablePath(Environment.ProcessId);
        if (string.IsNullOrWhiteSpace(currentPath) || ProcessOrigin.Classify("Hako.Checks", currentPath) != "user")
            throw new Exception("Actual executable image path could not be read/classified");
        Console.WriteLine("PASS: Windows binary origin, third-party service Session 0, Python/Verge, unreadable paths and directory boundaries");
    }
}
