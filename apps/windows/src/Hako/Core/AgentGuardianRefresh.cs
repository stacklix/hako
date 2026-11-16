using System;
using System.Diagnostics;
using System.IO;
using System.Threading;
using System.Threading.Tasks;
using Hako.Platform;

namespace Hako.Core;

// A short-lived updater replaces the guardian outside its own command job.
// It survives main-process replacement and exits after the new guardian is ready.
internal static class AgentGuardianRefresh
{
    internal sealed record State(int ProcessId, string Sha256, string StateName, string? Error = null);
    internal static string StatePath(string profile) => AgentGuardianControl.FileFor(profile, "refresh.json");
    internal static async Task<int> StartAsync(AgentGuardianOptions options, string hash, CancellationToken token)
    {
        var directory = AgentGuardianControl.FileFor(options.ProfileDirectory, Path.Combine("refresh", hash));
        var executable = Path.Combine(directory, "Hako.GuardianUpdate.exe");
        var previous = AgentGuardianControl.Read<State>(StatePath(options.ProfileDirectory));
        if (previous?.Sha256 == hash && previous.StateName is "waiting_server" or "waiting_update" or "draining" or "starting")
        {
            try
            {
                using var process = Process.GetProcessById(previous.ProcessId);
                if (!process.HasExited && string.Equals(process.MainModule?.FileName, executable, StringComparison.OrdinalIgnoreCase)) return process.Id;
            }
            catch (ArgumentException) { }
        }
        Directory.CreateDirectory(directory);
        if (!File.Exists(executable))
        {
            var temporary = executable + "." + Guid.NewGuid().ToString("N") + ".tmp";
            try
            {
                File.Copy(options.TargetPath, temporary);
                if (AgentGuardian.Hash(temporary) != hash) throw new IOException("Guardian refresh candidate changed.");
                File.Move(temporary, executable);
            }
            finally { if (File.Exists(temporary)) File.Delete(temporary); }
        }
        if (AgentGuardian.Hash(executable) != hash) throw new IOException("Guardian refresh candidate hash mismatch.");
        using var launched = DetachedAgentProcess.Start(executable, ["--refresh-guardian", "--config",
            AgentGuardianControl.FileFor(options.ProfileDirectory, "config.json"), "--sha256", hash]);
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(token);
        deadline.CancelAfter(TimeSpan.FromSeconds(12));
        while (AgentGuardianControl.Read<State>(StatePath(options.ProfileDirectory))?.ProcessId != launched.Id)
        {
            if (launched.HasExited) throw new IOException("Guardian refresh could not start.");
            await Task.Delay(100, deadline.Token);
        }
        return launched.Id;
    }

    internal static async Task<FileStream> LockAsync(string path, CancellationToken token)
    {
        while (true)
        {
            token.ThrowIfCancellationRequested();
            try { return new FileStream(path, FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None); }
            catch (IOException) { await Task.Delay(100, token); }
        }
    }
    internal static async Task RunAsync(string configuration, string hash)
    {
        var options = AgentGuardianControl.Read<AgentGuardianOptions>(configuration) ?? throw new IOException("Missing guardian configuration.");
        options.Validate();
        var source = Environment.ProcessPath ?? throw new IOException("Missing updater image.");
        if (AgentGuardian.Hash(source) != hash) throw new IOException("Updater hash mismatch.");
        var executable = AgentGuardianControl.ExecutableFor(options);
        if (string.Equals(executable, options.TargetPath, StringComparison.OrdinalIgnoreCase)) throw new IOException("Guardian refresh requires a standalone installation.");
        FileStream owner;
        try { owner = new FileStream(AgentGuardianControl.FileFor(options.ProfileDirectory, "refresh.lock"), FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None); }
        catch (IOException) { return; }
        using (owner)
        {
            void Status(string state, string? error = null) => AgentGuardianControl.Write(StatePath(options.ProfileDirectory), new State(Environment.ProcessId, hash, state, error));
            try
            {
                while (true)
                {
                    if (AgentGuardian.Hash(options.TargetPath) != hash) throw new IOException("Installed Agent changed before guardian refresh.");
                    Status("waiting_server");
                    try
                    {
                        var settings = new AgentSettingsStore(options.ProfileDirectory).Load();
                        if (await ServerCompatibility.CheckAsync(settings.Origin(), CancellationToken.None) is null) break;
                    }
                    catch (Exception error) when (error is System.Net.Http.HttpRequestException or TaskCanceledException) { }
                    await Task.Delay(TimeSpan.FromSeconds(30));
                }
                Status("waiting_update");
                // Same lock order as the direct installer. A main update must
                // finish its readiness check before the guardian can exit.
                using var update = await LockAsync(Path.Combine(Path.GetDirectoryName(options.TargetPath)!, "update.lock"), CancellationToken.None);
                using var install = await LockAsync(AgentGuardianControl.FileFor(options.ProfileDirectory, "install.lock"), CancellationToken.None);
                if (AgentGuardian.Hash(options.TargetPath) != hash) throw new IOException("Installed Agent changed during guardian refresh.");
                var confirmed = new AgentSettingsStore(options.ProfileDirectory).Load();
                if (await ServerCompatibility.CheckAsync(confirmed.Origin(), CancellationToken.None) is not null)
                    throw new IOException("Server compatibility changed before guardian refresh.");
                var current = AgentGuardianControl.Running(options.ProfileDirectory, executable);
                var stop = AgentGuardianControl.FileFor(options.ProfileDirectory, "stop");
                if (current is int id)
                {
                    using var process = Process.GetProcessById(id);
                    Status("draining"); File.WriteAllText(stop, "refresh");
                    await process.WaitForExitAsync();
                }
                var backup = Path.Combine(Path.GetDirectoryName(source)!, "Hako.Guardian.previous.exe");
                if (File.Exists(executable)) File.Copy(executable, backup, true);
                var temporary = executable + "." + Guid.NewGuid().ToString("N") + ".tmp";
                Process? replacement = null;
                try
                {
                    File.Copy(source, temporary);
                    if (AgentGuardian.Hash(temporary) != hash) throw new IOException("Guardian replacement hash mismatch.");
                    File.Move(temporary, executable, true); File.Delete(stop); Status("starting");
                    replacement = DetachedAgentProcess.Start(executable, ["--guardian", "--config", configuration]);
                    using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(20));
                    while (AgentGuardianControl.Running(options.ProfileDirectory, executable) != replacement.Id)
                    {
                        if (replacement.HasExited) throw new IOException("Replacement guardian exited.");
                        await Task.Delay(100, deadline.Token);
                    }
                    await LocalRpc.CallAsync(LocalRpc.GuardianPipe(options.ProfileDirectory), LocalRpc.Request("status"), deadline.Token);
                    Status("complete");
                }
                catch
                {
                    if (replacement is not null && !replacement.HasExited)
                    {
                        File.WriteAllText(stop, "rollback");
                        await replacement.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(20));
                    }
                    if (File.Exists(backup)) { File.Copy(backup, temporary, true); File.Move(temporary, executable, true); }
                    File.Delete(stop);
                    using var restored = DetachedAgentProcess.Start(executable, ["--guardian", "--config", configuration]);
                    throw;
                }
                finally { replacement?.Dispose(); if (File.Exists(temporary)) File.Delete(temporary); }
            }
            catch (Exception error) { Status("failed", error.GetType().Name); }
        }
    }
}
