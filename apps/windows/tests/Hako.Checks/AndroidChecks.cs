using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Imaging;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Hako.Core;
using Hako.Platform;

internal static class AndroidChecks
{
    private static JsonElement Json(object value) => JsonSerializer.SerializeToElement(value, AgentConnection.Json);
    private static void Check(bool condition, string message) { if (!condition) throw new Exception(message); }
    private sealed class FakeAdb : IAndroidAdb
    {
        public string? Executable => "fixture-adb.exe";
        internal readonly List<string[]> Calls = [];
        internal TaskCompletionSource? Hold;
        internal bool Timeout;
        internal byte[]? Screenshot;
        public async Task<byte[]> RunAsync(string[] args, CancellationToken token, string? input = null, int limit = 2097152)
        {
            lock (Calls) Calls.Add(args);
            if (args.Contains("screencap")) return Screenshot ?? throw new Exception("Missing screenshot fixture");
            string output;
            if (args[0] == "devices") output = "List of devices attached\nSERIAL device usb:1 transport_id:1\nadb-SERIAL-abc._adb-tls-connect._tcp device transport_id:2\n";
            else if (args.Contains("getprop")) output = "[ro.serialno]: [SERIAL]\n[ro.product.model]: [Test phone]\n[ro.product.manufacturer]: [Xiaomi]\n[ro.build.version.release]: [14]\n";
            else if (args.Contains("224") || args.Contains("223")) { if (Hold is not null) await Hold.Task.WaitAsync(token); if (Timeout) throw new OperationCanceledException(); output = ""; }
            else if (args.Contains(AndroidParsing.DetailScript)) output = "@@memory\nMemTotal: 8000000 kB\nMemAvailable: 2000000 kB\n@@disk\nFilesystem 1K-blocks Used Available Use% Mounted\n/dev/block/test 128000000 64000000 64000000 50% /data\n@@uptime\n3600.5 1.0\n@@battery\n level: 89\n scale: 100\n status: 3\n@@display\nmScreenState=OFF\n@@package\n versionCode=15 minSdk=26\n versionName=1.0.14\n@@process\n1234\n@@agent\n1235\n@@end\n";
            else if (args[0] == "pair") { Check(input == "123456\n", "pairing code must go through stdin"); output = "Successfully paired to 192.168.0.9:12345"; }
            else output = "Status: ok";
            return Encoding.UTF8.GetBytes(output);
        }
    }
    private static async Task<AndroidOperation> Wait(AndroidManager manager, string id)
    {
        for (var count = 0; count < 150; count++)
        {
            var operation = (AndroidOperation)(await manager.QueryAsync("query.android.operation", Json(new { requestId = id }), default))!;
            if (operation.Status is not ("queued" or "running")) return operation;
            await Task.Delay(10);
        }
        throw new Exception("Android operation did not finish.");
    }
    internal static async Task RunAsync()
    {
        await AndroidVideoChecks.RunAsync();
        var folder = Path.Combine(Path.GetTempPath(), "hako-android-check-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(folder);
        try
        {
            var adb = new FakeAdb();
            await using (var manager = new AndroidManager(folder, adb))
            {
                var list = await manager.ListAsync(default);
                Check(list.Devices.Length == 1 && list.Devices[0].Connections.Length == 2, "USB and TLS endpoints must merge by hardware identity");
                var device = list.Devices[0];
                using (var bitmap = new Bitmap(1000, 2000, PixelFormat.Format24bppRgb))
                {
                    var bits = bitmap.LockBits(new Rectangle(0, 0, bitmap.Width, bitmap.Height), ImageLockMode.WriteOnly, PixelFormat.Format24bppRgb);
                    var pixels = new byte[bits.Stride * bits.Height]; new Random(21).NextBytes(pixels);
                    Marshal.Copy(pixels, 0, bits.Scan0, pixels.Length); bitmap.UnlockBits(bits);
                    using var png = new MemoryStream(); bitmap.Save(png, ImageFormat.Png); adb.Screenshot = png.ToArray();
                }
                var captureId = Guid.NewGuid().ToString("D");
                _ = await manager.ActionAsync("action.android.execute", Json(new { requestId = captureId, operation = "screenshot", deviceId = device.Id }), default);
                Check((await Wait(manager, captureId)).Status == "completed", "Screenshot fixture was not captured");
                var preview = Json((await manager.QueryAsync("query.android.preview", Json(new { requestId = captureId }), default))!);
                var jpeg = Convert.FromBase64String(preview.GetProperty("data").GetString()!);
                Check(jpeg.Length <= AndroidScreenshotPreview.MaximumBytes && preview.GetProperty("contentType").GetString() == "image/jpeg", "Preview exceeds a single LAN response");
                Check(Encoding.UTF8.GetByteCount(Json(new { id = Guid.NewGuid(), result = preview }).GetRawText()) < 65536, "Preview violates encrypted LAN result limit");
                using (var picture = Image.FromStream(new MemoryStream(jpeg))) Check(picture.Width <= 720 && picture.Height <= 1600, "Preview did not scale the image");
                var cached = Json((await manager.QueryAsync("query.android.preview", Json(new { requestId = captureId }), default))!);
                Check(cached.GetProperty("data").GetString() == preview.GetProperty("data").GetString(), "Preview cache changed the screenshot");
                Check(File.ReadAllBytes(Path.Combine(folder, "android", "tasks", captureId, "screen.png")).SequenceEqual(adb.Screenshot), "Preview modified the original PNG");
                var detail = (AndroidDetail)(await manager.QueryAsync("query.android.device", Json(new { deviceId = device.Id }), default))!;
                Check(detail.Screen == "off" && detail.MemoryAvailableBytes == 2048000000L && detail.StorageAvailableBytes == 65536000000L
                    && detail.NamiVersion == "1.0.14" && detail.ProcessRunning && detail.BatteryPercent == 89 && detail.Charging == false, "ADB state parsing must preserve units and process semantics");
                Check(AndroidParsing.Detail("id", "@@display\nno default display\n@@end").Screen == "unknown", "Missing screen state cannot mean off");
                adb.Hold = new(TaskCreationOptions.RunContinuationsAsynchronously);
                var id = Guid.NewGuid().ToString("D"); var request = Json(new { requestId = id, operation = "sleep", deviceId = device.Id, serial = "SERIAL" });
                _ = await manager.ActionAsync("action.android.execute", request, default);
                _ = await manager.ActionAsync("action.android.execute", request, default);
                try { _ = await manager.ActionAsync("action.android.execute", Json(new { requestId = id, operation = "wake", deviceId = device.Id }), default); throw new Exception("Request conflict accepted"); }
                catch (AgentActionException e) when (e.Code == "request_conflict") { }
                try { _ = await manager.ActionAsync("action.android.execute", Json(new { requestId = Guid.NewGuid().ToString("D"), operation = "wake", deviceId = device.Id }), default); throw new Exception("Concurrent device operation accepted"); }
                catch (AgentActionException e) when (e.Code == "android_busy") { }
                adb.Hold.SetResult();
                Check((await Wait(manager, id)).Status == "completed", "Screen operation must be verified");
                Check(adb.Calls.Count(c => c.Contains("223")) == 1 && adb.Calls.Single(c => c.Contains("223"))[1] == "1", "Idempotent operation must execute once on the selected transport");
                adb.Hold = null; adb.Timeout = true;
                var timeoutId = Guid.NewGuid().ToString("D");
                _ = await manager.ActionAsync("action.android.execute", Json(new { requestId = timeoutId, operation = "wake", deviceId = device.Id }), default);
                Check((await Wait(manager, timeoutId)).Status == "unknown", "After dispatch timeout must remain unknown");
                foreach (var address in new[] { "example.com:5555", "8.8.8.8:5555", "192.168.0.9:0", "192.168.0.9:70000", "192.168.0.9:5555;id" })
                { try { AndroidManager.ValidateAddress(address); throw new Exception("Unsafe address accepted"); } catch (AgentActionException) { } }
                AndroidManager.ValidateAddress("192.168.0.9:37123");
                var bytes = Encoding.UTF8.GetBytes("APK fixture content"); var hash = Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant();
                var uploadId = Guid.NewGuid().ToString("D");
                var upload = Json(new { uploadId, fileName = "nami.apk", length = bytes.Length, sha256 = hash, offset = 0, data = Convert.ToBase64String(bytes) });
                _ = await manager.ActionAsync("action.android.upload", upload, default);
                _ = await manager.ActionAsync("action.android.upload", upload, default);
                Check(File.ReadAllBytes(Path.Combine(folder, "android", "uploads", uploadId, "package.apk")).SequenceEqual(bytes), "Repeated upload chunks must not duplicate bytes");
                try { AndroidApk.Read(Path.Combine(folder, "android", "uploads", uploadId, "package.apk")); throw new Exception("Invalid APK accepted"); }
                catch (InvalidDataException) { }
                var pairId = Guid.NewGuid().ToString("D");
                _ = await manager.ActionAsync("action.android.execute", Json(new { requestId = pairId, operation = "pair", address = "192.168.0.9:37123", code = "123456" }), default);
                Check((await Wait(manager, pairId)).Status == "completed", "Pairing result must be verified");
                Check(!File.ReadAllText(Path.Combine(folder, "android", "tasks", pairId, "state.json")).Contains("123456"), "Pairing secrets must not be persisted");
            }
            var before = adb.Calls.Count;
            await using (var reopened = new AndroidManager(folder, adb))
            { _ = await reopened.QueryAsync("query.android.operations", Json(new { deviceId = (await reopened.ListAsync(default)).Devices[0].Id }), default); }
            Check(adb.Calls.Skip(before).All(args => !args.Contains("224") && !args.Contains("223")), "Restarting Kage must not replay actions");
            Console.WriteLine("PASS: Android endpoint identity, state units, screen unknown, request deduplication, transport pinning, pending limits, unknown results, upload hash/idempotence, private pairing and restart without replay.");
        }
        finally { if (Path.GetFullPath(folder).StartsWith(Path.GetTempPath(), StringComparison.OrdinalIgnoreCase)) Directory.Delete(folder, true); }
    }
    internal static async Task ReadLiveAsync(string folder, string apk)
    {
        await using var manager = new AndroidManager(folder);
        var list = await manager.ListAsync(default);
        var device = list.Devices.Single(d => d.Connections.Any(c => c.Serial == "731dd756"));
        var detail = (AndroidDetail)(await manager.QueryAsync("query.android.device", Json(new { deviceId = device.Id, serial = "731dd756" }), default))!;
        var metadata = AndroidApk.Read(apk);
        Check(metadata.PackageName == "me.stackli.doppel" && metadata.VersionCode == 15, "Real Nami APK manifest validation failed");
        Check(detail.MemoryAvailableBytes is >= 0 && detail.MemoryTotalBytes > 0 && detail.StorageAvailableBytes is >= 0, "Real ADB status incomplete");
        Console.WriteLine(JsonSerializer.Serialize(new { device.Name, device.Model, device.AndroidVersion, connections = device.Connections.Length,
            detail.Screen, detail.BatteryPercent, detail.MemoryAvailableBytes, detail.StorageAvailableBytes, detail.UptimeSeconds,
            detail.NamiVersion, detail.ProcessRunning, apkPackage = metadata.PackageName, apkVersionCode = metadata.VersionCode }, AgentConnection.Json));
    }
    internal static async Task PreviewLiveAsync(string folder, string requestId)
    {
        await using var manager = new AndroidManager(folder);
        var clock = Stopwatch.StartNew();
        var preview = Json((await manager.QueryAsync("query.android.preview", Json(new { requestId }), default))!);
        var elapsed = clock.Elapsed.TotalMilliseconds;
        var jpeg = Convert.FromBase64String(preview.GetProperty("data").GetString()!);
        using var picture = Image.FromStream(new MemoryStream(jpeg));
        var original = new FileInfo(Path.Combine(folder, "android", "tasks", requestId, "screen.png")).Length;
        Console.WriteLine(JsonSerializer.Serialize(new { originalBytes = original, previewBytes = jpeg.Length,
            originalRequests = (original + 24575) / 24576, previewRequests = 1, elapsedMilliseconds = elapsed,
            width = picture.Width, height = picture.Height }, AgentConnection.Json));
    }
}
