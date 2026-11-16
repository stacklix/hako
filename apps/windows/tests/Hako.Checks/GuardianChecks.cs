using System;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Hako.Core;

internal static class GuardianChecks
{
    private sealed class Source : IAgentUpdateSource
    {
        internal AgentUpdateCandidate? Candidate;
        internal Task<AgentUpdateCandidate?>? Waiting;
        public Task<AgentUpdateCandidate?> LatestAsync(CancellationToken token) => Waiting ?? Task.FromResult(Candidate);
    }
    private sealed class Server : IAsyncDisposable
    {
        private readonly TcpListener listener = new(IPAddress.Loopback, 0);
        private readonly CancellationTokenSource stopping = new();
        private readonly Task worker;
        internal volatile string Version = "0.7.0";
        internal string Origin { get; }
        internal Server()
        {
            listener.Start(); Origin = "http://127.0.0.1:" + ((IPEndPoint)listener.LocalEndpoint).Port;
            worker = Task.Run(async () =>
            {
                try
                {
                    while (!stopping.IsCancellationRequested)
                    {
                        using var client = await listener.AcceptTcpClientAsync(stopping.Token);
                        using var stream = client.GetStream();
                        using var reader = new StreamReader(stream, Encoding.ASCII, false, 1024, true);
                        var request = await reader.ReadLineAsync(stopping.Token);
                        while (!string.IsNullOrEmpty(await reader.ReadLineAsync(stopping.Token))) { }
                        var body = request?.StartsWith("GET /api/v1/version ") == true
                            ? "{\"serverVersion\":\"" + Version + "\",\"minimumAgentVersion\":\"1.4.0\"}" : "";
                        var bytes = Encoding.ASCII.GetBytes("HTTP/1.1 " + (body.Length > 0 ? "200 OK" : "404 Not Found") +
                            "\r\nContent-Type: application/json\r\nContent-Length: " + body.Length + "\r\nConnection: close\r\n\r\n" + body);
                        await stream.WriteAsync(bytes, stopping.Token);
                    }
                }
                catch (OperationCanceledException) { }
                catch (SocketException) when (stopping.IsCancellationRequested) { }
                catch (IOException) when (stopping.IsCancellationRequested) { }
            });
        }
        public async ValueTask DisposeAsync() { stopping.Cancel(); listener.Stop(); await worker; stopping.Dispose(); }
    }
    private sealed class Fixture : IAsyncDisposable
    {
        internal string Root { get; } = Path.Combine(Path.GetTempPath(), "hako-guardian-" + Guid.NewGuid().ToString("N"));
        internal string Target => Path.Combine(Root, "install", "Hako.exe");
        internal string Profile => Path.Combine(Root, "profile");
        internal AgentGuardianOptions Options => new(Target, Profile, "stacklix/hako", PollSeconds: 1, UpdatePollSeconds: 5, RestartDelaySeconds: 1);
        internal Fixture(string executable, string origin)
        {
            Directory.CreateDirectory(Path.GetDirectoryName(Target)!); Directory.CreateDirectory(Profile);
            File.Copy(executable, Target);
            using var rsa = RSA.Create(2048);
            new AgentSettingsStore(Profile).Save(new AgentSettings(origin, "guardian-fixture", rsa.ExportPkcs8PrivateKeyPem()));
            Directory.CreateDirectory(AgentGuardianControl.DirectoryFor(Profile));
            File.WriteAllText(AgentGuardianControl.FileFor(Profile, "config.json"), "invalid guardian configuration");
            Directory.CreateDirectory(Path.Combine(Path.GetDirectoryName(Target)!, "guardian"));
            File.WriteAllText(Path.Combine(Path.GetDirectoryName(Target)!, "guardian", "Hako.Guardian.exe"), "startup target fixture");
        }
        internal AgentUpdateCandidate Candidate()
        {
            var path = Path.Combine(Root, "candidate.exe"); File.Copy(Target, path, true);
            // A different valid bundle with the same release version exercises internal build updates.
            using (var stream = new FileStream(path, FileMode.Append, FileAccess.Write)) stream.Write(Guid.NewGuid().ToByteArray());
            return new(path, AgentGuardian.Hash(path), 10, FileVersionInfo.GetVersionInfo(path).ProductVersion!.Split('+')[0]);
        }
        internal AgentGuardian.Session? Session => AgentGuardianControl.Read<AgentGuardian.Session>(Path.Combine(Profile, "logs", "agent-session.json"));
        internal static Process Launch(string executable, string[] arguments)
        {
            // Test-only supervision permits hosted CI jobs that forbid process breakaway.
            // Production always uses DetachedAgentProcess and never falls back to this launcher.
            var start = new ProcessStartInfo(executable) { UseShellExecute = false, CreateNoWindow = true, WindowStyle = ProcessWindowStyle.Hidden };
            foreach (var arg in arguments) start.ArgumentList.Add(arg);
            return Process.Start(start)!;
        }
        internal async Task<Process> StartAsync()
        {
            var process = Launch(Target, ["--background", "--data-dir", Profile]);
            await ReadyAsync(process.Id); return process;
        }
        internal async Task ReadyAsync(int id)
        {
            var deadline = DateTime.UtcNow.AddSeconds(20);
            do
            {
                await Task.Delay(100);
                var reply = await CliAsync("status");
                if (reply.GetProperty("data").GetProperty("running").GetBoolean() && reply.GetProperty("data").GetProperty("processId").GetInt32() == id) return;
            } while (DateTime.UtcNow < deadline);
            throw new Exception("Guardian fixture Agent did not become ready.");
        }
        internal async Task<JsonElement> CliAsync(string command)
        {
            var start = new ProcessStartInfo(Target) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true };
            foreach (var arg in new[] { command, "--data-dir", Profile, "--json" }) start.ArgumentList.Add(arg);
            using var process = Process.Start(start)!;
            var output = process.StandardOutput.ReadToEndAsync(); var error = process.StandardError.ReadToEndAsync();
            await process.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(15));
            var text = await output; await error;
            using var document = JsonDocument.Parse(text);
            if (process.ExitCode != 0) throw new Exception("Guardian fixture CLI failed.");
            return document.RootElement.Clone();
        }
        internal async Task StopAsync()
        {
            if (Session is not { } session) return;
            Process process;
            try { process = Process.GetProcessById(session.ProcessId); } catch (ArgumentException) { return; }
            using (process)
            {
                if (process.MainModule?.FileName != Target) throw new Exception("Fixture PID no longer belongs to its Agent.");
                await CliAsync("exit"); await process.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(10));
            }
        }
        public async ValueTask DisposeAsync()
        {
            try { await StopAsync(); }
            finally
            {
                if (Session is { } session)
                {
                    try { using var process = Process.GetProcessById(session.ProcessId); if (process.MainModule?.FileName == Target) { process.Kill(); await process.WaitForExitAsync(); } }
                    catch (ArgumentException) { }
                }
                if (!Path.GetFullPath(Root).StartsWith(Path.GetFullPath(Path.GetTempPath()), StringComparison.OrdinalIgnoreCase)) throw new Exception("Unsafe fixture cleanup path.");
                Directory.Delete(Root, true);
            }
        }
    }
    private static void Check(bool value, string message) { if (!value) throw new Exception(message); }
    internal static async Task RunAsync(string executable)
    {
        executable = Path.GetFullPath(executable);
        await using var server = new Server();
        await using (var fixture = new Fixture(executable, server.Origin))
        {
            var source = new Source { Candidate = fixture.Candidate() };
            var staged = Path.Combine(Path.GetDirectoryName(fixture.Target)!, "updates", "pending", "Hako-new.exe");
            Directory.CreateDirectory(Path.GetDirectoryName(staged)!); File.Copy(source.Candidate.Path, staged);
            AgentGuardianControl.Write(AgentGuardianControl.FileFor(fixture.Profile, "pending-update.json"),
                new AgentPendingUpdate(staged, source.Candidate.Sha256, source.Candidate.Version, DateTimeOffset.UtcNow, true));
            var guardian = new AgentGuardian(fixture.Options, source, Fixture.Launch);
            server.Version = "0.3.1";
            using var old = await fixture.StartAsync();
            var oldHash = AgentGuardian.Hash(fixture.Target);
            var configHash = AgentGuardian.Hash(Path.Combine(fixture.Profile, "agent.dat"));
            await guardian.TickAsync(default);
            Check(!old.HasExited && AgentGuardian.Hash(fixture.Target) == oldHash, "Incompatible update stopped or replaced the original Agent.");
            server.Version = "0.7.0";
            await Task.Delay(5100); await guardian.TickAsync(default);
            Check(old.HasExited && AgentGuardian.Hash(fixture.Target) == source.Candidate.Sha256, "Guardian did not update when the server became compatible.");
            Check(AgentGuardian.Hash(Path.Combine(fixture.Profile, "agent.dat")) == configHash, "Update changed the Agent configuration.");
            var updatedId = fixture.Session!.ProcessId; await fixture.ReadyAsync(updatedId);
            await fixture.StopAsync(); await guardian.TickAsync(default); await Task.Delay(1100); await guardian.TickAsync(default);
            Check(fixture.Session!.ProcessId == updatedId && fixture.Session.EndedAt is not null, "Guardian restarted a manual exit.");
            using var reopened = await fixture.StartAsync();
            reopened.Kill(); await reopened.WaitForExitAsync();
            var slowDownload = new TaskCompletionSource<AgentUpdateCandidate?>();
            guardian = new AgentGuardian(fixture.Options, new Source { Waiting = slowDownload.Task }, Fixture.Launch);
            await guardian.TickAsync(default, waitForUpdate: false); await Task.Delay(1100); await guardian.TickAsync(default, waitForUpdate: false);
            slowDownload.SetResult(null);
            var rescuedId = fixture.Session!.ProcessId;
            Check(rescuedId != reopened.Id, "Guardian did not replace the crashed Agent process."); await fixture.ReadyAsync(rescuedId);
            using var rescued = Process.GetProcessById(rescuedId);
            await guardian.TickAsync(default); rescued.Kill(); await rescued.WaitForExitAsync();
            await guardian.TickAsync(default); await Task.Delay(1100); await guardian.TickAsync(default);
            Check(fixture.Session!.ProcessId == rescuedId, "Repeated crashes ignored restart backoff.");
            Console.WriteLine("PASS: real guardian compatibility wait, deferred update, process/configuration verification, manual exit, crash recovery and crash-loop backoff.");
        }
        await using (var fixture = new Fixture(executable, server.Origin))
        {
            var candidate = fixture.Candidate(); var source = new Source { Candidate = candidate };
            using var old = await fixture.StartAsync(); var oldHash = AgentGuardian.Hash(fixture.Target);
            var launches = 0;
            var guardian = new AgentGuardian(fixture.Options, source, (path, args) =>
            { if (++launches == 1) throw new Win32Exception(5); return Fixture.Launch(path, args); });
            await guardian.TickAsync(default);
            Check(AgentGuardian.Hash(fixture.Target) == oldHash && launches == 2, "Failed startup did not roll back and restart the original Agent.");
            var restoredId = fixture.Session!.ProcessId; await fixture.ReadyAsync(restoredId);
            await Task.Delay(5100); await guardian.TickAsync(default);
            Check(fixture.Session!.ProcessId == restoredId, "Rejected artifact was repeatedly installed.");
            var backup = Path.Combine(fixture.Root, "recovery-backup.exe"); File.Copy(fixture.Target, backup);
            AgentGuardianControl.BeginMaintenance(fixture.Profile, restoredId);
            await fixture.StopAsync();
            var replacing = fixture.Target + ".recovery-fixture"; File.Copy(candidate.Path, replacing);
            var replacementDeadline = DateTime.UtcNow.AddSeconds(10);
            while (true)
            {
                try { File.Move(replacing, fixture.Target, true); break; }
                catch (IOException) when (DateTime.UtcNow < replacementDeadline) { await Task.Delay(100); }
            }
            var journal = AgentGuardianControl.FileFor(fixture.Profile, "transaction.json");
            AgentGuardianControl.Write(journal, new { backup, oldHash, candidate, restart = true, startedAt = DateTimeOffset.UtcNow });
            await guardian.TickAsync(default);
            Check(!File.Exists(journal) && AgentGuardian.Hash(fixture.Target) == oldHash, "Interrupted update recovery did not restore its verified backup.");
            await fixture.ReadyAsync(fixture.Session!.ProcessId);
            var forged = new Source { Candidate = candidate with { Sha256 = new string('0', 64) } };
            var invalid = new AgentGuardian(fixture.Options, forged, Fixture.Launch);
            using (var updateLock = new FileStream(Path.Combine(Path.GetDirectoryName(fixture.Target)!, "update.lock"), FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None))
                await invalid.TickAsync(default);
            await invalid.TickAsync(default);
            using var status = JsonDocument.Parse(File.ReadAllText(AgentGuardianControl.FileFor(fixture.Profile, "status.json")));
            Check(status.RootElement.GetProperty("updateState").GetString() == "source_unavailable" && AgentGuardian.Hash(fixture.Target) == oldHash,
                "Unverified artifact modified the installed Agent.");
            Console.WriteLine("PASS: guardian rollback, rejected-artifact suppression, interrupted transaction recovery, update lock and hash rejection.");
        }
    }
}
