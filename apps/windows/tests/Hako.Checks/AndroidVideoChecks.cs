using System;
using System.Buffers.Binary;
using System.Diagnostics;
using System.IO;
using System.IO.Pipes;
using System.Net.WebSockets;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Hako.Core;
using Hako.Platform;

internal static class AndroidVideoChecks
{
    private sealed class NoAdb : IAndroidAdb
    {
        public string? Executable => null;
        public Task<byte[]> RunAsync(string[] arguments, CancellationToken token, string? input = null, int limit = 2097152)
            => throw new Exception("Creating/stopping a video session must not launch ADB");
    }
    internal static async Task RunAsync()
    {
        using var resource = typeof(AndroidVideoSource).Assembly.GetManifestResourceStream("Hako.scrcpy-server-v3.3.4")!;
        var digest = Convert.ToHexString(await System.Security.Cryptography.SHA256.HashDataAsync(resource)).ToLowerInvariant();
        if (digest != AndroidVideoSource.Sha256) throw new Exception("Embedded video encoder integrity mismatch");
        await using var streams = new AndroidVideoStreams(new NoAdb(), () => null, Path.GetTempPath());
        var id = Guid.NewGuid().ToString("D"); var endpoint = new AndroidEndpoint("selected", "1", "usb", "device");
        var first = JsonSerializer.Serialize(streams.Create(id, "phone", endpoint, 8003), AgentConnection.Json);
        if (first != JsonSerializer.Serialize(streams.Create(id, "phone", endpoint, 8003), AgentConnection.Json)) throw new Exception("Retried session changed its key");
        try { streams.Create(id, "other", endpoint, 8003); throw new Exception("Session target changed"); } catch (AgentActionException e) when (e.Code == "stream_conflict") { }
        try { streams.Create(Guid.NewGuid().ToString("D"), "phone", endpoint, 8003); throw new Exception("Parallel source on one phone accepted"); } catch (AgentActionException e) when (e.Code == "stream_busy") { }
        var second = Guid.NewGuid().ToString("D"); streams.Create(second, "second", endpoint, 8003);
        try { streams.Create(Guid.NewGuid().ToString("D"), "third", endpoint, 8003); throw new Exception("Unbounded video sessions accepted"); } catch (AgentActionException e) when (e.Code == "stream_busy") { }
        streams.Stop(id); streams.Stop(id);
        streams.Create(Guid.NewGuid().ToString("D"), "phone", endpoint, 8003);
        Console.WriteLine("PASS: video encoder integrity, idempotent session keys, device pinning, source limits and stop without launching ADB.");
    }
    internal static async Task LiveAsync(string profile, string output)
    {
        await using var manager = new AndroidManager(profile);
        var inventory = await manager.ListAsync(default);
        var device = Array.Find(inventory.Devices, d => Array.Exists(d.Connections, c => c.Serial == "731dd756")) ?? throw new Exception("Selected test phone offline");
        var id = Guid.NewGuid().ToString("D");
        var descriptor = JsonSerializer.SerializeToElement(await manager.ActionAsync("action.android.stream",
            JsonSerializer.SerializeToElement(new { operation = "start", sessionId = id, deviceId = device.Id, serial = "731dd756" }), default), AgentConnection.Json);
        var key = Convert.FromBase64String(descriptor.GetProperty("key").GetString()!);
        var name = "Kage.Video.Check." + Guid.NewGuid().ToString("N");
        using var pipe = new NamedPipeServerStream(name, PipeDirection.InOut, 1, PipeTransmissionMode.Byte, PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
        using var peer = new NamedPipeClientStream(".", name, PipeDirection.InOut, PipeOptions.Asynchronous);
        var accepting = pipe.WaitForConnectionAsync(); await peer.ConnectAsync(3000); await accepting;
        using var server = WebSocket.CreateFromStream(pipe, true, null, TimeSpan.FromSeconds(15));
        using var consumer = WebSocket.CreateFromStream(peer, false, null, TimeSpan.FromSeconds(15));
        using var duration = new CancellationTokenSource(TimeSpan.FromSeconds(8));
        var work = manager.Video.AcceptAsync(id, server, duration.Token);
        var hello = JsonSerializer.SerializeToUtf8Bytes(new { sessionId = id, timestamp = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() });
        await consumer.SendAsync(AgentLanEndpoint.Seal(key, hello, "video-client:" + id).AsMemory(), WebSocketMessageType.Binary, true, default);
        using var video = new MemoryStream(); var clock = Stopwatch.StartNew(); double? first = null;
        ulong sequence = 0;
        try {
            while (!duration.IsCancellationRequested) {
                var bytes = new byte[65564]; var length = 0;
                ValueWebSocketReceiveResult result;
                do { result = await consumer.ReceiveAsync(bytes.AsMemory(length), duration.Token); length += result.Count; } while (!result.EndOfMessage);
                if (result.MessageType == WebSocketMessageType.Close) break;
                var plain = AgentLanEndpoint.Open(key, bytes[..length], "video-server:" + id);
                if (BinaryPrimitives.ReadUInt64BigEndian(plain) != sequence++) throw new Exception("Video sequence changed");
                if (plain[8] == 1) throw new Exception(Encoding.UTF8.GetString(plain, 9, plain.Length - 9));
                if (plain[8] == 0) { video.Write(plain, 9, plain.Length - 9); first ??= clock.Elapsed.TotalMilliseconds; }
            }
        } catch (OperationCanceledException) when (duration.IsCancellationRequested) { }
        finally { duration.Cancel(); consumer.Abort(); try { await work; } catch (OperationCanceledException) { } }
        if (video.Length < 20 || !video.ToArray().AsSpan(0, 4).SequenceEqual("h264"u8)) throw new Exception("No live H264 data");
        await File.WriteAllBytesAsync(output, video.ToArray());
        Console.WriteLine(JsonSerializer.Serialize(new { videoBytes = video.Length, messages = sequence, firstDataMilliseconds = first, closed = work.IsCompleted }, AgentConnection.Json));
    }
}
