using System;
using System.Diagnostics;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using Hako.Core;

internal static class GuardianRefreshChecks
{
    private sealed class VersionServer : IAsyncDisposable
    {
        private readonly TcpListener listener = new(IPAddress.Loopback, 0);
        private readonly CancellationTokenSource stopping = new();
        private readonly Task work;
        internal string Version = "0.5.0";
        internal string Url { get; }
        internal VersionServer()
        {
            listener.Start(); Url = "http://127.0.0.1:" + ((IPEndPoint)listener.LocalEndpoint).Port;
            work = Task.Run(async () =>
            {
                while (!stopping.IsCancellationRequested)
                {
                    using var client = await listener.AcceptTcpClientAsync(stopping.Token);
                    await using var stream = client.GetStream();
                    using var reader = new StreamReader(stream, Encoding.ASCII, leaveOpen: true);
                    string? line;
                    do { line = await reader.ReadLineAsync(stopping.Token); } while (!string.IsNullOrEmpty(line));
                    var body = "{\"serverVersion\":\"" + Version + "\",\"minimumAgentVersion\":\"1.4.0\"}";
                    var response = Encoding.UTF8.GetBytes("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: " + Encoding.UTF8.GetByteCount(body) + "\r\nConnection: close\r\n\r\n" + body);
                    await stream.WriteAsync(response, stopping.Token);
                }
            });
        }
        public async ValueTask DisposeAsync()
        {
            await stopping.CancelAsync(); listener.Stop();
            try { await work; } catch (OperationCanceledException) { }
            stopping.Dispose();
        }
    }
    private static async Task WaitFor(Func<bool> predicate, CancellationToken token)
    { while (!predicate()) await Task.Delay(100, token); }
    internal static async Task RunAsync(string executable)
    {
        var root = Path.Combine(Path.GetTempPath(), "hako-guardian-refresh-" + Guid.NewGuid().ToString("N"));
        var profile = Path.Combine(root, "profile");
        var target = Path.Combine(root, "install", "Kage.exe");
        Directory.CreateDirectory(Path.GetDirectoryName(target)!);
        File.Copy(executable, target);
        await using var server = new VersionServer();
        new AgentSettingsStore(profile).Save(new AgentSettings(server.Url, "owner"));
        var options = new AgentGuardianOptions(target, profile, "stacklix/hako", PollSeconds: 1, UpdatePollSeconds: 86400, RestartDelaySeconds: 3600);
        var config = AgentGuardianControl.FileFor(profile, "config.json");
        AgentGuardianControl.Write(config, options);
        AgentGuardianControl.Write(AgentGuardianControl.FileFor(profile, "paused.json"), new { paused = true });
        var guardian = AgentGuardianControl.ExecutableFor(options);
        Directory.CreateDirectory(Path.GetDirectoryName(guardian)!); File.Copy(target, guardian);
        using (var oldImage = new FileStream(guardian, FileMode.Append, FileAccess.Write)) oldImage.Write(Guid.NewGuid().ToByteArray());
        var oldHash = AgentGuardian.Hash(guardian); var hash = AgentGuardian.Hash(target);
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(85));
        var token = timeout.Token;
        FileStream? updateLock = new(Path.Combine(Path.GetDirectoryName(target)!, "update.lock"), FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None);
        Process? old = null, helper = null, replacement = null, standby = null;
        try
        {
            old = Process.Start(new ProcessStartInfo(guardian) { UseShellExecute = false, CreateNoWindow = true,
                ArgumentList = { "--guardian", "--config", config } })!;
            await WaitFor(() => AgentGuardianControl.Running(profile, guardian) == old.Id, token);
            var warm = GuardianHandoff.ExecutableFor(guardian, hash);
            Directory.CreateDirectory(Path.GetDirectoryName(warm)!); File.Copy(target, warm);
            var nonce = Guid.NewGuid().ToString("N");
            standby = Process.Start(new ProcessStartInfo(warm) { UseShellExecute = false, CreateNoWindow = true,
                ArgumentList = { "--guardian-standby", "--config", config, "--handoff", nonce, "--parent", Environment.ProcessId.ToString() } })!;
            await WaitFor(() => AgentGuardianControl.Read<GuardianHandoff.Ready>(GuardianHandoff.ReadyPath(profile))?.Nonce == nonce, token);
            if (old.HasExited || AgentGuardianControl.Running(profile, guardian) != old.Id || File.Exists(AgentGuardianControl.FileFor(profile, "stop")))
                throw new Exception("Standby stole ownership or stopped the current guardian");
            await LocalRpc.CallAsync(LocalRpc.GuardianPipe(profile), LocalRpc.Request("status"), token);
            standby.Kill(); await standby.WaitForExitAsync(token);
            var updaterId = await AgentGuardianRefresh.StartAsync(options, hash, token);
            helper = Process.GetProcessById(updaterId);
            await Task.Delay(500, token);
            if (old.HasExited || AgentGuardian.Hash(guardian) != oldHash || File.Exists(AgentGuardianControl.FileFor(profile, "stop")))
                throw new Exception("Incompatible refresh touched the running guardian");
            server.Version = "0.8.0";
            await WaitFor(() => AgentGuardianControl.Read<AgentGuardianRefresh.State>(AgentGuardianRefresh.StatePath(profile))?.StateName == "waiting_update", token);
            if (old.HasExited || AgentGuardian.Hash(guardian) != oldHash) throw new Exception("Refresh bypassed the main update lock");
            // A bad candidate must fail before the existing owner is asked to stop.
            await File.AppendAllTextAsync(warm, "corrupt candidate", token);
            updateLock.Dispose(); updateLock = null;
            await helper.WaitForExitAsync(token);
            if (AgentGuardianControl.Read<AgentGuardianRefresh.State>(AgentGuardianRefresh.StatePath(profile))?.StateName != "failed"
                || old.HasExited || File.Exists(AgentGuardianControl.FileFor(profile, "stop")))
                throw new Exception("A failed warmup interrupted the existing guardian");
            File.Copy(target, warm, true);
            helper.Dispose();
            helper = Process.GetProcessById(await AgentGuardianRefresh.StartAsync(options, hash, token));
            await helper.WaitForExitAsync(token);
            var result = AgentGuardianControl.Read<AgentGuardianRefresh.State>(AgentGuardianRefresh.StatePath(profile));
            if (result?.StateName != "complete" || !old.HasExited || AgentGuardian.Hash(guardian) != hash)
                throw new Exception("Guardian replacement failed: " + result);
            var newId = AgentGuardianControl.Running(profile, guardian) ?? throw new Exception("Replacement guardian is not running");
            replacement = Process.GetProcessById(newId);
            var ready = AgentGuardianControl.Read<GuardianHandoff.Ready>(GuardianHandoff.ReadyPath(profile));
            if (ready?.ProcessId != newId || ready.Nonce == nonce || ready.ReadyAt.UtcDateTime >= old.ExitTime.ToUniversalTime()
                || replacement.StartTime.ToUniversalTime() >= old.ExitTime.ToUniversalTime())
                throw new Exception("The new guardian was not running and ready before the old guardian exited");
            await LocalRpc.CallAsync(LocalRpc.GuardianPipe(profile), LocalRpc.Request("status"), token);
            if (!File.Exists(AgentGuardianControl.FileFor(profile, Path.Combine("refresh", hash, "Kage.Guardian.previous.exe"))))
                throw new Exception("Guardian backup missing");
            Console.WriteLine("PASS: standby warms without taking ownership; refresh checks compatibility and update locks, confirms readiness before retirement, preserves the old image and activates the same warm process");
        }
        finally
        {
            updateLock?.Dispose();
            foreach (var process in new[] { replacement, helper, standby, old })
                if (process is not null)
                {
                    try { if (!process.HasExited) process.Kill(true); await process.WaitForExitAsync(); } catch (InvalidOperationException) { }
                    process.Dispose();
                }
            if (!Path.GetFullPath(root).StartsWith(Path.GetFullPath(Path.GetTempPath()) + "hako-guardian-refresh-", StringComparison.OrdinalIgnoreCase))
                throw new Exception("Unsafe refresh fixture cleanup");
            // Windows can briefly retain an executable section after the
            // process handle signals exit. Keep cleanup scoped to this fixture.
            var cleanupDeadline = DateTime.UtcNow.AddSeconds(5);
            while (true)
            {
                try { Directory.Delete(root, true); break; }
                catch (Exception error) when (error is IOException or UnauthorizedAccessException && DateTime.UtcNow < cleanupDeadline)
                { await Task.Delay(100); }
            }
        }
    }
}
