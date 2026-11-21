using System;
using System.Buffers.Binary;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Net.WebSockets;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Hako.Core;

namespace Hako.Platform;

// A live, single-consumer session. No recorded video is written to disk, and
// closing the media socket kills only its own ADB process.
internal sealed class AndroidVideoStreams(IAndroidAdb adb, Func<Uri?> origin, string directory) : IAsyncDisposable
{
    private sealed class Session(string id, string device, AndroidEndpoint endpoint)
    {
        internal readonly string Id = id, Device = device;
        internal readonly AndroidEndpoint Endpoint = endpoint;
        internal readonly byte[] Key = RandomNumberGenerator.GetBytes(32);
        internal readonly CancellationTokenSource Lifetime = new(TimeSpan.FromSeconds(30));
        internal bool Claimed;
        internal Task? Worker;
    }
    private readonly object sync = new();
    private readonly Dictionary<string, Session> sessions = new();
    private bool disposed;
    internal object Create(string id, string device, AndroidEndpoint endpoint, int port)
    {
        lock (sync)
        {
            ObjectDisposedException.ThrowIf(disposed, this);
            foreach (var expired in sessions.Values.Where(s => s.Lifetime.IsCancellationRequested && s.Worker?.IsCompleted != false).ToArray())
            { sessions.Remove(expired.Id); expired.Lifetime.Dispose(); CryptographicOperations.ZeroMemory(expired.Key); }
            if (sessions.TryGetValue(id, out var prior))
            {
                if (prior.Device != device || prior.Endpoint.Serial != endpoint.Serial) throw new AgentActionException("stream_conflict", "视频会话目标不一致。");
                return Snapshot(prior, port);
            }
            if (sessions.Count >= 2 || sessions.Values.Any(s => s.Device == device && !s.Lifetime.IsCancellationRequested))
                throw new AgentActionException("stream_busy", "这台手机已有投屏会话，请先结束原会话。");
            var session = new Session(id, device, endpoint);
            sessions.Add(id, session);
            return Snapshot(session, port);
        }
    }
    private static object Snapshot(Session s, int port) => new { sessionId = s.Id, codec = "h264", protocol = "hako-video-v1",
        key = Convert.ToBase64String(s.Key), port, addresses = AgentLanEndpoint.Addresses(), path = "/agent/v1/streams/" + s.Id };

    internal object Stop(string id)
    {
        lock (sync) if (sessions.TryGetValue(id, out var value)) value.Lifetime.Cancel();
        return new { stopped = true };
    }
    private Session Get(string id)
    {
        lock (sync) return sessions.TryGetValue(id, out var value) && !value.Lifetime.IsCancellationRequested
            ? value : throw new AgentActionException("stream_expired", "视频会话已结束，请重新连接。");
    }
    private Task Claim(Session s, Func<Task> work)
    {
        lock (sync)
        {
            if (s.Claimed || s.Lifetime.IsCancellationRequested || disposed) throw new AgentActionException("stream_busy", "视频会话已连接或已过期。");
            s.Claimed = true; s.Lifetime.CancelAfter(TimeSpan.FromHours(1));
            return s.Worker = Task.Run(work);
        }
    }
    internal async Task AcceptAsync(string id, WebSocket socket, CancellationToken token)
    {
        var s = Get(id);
        using (var deadline = CancellationTokenSource.CreateLinkedTokenSource(token, s.Lifetime.Token))
        {
            deadline.CancelAfter(TimeSpan.FromSeconds(5));
            var bytes = new byte[1024];
            var reply = await socket.ReceiveAsync(bytes.AsMemory(), deadline.Token);
            if (!reply.EndOfMessage || reply.MessageType != WebSocketMessageType.Binary) throw new InvalidDataException("Invalid video handshake.");
            var plain = AgentLanEndpoint.Open(s.Key, bytes[..reply.Count], "video-client:" + id);
            using var json = JsonDocument.Parse(plain);
            if (json.RootElement.GetProperty("sessionId").GetString() != id ||
                Math.Abs((double)DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() - json.RootElement.GetProperty("timestamp").GetInt64()) > 30000)
                throw new InvalidDataException("Expired video handshake.");
        }
        await Claim(s, () => PumpAsync(s, socket, token));
    }
    internal object Relay(string id, string relayId, string ticket)
    {
        var s = Get(id);
        var server = origin() ?? throw new AgentActionException("stream_unavailable", "工作站没有配置服务器。");
        if (!System.Text.RegularExpressions.Regex.IsMatch(relayId, @"\A[A-Za-z0-9_-]{32,128}\z") ||
            !System.Text.RegularExpressions.Regex.IsMatch(ticket, @"\A[A-Za-z0-9_-]{32,128}\z"))
            throw new AgentActionException("invalid_params", "视频转发凭据无效。");
        // Only the configured origin may receive media; callers cannot supply a URL.
        var uri = new UriBuilder(server) { Scheme = server.Scheme == "https" ? "wss" : "ws", Path = "/ws/streams/" + relayId }.Uri;
        _ = Claim(s, async () =>
        {
            using var socket = new ClientWebSocket();
            socket.Options.Proxy = null;
            socket.Options.SetRequestHeader("Authorization", "Stream " + ticket);
            try
            {
                using var connecting = CancellationTokenSource.CreateLinkedTokenSource(s.Lifetime.Token);
                connecting.CancelAfter(TimeSpan.FromSeconds(10));
                await socket.ConnectAsync(uri, connecting.Token);
                await PumpAsync(s, socket, s.Lifetime.Token);
            }
            catch (Exception) { s.Lifetime.Cancel(); }
        });
        return new { connecting = true };
    }

    private async Task PumpAsync(Session s, WebSocket socket, CancellationToken parent)
    {
        using var lifetime = CancellationTokenSource.CreateLinkedTokenSource(parent, s.Lifetime.Token);
        var token = lifetime.Token;
        await using var source = new AndroidVideoSource(adb, s.Endpoint, directory);
        Task? reading = null, heartbeat = null;
        using var sending = new SemaphoreSlim(1, 1);
        ulong sequence = 0;
        async Task Send(byte kind, ReadOnlyMemory<byte> payload)
        {
            await sending.WaitAsync(token);
            try {
            var plain = new byte[9 + payload.Length];
            BinaryPrimitives.WriteUInt64BigEndian(plain, sequence++); plain[8] = kind; payload.CopyTo(plain.AsMemory(9));
            var encrypted = AgentLanEndpoint.Seal(s.Key, plain, "video-server:" + s.Id);
            using var write = CancellationTokenSource.CreateLinkedTokenSource(token); write.CancelAfter(TimeSpan.FromSeconds(5));
            await socket.SendAsync(encrypted.AsMemory(), WebSocketMessageType.Binary, true, write.Token);
            } finally { sending.Release(); }
        }
        try
        {
            await Send(2, Encoding.UTF8.GetBytes("ready"));
            heartbeat = Task.Run(async () =>
            {
                try { using var timer = new PeriodicTimer(TimeSpan.FromSeconds(10));
                    while (await timer.WaitForNextTickAsync(token)) await Send(3, Encoding.UTF8.GetBytes("alive"));
                } finally { lifetime.Cancel(); }
            });
            var raw = Encoding.UTF8.GetString(await adb.RunAsync(["-t", s.Endpoint.TransportId, "shell", "dumpsys display"], token));
            if (raw.Contains("mScreenState=OFF", StringComparison.Ordinal)) throw new AgentActionException("screen_off", "手机当前息屏，请先亮屏再连接投屏。");
            reading = Task.Run(async () =>
            {
                try { var buffer = new byte[1024]; while (!token.IsCancellationRequested) {
                    var result = await socket.ReceiveAsync(buffer.AsMemory(), token);
                    if (result.MessageType == WebSocketMessageType.Close) break;
                    // Consumer frames after authentication are not part of this protocol.
                    throw new InvalidDataException("Unexpected video input.");
                } } finally { lifetime.Cancel(); }
            });
            var video = await source.OpenAsync(token);
            await Send(0, source.Header);
            var data = new byte[32768];
            while (true)
            {
                var count = await video.ReadAsync(data, token);
                if (count == 0) break;
                await Send(0, data.AsMemory(0, count));
            }
            throw new IOException("手机视频源已结束，请重新连接。");
        }
        catch (Exception error) when (!token.IsCancellationRequested)
        {
            try { await Send(1, Encoding.UTF8.GetBytes(error is AgentActionException ? error.Message : "视频源已中断，请确认手机已亮屏、ADB 连接正常且允许屏幕捕获。")); } catch { }
        }
        finally
        {
            lifetime.Cancel(); s.Lifetime.Cancel(); socket.Abort();
            if (reading is not null) try { await reading; } catch { }
            if (heartbeat is not null) try { await heartbeat; } catch { }
        }
    }
    public async ValueTask DisposeAsync()
    {
        Session[] values;
        lock (sync) { disposed = true; values = sessions.Values.ToArray(); foreach (var s in values) s.Lifetime.Cancel(); }
        foreach (var s in values) { if (s.Worker is not null) try { await s.Worker; } catch { }
            s.Lifetime.Dispose(); CryptographicOperations.ZeroMemory(s.Key); }
    }
}
