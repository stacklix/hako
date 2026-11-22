using System;
using System.Buffers.Binary;
using System.Diagnostics;
using System.Collections.Generic;
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
        await streams.StopAsync(id); await streams.StopAsync(id);
        streams.Create(Guid.NewGuid().ToString("D"), "phone", endpoint, 8003);
        await CheckPowerLifecycle(false, false);
        await CheckPowerLifecycle(true, false);
        await CheckPowerLifecycle(false, true);
        await CheckCancelledWriteRace();
        CheckTouchValidation();
        Console.WriteLine("PASS: video encoder integrity, idempotent session keys, device pinning, source limits and stop without launching ADB.");
    }
    private sealed class CancelledWriteSocket(byte[] hello) : WebSocket
    {
        internal readonly TaskCompletionSource Writing = new(TaskCreationOptions.RunContinuationsAsynchronously);
        private int writes, reads;
        private WebSocketState state = WebSocketState.Open;
        public override WebSocketState State => state;
        public override WebSocketCloseStatus? CloseStatus => null;
        public override string? CloseStatusDescription => null;
        public override string? SubProtocol => null;
        public override void Abort() => state = WebSocketState.Aborted;
        public override void Dispose() => Abort();
        public override Task CloseAsync(WebSocketCloseStatus status, string? description, CancellationToken token) => Task.CompletedTask;
        public override Task CloseOutputAsync(WebSocketCloseStatus status, string? description, CancellationToken token) => Task.CompletedTask;
        public override async Task<WebSocketReceiveResult> ReceiveAsync(ArraySegment<byte> buffer, CancellationToken token)
        {
            if (Interlocked.Increment(ref reads) == 1) {
                hello.CopyTo(buffer.AsSpan());
                return new(hello.Length, WebSocketMessageType.Binary, true);
            }
            await Task.Delay(Timeout.Infinite, token);
            throw new InvalidOperationException();
        }
        public override async Task SendAsync(ArraySegment<byte> buffer, WebSocketMessageType type, bool end, CancellationToken token)
        {
            if (Interlocked.Increment(ref writes) != 2) return;
            Writing.TrySetResult();
            try { await Task.Delay(Timeout.Infinite, token); }
            catch (OperationCanceledException) { throw new WebSocketException("Fixture: an aborted write raced with stop."); }
        }
    }
    private static async Task CheckCancelledWriteRace()
    {
        var source = new Source(); var adb = new PowerAdb(source, false, false);
        await using var streams = new AndroidVideoStreams(adb, () => null, Path.GetTempPath(), _ => source);
        var id = Guid.NewGuid().ToString("D");
        var descriptor = JsonSerializer.SerializeToElement(streams.Create(id, "phone", new("pinned", "7", "usb", "device"), 0), AgentConnection.Json);
        var key = Convert.FromBase64String(descriptor.GetProperty("key").GetString()!);
        var hello = JsonSerializer.SerializeToUtf8Bytes(new { sessionId = id, timestamp = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() });
        using var socket = new CancelledWriteSocket(AgentLanEndpoint.Seal(key, hello, "video-client:" + id));
        var worker = streams.AcceptAsync(id, socket, default);
        await socket.Writing.Task.WaitAsync(TimeSpan.FromSeconds(3));
        await streams.StopAsync(id).WaitAsync(TimeSpan.FromSeconds(3));
        await worker;
        if (!source.Disposed || adb.Awake || string.Join(",", adb.Keys) != "224,223")
            throw new Exception("A cancelled WebSocket write skipped source disposal or phone power cleanup");
        Console.WriteLine("PASS: aborted WebSocket write during stop completes cleanup without leaking a socket exception.");
    }
    private sealed class IdleStream : Stream
    {
        public override bool CanRead => true;
        public override bool CanSeek => false;
        public override bool CanWrite => false;
        public override long Length => throw new NotSupportedException();
        public override long Position { get => throw new NotSupportedException(); set => throw new NotSupportedException(); }
        public override void Flush() { }
        public override int Read(byte[] b, int o, int c) => throw new NotSupportedException();
        public override long Seek(long o, SeekOrigin s) => throw new NotSupportedException();
        public override void SetLength(long l) => throw new NotSupportedException();
        public override void Write(byte[] b, int o, int c) => throw new NotSupportedException();
        public override async ValueTask<int> ReadAsync(Memory<byte> bytes, CancellationToken token = default)
        { await Task.Delay(Timeout.Infinite, token); return 0; }
    }
    private sealed class Source : IAndroidVideoSource
    {
        internal readonly TaskCompletionSource Opened = new(TaskCreationOptions.RunContinuationsAsynchronously);
        internal readonly TaskCompletionSource Disposing = new(TaskCreationOptions.RunContinuationsAsynchronously);
        internal TaskCompletionSource? CloseGate;
        internal bool Disposed;
        internal readonly List<byte[]> Touches = [];
        internal readonly TaskCompletionSource Touched = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public byte[] Header => [104, 50, 54, 52, 0, 0, 2, 28, 0, 0, 4, 176];
        public Task<Stream> OpenAsync(CancellationToken token) { Opened.TrySetResult(); return Task.FromResult<Stream>(new IdleStream()); }
        public Task TouchAsync(ReadOnlyMemory<byte> message, CancellationToken token) {
            Touches.Add(message.ToArray()); if (Touches.Count == 3) Touched.TrySetResult(); return Task.CompletedTask;
        }
        public async ValueTask DisposeAsync() { Disposed = true; Disposing.TrySetResult(); if (CloseGate is not null) await CloseGate.Task; }
    }
    private sealed class PowerAdb(Source source, bool failWake, bool failSleep) : IAndroidAdb
    {
        public string? Executable => "fixture";
        internal bool Awake;
        internal readonly List<string> Keys = [];
        public Task<byte[]> RunAsync(string[] arguments, CancellationToken token, string? input = null, int limit = 2097152)
        {
            if (arguments[0] != "-t" || arguments[1] != "7") throw new Exception("Video power control changed transport");
            if (arguments[^2] == "keyevent") {
                var key = arguments[^1]; Keys.Add(key);
                if ((key == "224" && failWake) || (key == "223" && failSleep)) throw new AgentActionException("adb_failed", "fixture denied");
                if (key == "223" && !source.Disposed) throw new Exception("Phone slept before video source closed");
                Awake = key == "224";
            }
            return Task.FromResult(Encoding.UTF8.GetBytes("mScreenState=" + (Awake ? "ON" : "OFF")));
        }
    }
    private static async Task CheckPowerLifecycle(bool failWake, bool failSleep)
    {
        var source = new Source { CloseGate = failWake ? null : new(TaskCreationOptions.RunContinuationsAsynchronously) }; var adb = new PowerAdb(source, failWake, failSleep);
        await using var streams = new AndroidVideoStreams(adb, () => null, Path.GetTempPath(), _ => source);
        var id = Guid.NewGuid().ToString("D");
        var descriptor = JsonSerializer.SerializeToElement(streams.Create(id, "phone", new("pinned", "7", "usb", "device"), 0), AgentConnection.Json);
        if (adb.Keys.Count != 0) throw new Exception("Merely reserving a session woke the phone");
        var key = Convert.FromBase64String(descriptor.GetProperty("key").GetString()!);
        var name = "Kage.Video.Power." + Guid.NewGuid().ToString("N");
        using var pipe = new NamedPipeServerStream(name, PipeDirection.InOut, 1, PipeTransmissionMode.Byte, PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
        using var peer = new NamedPipeClientStream(".", name, PipeDirection.InOut, PipeOptions.Asynchronous);
        var waiting = pipe.WaitForConnectionAsync(); await peer.ConnectAsync(3000); await waiting;
        using var server = WebSocket.CreateFromStream(pipe, true, null, TimeSpan.FromSeconds(15));
        using var client = WebSocket.CreateFromStream(peer, false, null, TimeSpan.FromSeconds(15));
        var receiving = Task.Run(async () => {
            try { var bytes = new byte[65564]; while (true) { var frame = await client.ReceiveAsync(bytes.AsMemory(), default); if (frame.MessageType == WebSocketMessageType.Close) return; } }
            catch (Exception error) when (error is WebSocketException or IOException or OperationCanceledException) { }
        });
        var work = streams.AcceptAsync(id, server, default);
        var hello = JsonSerializer.SerializeToUtf8Bytes(new { sessionId = id, timestamp = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() });
        await client.SendAsync(AgentLanEndpoint.Seal(key, hello, "video-client:" + id).AsMemory(), WebSocketMessageType.Binary, true, default);
        if (failWake) await work.WaitAsync(TimeSpan.FromSeconds(3));
        else { await source.Opened.Task.WaitAsync(TimeSpan.FromSeconds(3)); if (!adb.Awake) throw new Exception("Capture started before wake verification"); }
        if (!failWake && !failSleep)
        {
            for (ulong i = 0; i < 3; i++)
            {
                var plain = Touch(i, i == 0 ? (byte)0 : i == 1 ? (byte)2 : (byte)1);
                var encrypted = AgentLanEndpoint.Seal(key, plain, "video-input:" + id);
                if (i == 1) {
                    await client.SendAsync(encrypted.AsMemory(0, 17), WebSocketMessageType.Binary, false, default);
                    await client.SendAsync(encrypted.AsMemory(17), WebSocketMessageType.Binary, true, default);
                } else await client.SendAsync(encrypted.AsMemory(), WebSocketMessageType.Binary, true, default);
            }
            await source.Touched.Task.WaitAsync(TimeSpan.FromSeconds(3));
            if (source.Touches[0][1] != 0 || source.Touches[1][1] != 2 || source.Touches[2][1] != 1)
                throw new Exception("Encrypted touch events were dropped or reordered");
        }
        var stop = streams.StopAsync(id);
        if (source.CloseGate is not null) {
            await source.Disposing.Task.WaitAsync(TimeSpan.FromSeconds(3));
            try { streams.Create(Guid.NewGuid().ToString("D"), "phone", new("pinned", "7", "usb", "device"), 0); throw new Exception("Closing source allowed a new session to wake before old sleep"); }
            catch (AgentActionException error) when (error.Code == "stream_busy") { }
            source.CloseGate.TrySetResult();
        }
        try { await stop.WaitAsync(TimeSpan.FromSeconds(3)); if (failSleep) throw new Exception("Sleep failure was hidden"); }
        catch (AgentActionException error) when (failSleep && error.Code == "screen_sleep_failed") { }
        client.Abort(); try { await work; } catch (OperationCanceledException) { } await receiving;
        if (!source.Disposed || (!failSleep && adb.Awake) || (failWake && source.Opened.Task.IsCompleted)) throw new Exception("Video power lifecycle failed");
        if (!failWake && string.Join(",", adb.Keys) != "224,223") throw new Exception("Wake/sleep was repeated or omitted");
        await streams.StopAsync(id).ContinueWith(_ => { });
        if (adb.Keys.Count != (failWake ? 1 : 2)) throw new Exception("Repeated stop repeated input");
    }
    private static byte[] Touch(ulong sequence, byte action)
    {
        var bytes = new byte[40]; BinaryPrimitives.WriteUInt64BigEndian(bytes, sequence);
        bytes[8] = 2; bytes[9] = action;
        BinaryPrimitives.WriteUInt32BigEndian(bytes.AsSpan(18), 270);
        BinaryPrimitives.WriteUInt32BigEndian(bytes.AsSpan(22), 600);
        BinaryPrimitives.WriteUInt16BigEndian(bytes.AsSpan(26), 540);
        BinaryPrimitives.WriteUInt16BigEndian(bytes.AsSpan(28), 1200);
        BinaryPrimitives.WriteUInt16BigEndian(bytes.AsSpan(30), (ushort)(action is 1 or 3 ? 0 : 65535));
        return bytes;
    }
    private static void CheckTouchValidation()
    {
        var input = new AndroidVideoInput();
        void Reject(byte[] packet) {
            try { input.Read(packet); throw new Exception("Unsafe touch packet accepted"); } catch (InvalidDataException) { }
        }
        Reject(Touch(0, 2)); // No move without a finger down.
        var invalid = Touch(0, 0); invalid[8] = 1; Reject(invalid); // No text/clipboard commands.
        invalid = Touch(0, 0); BinaryPrimitives.WriteUInt32BigEndian(invalid.AsSpan(18), 540); Reject(invalid);
        input.Read(Touch(0, 0));
        Reject(Touch(0, 0)); // No replay.
        Reject(Touch(1, 0)); // No second finger.
        input.Read(Touch(1, 2)); input.Read(Touch(2, 3));
        Reject(Touch(3, 1));
        input.Read(Touch(3, 0)); input.Read(Touch(4, 1));
        Console.WriteLine("PASS: encrypted ordered touch delivery, coordinate bounds, gesture lifecycle and replay rejection.");
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
