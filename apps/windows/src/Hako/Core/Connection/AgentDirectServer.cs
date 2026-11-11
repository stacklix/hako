using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Net.WebSockets;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace Hako.Core;

// A separate, explicitly enabled LAN endpoint. It shares the dispatcher and
// durable Workshop workers with the cloud transport; closing a socket never
// cancels an execution. Native LAN clients intentionally do not authenticate.
internal sealed class AgentDirectServer : IAsyncDisposable
{
    private readonly AgentDispatcher dispatcher;
    private readonly Func<string?> agentId;
    private readonly string localId;
    private readonly TcpListener listener;
    private readonly CancellationTokenSource stopping = new();
    private readonly HashSet<Task> clients = new();
    private readonly object gate = new();
    private readonly SemaphoreSlim capacity = new(16, 16);
    private readonly Task accepting;
    public int Port => ((IPEndPoint)listener.LocalEndpoint).Port;

    internal AgentDirectServer(AgentDispatcher dispatcher, int port, Func<string?> agentId, string identity)
    {
        this.dispatcher = dispatcher; this.agentId = agentId;
        localId = "lan-" + Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(identity)))[..16].ToLowerInvariant();
        listener = new TcpListener(IPAddress.IPv6Any, port);
        listener.Server.DualMode = true;
        listener.Start(16);
        accepting = AcceptAsync();
    }

    private async Task AcceptAsync()
    {
        try
        {
            while (!stopping.IsCancellationRequested)
            {
                var client = await listener.AcceptTcpClientAsync(stopping.Token);
                if (!capacity.Wait(0)) { client.Dispose(); continue; }
                var work = RunClientAsync(client);
                lock (gate) clients.Add(work);
                _ = work.ContinueWith(_ => { lock (gate) clients.Remove(work); }, TaskScheduler.Default);
            }
        }
        catch (Exception e) when (stopping.IsCancellationRequested && e is OperationCanceledException or SocketException or ObjectDisposedException) { }
    }

    private async Task RunClientAsync(TcpClient client)
    {
        try { await ServeAsync(client); }
        finally { capacity.Release(); }
    }

    internal static bool IsLANPeer(IPAddress address)
    {
        if (address.IsIPv4MappedToIPv6) address = address.MapToIPv4();
        if (IPAddress.IsLoopback(address)) return true;
        var raw = address.GetAddressBytes();
        var privateAddress = raw.Length == 4
            ? raw[0] == 10 || raw[0] == 192 && raw[1] == 168 || raw[0] == 172 && raw[1] is >= 16 and <= 31 || raw[0] == 169 && raw[1] == 254
            : (raw[0] & 0xfe) == 0xfc || raw[0] == 0xfe && (raw[1] & 0xc0) == 0x80;
        if (!privateAddress) return false;
        foreach (var adapter in NetworkInterface.GetAllNetworkInterfaces())
        {
            if (adapter.OperationalStatus != OperationalStatus.Up || adapter.NetworkInterfaceType == NetworkInterfaceType.Loopback) continue;
            foreach (var local in adapter.GetIPProperties().UnicastAddresses)
            {
                var own = local.Address;
                if (own.AddressFamily != address.AddressFamily || local.PrefixLength <= 0) continue;
                var peer = address.GetAddressBytes(); var bytes = own.GetAddressBytes();
                var count = local.PrefixLength;
                var matches = true;
                for (var index = 0; index < peer.Length && count > 0; index++, count -= 8)
                {
                    var mask = (byte)(0xff << Math.Max(0, 8 - count));
                    if ((peer[index] & mask) != (bytes[index] & mask)) { matches = false; break; }
                }
                if (matches) return true;
            }
        }
        return false;
    }

    private async Task ServeAsync(TcpClient client)
    {
        using (client)
        using (var lifetime = CancellationTokenSource.CreateLinkedTokenSource(stopping.Token))
        {
            try
            {
                if (client.Client.RemoteEndPoint is not IPEndPoint peer || !IsLANPeer(peer.Address)) return;
                client.NoDelay = true;
                var stream = client.GetStream();
                using var handshake = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token);
                handshake.CancelAfter(TimeSpan.FromSeconds(5));
                var path = await UpgradeAsync(stream, handshake.Token);
                using var socket = WebSocket.CreateFromStream(stream, true, null, TimeSpan.FromSeconds(15));
                using var writing = new SemaphoreSlim(1, 1);
                async Task Send(object frame)
                {
                    var bytes = JsonSerializer.SerializeToUtf8Bytes(frame, AgentConnection.Json);
                    if (bytes.Length > 64 * 1024) throw new InvalidDataException("Direct reply is too large.");
                    using var timeout = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token);
                    timeout.CancelAfter(TimeSpan.FromSeconds(5));
                    await writing.WaitAsync(timeout.Token);
                    try { await socket.SendAsync(bytes, WebSocketMessageType.Text, true, timeout.Token); }
                    finally { writing.Release(); }
                }
                await Send(new { type = "ready" });
                var workers = new List<Task>();
                var reading = ReadAsync(socket, lifetime.Token);
                try
                {
                    if (path.StartsWith("/workshop/", StringComparison.Ordinal))
                    {
                        var parts = path.Split('/');
                        if (parts.Length != 4 || !Guid.TryParse(parts[2], out _) || !long.TryParse(parts[3], out var cursor) || cursor < 0)
                            throw new InvalidDataException("Invalid subscription.");
                        var parameters = JsonSerializer.SerializeToElement(new { operationId = parts[2], cursor });
                        var pushing = Task.Run(async () =>
                        {
                            try { await dispatcher.WatchWorkshopAsync(parameters, page => Send(new { type = "update", body = new { result = page } }), lifetime.Token); }
                            catch (OperationCanceledException) when (lifetime.IsCancellationRequested) { }
                            catch (Exception e)
                            {
                                var error = Failure(e);
                                await Send(new { type = "update", body = new { error } });
                            }
                        });
                        workers.Add(pushing);
                        // The only inbound traffic for subscriptions is WebSocket control
                        // traffic, handled by the runtime; a data frame closes the stream.
                        await Task.WhenAny(reading, pushing);
                        return;
                    }
                    if (path != "/agents") throw new InvalidDataException("Unknown direct endpoint.");
                    while (!lifetime.IsCancellationRequested)
                    {
                        using var message = await reading;
                        var command = message.RootElement.Clone();
                        reading = ReadAsync(socket, lifetime.Token);
                        var id = command.GetProperty("id").GetString()!;
                        if (id.Length is 0 or > 80) throw new InvalidDataException("Invalid request ID.");
                        workers.RemoveAll(value => value.IsCompleted);
                        if (workers.Count >= 4)
                        {
                            await Send(new { type = "reply", id, status = 429, body = new { error = "agent_busy" } });
                            continue;
                        }
                        workers.Add(Task.Run(async () =>
                        {
                            try
                            {
                                if (command.GetProperty("type").GetString() == "list")
                                {
                                    await Send(new { type = "reply", id, status = 200, body = new { agents = new[] {
                                        new { id = agentId() ?? localId, name = Environment.MachineName, online = true, capabilities = dispatcher.Capabilities }
                                    } } });
                                    return;
                                }
                                if (command.GetProperty("type").GetString() != "request") throw new AgentActionException("invalid_request", "不支持的直连请求。");
                                if (command.TryGetProperty("agentId", out var target) && target.GetString() is { Length: > 0 } requested && requested != (agentId() ?? localId))
                                    throw new AgentActionException("agent_changed", "局域网地址对应的电脑已改变，请返回列表重新选择电脑。");
                                var body = command.GetProperty("body");
                                var method = body.GetProperty("method").GetString()!;
                                if (!method.StartsWith("query.codex.", StringComparison.Ordinal) && !method.StartsWith("action.codex.", StringComparison.Ordinal))
                                    throw new AgentActionException("unsupported_method", "局域网直连当前仅支持代码工坊。");
                                var result = await dispatcher.InvokeAsync(method, body.GetProperty("version").GetInt32(), body.GetProperty("params"), lifetime.Token);
                                await Send(new { type = "reply", id, status = 200, body = new { result } });
                            }
                            catch (OperationCanceledException) when (lifetime.IsCancellationRequested) { }
                            catch (Exception e) { await Send(new { type = "reply", id, status = 200, body = new { error = Failure(e) } }); }
                        }));
                    }
                }
                finally
                {
                    lifetime.Cancel(); socket.Abort();
                    try { using var ignored = await reading; } catch { }
                    try { await Task.WhenAll(workers); } catch { }
                }
            }
            catch (Exception e) when (e is IOException or SocketException or WebSocketException or OperationCanceledException or InvalidDataException or JsonException or KeyNotFoundException or InvalidOperationException or FormatException or ArgumentException) { }
        }
    }

    private static CapabilityError Failure(Exception error) => error is AgentActionException action
        ? new(action.Code, action.Message) : new("execution_failed", "直连请求失败，请检查电脑端状态。");

    private static async Task<JsonDocument> ReadAsync(WebSocket socket, CancellationToken token)
    {
        var buffer = new byte[17 * 1024];
        var size = 0;
        while (true)
        {
            var frame = await socket.ReceiveAsync(buffer.AsMemory(size), token);
            if (frame.MessageType != WebSocketMessageType.Text) throw new InvalidDataException("Text frames required.");
            size += frame.Count;
            if (size > 16 * 1024) throw new InvalidDataException("Request too large.");
            if (frame.EndOfMessage) return JsonDocument.Parse(buffer.AsMemory(0, size));
        }
    }

    private static async Task<string> UpgradeAsync(NetworkStream stream, CancellationToken token)
    {
        var bytes = new List<byte>();
        var one = new byte[1];
        while (bytes.Count < 8192)
        {
            if (await stream.ReadAsync(one, token) == 0) throw new EndOfStreamException();
            bytes.Add(one[0]);
            if (bytes.Count >= 4 && bytes[^4] == 13 && bytes[^3] == 10 && bytes[^2] == 13 && bytes[^1] == 10) break;
        }
        var lines = Encoding.ASCII.GetString(bytes.ToArray()).Split("\r\n", StringSplitOptions.None);
        if (bytes.Count < 4 || bytes[^4] != 13 || bytes[^3] != 10 || bytes[^2] != 13 || bytes[^1] != 10)
            throw new InvalidDataException("Headers too large.");
        var request = lines[0].Split(' ');
        var headers = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (var line in lines.Skip(1).Where(value => value.Length > 0))
        {
            var colon = line.IndexOf(':');
            if (colon < 1 || !headers.TryAdd(line[..colon].Trim(), line[(colon + 1)..].Trim())) throw new InvalidDataException("Invalid headers.");
        }
        if (request.Length != 3 || request[0] != "GET" || request[2] != "HTTP/1.1" || headers.ContainsKey("Origin") || !headers.ContainsKey("Host") ||
            !headers.TryGetValue("Upgrade", out var upgrade) || !upgrade.Equals("websocket", StringComparison.OrdinalIgnoreCase) ||
            !headers.TryGetValue("Connection", out var connection) || !connection.Split(',').Any(value => value.Trim().Equals("Upgrade", StringComparison.OrdinalIgnoreCase)) ||
            !headers.TryGetValue("Sec-WebSocket-Version", out var version) || version != "13" ||
            !headers.TryGetValue("Sec-WebSocket-Key", out var key) || Convert.FromBase64String(key).Length != 16 ||
            (request[1] != "/agents" && !request[1].StartsWith("/workshop/", StringComparison.Ordinal)))
            throw new InvalidDataException("Invalid WebSocket upgrade.");
        var accept = Convert.ToBase64String(SHA1.HashData(Encoding.ASCII.GetBytes(key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11")));
        var response = Encoding.ASCII.GetBytes("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: " + accept + "\r\n\r\n");
        await stream.WriteAsync(response, token);
        return request[1];
    }

    public async ValueTask DisposeAsync()
    {
        stopping.Cancel(); listener.Stop();
        try { await accepting; } catch { }
        Task[] pending; lock (gate) pending = clients.ToArray();
        try { await Task.WhenAll(pending); } catch { }
        stopping.Dispose(); capacity.Dispose();
    }
}
