using System;
using System.Diagnostics;
using System.IO;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace Hako.Platform;

// scrcpy 3.3.4 (Apache-2.0), pinned official server. It supplies MediaCodec
// packet boundaries and configuration changes, including screen rotation.
internal interface IAndroidVideoSource : IAsyncDisposable
{
    byte[] Header { get; }
    Task<Stream> OpenAsync(CancellationToken token);
    Task TouchAsync(ReadOnlyMemory<byte> message, CancellationToken token);
}
internal sealed class AndroidVideoSource(IAndroidAdb adb, AndroidEndpoint endpoint, string directory) : IAndroidVideoSource
{
    internal const string Sha256 = "8588238c9a5a00aa542906b6ec7e6d5541d9ffb9b5d0f6e1bc0e365e2303079e";
    internal const string LegacySha256 = "9ad94bdb5b0209530801a5d3efe4ee95afc0455a967b9bb91d6cc7c286bc053d";
    internal static bool UsesLegacy(int sdk) => sdk is 19 or 20;
    private readonly string identity = Guid.NewGuid().ToString("N");
    private Process? process;
    private TcpClient? client;
    private TcpClient? control;
    private byte[]? activeTouch;
    private int port;
    private Task? output, errors, controlReplies;
    private readonly CancellationTokenSource stopping = new();
    private string Remote => "/data/local/tmp/kage-video-" + identity + ".jar";
    private string LegacyData => "/data/local/tmp/kage-video-data-" + identity;
    private bool legacyCache;
    public async Task<Stream> OpenAsync(CancellationToken token)
    {
        var sdkText = Encoding.UTF8.GetString(await adb.RunAsync(["-t", endpoint.TransportId, "shell", "getprop", "ro.build.version.sdk"], token)).Trim();
        if (!int.TryParse(sdkText, out var sdk) || sdk < 19)
            throw new Hako.Core.AgentActionException("screen_version_unsupported", "投屏需要 Android 4.4 或更高版本，当前设备系统版本无法支持或尚未确认。");
        var legacy = UsesLegacy(sdk);
        if (legacy) {
            legacyCache = true;
            await adb.RunAsync(["-t", endpoint.TransportId, "shell", "mkdir", "-p", LegacyData + "/dalvik-cache"], token);
        }
        using var resource = typeof(AndroidVideoSource).Assembly.GetManifestResourceStream(legacy ? "Hako.video-api19" : "Hako.scrcpy-server-v3.3.4")
            ?? throw new IOException("投屏编码器资源缺失。");
        using var bytes = new MemoryStream(); await resource.CopyToAsync(bytes, token);
        var contents = bytes.ToArray();
        if (Convert.ToHexString(SHA256.HashData(contents)).ToLowerInvariant() != (legacy ? LegacySha256 : Sha256)) throw new IOException("投屏编码器完整性校验失败。");
        var local = Path.Combine(directory, "video-" + identity + ".jar");
        try {
            await File.WriteAllBytesAsync(local, contents, token);
            await adb.RunAsync(["-t", endpoint.TransportId, "push", local, Remote], token);
        } finally { if (File.Exists(local)) File.Delete(local); }
        var scid = RandomNumberGenerator.GetInt32(1, int.MaxValue).ToString("x8");
        var socketName = legacy ? "hako_video_" + identity : "scrcpy_" + scid;
        var forwarded = Encoding.UTF8.GetString(await adb.RunAsync(["-t", endpoint.TransportId, "forward", "tcp:0", "localabstract:" + socketName], token)).Trim();
        if (!int.TryParse(forwarded, out port) || port is < 1 or > 65535) throw new IOException("无法创建 ADB 视频通道。");
        var start = new ProcessStartInfo(adb.Executable ?? throw new IOException("ADB 不可用。")) {
            UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true };
        var arguments = legacy
            ? ["-t", endpoint.TransportId, "shell", "CLASSPATH=" + Remote, "ANDROID_DATA=" + LegacyData, "app_process", "/", "me.stackli.hako.LegacyVideoServer", socketName]
            : new[] { "-t", endpoint.TransportId, "shell", "CLASSPATH=" + Remote, "app_process", "/", "com.genymobile.scrcpy.Server", "3.3.4",
            "scid=" + scid, "tunnel_forward=true", "audio=false", "control=true", "clipboard_autosync=false", "cleanup=false", "power_on=false",
            "send_device_meta=false", "send_dummy_byte=false", "send_codec_meta=true", "send_frame_meta=true",
            "video_codec=h264", "video_bit_rate=2000000", "max_size=1280", "max_fps=30" };
        foreach (var arg in arguments) start.ArgumentList.Add(arg);
        process = Process.Start(start) ?? throw new IOException("无法启动手机投屏编码器。");
        output = Drain(process.StandardOutput.BaseStream); errors = Drain(process.StandardError.BaseStream);
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(token); deadline.CancelAfter(TimeSpan.FromSeconds(10));
        while (true)
        {
            deadline.Token.ThrowIfCancellationRequested();
            if (process.HasExited) throw new Hako.Core.AgentActionException("screen_encoder_failed", "手机投屏编码器已退出，设备可能缺少可用的 H.264 硬件编码器。");
            client = new TcpClient { NoDelay = true };
            try {
                await client.ConnectAsync("127.0.0.1", port, deadline.Token);
                // scrcpy accepts video, then control, before starting the encoder.
                control = new TcpClient { NoDelay = true };
                await control.ConnectAsync("127.0.0.1", port, deadline.Token);
                var stream = client.GetStream();
                // An ADB forward may accept before the Android socket is ready.
                // Read the codec header to distinguish that from a live source.
                var header = new byte[12]; await stream.ReadExactlyAsync(header, deadline.Token);
                if (!header.AsSpan(0, 4).SequenceEqual("h264"u8)) throw new IOException("手机视频编码格式无效。");
                controlReplies = Drain(control.GetStream());
                Header = header; return stream;
            } catch (Exception e) when (e is IOException or SocketException) {
                client.Dispose(); client = null;
                control?.Dispose(); control = null;
                if (process.HasExited) throw new IOException("手机投屏编码器不可用，请确认已亮屏且允许屏幕捕获。", e);
                await Task.Delay(100, deadline.Token);
            }
        }
    }
    public byte[] Header { get; private set; } = [];
    public async Task TouchAsync(ReadOnlyMemory<byte> message, CancellationToken token)
    {
        if (control is null) throw new IOException("手机触控通道未连接。");
        await control.GetStream().WriteAsync(message, token);
        activeTouch = message.Span[1] is 0 or 2 ? message.ToArray() : null;
    }
    private async Task Drain(Stream stream) { var bytes = new byte[4096]; try { while (await stream.ReadAsync(bytes, stopping.Token) != 0) { } } catch (OperationCanceledException) { } }
    public async ValueTask DisposeAsync()
    {
        if (control is not null && activeTouch is { } touch)
        {
            touch[1] = 3; touch[22] = 0; touch[23] = 0;
            using var release = new CancellationTokenSource(TimeSpan.FromSeconds(1));
            try { await control.GetStream().WriteAsync(touch, release.Token); } catch { }
        }
        client?.Dispose();
        control?.Dispose();
        if (process is not null) {
            try { await process.WaitForExitAsync().WaitAsync(TimeSpan.FromMilliseconds(500)); } catch { }
            try { if (!process.HasExited) process.Kill(true); } catch (InvalidOperationException) { }
            try { await process.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(2)); } catch { }
        }
        stopping.Cancel();
        if (output is not null) try { await output; } catch { }
        if (errors is not null) try { await errors; } catch { }
        if (controlReplies is not null) try { await controlReplies; } catch { }
        using var cleanup = new CancellationTokenSource(TimeSpan.FromSeconds(4));
        if (port > 0) try { await adb.RunAsync(["-t", endpoint.TransportId, "forward", "--remove", "tcp:" + port], cleanup.Token); } catch { }
        try { await adb.RunAsync(["-t", endpoint.TransportId, "shell", "rm", "-f", Remote], cleanup.Token); } catch { }
        if (legacyCache) try { await adb.RunAsync(["-t", endpoint.TransportId, "shell", "rm", "-rf", LegacyData], cleanup.Token); } catch { }
        process?.Dispose(); stopping.Dispose();
    }
}
