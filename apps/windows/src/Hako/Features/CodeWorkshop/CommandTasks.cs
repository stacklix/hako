using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace Hako.Platform;

internal sealed record CommandTaskRequest(string Id, string ApplicationId, string Name, string Command, int TimeoutSeconds, bool AllowBackgroundProcesses);
internal sealed record CommandTaskState(string Id, string ApplicationId, string Name, string Command, string Directory,
    string State, long StartedAt, bool AllowBackgroundProcesses, long? FinishedAt = null, int? ExitCode = null, string? Error = null, bool CanStop = true)
{
    internal bool Active => State is "starting" or "running" or "stopping";
}

internal sealed class CommandTasks : IAsyncDisposable
{
    private sealed record Running(CancellationTokenSource Cancellation, Task Worker);
    private readonly object gate = new();
    private readonly Dictionary<string, Running> running = new();
    private readonly string root;
    private readonly string profile;
    private readonly string scope;
    private readonly CodeWorkshop projects;
    private DateTime lastRequest = DateTime.UtcNow;
    private bool retiring;
    internal bool HasRunning { get { lock (gate) return running.Values.Any(value => !value.Worker.IsCompleted); } }
    internal DateTime LastRequest { get { lock (gate) return lastRequest; } }
    internal bool RetireIfIdle()
    {
        lock (gate)
        {
            if (HasRunning || DateTime.UtcNow - lastRequest < TimeSpan.FromMinutes(5)) return false;
            retiring = true; return true;
        }
    }

    internal CommandTasks(string profile, CodeWorkshop projects)
    {
        this.profile = profile; this.projects = projects;
        scope = CommandHost.Scope(new Hako.Core.AgentSettingsStore(profile));
        root = Path.Combine(profile, "command-tasks", scope);
        Directory.CreateDirectory(root);
        foreach (var directory in System.IO.Directory.EnumerateDirectories(root))
        {
            if (!Guid.TryParseExact(Path.GetFileName(directory), "D", out _)) continue;
            var state = Read(directory);
            if (state.Active) Write(directory, state with { State = "interrupted", FinishedAt = Now(), Error = "命令执行器已中断，请查看日志后决定是否重新执行。" });
        }
    }
    private static long Now() => DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
    private static CommandTaskState Read(string directory)
    {
        try { return JsonSerializer.Deserialize<CommandTaskState>(CommandHost.ReadShared(Path.Combine(directory, "state.json")), WorkshopProtocol.Json) ?? throw new IOException("任务记录无法读取。"); }
        catch (IOException error) when (error is FileNotFoundException or DirectoryNotFoundException)
        { throw new WorkshopException("command_not_found", "执行器尚未找到该任务，请核对启动结果。"); }
    }
    private static void Write(string directory, CommandTaskState state) => CommandHost.Save(Path.Combine(directory, "state.json"), JsonSerializer.SerializeToUtf8Bytes(state, WorkshopProtocol.Json));
    private string DirectoryFor(string id)
    {
        if (!Guid.TryParseExact(id, "D", out _)) throw CodexJson.Invalid();
        return Path.Combine(root, id.ToLowerInvariant());
    }
    internal Task<object?> CallAsync(string method, JsonElement parameters, CancellationToken token)
    {
        token.ThrowIfCancellationRequested();
        lock (gate)
        {
            if (retiring) throw new WorkshopException("command_host_stopping", "空闲执行器正在退出，请重新连接后重试原请求。");
            if (scope != CommandHost.Scope(new Hako.Core.AgentSettingsStore(profile))) throw new WorkshopException("command_context_changed", "电脑账号配置已改变，请重新打开快捷命令。");
            lastRequest = DateTime.UtcNow;
            object result = method switch
            {
                "commands.start" => Start(parameters),
                "commands.read" => Page(parameters),
                "commands.stop" => Stop(parameters),
                "commands.list" => List(parameters),
                _ => throw new WorkshopException("unsupported_method", "执行器不支持此操作。")
            };
            return Task.FromResult<object?>(result);
        }
    }
    private object Start(JsonElement parameters)
    {
        CodexJson.Keys(parameters, "requestId", "applicationId", "name", "command", "timeoutSeconds", "allowBackgroundProcesses");
        var id = CodexJson.Required(parameters, "requestId", 36).ToLowerInvariant();
        var directory = DirectoryFor(id);
        var application = CodexJson.Required(parameters, "applicationId", 16);
        var name = CodexJson.Required(parameters, "name", 120).Trim();
        var command = CodexJson.Required(parameters, "command", 8000);
        if (!parameters.TryGetProperty("timeoutSeconds", out var timeoutValue) || !timeoutValue.TryGetInt32(out var timeout) || timeout is < 1 or > 86400
            || string.IsNullOrWhiteSpace(command) || name.Length == 0 || command.Contains('\0') || Encoding.UTF8.GetByteCount(command) > 8000) throw CodexJson.Invalid();
        var background = CodexJson.Field(parameters, "allowBackgroundProcesses");
        if (background.ValueKind is not (JsonValueKind.True or JsonValueKind.False)) throw CodexJson.Invalid();
        var allowBackgroundProcesses = background.GetBoolean();
        var request = new CommandTaskRequest(id, application, name, command, timeout, allowBackgroundProcesses);
        if (System.IO.Directory.Exists(directory))
        {
            var original = JsonSerializer.Deserialize<CommandTaskRequest>(File.ReadAllBytes(Path.Combine(directory, "request.json")), WorkshopProtocol.Json);
            if (original != request) throw new WorkshopException("command_request_conflict", "请求 ID 已用于另一条命令。");
            return Read(directory);
        }
        if (HasRunning) throw new WorkshopException("command_busy", "电脑已有命令任务正在执行，请先查看该任务。");
        var workingDirectory = projects.ResolveApplication(application);
        var shell = FindPowerShell();
        var state = new CommandTaskState(id, application, name, command, workingDirectory, "starting", Now(), allowBackgroundProcesses);
        if (JsonSerializer.SerializeToUtf8Bytes(state, WorkshopProtocol.Json).Length > 48 * 1024)
            throw new WorkshopException("command_result_large", "命令与目录的编码结果过长，请缩短后重试。");
        var staging = Path.Combine(root, ".starting-" + Guid.NewGuid().ToString("N"));
        System.IO.Directory.CreateDirectory(staging);
        CommandHost.Save(Path.Combine(staging, "request.json"), JsonSerializer.SerializeToUtf8Bytes(request, WorkshopProtocol.Json));
        Write(staging, state);
        File.WriteAllText(Path.Combine(staging, "output.log"), "", new UTF8Encoding(false));
        System.IO.Directory.Move(staging, directory);
        var cancellation = new CancellationTokenSource();
        var worker = Task.Run(() => ExecuteAsync(directory, state, shell, timeout, cancellation.Token));
        running.Add(id, new Running(cancellation, worker));
        return state;
    }
    private object List(JsonElement parameters)
    {
        CodexJson.Keys(parameters, "applicationId");
        var application = CodexJson.Required(parameters, "applicationId", 16);
        return new { tasks = System.IO.Directory.EnumerateDirectories(root)
            .Where(path => Guid.TryParseExact(Path.GetFileName(path), "D", out _)).Select(Read)
            .Where(state => state.ApplicationId == application).OrderByDescending(state => state.StartedAt).Take(30)
            .Select(state => new { state.Id, state.ApplicationId, state.Name, state.State, state.StartedAt }).ToArray() };
    }
    private object Page(JsonElement parameters)
    {
        CodexJson.Keys(parameters, "taskId", "cursor");
        var directory = DirectoryFor(CodexJson.Required(parameters, "taskId", 36));
        var cursorValue = CodexJson.Field(parameters, "cursor");
        if (!cursorValue.TryGetInt64(out var cursor) || cursor < 0) throw CodexJson.Invalid();
        var state = Read(directory) with { CanStop = !File.Exists(Path.Combine(directory, "installing")) };
        using var file = new FileStream(Path.Combine(directory, "output.log"), FileMode.Open, FileAccess.Read, FileShare.ReadWrite);
        if (cursor > file.Length) throw CodexJson.Invalid();
        file.Position = cursor;
        // JSON escapes can expand one log byte to six bytes. Reserve the full
        // task snapshot and envelope before selecting a page for 64 KiB frames.
        var budget = Math.Max(1, (63 * 1024 - JsonSerializer.SerializeToUtf8Bytes(state, WorkshopProtocol.Json).Length - 512) / 6);
        var bytes = new byte[(int)Math.Min(Math.Min(12 * 1024, budget), file.Length - cursor)];
        var count = file.Read(bytes);
        // Keep a UTF-8 sequence together between cursor pages.
        if (count == bytes.Length && cursor + count < file.Length)
        {
            var end = count;
            while (end > 0 && (bytes[end - 1] & 0xc0) == 0x80) end--;
            if (end > 0 && bytes[end - 1] >= 0xc0) count = end - 1;
        }
        return new { task = state, cursor = cursor + count, output = Encoding.UTF8.GetString(bytes, 0, count), hasMore = cursor + count < file.Length };
    }
    private object Stop(JsonElement parameters)
    {
        CodexJson.Keys(parameters, "taskId");
        var id = CodexJson.Required(parameters, "taskId", 36).ToLowerInvariant();
        var directory = DirectoryFor(id);
        var state = Read(directory);
        if (state.Active && running.TryGetValue(id, out var entry) && !entry.Worker.IsCompleted)
        {
            using var phase = PhaseLock(directory);
            if (File.Exists(Path.Combine(directory, "installing"))) throw new WorkshopException("command_installing", "正在替换 Agent，安装事务结束前暂不可停止。");
            File.WriteAllText(Path.Combine(directory, "cancelled"), "");
            entry.Cancellation.Cancel();
            state = state with { State = "stopping" }; Write(directory, state);
        }
        return state;
    }
    private static FileStream PhaseLock(string directory)
    {
        var deadline = DateTime.UtcNow.AddSeconds(5);
        while (true)
        {
            try { return new(Path.Combine(directory, "phase.lock"), FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None); }
            catch (IOException) when (DateTime.UtcNow < deadline) { Thread.Sleep(20); }
        }
    }
    private static string FindPowerShell()
    {
        foreach (var directory in (Environment.GetEnvironmentVariable("PATH") ?? "").Split(Path.PathSeparator))
        {
            if (string.IsNullOrWhiteSpace(directory)) continue;
            var candidate = Path.Combine(directory.Trim('"'), "pwsh.exe");
            if (File.Exists(candidate)) return candidate;
        }
        var installed = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "PowerShell", "7", "pwsh.exe");
        if (File.Exists(installed)) return installed;
        throw new WorkshopException("command_shell_missing", "电脑尚未安装 PowerShell 7。");
    }
    private async Task ExecuteAsync(string directory, CommandTaskState state, string shell, int seconds, CancellationToken cancellation)
    {
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(seconds));
        using var lifetime = CancellationTokenSource.CreateLinkedTokenSource(cancellation, timeout.Token);
        try
        {
            using var startGate = new EventWaitHandle(false, EventResetMode.ManualReset, "Local\\Hako.Command." + state.Id);
            using var job = new CommandProcessJob(state.AllowBackgroundProcesses);
            using var process = new Process();
            var commandFile = Path.Combine(directory, "command.ps1");
            File.WriteAllText(commandFile,
                "$gate=[Threading.EventWaitHandle]::OpenExisting('Local\\Hako.Command." + state.Id + "')\n" +
                "if (!$gate.WaitOne(30000)) { exit 124 }; $gate.Dispose()\n" +
                "$ErrorActionPreference='Stop'\n$OutputEncoding=[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)\n$global:LASTEXITCODE=0\n" + state.Command + "\nif (!$?) { exit 1 }; exit $global:LASTEXITCODE\n", new UTF8Encoding(false));
            var start = new ProcessStartInfo(shell) { UseShellExecute = false, CreateNoWindow = true, WindowStyle = ProcessWindowStyle.Hidden,
                RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true, WorkingDirectory = state.Directory,
                StandardOutputEncoding = Encoding.UTF8, StandardErrorEncoding = Encoding.UTF8 };
            foreach (var argument in new[] { "-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", commandFile }) start.ArgumentList.Add(argument);
            start.Environment["HAKO_COMMAND_EXECUTABLE"] = Environment.ProcessPath!;
            start.Environment["HAKO_COMMAND_TASK_DIRECTORY"] = directory;
            process.StartInfo = start;
            lifetime.Token.ThrowIfCancellationRequested();
            process.Start(); process.StandardInput.Close(); job.Assign(process);
            Write(directory, state with { State = "running" }); startGate.Set();
            using var output = new FileStream(Path.Combine(directory, "output.log"), FileMode.Append, FileAccess.Write, FileShare.Read);
            using var writing = new SemaphoreSlim(1, 1);
            using var draining = new CancellationTokenSource();
            var stdout = CopyOutput(process.StandardOutput, output, writing, draining.Token);
            var stderr = CopyOutput(process.StandardError, output, writing, draining.Token);
            try { await process.WaitForExitAsync(lifetime.Token); }
            catch (OperationCanceledException)
            {
                bool installing;
                using (PhaseLock(directory))
                {
                    installing = File.Exists(Path.Combine(directory, "installing"));
                    if (!installing) { File.WriteAllText(Path.Combine(directory, "cancelled"), ""); job.Stop(); }
                }
                if (installing)
                {
                    using var installation = new CancellationTokenSource(TimeSpan.FromMinutes(3));
                    try { await process.WaitForExitAsync(installation.Token); }
                    catch (OperationCanceledException) { job.Stop(); }
                }
                await process.WaitForExitAsync();
            }
            // Closing the job now cleans ordinary descendants before waiting
            // for EOF. Opted-in descendants can retain inherited pipe handles,
            // so their lifetime must not keep the submitting command active.
            job.Dispose();
            draining.CancelAfter(TimeSpan.FromSeconds(2));
            await Task.WhenAll(stdout, stderr);
            Write(directory, state with { State = cancellation.IsCancellationRequested ? "cancelled" : timeout.IsCancellationRequested ? "timed_out" : process.ExitCode == 0 ? "succeeded" : "failed",
                ExitCode = process.ExitCode, FinishedAt = Now() });
        }
        catch (Exception error)
        {
            Write(directory, state with { State = cancellation.IsCancellationRequested ? "cancelled" : timeout.IsCancellationRequested ? "timed_out" : "failed", FinishedAt = Now(), Error = error.Message[..Math.Min(1000, error.Message.Length)] });
        }
    }
    private static async Task CopyOutput(StreamReader reader, Stream output, SemaphoreSlim writing, CancellationToken token)
    {
        var buffer = new char[2048];
        var encoder = Encoding.UTF8.GetEncoder();
        var encoded = new byte[Encoding.UTF8.GetMaxByteCount(buffer.Length)];
        int count;
        try
        {
            while ((count = await reader.ReadAsync(buffer.AsMemory(), token)) > 0)
            {
                var byteCount = encoder.GetBytes(buffer, 0, count, encoded, 0, false);
                await writing.WaitAsync(token);
                try
                {
                    const int limit = 20 * 1024 * 1024;
                    if (output.Length < limit)
                    {
                        await output.WriteAsync(encoded.AsMemory(0, byteCount));
                        if (output.Length >= limit) await output.WriteAsync(Encoding.UTF8.GetBytes("\n[日志已达到 20 MB 上限，后续输出省略]\n"));
                        await output.FlushAsync();
                    }
                }
                finally { writing.Release(); }
            }
        }
        catch (OperationCanceledException) when (token.IsCancellationRequested) { }
    }
    public async ValueTask DisposeAsync()
    {
        Running[] tasks; lock (gate) tasks = running.Values.ToArray();
        foreach (var task in tasks) task.Cancellation.Cancel();
        await Task.WhenAll(tasks.Select(task => task.Worker));
        foreach (var task in tasks) task.Cancellation.Dispose();
    }
}
