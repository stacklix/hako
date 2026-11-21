using System;
using System.Collections.Generic;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using Hako.Core;

namespace Hako.Platform;

internal sealed record AndroidOperation(string Id, string Kind, string DeviceId, string Status, string Phase,
    string Message, string CreatedAt, string UpdatedAt, string Fingerprint, string? Artifact = null);
internal sealed record AndroidUpload(string Id, string FileName, long Length, string Sha256);

internal sealed class AndroidManager : IAsyncDisposable
{
    internal const string ListCommand = "query.android.devices";
    internal static readonly string[] QueryCommands = [ListCommand, "query.android.device", "query.android.operations", "query.android.operation", "query.android.logs", "query.android.artifact", "query.android.preview"];
    internal static readonly string[] ActionCommands = ["action.android.execute", "action.android.upload", "action.android.stream"];
    internal AndroidVideoStreams Video { get; }
    internal Func<int> VideoPort { get; set; } = () => 0;
    private readonly string directory;
    private readonly IAndroidAdb adb;
    private readonly SemaphoreSlim gate = new(1, 1), scanGate = new(1, 1), previewGate = new(1, 1);
    private readonly CancellationTokenSource stopping = new();
    private readonly Dictionary<string, AndroidOperation> operations = new();
    private readonly Dictionary<string, Task> running = new();
    private readonly Dictionary<string, AndroidManagedDevice> devices = new();
    private readonly object sync = new();
    internal AndroidManager(string profile, IAndroidAdb? adb = null, Func<Uri?>? streamOrigin = null)
    {
        directory = Path.Combine(profile, "android"); this.adb = adb ?? new AndroidAdb(directory);
        Video = new(this.adb, streamOrigin ?? (() => null), directory);
        Directory.CreateDirectory(directory);
        var inventory = Path.Combine(directory, "devices.json");
        if (File.Exists(inventory)) foreach (var d in JsonSerializer.Deserialize<AndroidManagedDevice[]>(File.ReadAllBytes(inventory), AgentConnection.Json) ?? [])
            devices[d.Id] = d with { Connections = d.Connections.Select(c => c with { State = "offline" }).ToArray() };
        var taskRoot = Path.Combine(directory, "tasks");
        if (Directory.Exists(taskRoot)) foreach (var file in Directory.EnumerateFiles(taskRoot, "state.json", SearchOption.AllDirectories).Take(1000))
        {
            var operation = JsonSerializer.Deserialize<AndroidOperation>(File.ReadAllBytes(file), AgentConnection.Json);
            if (operation is null) continue;
            if (operation.Status is "queued" or "running") operation = operation with { Status = "unknown", Message = "Kage 进程已重启，原操作结果待确认；未重复执行。", UpdatedAt = Now() };
            operations[operation.Id] = operation;
        }
    }
    private static string Now() => DateTimeOffset.UtcNow.ToString("O");
    private static string Identity(string value) => Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(value))).ToLowerInvariant()[..24];
    private string TaskDirectory(string id) => Path.Combine(directory, "tasks", id);
    private string UploadDirectory(string id) => Path.Combine(directory, "uploads", id);
    private static void Atomic<T>(string path, T value)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!); var temporary = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try { File.WriteAllBytes(temporary, JsonSerializer.SerializeToUtf8Bytes(value, AgentConnection.Json)); File.Move(temporary, path, true); }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }
    private void Save(AndroidOperation operation) => Atomic(Path.Combine(TaskDirectory(operation.Id), "state.json"), operation);
    private static AgentActionException Invalid() => new("invalid_params", "Android 命令参数无效。");
    internal static string Text(JsonElement p, string key, int limit = 128)
    {
        if (!p.TryGetProperty(key, out var field) || field.ValueKind != JsonValueKind.String || field.GetString() is not { Length: > 0 } text || text.Length > limit || text.Any(char.IsControl)) throw Invalid();
        return text;
    }
    private static string Id(JsonElement p, string key)
    { var value = Text(p, key); return Guid.TryParseExact(value, "D", out var id) ? id.ToString("D") : throw Invalid(); }
    private static void Fields(JsonElement p, params string[] names)
    { if (p.ValueKind != JsonValueKind.Object || p.EnumerateObject().Any(field => !names.Contains(field.Name))) throw Invalid(); }
    private async Task<string> Run(string[] args, CancellationToken token, string? input = null) => Encoding.UTF8.GetString(await adb.RunAsync(args, token, input));
    internal async Task<AndroidInventory> ListAsync(CancellationToken token)
    {
        await scanGate.WaitAsync(token);
        try
        {
            if (adb.Executable is null) { lock (sync) return new(false, devices.Values.ToArray(), Now()); }
            var endpoints = AndroidParsing.Devices(await Run(["devices", "-l"], token));
            var found = new Dictionary<string, AndroidManagedDevice>();
            foreach (var endpoint in endpoints)
            {
                var properties = endpoint.State == "device" ? AndroidParsing.Properties(await Run(["-t", endpoint.TransportId, "shell", "getprop"], token)) : new();
                var hardware = properties.GetValueOrDefault("ro.serialno");
                var id = Identity(string.IsNullOrEmpty(hardware) ? endpoint.Serial : hardware);
                AndroidManagedDevice? previous;
                lock (sync) previous = devices.GetValueOrDefault(id) ?? devices.Values.FirstOrDefault(d => d.Connections.Any(c => c.Serial == endpoint.Serial));
                // An authorized hardware identity supersedes an earlier unknown
                // endpoint identity (for example a wireless service name).
                id = string.IsNullOrEmpty(hardware) ? previous?.Id ?? id : id;
                var model = properties.GetValueOrDefault("ro.product.model") ?? previous?.Model;
                var version = properties.GetValueOrDefault("ro.build.version.release") ?? previous?.AndroidVersion;
                var name = properties.GetValueOrDefault("ro.product.manufacturer") ?? previous?.Name ?? model ?? endpoint.Serial;
                if (found.TryGetValue(id, out var same)) found[id] = same with { Connections = [.. same.Connections, endpoint] };
                else found[id] = new(id, name, model, version, [endpoint], previous?.AgentId);
            }
            lock (sync)
            {
                foreach (var old in devices.Values.Where(d => !found.ContainsKey(d.Id)
                    && !d.Connections.Any(c => endpoints.Any(e => e.Serial == c.Serial))))
                    found[old.Id] = old with { Connections = old.Connections.Select(c => c with { State = "offline" }).ToArray() };
                foreach (var value in found.Values.ToArray())
                    if (devices.TryGetValue(value.Id, out var prior)) found[value.Id] = value with { Connections = [.. value.Connections, .. prior.Connections.Where(c => !value.Connections.Any(n => n.Serial == c.Serial)).Select(c => c with { State = "offline" })] };
                devices.Clear(); foreach (var d in found.Values) devices[d.Id] = d;
                Atomic(Path.Combine(directory, "devices.json"), devices.Values.ToArray());
                return new(true, devices.Values.ToArray(), Now());
            }
        }
        finally { scanGate.Release(); }
    }
    private async Task<AndroidEndpoint> Resolve(string deviceId, string? serial, CancellationToken token)
    {
        // Capture one transport for the whole operation. Never fail over while an
        // action might already have executed on another connection.
        await ListAsync(token);
        lock (sync)
        {
            if (!devices.TryGetValue(deviceId, out var device)) throw new AgentActionException("device_not_found", "没有找到这台 Android 设备。");
            var endpoint = device.Connections.Where(c => c.State == "device" && (serial is null || c.Serial == serial)).OrderBy(c => c.Kind == "usb" ? 0 : 1).FirstOrDefault();
            return endpoint ?? throw new AgentActionException("device_unavailable", "设备连接不可用，请检查 ADB 连接和手机授权。");
        }
    }
    private async Task<AndroidDetail> Detail(string id, AndroidEndpoint endpoint, CancellationToken token) => AndroidParsing.Detail(id,
        await Run(["-t", endpoint.TransportId, "shell", AndroidParsing.DetailScript], token));
    internal async Task<object?> QueryAsync(string method, JsonElement p, CancellationToken token)
    {
        switch (method)
        {
            case ListCommand: Fields(p); return await ListAsync(token);
            case "query.android.device":
                Fields(p, "deviceId", "serial"); var id = Text(p, "deviceId");
                return await Detail(id, await Resolve(id, p.TryGetProperty("serial", out var serial) ? serial.GetString() : null, token), token);
            case "query.android.operations":
                Fields(p, "deviceId"); var deviceId = Text(p, "deviceId");
                lock (sync) return new { operations = operations.Values.Where(o => o.DeviceId == deviceId || o.DeviceId == "computer").OrderByDescending(o => o.CreatedAt).Take(50).ToArray() };
            case "query.android.operation":
                Fields(p, "requestId"); var requestId = Id(p, "requestId");
                lock (sync) return operations.GetValueOrDefault(requestId) ?? throw new AgentActionException("operation_not_found", "未找到操作记录，请勿直接重复执行。");
            case "query.android.preview":
                Fields(p, "requestId"); var previewId = Id(p, "requestId");
                lock (sync)
                    if (!operations.TryGetValue(previewId, out var captured) || captured.Status != "completed" || captured.Artifact != "screen.png")
                        throw new AgentActionException("artifact_unavailable", "截图尚未生成。");
                await previewGate.WaitAsync(token);
                try
                {
                    var previewPath = Path.Combine(TaskDirectory(previewId), "preview.jpg");
                    byte[] preview;
                    if (File.Exists(previewPath))
                    {
                        if (new FileInfo(previewPath).Length > AndroidScreenshotPreview.MaximumBytes) throw Invalid();
                        preview = await File.ReadAllBytesAsync(previewPath, token);
                    }
                    else
                    {
                        var pngPath = Path.Combine(TaskDirectory(previewId), "screen.png");
                        if (new FileInfo(pngPath).Length > 16 * 1024 * 1024) throw Invalid();
                        preview = AndroidScreenshotPreview.Create(await File.ReadAllBytesAsync(pngPath, token));
                        var temporary = previewPath + "." + Guid.NewGuid().ToString("N") + ".tmp";
                        try { await File.WriteAllBytesAsync(temporary, preview, token); File.Move(temporary, previewPath, true); }
                        finally { if (File.Exists(temporary)) File.Delete(temporary); }
                    }
                    if (preview.Length > AndroidScreenshotPreview.MaximumBytes) throw Invalid();
                    return new { contentType = "image/jpeg", total = preview.Length, data = Convert.ToBase64String(preview) };
                }
                finally { previewGate.Release(); }
            case "query.android.artifact":
                Fields(p, "requestId", "offset"); var artifactId = Id(p, "requestId");
                AndroidOperation op; lock (sync) op = operations.GetValueOrDefault(artifactId) ?? throw Invalid();
                if (op.Artifact != "screen.png" || op.Status != "completed") throw new AgentActionException("artifact_unavailable", "截图尚未生成。");
                var path = Path.Combine(TaskDirectory(artifactId), "screen.png");
                if (!p.TryGetProperty("offset", out var offsetValue) || !offsetValue.TryGetInt64(out var offset) || offset < 0) throw Invalid();
                using (var file = File.OpenRead(path))
                { if (offset > file.Length) throw Invalid(); file.Position = offset; var buffer = new byte[Math.Min(24576L, file.Length - offset)];
                    var count = await file.ReadAsync(buffer, token); return new { offset, total = file.Length, data = Convert.ToBase64String(buffer, 0, count) }; }
            case "query.android.logs":
                Fields(p, "deviceId", "serial"); var target = Text(p, "deviceId");
                var connection = await Resolve(target, p.TryGetProperty("serial", out var route) ? route.GetString() : null, token);
                var pid = (await Run(["-t", connection.TransportId, "shell", "pidof me.stackli.doppel:agent; true"], token)).Trim().Split(' ')[0];
                if (!Regex.IsMatch(pid, @"\A[0-9]{1,10}\z")) return new { text = "Nami Agent 进程当前未运行，无法读取该进程日志。", sampledAt = Now() };
                var logs = await Run(["-t", connection.TransportId, "logcat", "-d", "-t", "80", "--pid=" + pid], token);
                logs = Regex.Replace(logs, "(?i)(token|password|authorization|privateKey)[\\\"']?\\s*[:=][^\\r\\n]*", "$1=[已隐藏]");
                return new { text = logs[..Math.Min(logs.Length, 12000)], sampledAt = Now() };
            default: throw new AgentActionException("unsupported_method", "不支持的 Android 查询。");
        }
    }
    internal async Task<object?> ActionAsync(string method, JsonElement p, CancellationToken token)
    {
        if (method == "action.android.stream")
        {
            Fields(p, "sessionId", "operation", "deviceId", "serial", "relayId", "ticket");
            var session = Id(p, "sessionId");
            switch (Text(p, "operation"))
            {
                case "stop": return Video.Stop(session);
                case "relay": return Video.Relay(session, Text(p, "relayId"), Text(p, "ticket"));
                case "start":
                    var target = Text(p, "deviceId");
                    return Video.Create(session, target, await Resolve(target, p.TryGetProperty("serial", out _) ? Text(p, "serial", 256) : null, token), VideoPort());
                default: throw Invalid();
            }
        }
        if (method == "action.android.upload") return await UploadAsync(p, token);
        Fields(p, "requestId", "operation", "deviceId", "serial", "address", "code", "uploadId", "agentId");
        var requestId = Id(p, "requestId"); var kind = Text(p, "operation");
        if (!new[] { "wake", "sleep", "screenshot", "start", "restart", "install", "pair", "connect", "tools", "associate" }.Contains(kind)) throw Invalid();
        var deviceId = kind is "pair" or "connect" or "tools" ? "computer" : Text(p, "deviceId");
        var serial = p.TryGetProperty("serial", out _) ? Text(p, "serial", 256) : null;
        if (kind is "pair" or "connect") ValidateAddress(Text(p, "address"));
        if (kind == "pair" && !Regex.IsMatch(Text(p, "code"), @"\A[0-9]{6}\z")) throw Invalid();
        if (kind == "install") _ = Id(p, "uploadId");
        if (kind == "associate" && !Regex.IsMatch(Text(p, "agentId"), @"\A[A-Za-z0-9_-]{1,80}\z")) throw Invalid();
        var fingerprint = Convert.ToHexString(SHA256.HashData(JsonSerializer.SerializeToUtf8Bytes(p))).ToLowerInvariant();
        await gate.WaitAsync(token);
        try
        {
            lock (sync)
            {
                if (operations.TryGetValue(requestId, out var prior))
                { if (prior.Fingerprint != fingerprint) throw new AgentActionException("request_conflict", "此操作编号已用于不同请求。"); return prior; }
                if (operations.Values.Any(o => o.DeviceId == deviceId && o.Status is "running" or "queued")) throw new AgentActionException("android_busy", "设备已有操作正在执行，请先查看原任务。");
                if (running.Count >= 8 || operations.Count >= 1000) throw new AgentActionException("android_limit", "Android 操作记录或并发达到上限，请在电脑上检查。");
                var operation = new AndroidOperation(requestId, kind, deviceId, "queued", "queued", "任务已提交到 Kage。", Now(), Now(), fingerprint);
                Save(operation); operations[requestId] = operation;
                var parameters = p.Clone();
                running[requestId] = Task.Run(async () =>
                { try { await ExecuteAsync(operation, parameters, serial, stopping.Token); }
                    finally { lock (sync) running.Remove(requestId); } });
                return operation;
            }
        }
        finally { gate.Release(); }
    }
    private void Update(string id, string status, string phase, string message, string? artifact = null)
    { lock (sync) { var next = operations[id] with { Status = status, Phase = phase, Message = message, UpdatedAt = Now(), Artifact = artifact };
            Save(next); operations[id] = next; } }
    private async Task ExecuteAsync(AndroidOperation operation, JsonElement p, string? serial, CancellationToken token)
    {
        var id = operation.Id; var dispatched = false;
        try
        {
            Update(id, "running", "checking", "正在检查设备连接。");
            if (operation.Kind == "tools") { await InstallTools(token); Update(id, "completed", "verified", "官方 ADB 平台工具已就绪。"); return; }
            if (operation.Kind is "pair" or "connect")
            {
                dispatched = true;
                var output = await Run([operation.Kind, Text(p, "address")], token, operation.Kind == "pair" ? Text(p, "code") + "\n" : null);
                if (!output.Contains(operation.Kind == "pair" ? "Successfully paired" : "connected to", StringComparison.OrdinalIgnoreCase)) throw new AgentActionException("connection_failed", "配对或连接未成功，请核对手机显示的地址、端口和配对码。");
                Update(id, "completed", "verified", operation.Kind == "pair" ? "配对成功，请继续连接无线调试端口。" : "连接成功，请刷新设备列表。"); return;
            }
            var endpoint = await Resolve(operation.DeviceId, serial, token);
            if (operation.Kind == "associate")
            { lock (sync) { devices[operation.DeviceId] = devices[operation.DeviceId] with { AgentId = Text(p, "agentId") }; Atomic(Path.Combine(directory, "devices.json"), devices.Values.ToArray()); }
                Update(id, "completed", "verified", "Agent 关联已保存。"); return; }
            var prefix = new[] { "-t", endpoint.TransportId };
            if (operation.Kind == "install")
            {
                var uploadId = Id(p, "uploadId"); var apk = Path.Combine(UploadDirectory(uploadId), "package.apk");
                var metadata = AndroidApk.Read(apk);
                var before = await Detail(operation.DeviceId, endpoint, token);
                if (before.NamiVersionCode is { } version && metadata.VersionCode < version) throw new AgentActionException("apk_downgrade", "APK 版本低于已安装版本，已拒绝降级。");
                Update(id, "running", "installing", "包名和版本检查通过，签名由 Android 安装器校验；正在保留数据覆盖安装。");
                dispatched = true;
                var install = await Run([.. prefix, "install", "-r", apk], token);
                if (!install.Contains("Success", StringComparison.Ordinal)) throw new AgentActionException("install_failed", "Android 未确认安装成功，未卸载应用或清除数据。");
                var after = await Detail(operation.DeviceId, endpoint, token);
                if (after.NamiVersionCode != metadata.VersionCode) throw new AgentActionException("version_unconfirmed", "安装后版本回查未通过，请查询手机实际状态。");
            }
            Update(id, "running", "executing", "正在通过已选 ADB 连接执行操作。"); dispatched = true;
            if (operation.Kind is "wake" or "sleep") await Run([.. prefix, "shell", "input", "keyevent", operation.Kind == "wake" ? "224" : "223"], token);
            else if (operation.Kind == "screenshot")
            {
                var image = await adb.RunAsync([.. prefix, "exec-out", "screencap", "-p"], token, limit: 16 * 1024 * 1024);
                if (image.Length < 8 || !image.AsSpan(0, 8).SequenceEqual(new byte[] { 137, 80, 78, 71, 13, 10, 26, 10 })) throw new IOException("截图格式无效。");
                await File.WriteAllBytesAsync(Path.Combine(TaskDirectory(id), "screen.png"), image, token);
                Update(id, "completed", "verified", "已获取单张屏幕截图。", "screen.png"); return;
            }
            else
            {
                if (operation.Kind == "restart") await Run([.. prefix, "shell", "am", "force-stop", "me.stackli.doppel"], token);
                var launch = await Run([.. prefix, "shell", "am", "start", "-W", "-n", "me.stackli.doppel/.MainActivity"], token);
                if (launch.Contains("Error", StringComparison.OrdinalIgnoreCase) || !launch.Contains("Status: ok", StringComparison.OrdinalIgnoreCase)) throw new AgentActionException("launch_unconfirmed", "系统未确认应用启动，请检查手机状态。");
            }
            Update(id, "running", "verifying", "正在回查手机实际状态。");
            var detail = await Detail(operation.DeviceId, endpoint, token);
            if (operation.Kind is "wake" or "sleep")
            {
                if (detail.Screen != (operation.Kind == "wake" ? "on" : "off")) { Update(id, "unknown", "verification", "指令已发送，但屏幕状态尚未确认，请查看设备数据。"); return; }
                Update(id, "completed", "verified", operation.Kind == "wake" ? "已回查：屏幕亮起；未解除锁屏。" : "已回查：屏幕熄灭。");
            }
            else if (!detail.ProcessRunning) Update(id, "unknown", "verification", "启动指令已返回，但尚未确认 Nami 进程运行。");
            else Update(id, "completed", "process_verified", "已确认 Nami 进程运行；Agent 是否在线请在 Hako 中独立确认。");
        }
        catch (Exception error)
        {
            var known = error as AgentActionException;
            Update(id, dispatched && known is null ? "unknown" : "failed", "stopped",
                known?.Message ?? (dispatched ? "操作结果待确认，未自动重试。请查询设备实际状态和原操作记录。" : "操作未开始，请检查 ADB、设备连接或文件。"));
        }
    }
    internal static void ValidateAddress(string value)
    {
        var parts = value.Split(':');
        if (parts.Length != 2 || !IPAddress.TryParse(parts[0], out var address) || !AgentLanEndpoint.IsPrivateIPv4(address)
            || !int.TryParse(parts[1], out var port) || port is < 1 or > 65535) throw new AgentActionException("invalid_address", "请填写局域网 IPv4 和 1–65535 端口。");
    }
    private async Task<object> UploadAsync(JsonElement p, CancellationToken token)
    {
        Fields(p, "uploadId", "fileName", "length", "sha256", "offset", "data");
        var id = Id(p, "uploadId"); var name = Text(p, "fileName", 255); var hash = Text(p, "sha256");
        if (!name.EndsWith(".apk", StringComparison.OrdinalIgnoreCase) || !Regex.IsMatch(hash, @"\A[a-f0-9]{64}\z")
            || !p.GetProperty("length").TryGetInt64(out var length) || length is < 1 or > 256 * 1024 * 1024
            || !p.GetProperty("offset").TryGetInt64(out var offset) || offset < 0) throw Invalid();
        byte[] bytes; try { bytes = Convert.FromBase64String(Text(p, "data", 11000)); } catch (FormatException) { throw Invalid(); }
        if (bytes.Length is < 1 or > 8192 || offset > length - bytes.Length) throw Invalid();
        await gate.WaitAsync(token);
        try
        {
            var folder = UploadDirectory(id); var metadata = new AndroidUpload(id, name, length, hash); var metadataFile = Path.Combine(folder, "metadata.json");
            if (File.Exists(metadataFile)) { if (JsonSerializer.Deserialize<AndroidUpload>(File.ReadAllBytes(metadataFile), AgentConnection.Json) != metadata) throw new AgentActionException("upload_conflict", "上传编号已用于其他文件。"); }
            else
            {
                if (offset != 0) throw Invalid();
                var uploads = Path.Combine(directory, "uploads");
                if (Directory.Exists(uploads) && Directory.EnumerateDirectories(uploads).Count() >= 16) throw new AgentActionException("upload_limit", "上传缓存已达上限，请在电脑上清理已完成文件。");
                Atomic(metadataFile, metadata);
            }
            var complete = Path.Combine(folder, "package.apk"); var partial = Path.Combine(folder, "partial.apk");
            using (var file = new FileStream(File.Exists(complete) ? complete : partial, FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None))
            {
                if (offset > file.Length) throw new AgentActionException("upload_offset", "上传偏移不连续，请查询原上传状态。");
                if (offset < file.Length)
                { if (offset + bytes.Length > file.Length) throw Invalid(); file.Position = offset; var previous = new byte[bytes.Length]; file.ReadExactly(previous); if (!previous.SequenceEqual(bytes)) throw new AgentActionException("upload_conflict", "重复上传块与原内容不同。"); }
                else { file.Position = offset; await file.WriteAsync(bytes, token); await file.FlushAsync(token); }
                if (file.Length == length) { file.Position = 0; if (!Convert.ToHexString(await SHA256.HashDataAsync(file, token)).Equals(hash, StringComparison.OrdinalIgnoreCase)) throw new AgentActionException("upload_hash", "上传文件校验失败。"); }
            }
            var received = new FileInfo(File.Exists(complete) ? complete : partial).Length;
            if (received == length && !File.Exists(complete)) File.Move(partial, complete);
            return new { uploadId = id, received, completed = File.Exists(complete) };
        }
        finally { gate.Release(); }
    }
    private async Task InstallTools(CancellationToken token)
    {
        var zipPath = Path.Combine(directory, "platform-tools.download.zip");
        using var client = new HttpClient(new HttpClientHandler { AllowAutoRedirect = false }) { Timeout = TimeSpan.FromMinutes(3) };
        using var response = await client.GetAsync("https://dl.google.com/android/repository/platform-tools-latest-windows.zip", HttpCompletionOption.ResponseHeadersRead, token);
        response.EnsureSuccessStatusCode();
        await using (var output = File.Create(zipPath))
        { await using var input = await response.Content.ReadAsStreamAsync(token); var buffer = new byte[81920]; long total = 0;
            while (true) { var count = await input.ReadAsync(buffer, token); if (count == 0) break; total += count; if (total > 50 * 1024 * 1024) throw new IOException("下载过大。"); await output.WriteAsync(buffer.AsMemory(0, count), token); } }
        using (var zip = ZipFile.OpenRead(zipPath)) foreach (var name in new[] { "adb.exe", "AdbWinApi.dll", "AdbWinUsbApi.dll" })
        { var entry = zip.GetEntry("platform-tools/" + name) ?? throw new IOException("工具包不完整。"); if (entry.Length > 20 * 1024 * 1024) throw new IOException("工具文件过大。");
            var target = Path.Combine(directory, "platform-tools", name); Directory.CreateDirectory(Path.GetDirectoryName(target)!); entry.ExtractToFile(target, true); }
        _ = await Run(["version"], token);
        File.Delete(zipPath);
    }
    public async ValueTask DisposeAsync()
    { await stopping.CancelAsync(); await Video.DisposeAsync(); Task[] tasks; lock (sync) tasks = running.Values.ToArray(); await Task.WhenAll(tasks); stopping.Dispose(); }
}
