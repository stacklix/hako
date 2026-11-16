using System;
using System.Diagnostics;
using System.IO;
using System.Threading;
using System.Threading.Tasks;
using Hako.Platform;

namespace Hako.Core;

internal static partial class AgentGuardianControl
{
    private sealed record StatusIdentity(int ProcessId);

    // Standalone installations use their own image so replacing Hako.exe never
    // locks or terminates the guardian. Development apphosts share their build output.
    internal static string ExecutableFor(AgentGuardianOptions options) =>
        File.Exists(Path.Combine(Path.GetDirectoryName(options.TargetPath)!, "Hako.dll"))
            ? options.TargetPath : Path.Combine(Path.GetDirectoryName(options.TargetPath)!, "guardian", "Hako.Guardian.exe");

    internal static int? Running(string profile, string executable)
    {
        var state = Read<StatusIdentity>(FileFor(profile, "status.json"));
        if (state is null) return null;
        try
        {
            using var process = Process.GetProcessById(state.ProcessId);
            return !process.HasExited && string.Equals(process.MainModule?.FileName, executable, StringComparison.OrdinalIgnoreCase)
                ? process.Id : null;
        }
        catch (ArgumentException) { return null; }
    }

    internal static async Task<int> EnsureRunningAsync(string profile, CancellationToken token)
    {
        Directory.CreateDirectory(DirectoryFor(profile));
        // Use the installer's lock: opening commands cannot race guardian replacement.
        using var startupDeadline = CancellationTokenSource.CreateLinkedTokenSource(token);
        startupDeadline.CancelAfter(TimeSpan.FromSeconds(12));
        using var ownership = await AgentGuardianRefresh.LockAsync(FileFor(profile, "install.lock"), startupDeadline.Token);
        var configuration = FileFor(profile, "config.json");
        var options = Read<AgentGuardianOptions>(configuration);
        if (options is null)
        {
            var target = Environment.ProcessPath ?? throw new IOException("找不到 Agent 程序。");
            if (Path.GetFileNameWithoutExtension(target).Equals("dotnet", StringComparison.OrdinalIgnoreCase))
                target = Path.Combine(AppContext.BaseDirectory, "Hako.exe");
            options = new AgentGuardianOptions(target, profile, "stacklix/hako");
        }
        options.Validate();
        if (!string.Equals(Path.GetFullPath(options.ProfileDirectory), Path.GetFullPath(profile), StringComparison.OrdinalIgnoreCase))
            throw new IOException("守护进程配置不属于当前 Agent。");
        var executable = ExecutableFor(options);
        if (!File.Exists(configuration)) Write(configuration, options);
        if (File.Exists(executable) && !string.Equals(executable, options.TargetPath, StringComparison.OrdinalIgnoreCase)
            && AgentGuardian.Hash(executable) != AgentGuardian.Hash(options.TargetPath))
        {
            var hash = AgentGuardian.Hash(options.TargetPath);
            var updaterId = await AgentGuardianRefresh.StartAsync(options, hash, token);
            ownership.Dispose();
            using var updater = Process.GetProcessById(updaterId);
            while (true)
            {
                token.ThrowIfCancellationRequested();
                var refresh = Read<AgentGuardianRefresh.State>(AgentGuardianRefresh.StatePath(profile));
                if (refresh?.ProcessId == updaterId && refresh.StateName == "failed") throw new IOException("守护进程更新失败，请检查 guardian/refresh.json。");
                if (refresh?.ProcessId == updaterId && refresh.StateName == "complete" && Running(profile, executable) is int updated) return updated;
                if (updater.HasExited) throw new IOException("守护进程更新未完成，请检查 guardian/refresh.json 后重新连接。");
                await Task.Delay(200, token);
            }
        }
        if (Running(profile, executable) is int current)
        {
            if (File.Exists(FileFor(profile, "stop"))) throw new WorkshopException("command_host_stopping", "守护进程正在等待任务结束，请稍后重新打开快捷命令。");
            return current;
        }
        if (!File.Exists(executable))
        {
            Directory.CreateDirectory(Path.GetDirectoryName(executable)!);
            var temporary = executable + "." + Guid.NewGuid().ToString("N") + ".tmp";
            try
            {
                var hash = AgentGuardian.Hash(options.TargetPath);
                File.Copy(options.TargetPath, temporary);
                if (AgentGuardian.Hash(temporary) != hash) throw new IOException("守护进程副本校验失败。");
                File.Move(temporary, executable);
            }
            finally { if (File.Exists(temporary)) File.Delete(temporary); }
        }
        File.Delete(FileFor(profile, "stop"));
        using var launched = DetachedAgentProcess.Start(executable, ["--guardian", "--config", configuration]);
        var deadline = DateTime.UtcNow.AddSeconds(12);
        do
        {
            token.ThrowIfCancellationRequested();
            if (Running(profile, executable) == launched.Id) return launched.Id;
            if (launched.HasExited) throw new IOException("守护进程启动失败。");
            await Task.Delay(100, token);
        } while (DateTime.UtcNow < deadline);
        throw new TimeoutException("守护进程启动结果尚未确认，请稍后查询状态。");
    }
}
