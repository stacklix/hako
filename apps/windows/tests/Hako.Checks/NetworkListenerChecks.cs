using System;
using System.Diagnostics;
using System.Linq;
using System.Net;
using System.Net.Sockets;
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
        var reads = 0;
        var merged = NetworkListeners.Merge([
            new("TCP", 8080, "0.0.0.0", 10), new("TCP", 8080, "::", 10),
            new("TCP", 8080, "::", 10), new("TCP", 8080, "127.0.0.2", 11),
            new("UDP", 8080, "fe80::1%3", 10), new("TCP", 80, "127.0.0.1", 12)
        ], pid => { reads++; return pid == 11 ? new(null, null) : new("test", now.AddSeconds(-90061)); }, now);
        var tcp = merged.Ports.Single(port => port.Protocol == "TCP" && port.Port == 8080);
        if (merged.Ports.Length != 3 || merged.Ports[0].Port != 80 || tcp.Processes.Length != 2 || reads != 3
            || !tcp.Processes[0].Addresses.SequenceEqual(new[] { "0.0.0.0", "::" })
            || tcp.Processes[0].UptimeSeconds != 90061 || tcp.Processes[1].ProcessName != null
            || tcp.Processes[1].StartedAt != null || tcp.Processes[1].UptimeSeconds != null
            || merged.Ports.Single(port => port.Protocol == "UDP").Processes[0].Addresses[0] != "fe80::1%3")
            throw new Exception("Listener merge lost addresses, owners, protocols or process timing");
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
}
