using System;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Hako.Core;

namespace Hako.Platform;

public sealed record ServiceStartupStatus(string State, string Message, string RequestedAt);
public sealed record ServiceStartReply(string Name, string RequestId, string State, string Message);

public sealed partial class RegisteredServices
{
    public const string StartCommand = "admin.services.start";
    private readonly string startupDirectory;
    private sealed record StartReceipt(string Name, string RequestId, string State, string RequestedAt,
        int? ProcessId = null, long? ProcessStartedAt = null);

    private string ScopeDirectory => Path.Combine(startupDirectory,
        Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(Path.GetFullPath(registryPath).ToUpperInvariant()))));
    private string LatestPath(string name) => Path.Combine(ScopeDirectory,
        "service-" + Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(name))) + ".json");
    private string ReceiptPath(string id) => Path.Combine(ScopeDirectory, id + ".json");
    private string CompletionPath(string id) => Path.Combine(ScopeDirectory, id + ".exit");

    public async Task<ServiceStartReply> StartAsync(JsonElement parameters, CancellationToken token)
    {
        if (parameters.ValueKind != JsonValueKind.Object || parameters.EnumerateObject().Count() != 2
            || !parameters.TryGetProperty("name", out var nameValue) || nameValue.ValueKind != JsonValueKind.String
            || nameValue.GetString() is not { Length: > 0 and <= 200 } name
            || !parameters.TryGetProperty("requestId", out var idValue) || idValue.ValueKind != JsonValueKind.String
            || !Guid.TryParseExact(idValue.GetString(), "D", out var id))
            throw new AgentActionException("invalid_params", "启动服务需要已登记的 name 和唯一 requestId。");
        var requestId = id.ToString("D");
        // Share the same exclusive registry lock as service registration tools.
        // It serializes starts from the local UI and every remote Console.
        using var registryLock = await LockRegistryAsync(token);
        var registrations = await ReadRegistryAsync(token);
        var service = registrations.SingleOrDefault(service => service.Name == name)
            ?? throw new AgentActionException("service_not_registered", "该服务已不在登记表中，请刷新列表。");
        var previous = ReadReceipt(ReceiptPath(requestId));
        if (previous is not null)
        {
            if (previous.Name != name) throw new AgentActionException("request_conflict", "该 requestId 已用于其他服务。");
            var status = StartupStatus(previous);
            return new(name, requestId, status.State, status.Message);
        }
        var listeners = readListeners is not null ? await readListeners(token)
            : await new NetworkListeners().ReadAsync(token, new System.Collections.Generic.HashSet<int> { service.Port });
        if (listeners.Ports.Any(port => port.Protocol == "TCP" && port.Port == service.Port))
            return new(name, requestId, "already_listening", "登记端口已在监听，未重复启动。请刷新查看当前进程。");
        if (listeners.Warnings.Any(warning => warning.StartsWith("TCP ", StringComparison.Ordinal)))
            throw new AgentActionException("listener_unavailable", "无法完整确认端口状态，暂不启动服务。");
        var existing = ReadStartup(name);
        if (existing?.State is "starting" or "unknown") return new(name, requestId, existing.State, existing.Message);
        if (service.StartCommand is null)
            throw new AgentActionException("start_command_missing", "该服务尚未登记 startCommand，请在设备的 server.json 中填写启动命令。");
        var directory = service.WorkingDirectory ?? Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        if (!Directory.Exists(directory)) throw new AgentActionException("working_directory_missing", "登记的 workingDirectory 不存在，请在设备上修正后重试。");
        token.ThrowIfCancellationRequested();
        Directory.CreateDirectory(ScopeDirectory);
        var receipt = new StartReceipt(name, requestId, "dispatching", DateTimeOffset.UtcNow.ToString("O"));
        // Persist the intent before launching. An interrupted or repeated request
        // must never spawn a second copy of an unconfirmed command.
        SaveReceipt(receipt);
        try
        {
            var log = Path.Combine(ScopeDirectory, requestId + ".log");
            var completion = CompletionPath(requestId);
            static string Literal(string value) => "'" + value.Replace("'", "''") + "'";
            var script = """
                $ErrorActionPreference = 'Stop'
                $ProgressPreference = 'SilentlyContinue'
                $serviceExitCode = 0
                $LASTEXITCODE = 0
                try {
                """ + "\nSet-Location -LiteralPath " + Literal(directory) + "\n& {\n" + service.StartCommand + "\n} *> " + Literal(log) + "\n" + """
                    if ($LASTEXITCODE -ne 0) { $serviceExitCode = $LASTEXITCODE }
                } catch {
                    $serviceExitCode = 1
                """ + "\n$_ | Out-String | Add-Content -LiteralPath " + Literal(log) + "\n" + """
                } finally {
                """ + "\n[IO.File]::WriteAllText(" + Literal(completion) + ", [string]$serviceExitCode)\n}\n";
            var shell = Path.Combine(Environment.SystemDirectory, "WindowsPowerShell", "v1.0", "powershell.exe");
            using var process = DetachedAgentProcess.Start(shell,
                ["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-WindowStyle", "Hidden",
                 "-EncodedCommand", Convert.ToBase64String(Encoding.Unicode.GetBytes(script))]);
            receipt = receipt with { State = "submitted", ProcessId = process.Id, ProcessStartedAt = process.StartTime.ToUniversalTime().Ticks };
            SaveReceipt(receipt);
            return new(name, requestId, "starting", "已提交启动命令，等待登记端口监听。请刷新查看实际状态。");
        }
        catch (Win32Exception)
        {
            SaveReceipt(receipt with { State = "failed" });
            throw new AgentActionException("start_failed", "无法创建服务启动进程，请在设备上检查启动环境。");
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or InvalidOperationException or ArgumentException)
        {
            // Leave the dispatching receipt in place: launch may have succeeded
            // before the receipt could be updated. Do not invite a blind retry.
            throw new AgentActionException("start_unconfirmed", "启动结果未确认，请先刷新端口状态并在设备上检查启动记录，勿重复启动。");
        }
    }

    private async Task<FileStream> LockRegistryAsync(CancellationToken token)
    {
        var watch = Stopwatch.StartNew();
        while (true)
        {
            token.ThrowIfCancellationRequested();
            try { return new FileStream(registryPath + ".lock", FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None); }
            catch (DirectoryNotFoundException) { throw new AgentActionException("registry_missing", "设备尚未创建服务登记表。"); }
            catch (UnauthorizedAccessException) { throw new AgentActionException("registry_unavailable", "无法锁定服务登记表，请检查设备上的文件权限。"); }
            catch (IOException)
            {
                if (watch.Elapsed > TimeSpan.FromSeconds(2)) throw new AgentActionException("registry_busy", "登记表正在更新或服务正在启动，请稍后刷新。");
                await Task.Delay(100, token);
            }
        }
    }

    private void SaveReceipt(StartReceipt receipt)
    {
        var bytes = JsonSerializer.SerializeToUtf8Bytes(receipt, AgentConnection.Json);
        CommandHost.Save(ReceiptPath(receipt.RequestId), bytes);
        CommandHost.Save(LatestPath(receipt.Name), bytes);
    }

    private static StartReceipt? ReadReceipt(string path)
    {
        try { return JsonSerializer.Deserialize<StartReceipt>(CommandHost.ReadShared(path), AgentConnection.Json)
            ?? throw new JsonException(); }
        catch (FileNotFoundException) { return null; }
        catch (DirectoryNotFoundException) { return null; }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or JsonException)
        { throw new AgentActionException("startup_record_unavailable", "无法读取服务启动记录，请在设备上检查后重试。"); }
    }

    private ServiceStartupStatus? ReadStartup(string name)
    {
        try { return ReadReceipt(LatestPath(name)) is { } receipt ? StartupStatus(receipt) : null; }
        catch (AgentActionException) { return new("unknown", "无法读取上次启动记录，请在设备上检查。", ""); }
    }

    private ServiceStartupStatus StartupStatus(StartReceipt receipt)
    {
        if (receipt.State == "failed") return new("failed", "创建启动进程失败。", receipt.RequestedAt);
        try
        {
            if (File.Exists(CompletionPath(receipt.RequestId)))
            {
                var code = File.ReadAllText(CompletionPath(receipt.RequestId)).Trim();
                return int.TryParse(code, out var exitCode)
                    ? new(exitCode == 0 ? "exited" : "failed", exitCode == 0 ? "启动命令已结束，请以端口和 HTTP 检查结果为准。" : $"启动命令失败（退出码 {exitCode}），请在设备上检查启动日志。", receipt.RequestedAt)
                    : new("unknown", "启动结果未确认，请在设备上检查。", receipt.RequestedAt);
            }
            if (receipt.ProcessId is { } pid && pid > 0 && receipt.ProcessStartedAt is { } ticks && ticks > 0)
            {
                Process process;
                try { process = Process.GetProcessById(pid); }
                catch (ArgumentException) { return ExitedWithoutReceipt(); }
                using (process)
                {
                    if (process.HasExited || process.StartTime.ToUniversalTime().Ticks != ticks)
                        return ExitedWithoutReceipt();
                    return new("starting", "启动命令正在运行，请以端口和 HTTP 检查结果为准。", receipt.RequestedAt);
                }
            }
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or ArgumentException or InvalidOperationException or Win32Exception) { }
        return new("unknown", "启动结果未确认，请在设备上检查，勿重复启动。", receipt.RequestedAt);

        ServiceStartupStatus ExitedWithoutReceipt() => new("exited",
            "上次启动进程已退出，未留下退出回执；端口未监听时可重新启动。", receipt.RequestedAt);
    }
}
