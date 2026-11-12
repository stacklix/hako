using System;
using System.Diagnostics;
using System.IO;
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
    internal static string Scope(AgentSettingsStore store)
    {
        var settings = store.Load();
        var key = settings.PrivateKey.Length == 0 ? "" : AgentKeys.ExportPublicKey(settings.PrivateKey);
        return Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(store.DirectoryPath + "\n" + settings.Url + "\n" + settings.Username + "\n" + key)));
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
    private static CommandHostEndpoint? Endpoint(AgentSettingsStore store)
    {
        var path = EndpointPath(store.DirectoryPath);
        if (!File.Exists(path)) return null;
        var endpoint = JsonSerializer.Deserialize<CommandHostEndpoint>(DataProtection.Unprotect(ReadShared(path)), WorkshopProtocol.Json)
            ?? throw new IOException("无效的命令执行器状态。");
        try
        {
            using var process = Process.GetProcessById(endpoint.ProcessId);
            if (process.HasExited || process.StartTime.ToUniversalTime().Ticks != endpoint.StartedAt) return null;
        }
        catch (ArgumentException) { return null; }
        if (endpoint.Scope != Scope(store)) throw new WorkshopException("command_context_changed", "执行器仍属于之前的账号配置，请等待任务结束后重试。");
        return endpoint;
    }
    internal static async Task<object> OpenAsync(string directory, CancellationToken token)
    {
        var store = new AgentSettingsStore(directory);
        Directory.CreateDirectory(directory);
        using var startup = new FileStream(Path.Combine(directory, "command-host-start.lock"), FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None);
        var existing = Endpoint(store);
        if (existing is not null) return existing;
        var executable = Environment.ProcessPath ?? throw new IOException("找不到 Agent 程序。");
        var frameworkHost = Path.GetFileNameWithoutExtension(executable).Equals("dotnet", StringComparison.OrdinalIgnoreCase);
        if (!frameworkHost && !File.Exists(Path.Combine(Path.GetDirectoryName(executable)!, "Hako.dll")))
        {
            using var input = File.OpenRead(executable);
            var hash = Convert.ToHexString(SHA256.HashData(input));
            var cache = Path.Combine(directory, "command-runners", hash);
            Directory.CreateDirectory(cache);
            var target = Path.Combine(cache, "Hako.exe");
            if (!File.Exists(target)) File.Copy(executable, target);
            using var cached = File.OpenRead(target);
            if (Convert.ToHexString(SHA256.HashData(cached)) != hash) throw new IOException("独立执行器副本校验失败。");
            executable = target;
        }
        var arguments = new[] { "--command-host", "--data-dir", directory };
        if (frameworkHost)
            arguments = new[] { Path.Combine(AppContext.BaseDirectory, "Hako.dll"), "--command-host", "--data-dir", directory };
        using var launched = DetachedAgentProcess.Start(executable, arguments);
        var deadline = DateTime.UtcNow.AddSeconds(12);
        do
        {
            token.ThrowIfCancellationRequested();
            var endpoint = Endpoint(store);
            if (endpoint is not null) return endpoint;
            if (launched.HasExited) throw new IOException("独立命令执行器启动失败。");
            await Task.Delay(100, token);
        } while (DateTime.UtcNow < deadline);
        throw new TimeoutException("执行器启动结果尚未确认，请重新打开快捷命令查询。");
    }
    internal static async Task RunAsync(string directory)
    {
        var profile = new AgentProfile(directory);
        Directory.CreateDirectory(directory);
        FileStream owner;
        try { owner = new FileStream(Path.Combine(directory, "command-host-owner.lock"), FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None); }
        catch (IOException) { return; }
        using (owner)
        {
            var scope = Scope(profile.Store);
            await using var dispatcher = new WorkshopDispatcher(directory, commandsOnly: true);
            var token = Convert.ToHexString(RandomNumberGenerator.GetBytes(32));
            string? computerId = null;
            var identityFile = Path.Combine(directory, "workshop-computer-id.txt");
            if (File.Exists(identityFile)) computerId = File.ReadAllText(identityFile).Trim();
            await using var local = new WorkshopLocalServer(dispatcher, 0, () => computerId, directory, token);
            await using var cloud = new WorkshopConnection(dispatcher, id => computerId = id, commandHost: true);
            var settings = profile.Store.Load();
            if (settings.Url.Length > 0 && settings.PrivateKey.Length > 0) await cloud.StartAsync(settings);
            using var self = Process.GetCurrentProcess();
            Save(EndpointPath(directory), DataProtection.Protect(JsonSerializer.SerializeToUtf8Bytes(
                new CommandHostEndpoint(local.Port, token, self.Id, self.StartTime.ToUniversalTime().Ticks, scope), WorkshopProtocol.Json)));
            while (!dispatcher.Commands!.RetireIfIdle())
                await Task.Delay(1000);
        }
    }
}
