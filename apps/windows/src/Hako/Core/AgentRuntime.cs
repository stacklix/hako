using System;
using System.Collections.Generic;
using System.IO;
using System.Security.Cryptography;
using System.Threading;
using System.Threading.Tasks;
using Hako.Platform;

namespace Hako.Core;

public sealed class AgentRuntime : IAsyncDisposable
{
    public AgentSettingsStore Store { get; }
    public SystemMetrics Metrics { get; } = new();
    public AgentConnection Connection { get; }
    public event Action<string>? StatusChanged;
    public event Action<AgentSettings, bool>? SettingsChanged;
    public event Action<Metrics>? MetricsReceived;
    public event Action? ShowRequested;
    private readonly SemaphoreSlim operations = new(1, 1);
    private readonly bool running;
    private string? configurationError;
    private readonly CodexUsage codexUsage;

    public AgentRuntime(AgentSettingsStore store, bool running)
    {
        Store = store; this.running = running;
        codexUsage = new CodexUsage(cachePath: Path.Combine(store.DirectoryPath, "codex-usage.json"));
        Connection = new AgentConnection(Metrics, codexUsage);
        Connection.StatusChanged += text => StatusChanged?.Invoke(text);
        Connection.MetricsReceived += value => MetricsReceived?.Invoke(value);
    }
    public async Task InitializeAsync(bool autoConnect)
    {
        if (running) codexUsage.Start();
        try
        {
            var saved = Store.Load();
            if (autoConnect && saved.Url.Length > 0) { saved.Validate(); await Connection.StartAsync(saved); }
        }
        catch (Exception) { configurationError = "配置读取失败或配置不完整，请检查服务器设置。"; StatusChanged?.Invoke(configurationError); }
    }
    public object PublicSettings()
    {
        var value = Store.Load();
        string? keyId = null;
        if (value.PrivateKey.Length > 0) { using var rsa = RSA.Create(); rsa.ImportFromPem(value.PrivateKey); keyId = AgentSettings.KeyId(rsa); }
        return new { url = value.Url, account = value.Username, hasPrivateKey = value.PrivateKey.Length > 0, keyId };
    }
    public object Status()
    {
        var connection = Connection.Status;
        return new { running, processId = running ? Environment.ProcessId : (int?)null,
            connectionState = !running ? "stopped" : configurationError is not null ? "configuration_error" : connection.State,
            message = configurationError ?? (!running ? "后台实例未运行。" : connection.Message), agentId = connection.AgentId, configuration = PublicSettings() };
    }
    public async Task UpdateConfigurationAsync(string? url, string? account, bool connect, bool reloadForm = true, CancellationToken token = default)
    {
        await operations.WaitAsync(token);
        try
        {
            var current = Store.Load();
            var next = current with { Url = url is null ? current.Url : url.Trim().TrimEnd('/'), Username = account?.Trim() ?? current.Username };
            next.ValidateConnectionSettings();
            if (connect) next.Validate();
            await Connection.StopAsync();
            token.ThrowIfCancellationRequested();
            Store.Save(next); configurationError = null;
            SettingsChanged?.Invoke(next, reloadForm);
            if (connect) await Connection.StartAsync(next);
        }
        finally { operations.Release(); }
    }
    public async Task UpdatePrivateKeyAsync(string pem, bool reloadForm = true)
    {
        await operations.WaitAsync();
        try { await SaveKeyLockedAsync(AgentKeys.NormalizePrivateKey(pem), reloadForm, CancellationToken.None); }
        finally { operations.Release(); }
    }
    private async Task SaveKeyLockedAsync(string pem, bool reloadForm, CancellationToken token)
    {
        var current = Store.Load();
        await Connection.StopAsync();
        token.ThrowIfCancellationRequested();
        var next = current with { PrivateKey = pem };
        Store.Save(next); configurationError = null;
        SettingsChanged?.Invoke(next, reloadForm);
        StatusChanged?.Invoke("设备密钥已保存，请登记服务端公钥后重新连接。");
    }
    public async Task ClearAsync()
    {
        await operations.WaitAsync();
        try
        {
            await Connection.StopAsync(); Store.Save(new()); configurationError = null;
            SettingsChanged?.Invoke(new(), true);
        }
        finally { operations.Release(); }
    }
    public async Task<CommandReply> ExecuteAsync(AgentCommand request, CancellationToken token = default)
    {
        try
        {
            CliParser.Validate(request);
            if (request.Command == "help") return CliHelp.Reply(request.Options.GetValueOrDefault("topic", ""));
            if (request.Command == "metrics")
            {
                var result = await Metrics.SampleAsync(token); MetricsReceived?.Invoke(result);
                var network = result.Network;
                var networkText = network?.Available == true
                    ? $"下行：{NetworkTraffic.FormatRate(network.DownloadBytesPerSecond)}\n上行：{NetworkTraffic.FormatRate(network.UploadBytesPerSecond)}"
                    : "网络：" + (network?.Message ?? "暂不可用");
                return CommandReply.Success(result, $"CPU：{result.CpuUsagePercent:F1}%\n内存：{result.MemoryUsagePercent:F1}%\n{networkText}\n采样：{result.SampledAt}");
            }
            if (request.Command == "config set")
            {
                await UpdateConfigurationAsync(request.Options.GetValueOrDefault("url"), request.Options.GetValueOrDefault("account"), false, token: token);
                return CommandReply.Success(PublicSettings(), "配置已加密保存。请使用 connect 连接服务器。");
            }
            await operations.WaitAsync(token);
            try
            {
                switch (request.Command)
                {
                    case "status": return CommandReply.Success(Status(), System.Text.Json.JsonSerializer.Serialize(Status(), CliWire.Json));
                    case "config show": return CommandReply.Success(PublicSettings(), System.Text.Json.JsonSerializer.Serialize(PublicSettings(), CliWire.Json));
                    case "key generate":
                    case "key import":
                        if (Store.Load().PrivateKey.Length > 0 && !request.Options.ContainsKey("force"))
                            return CommandReply.Failure(1, "key_exists", "已有设备密钥。如需替换并断开旧连接，请显式使用 --force。");
                        var key = request.Command == "key generate" ? await Task.Run(AgentKeys.GeneratePrivateKey, token)
                            : AgentKeys.NormalizePrivateKey(await File.ReadAllTextAsync(request.Options["input"], token));
                        await SaveKeyLockedAsync(key, true, token);
                        return CommandReply.Success(PublicSettings(), "设备密钥已生成或导入，并立即加密保存。请导出公钥登记到服务端。");
                    case "key export-public":
                        var settings = Store.Load();
                        if (settings.PrivateKey.Length == 0) return CommandReply.Failure(1, "key_missing", "尚无设备密钥，请先运行 key generate。");
                        var publicPem = AgentKeys.ExportPublicKey(settings.PrivateKey);
                        using (var rsa = RSA.Create())
                        {
                            rsa.ImportFromPem(settings.PrivateKey);
                            var keyId = AgentSettings.KeyId(rsa);
                            if (!request.Options.TryGetValue("output", out var output)) return CommandReply.Success(new { publicKeyPem = publicPem, keyId }, publicPem);
                            output = Path.GetFullPath(output);
                            if (string.Equals(output, Store.SettingsPath, StringComparison.OrdinalIgnoreCase)) throw new ArgumentException("不能用公钥覆盖设备配置文件。");
                            using var stream = new FileStream(output, request.Options.ContainsKey("force") ? FileMode.Create : FileMode.CreateNew, FileAccess.Write);
                            var bytes = System.Text.Encoding.UTF8.GetBytes(publicPem + "\n"); await stream.WriteAsync(bytes, token);
                            return CommandReply.Success(new { path = output, keyId }, "公钥已导出：" + output);
                        }
                    case "connect":
                        if (!running) return CommandReply.Failure(3, "instance_unavailable", "需要后台实例保持连接。");
                        var connectionSettings = Store.Load(); connectionSettings.Validate(); configurationError = null;
                        await Connection.StartAsync(connectionSettings);
                        return CommandReply.Success(Status(), "已发起连接；请使用 status 查看身份验证结果。");
                    case "disconnect":
                        await Connection.StopAsync(); return CommandReply.Success(Status(), "已断开连接，并停止自动重试。");
                    case "exit": return CommandReply.Success(new { exiting = running }, running ? "正在退出后台实例。" : "后台实例未运行。");
                    case "show": ShowRequested?.Invoke(); return CommandReply.Success(Status(), "已请求打开 Hako 窗口。");
                    default: throw new CliUsageException("未知命令。");
                }
            }
            finally { operations.Release(); }
        }
        catch (CliUsageException error) { return CommandReply.Failure(2, "invalid_arguments", error.Message); }
        catch (OperationCanceledException) { return CommandReply.Failure(4, "timeout", "操作超时，结果可能尚未确认，请查询状态后重试。"); }
        catch (Exception error) { return CommandReply.Failure(1, "operation_failed", error.Message); }
    }
    public async ValueTask DisposeAsync()
    {
        await Connection.DisposeAsync();
        await codexUsage.DisposeAsync();
    }
}
