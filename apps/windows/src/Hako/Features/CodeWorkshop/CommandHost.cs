using System;
using System.Diagnostics;
using System.IO;
using System.Net.WebSockets;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Hako.Core;

namespace Hako.Platform;

internal sealed record CommandHostEndpoint(int Port, string Token, int ProcessId, long StartedAt, string Scope);

internal static class CommandHost
{
    private static string EndpointPath(string directory) => Path.Combine(directory, "command-host.dat");
    private static string RequestPath(string directory) => AgentGuardianControl.FileFor(directory, "commands.requested");
    internal static string Scope(AgentSettingsStore store) => Scope(store.DirectoryPath, store.Load());
    internal static string Scope(string directory, AgentSettings settings)
    {
        var key = settings.PrivateKey.Length == 0 ? "" : AgentKeys.ExportPublicKey(settings.PrivateKey);
        return Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(directory + "\n" + settings.Url + "\n" + settings.Username + "\n" + key)));
    }
    internal static void Save(string path, byte[] bytes)
    {
        var temporary = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            File.WriteAllBytes(temporary, bytes);
            var deadline = DateTime.UtcNow.AddSeconds(2);
            while (true)
            {
                try { File.Move(temporary, path, true); break; }
                catch (Exception error) when (error is IOException or UnauthorizedAccessException && DateTime.UtcNow < deadline) { Thread.Sleep(10); }
            }
        }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }
    internal static byte[] ReadShared(string path)
    {
        using var file = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
        using var bytes = new MemoryStream(); file.CopyTo(bytes); return bytes.ToArray();
    }
    private static CommandHostEndpoint? Endpoint(AgentSettingsStore store, int? guardianId = null)
    {
        var path = EndpointPath(store.DirectoryPath);
        if (!File.Exists(path)) return null;
        var endpoint = JsonSerializer.Deserialize<CommandHostEndpoint>(DataProtection.Unprotect(ReadShared(path)), WorkshopProtocol.Json)
            ?? throw new IOException("无效的命令执行器状态。");
        if (guardianId is not null && endpoint.ProcessId != guardianId) return null;
        try
        {
            using var process = Process.GetProcessById(endpoint.ProcessId);
            if (process.HasExited || process.StartTime.ToUniversalTime().Ticks != endpoint.StartedAt) return null;
        }
        catch (ArgumentException) { return null; }
        if (endpoint.Scope != Scope(store)) throw new WorkshopException("command_context_changed", "执行器仍属于之前的账号配置，请等待任务结束后重试。");
        return endpoint;
    }
    // LAN clients use the Agent's configured port. Only this local hop uses the
    // guardian's authenticated, ephemeral endpoint; no extra firewall rule is needed.
    internal static async Task<object?> ForwardAsync(string directory, string method, JsonElement parameters, CancellationToken token)
    {
        var endpoint = Endpoint(new AgentSettingsStore(directory))
            ?? throw new WorkshopException("command_host_unavailable", "命令执行器尚未就绪，请重新连接快捷命令。");
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(token);
        deadline.CancelAfter(TimeSpan.FromSeconds(10));
        using var socket = new ClientWebSocket();
        socket.Options.Proxy = null;
        socket.Options.SetRequestHeader("X-Hako-Command", endpoint.Token);
        await socket.ConnectAsync(new Uri($"ws://127.0.0.1:{endpoint.Port}/workshop/v1"), deadline.Token);
        using var welcome = await Read(socket, deadline.Token);
        if (CodexJson.Text(welcome.RootElement, "kind") != "welcome" || CodexJson.Text(welcome.RootElement, "protocol") != WorkshopProtocol.Name)
            throw new WorkshopException("command_host_protocol", "本机命令执行器握手失败。");
        var id = Guid.NewGuid().ToString("N");
        await socket.SendAsync(JsonSerializer.SerializeToUtf8Bytes(new { kind = "call", id, method, @params = parameters }),
            WebSocketMessageType.Text, true, deadline.Token);
        using var response = await Read(socket, deadline.Token);
        var frame = response.RootElement;
        if (CodexJson.Text(frame, "id") != id) throw new WorkshopException("command_host_protocol", "本机命令执行器返回了不匹配的请求。");
        if (CodexJson.Text(frame, "kind") == "result") return frame.GetProperty("result").Clone();
        if (frame.TryGetProperty("error", out var error))
            throw new WorkshopException(CodexJson.Text(error, "code"), CodexJson.Text(error, "message"));
        throw new WorkshopException("command_host_protocol", "本机命令执行器返回了无效结果。");
    }
    private static async Task<JsonDocument> Read(ClientWebSocket socket, CancellationToken token)
    {
        using var bytes = new MemoryStream();
        var buffer = new byte[8192];
        WebSocketReceiveResult frame;
        do
        {
            frame = await socket.ReceiveAsync(buffer, token);
            if (frame.MessageType != WebSocketMessageType.Text || bytes.Length + frame.Count > 65536)
                throw new WorkshopException("command_host_protocol", "本机命令执行器返回的数据无效或过大。");
            bytes.Write(buffer, 0, frame.Count);
        } while (!frame.EndOfMessage);
        return JsonDocument.Parse(bytes.ToArray());
    }
    internal static async Task<object> OpenAsync(string directory, CancellationToken token)
    {
        var store = new AgentSettingsStore(directory);
        Directory.CreateDirectory(directory);
        using var startup = new FileStream(Path.Combine(directory, "command-host-start.lock"), FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None);
        var guardianId = await AgentGuardianControl.EnsureRunningAsync(directory, token);
        var existing = Endpoint(store, guardianId);
        if (existing is not null) return existing;
        Save(RequestPath(directory), []);
        using var guardian = Process.GetProcessById(guardianId);
        var deadline = DateTime.UtcNow.AddSeconds(12);
        do
        {
            token.ThrowIfCancellationRequested();
            var endpoint = Endpoint(store, guardianId);
            if (endpoint is not null) return endpoint;
            if (guardian.HasExited) throw new IOException("守护进程已退出，命令服务启动失败。");
            await Task.Delay(100, token);
        } while (DateTime.UtcNow < deadline);
        throw new TimeoutException("守护进程的命令服务尚未就绪，请检查守护进程状态后重新打开快捷命令。");
    }
    // This supervisor runs alongside, never inside, the guardian's update/recovery loop.
    internal static async Task RunRequestedAsync(string directory, CancellationToken stopping)
    {
        var stop = AgentGuardianControl.FileFor(directory, "stop");
        while (!stopping.IsCancellationRequested && !File.Exists(stop))
        {
            if (File.Exists(RequestPath(directory)))
            {
                try { await RunAsync(directory, stopping); }
                catch (Exception error)
                {
                    try { AgentGuardianControl.Write(AgentGuardianControl.FileFor(directory, "commands-status.json"),
                        new { state = "retrying", error = error.GetType().Name, updatedAt = DateTimeOffset.UtcNow }); }
                    catch (Exception logError) when (logError is IOException or UnauthorizedAccessException) { Debug.WriteLine(logError.GetType().Name); }
                    if (!stopping.IsCancellationRequested) await Task.Delay(1000);
                }
            }
            else await Task.Delay(200);
        }
    }
    private static async Task RunAsync(string directory, CancellationToken stopping)
    {
        var profile = new AgentProfile(directory);
        Directory.CreateDirectory(directory);
        var owner = new FileStream(Path.Combine(directory, "command-host-owner.lock"), FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None);
        using (owner)
        {
            var scope = Scope(profile.Store);
            await using var dispatcher = new WorkshopDispatcher(directory, commandsOnly: true);
            var token = Convert.ToHexString(RandomNumberGenerator.GetBytes(32));
            string? computerId = null;
            var identityFile = Path.Combine(directory, "workshop-computer-id.txt");
            if (File.Exists(identityFile)) computerId = File.ReadAllText(identityFile).Trim();
            await using var local = new WorkshopLocalServer(dispatcher, 0, () => computerId, directory, token);
            await using var cloud = new WorkshopConnection(dispatcher, id => computerId = id, commandHost: true, profileDirectory: directory);
            var settings = profile.Store.Load();
            var connected = false;
            using var self = Process.GetCurrentProcess();
            Save(EndpointPath(directory), DataProtection.Protect(JsonSerializer.SerializeToUtf8Bytes(
                new CommandHostEndpoint(local.Port, token, self.Id, self.StartTime.ToUniversalTime().Ticks, scope), WorkshopProtocol.Json)));
            try
            {
                AgentGuardianControl.Write(AgentGuardianControl.FileFor(directory, "commands-status.json"),
                    new { state = "ready", processId = self.Id, updatedAt = DateTimeOffset.UtcNow });
                var draining = false;
                while (true)
                {
                    bool changed;
                    try { changed = Scope(profile.Store) != scope; }
                    catch (Exception error) when (error is IOException or UnauthorizedAccessException or JsonException or CryptographicException or ArgumentException)
                    { changed = true; }
                    var enabled = !changed && !File.Exists(AgentGuardianControl.FileFor(directory, "connection-paused"))
                        && settings.Url.Length > 0 && settings.PrivateKey.Length > 0;
                    if (connected != enabled)
                    {
                        if (enabled) await cloud.StartAsync(settings); else await cloud.StopAsync();
                        connected = enabled;
                    }
                    if (stopping.IsCancellationRequested || File.Exists(AgentGuardianControl.FileFor(directory, "stop")) || changed)
                    {
                        dispatcher.Commands!.BeginDrain();
                        if (!draining) AgentGuardianControl.Write(AgentGuardianControl.FileFor(directory, "commands-status.json"),
                            new { state = "draining", processId = self.Id, updatedAt = DateTimeOffset.UtcNow });
                        draining = true;
                        if (!dispatcher.Commands.HasRunning) break;
                    }
                    await Task.Delay(200);
                }
            }
            finally { File.Delete(EndpointPath(directory)); }
        }
    }
}
