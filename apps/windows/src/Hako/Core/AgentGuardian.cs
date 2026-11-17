using System;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Security.Cryptography;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Hako.Platform;

namespace Hako.Core;

internal sealed class AgentGuardian(AgentGuardianOptions options, IAgentUpdateSource source, Func<string, string[], Process>? launch = null)
{
    internal sealed record Session(string Id, int ProcessId, DateTimeOffset StartedAt, DateTimeOffset LastHeartbeatAt,
        DateTimeOffset? EndedAt, string? ExitReason, int? ExitCode);
    private sealed record Journal(string Backup, string OldHash, AgentUpdateCandidate Candidate, bool Restart, DateTimeOffset StartedAt);
    private sealed record Saved(long InstalledBuild = 0, string? RejectedHash = null, int Failures = 0);
    private Saved saved = new();
    private DateTimeOffset nextUpdate, missingSince, retryAt, healthySince;
    private string updateState = "idle";
    private string? lastMessage;
    private int lastRunningProcess;
    private Task? updateWork;
    private DateTime pendingRevision;
    private string Root => AgentGuardianControl.DirectoryFor(options.ProfileDirectory);
    private string PathFor(string name) => System.IO.Path.Combine(Root, name);
    private string UpdateLock => System.IO.Path.Combine(System.IO.Path.GetDirectoryName(options.TargetPath)!, "update.lock");
    internal static string Hash(string path)
    {
        using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read);
        return Convert.ToHexString(SHA256.HashData(stream)).ToLowerInvariant();
    }
    internal static async Task RunAsync(string configuration, CancellationToken token = default, GuardianBroker? prepared = null)
    {
        var options = AgentGuardianControl.Read<AgentGuardianOptions>(configuration) ?? throw new InvalidDataException("Guardian configuration missing.");
        options.Validate();
        Directory.CreateDirectory(AgentGuardianControl.DirectoryFor(options.ProfileDirectory));
        FileStream owner;
        try
        {
            var path = AgentGuardianControl.FileFor(options.ProfileDirectory, "owner.lock");
            owner = prepared is null ? new FileStream(path, FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None)
                : await AgentGuardianRefresh.LockAsync(path, token);
        }
        catch (IOException) { if (prepared is not null) await prepared.DisposeAsync(); return; }
        using (owner)
        using (var lifetime = CancellationTokenSource.CreateLinkedTokenSource(token))
        using (var commandsStopping = CancellationTokenSource.CreateLinkedTokenSource(token))
        using (var source = new GitHubAgentUpdates(options.Repository, AgentGuardianControl.FileFor(options.ProfileDirectory, "downloads")))
        {
            var guardian = new AgentGuardian(options, source);
            await using var broker = prepared ?? new GuardianBroker(options.ProfileDirectory, start: false);
            broker.Start();
            guardian.saved = AgentGuardianControl.Read<Saved>(guardian.PathFor("state.json")) ?? new Saved();
            guardian.Status("starting", "守护进程已启动。");
            var commandsWork = Task.Run(() => CommandHost.RunRequestedAsync(options.ProfileDirectory, commandsStopping.Token));
            try
            {
                while (!token.IsCancellationRequested && !File.Exists(guardian.PathFor("stop")))
                {
                    try { await guardian.TickAsync(lifetime.Token, waitForUpdate: false); }
                    catch (OperationCanceledException) when (token.IsCancellationRequested) { break; }
                    catch (Exception error) when (error is IOException or InvalidDataException or UnauthorizedAccessException or JsonException or System.Net.Http.HttpRequestException or InvalidOperationException or Win32Exception or ArgumentException or TimeoutException or FormatException or System.Collections.Generic.KeyNotFoundException)
                    { guardian.Status("retrying", "守护检查失败，将自动重试（" + error.GetType().Name + "）。"); }
                    try { await Task.Delay(TimeSpan.FromSeconds(options.PollSeconds), token); }
                    catch (OperationCanceledException) { break; }
                }
            }
            finally
            {
                await commandsStopping.CancelAsync();
                guardian.Status("draining", "守护进程正在退出，等待现有命令完成；仍可查看或取消任务。");
                await commandsWork;
                if (!File.Exists(guardian.PathFor("transaction.json"))) await lifetime.CancelAsync();
                if (guardian.updateWork is not null) await guardian.updateWork;
                guardian.Status("stopped", "守护进程已停止。");
            }
        }
    }
    internal async Task TickAsync(CancellationToken token, bool waitForUpdate = true)
    {
        if (!CanAcquireUpdateLock()) { Status("maintenance", "正在更新，暂停拉起主 Agent。"); return; }
        if (File.Exists(PathFor("transaction.json"))) { await RecoverAsync(token); return; }
        var hasPending = File.Exists(PathFor("pending-update.json"));
        if (hasPending && File.GetLastWriteTimeUtc(PathFor("pending-update.json")) != pendingRevision)
        { pendingRevision = File.GetLastWriteTimeUtc(PathFor("pending-update.json")); nextUpdate = default; }
        if (DateTimeOffset.UtcNow >= nextUpdate && (updateWork is null || updateWork.IsCompleted))
        {
            nextUpdate = DateTimeOffset.UtcNow.AddSeconds(hasPending ? Math.Min(30, options.UpdatePollSeconds) : options.UpdatePollSeconds);
            updateWork = CheckUpdatesAsync(token);
        }
        if (waitForUpdate && updateWork is not null) await updateWork;
        // A direct Codex installer uses the same lock as this guardian.
        if (!CanAcquireUpdateLock()) { Status("maintenance", "安装程序正在替换 Agent。"); return; }
        var session = ReadSession();
        using var current = FindProcess(session);
        if (current is not null)
        {
            missingSince = default; retryAt = default;
            if (healthySince == default || lastRunningProcess != current.Id) healthySince = current.StartTime.ToUniversalTime();
            lastRunningProcess = current.Id;
            if (DateTimeOffset.UtcNow - healthySince > TimeSpan.FromMinutes(2) && saved.Failures != 0) Save(saved with { Failures = 0 });
            Status(session?.EndedAt is null ? "running" : "unresponsive",
                session?.EndedAt is null ? "主 Agent 正在运行。" : "主 Agent 已关闭接口但进程尚未结束，等待更新或人工处理。");
            return;
        }
        if (Paused(session))
        {
            missingSince = default; healthySince = default;
            Status(updateState == "waiting_server" ? "waiting_update" : "paused", updateState == "waiting_server"
                ? "主 Agent 当前未运行；暂缓更新正在等待服务端兼容。" : "主 Agent 已手动退出；重新打开 Agent 后恢复守护。");
            return;
        }
        if (missingSince == default)
        {
            missingSince = DateTimeOffset.UtcNow;
            if (healthySince != default && DateTimeOffset.UtcNow - healthySince < TimeSpan.FromMinutes(2))
            {
                Save(saved with { Failures = saved.Failures + 1 });
                retryAt = DateTimeOffset.UtcNow.AddSeconds(Math.Min(300, 5 * Math.Pow(2, Math.Min(saved.Failures, 6))));
            }
        }
        healthySince = default;
        if (DateTimeOffset.UtcNow - missingSince < TimeSpan.FromSeconds(options.RestartDelaySeconds) || DateTimeOffset.UtcNow < retryAt)
        { Status("restart_pending", "主 Agent 未运行，等待异常退出宽限期或重试间隔。"); return; }
        using var ownership = AcquireUpdateLock();
        if (ownership is null) return;
        // Re-read intent after acquiring the lock, so a manual stop always wins.
        session = ReadSession();
        using var rechecked = FindProcess(session);
        if (rechecked is not null || Paused(session)) return;
        try { await LaunchAsync(token); AgentGuardianControl.EndMaintenance(options.ProfileDirectory); Status("running", "主 Agent 异常退出后已自动拉起。"); }
        catch (Exception error) when (error is IOException or InvalidOperationException or Win32Exception or JsonException or TimeoutException)
        {
            Save(saved with { Failures = saved.Failures + 1 });
            retryAt = DateTimeOffset.UtcNow.AddSeconds(Math.Min(300, 5 * Math.Pow(2, Math.Min(saved.Failures, 6))));
            Status("restart_failed", "拉起未成功，将退避重试（" + error.GetType().Name + "）。");
        }
    }
    private async Task CheckUpdatesAsync(CancellationToken token)
    {
        try
        {
            var candidate = Pending() ?? await source.LatestAsync(token);
            if (candidate is not null) await TryUpdateAsync(candidate, token);
            else updateState = "no_release";
        }
        catch (Exception error) when (error is IOException or InvalidDataException or JsonException or System.Net.Http.HttpRequestException or OperationCanceledException or
            UnauthorizedAccessException or InvalidOperationException or Win32Exception or TimeoutException or ArgumentException or FormatException or System.Collections.Generic.KeyNotFoundException)
        { updateState = "source_unavailable"; lastMessage = "更新检查未完成，将稍后重试（" + error.GetType().Name + "）。"; }
    }
    private AgentUpdateCandidate? Pending()
    {
        var pending = AgentGuardianControl.Read<AgentPendingUpdate>(PathFor("pending-update.json"));
        if (pending is null) return null;
        var root = System.IO.Path.Combine(System.IO.Path.GetDirectoryName(options.TargetPath)!, "updates") + System.IO.Path.DirectorySeparatorChar;
        if (!System.IO.Path.GetFullPath(pending.Path).StartsWith(root, StringComparison.OrdinalIgnoreCase) || !File.Exists(pending.Path) || Hash(pending.Path) != pending.Sha256)
            throw new InvalidDataException("Pending update is not a verified staged artifact.");
        return new AgentUpdateCandidate(pending.Path, pending.Sha256, 0, pending.Version);
    }
    private async Task TryUpdateAsync(AgentUpdateCandidate candidate, CancellationToken token)
    {
        if (Hash(candidate.Path) != candidate.Sha256) throw new InvalidDataException("Candidate hash mismatch.");
        if (ReleaseVersion(FileVersionInfo.GetVersionInfo(candidate.Path).ProductVersion) != ReleaseVersion(candidate.Version))
            throw new InvalidDataException("Candidate version does not match its manifest.");
        if (File.Exists(options.TargetPath) && Hash(options.TargetPath) == candidate.Sha256)
        {
            using var cleanupLease = AcquireUpdateLock();
            if (cleanupLease is not null) ClearPending(candidate.Sha256);
            updateState = "current"; return;
        }
        if (saved.RejectedHash == candidate.Sha256) { updateState = "rejected"; return; }
        if (candidate.BuildId != 0 && candidate.BuildId <= saved.InstalledBuild) { updateState = "current"; return; }
        var installedVersion = File.Exists(options.TargetPath) ? ReleaseVersion(FileVersionInfo.GetVersionInfo(options.TargetPath).ProductVersion) : null;
        var candidateVersion = ReleaseVersion(candidate.Version);
        var stamp = AgentGuardianControl.Read<AgentInstallStamp>(PathFor("installed.json"));
        if (candidateVersion == installedVersion && candidate.PublishedAt is not null && stamp is not null && candidate.PublishedAt <= stamp.InstalledAt &&
            File.Exists(options.TargetPath) && Hash(options.TargetPath) == stamp.Sha256)
        { updateState = "older_release"; return; }
        if (candidateVersion is null || installedVersion is not null && candidateVersion < installedVersion)
        { updateState = "older_release"; return; }
        // The candidate itself supplies the compatibility contract, before any stop or replacement.
        var preflight = await Cli(candidate.Path, ["--check-server-version"], token);
        if (!preflight.Ok) { updateState = "waiting_server"; lastMessage = "候选更新尚未通过服务端版本检查，保留当前 Agent。"; return; }
        using var ownership = AcquireUpdateLock();
        if (ownership is null) { updateState = "maintenance"; return; }
        if (candidate.BuildId == 0 && Pending()?.Sha256 != candidate.Sha256) return;
        if (candidate.BuildId != 0 && File.Exists(PathFor("pending-update.json"))) return;
        preflight = await Cli(candidate.Path, ["--check-server-version"], token);
        if (!preflight.Ok) { updateState = "waiting_server"; return; }
        var session = ReadSession();
        using var current = FindProcess(session);
        var pending = candidate.BuildId == 0 ? AgentGuardianControl.Read<AgentPendingUpdate>(PathFor("pending-update.json")) : null;
        var laterManualStop = pending is not null && Paused(session) &&
            (session?.EndedAt > pending.CreatedAt || File.Exists(PathFor("paused.json")) && File.GetLastWriteTimeUtc(PathFor("paused.json")) > pending.CreatedAt.UtcDateTime);
        var restart = current is not null || !Paused(session) || pending?.RestartAfterUpdate == true && !laterManualStop;
        var record = System.IO.Path.Combine(System.IO.Path.GetDirectoryName(options.TargetPath)!, "updates", "guardian-" + DateTime.UtcNow.ToString("yyyyMMdd-HHmmss") + "-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(record);
        var backup = System.IO.Path.Combine(record, "Hako-previous.exe");
        var oldHash = File.Exists(options.TargetPath) ? Hash(options.TargetPath) : "";
        if (oldHash.Length != 0) File.Copy(options.TargetPath, backup);
        var journal = new Journal(backup, oldHash, candidate, restart, DateTimeOffset.UtcNow);
        AgentGuardianControl.Write(PathFor("transaction.json"), journal);
        AgentGuardianControl.BeginMaintenance(options.ProfileDirectory, current?.Id ?? 0);
        try
        {
            if (current is not null) await StopAsync(current, token);
            Replace(candidate.Path, candidate.Sha256);
            if (restart) await LaunchAsync(token);
            Save(saved with { InstalledBuild = Math.Max(saved.InstalledBuild, candidate.BuildId), RejectedHash = null, Failures = 0 });
            AgentGuardianControl.Write(PathFor("installed.json"), new AgentInstallStamp(candidate.Sha256, DateTimeOffset.UtcNow));
            updateState = "updated"; lastMessage = restart ? "Agent 已更新并通过本机接口回查。" : "Agent 文件已更新，保留手动停止状态。";
            ClearPending(candidate.Sha256);
            FinishTransaction();
        }
        catch (Exception)
        {
            await RollbackAsync(journal, CancellationToken.None);
            Save(saved with { RejectedHash = candidate.Sha256 });
            ClearPending(candidate.Sha256);
            updateState = "rolled_back"; lastMessage = "候选更新启动失败，已恢复原文件。";
            FinishTransaction();
        }
    }
    private async Task RecoverAsync(CancellationToken token)
    {
        using var ownership = AcquireUpdateLock();
        if (ownership is null) return;
        var journal = AgentGuardianControl.Read<Journal>(PathFor("transaction.json")) ?? throw new InvalidDataException("Update journal is invalid.");
        // Restore the known previous artifact after an interrupted transaction.
        await RollbackAsync(journal, token);
        Save(saved with { RejectedHash = journal.Candidate.Sha256 });
        ClearPending(journal.Candidate.Sha256);
        FinishTransaction();
        updateState = "recovered";
        Status("recovered", "已恢复上次中断的更新事务。");
    }
    private async Task RollbackAsync(Journal journal, CancellationToken token)
    {
        if (File.Exists(options.TargetPath))
        {
            var currentHash = Hash(options.TargetPath);
            if (currentHash != journal.Candidate.Sha256 && currentHash != journal.OldHash) throw new IOException("Installed file changed outside this update transaction.");
        }
        using var process = FindProcess(ReadSession());
        if (process is not null) await StopAsync(process, token);
        if (journal.OldHash.Length == 0)
        {
            if (File.Exists(options.TargetPath) && Hash(options.TargetPath) == journal.Candidate.Sha256) File.Delete(options.TargetPath);
            return;
        }
        Replace(journal.Backup, journal.OldHash);
        var stoppedAfterTransaction = File.Exists(PathFor("paused.json")) && File.GetLastWriteTimeUtc(PathFor("paused.json")) > journal.StartedAt.UtcDateTime;
        if (journal.Restart && !stoppedAfterTransaction) await LaunchAsync(token);
    }
    private void Replace(string sourcePath, string hash)
    {
        var temporary = options.TargetPath + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            File.Copy(sourcePath, temporary);
            if (Hash(temporary) != hash) throw new InvalidDataException("Replacement hash mismatch.");
            var deadline = DateTime.UtcNow.AddSeconds(10);
            while (true)
            {
                try { File.Move(temporary, options.TargetPath, true); break; }
                catch (Exception error) when (DateTime.UtcNow < deadline && error is IOException or UnauthorizedAccessException)
                { System.Threading.Thread.Sleep(100); }
            }
        }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }
    private async Task StopAsync(Process process, CancellationToken token)
    {
        _ = await Cli(options.TargetPath, ["exit"], token);
        try { await process.WaitForExitAsync(token).WaitAsync(TimeSpan.FromSeconds(15), token); }
        catch (TimeoutException)
        {
            if (!string.Equals(process.MainModule?.FileName, options.TargetPath, StringComparison.OrdinalIgnoreCase)) throw new IOException("Agent identity changed before shutdown.");
            process.Kill(); await process.WaitForExitAsync(token).WaitAsync(TimeSpan.FromSeconds(10), token);
        }
    }
    private async Task LaunchAsync(CancellationToken token)
    {
        var arguments = new[] { "--background", "--data-dir", options.ProfileDirectory };
        using var process = launch is null ? DetachedAgentProcess.Start(options.TargetPath, arguments, breakAway: true) : launch(options.TargetPath, arguments);
        var ready = false;
        try
        {
            var deadline = DateTimeOffset.UtcNow.AddSeconds(25);
            while (DateTimeOffset.UtcNow < deadline && !process.HasExited)
            {
                var status = await Cli(options.TargetPath, ["status"], token);
                if (status.Ok && status.Running && status.ProcessId == process.Id)
                { ready = true; missingSince = default; healthySince = DateTimeOffset.UtcNow; return; }
                await Task.Delay(200, token);
            }
            throw new IOException("Agent did not become ready.");
        }
        finally { if (!ready && !process.HasExited) { process.Kill(); await process.WaitForExitAsync(CancellationToken.None); } }
    }
    private sealed record Reply(bool Ok, bool Running, int ProcessId);
    private async Task<Reply> Cli(string executable, string[] arguments, CancellationToken token)
    {
        var start = new ProcessStartInfo(executable) { UseShellExecute = false, CreateNoWindow = true,
            RedirectStandardOutput = true, RedirectStandardError = true, WindowStyle = ProcessWindowStyle.Hidden };
        foreach (var arg in arguments) start.ArgumentList.Add(arg);
        start.ArgumentList.Add("--data-dir"); start.ArgumentList.Add(options.ProfileDirectory); start.ArgumentList.Add("--json");
        using var process = Process.Start(start) ?? throw new IOException("Cannot start Agent CLI.");
        var output = process.StandardOutput.ReadToEndAsync(token); var errors = process.StandardError.ReadToEndAsync(token);
        try { await process.WaitForExitAsync(token).WaitAsync(TimeSpan.FromSeconds(15), token); }
        catch { if (!process.HasExited) process.Kill(); throw; }
        var text = await output; await errors;
        if (text.Length > 65536) throw new InvalidDataException("Agent reply too large.");
        using var document = JsonDocument.Parse(text);
        var root = document.RootElement;
        var ok = process.ExitCode == 0 && root.GetProperty("ok").GetBoolean();
        var running = false; var id = 0;
        if (root.TryGetProperty("data", out var data) && data.ValueKind == JsonValueKind.Object)
        { if (data.TryGetProperty("running", out var value)) running = value.GetBoolean(); if (data.TryGetProperty("processId", out value) && value.ValueKind == JsonValueKind.Number) id = value.GetInt32(); }
        return new Reply(ok, running, id);
    }
    private Session? ReadSession() => AgentGuardianControl.Read<Session>(System.IO.Path.Combine(options.ProfileDirectory, "logs", "agent-session.json"));
    private Process? FindProcess(Session? session)
    {
        if (session is null) return null;
        Process? process = null;
        try
        {
            process = Process.GetProcessById(session.ProcessId);
            if (!process.HasExited && string.Equals(process.MainModule?.FileName, options.TargetPath, StringComparison.OrdinalIgnoreCase) &&
                Math.Abs((process.StartTime.ToUniversalTime() - session.StartedAt.UtcDateTime).TotalSeconds) < 15) return process;
        }
        catch (Exception error) when (error is ArgumentException or InvalidOperationException or Win32Exception) { }
        process?.Dispose(); return null;
    }
    private bool Paused(Session? session) => File.Exists(PathFor("paused.json")) ||
        session is { EndedAt: not null, ExitCode: 0, ExitReason: "cli_exit" or "tray_exit" } && !File.Exists(PathFor("maintenance.json"));
    private FileStream? AcquireUpdateLock()
    {
        Directory.CreateDirectory(System.IO.Path.GetDirectoryName(options.TargetPath)!);
        try { return new FileStream(UpdateLock, FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None); }
        catch (IOException) { return null; }
    }
    private bool CanAcquireUpdateLock() { using var ownership = AcquireUpdateLock(); return ownership is not null; }
    private void FinishTransaction() { File.Delete(PathFor("transaction.json")); AgentGuardianControl.EndMaintenance(options.ProfileDirectory); }
    private void ClearPending(string hash)
    {
        if (AgentGuardianControl.Read<AgentPendingUpdate>(PathFor("pending-update.json"))?.Sha256 == hash)
            File.Delete(PathFor("pending-update.json"));
    }
    private void Save(Saved value) { saved = value; AgentGuardianControl.Write(PathFor("state.json"), value); }
    private void Status(string state, string message)
    {
        try
        {
            AgentGuardianControl.Write(PathFor("status.json"), new { processId = Environment.ProcessId, state, message, updateState,
                updateMessage = lastMessage, updatedAt = DateTimeOffset.UtcNow, saved.Failures, retryAt, options.TargetPath, options.Repository });
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { Debug.WriteLine(error.GetType().Name); }
    }
    private static Version? ReleaseVersion(string? text) => Version.TryParse(text?.Split('+')[0], out var version) ? version : null;
}
