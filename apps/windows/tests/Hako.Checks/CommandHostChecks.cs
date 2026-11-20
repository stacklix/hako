using System;
using System.Diagnostics;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Net.WebSockets;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Hako.Core;
using Hako.Platform;

internal static class CommandHostChecks
{
    private static void Check(bool value, string message) { if (!value) throw new Exception(message); }
    private static async Task<JsonElement> Receive(ClientWebSocket socket)
    {
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(20));
        using var bytes = new MemoryStream(); var buffer = new byte[65536];
        WebSocketReceiveResult frame;
        do { frame = await socket.ReceiveAsync(buffer, timeout.Token); bytes.Write(buffer, 0, frame.Count); } while (!frame.EndOfMessage);
        return JsonDocument.Parse(bytes.ToArray()).RootElement.Clone();
    }
    private static async Task<ClientWebSocket> Open(int port, string? token = null)
    {
        var socket = new ClientWebSocket();
        if (token != null) socket.Options.SetRequestHeader("X-Hako-Command", token);
        try { using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(5)); await socket.ConnectAsync(new Uri($"ws://127.0.0.1:{port}/workshop/v1"), timeout.Token); return socket; }
        catch { socket.Dispose(); throw; }
    }
    private static async Task<JsonElement> Call(ClientWebSocket socket, string computer, string method, object parameters)
    {
        var id = Guid.NewGuid().ToString();
        await socket.SendAsync(JsonSerializer.SerializeToUtf8Bytes(new { kind = "call", id, computerId = computer, method, @params = parameters }), WebSocketMessageType.Text, true, CancellationToken.None);
        var reply = await Receive(socket);
        if (CodexJson.Text(reply, "kind") != "result") throw new Exception("Command host rejected request: " + reply);
        return reply.GetProperty("result");
    }
    private static async Task<JsonElement> Ready(AgentProfile profile)
    {
        var deadline = DateTime.UtcNow.AddSeconds(20);
        do
        {
            var reply = await AgentPipeClient.TrySendAsync(profile, new AgentCommand("status", new()), 500);
            if (reply?.ExitCode == 0) return JsonSerializer.SerializeToElement(reply.Data, WorkshopProtocol.Json);
            await Task.Delay(100);
        } while (DateTime.UtcNow < deadline);
        throw new Exception("Test Agent did not become ready");
    }
    private static async Task WaitFor(Func<bool> condition, string message)
    {
        var deadline = DateTime.UtcNow.AddSeconds(15);
        while (!condition())
        {
            if (DateTime.UtcNow >= deadline) throw new Exception(message);
            await Task.Delay(100);
        }
    }
    internal static async Task RunAsync(string executable, string project)
    {
        var root = Path.Combine(Path.GetTempPath(), "hako-command-host-" + Guid.NewGuid().ToString("N"));
        var profile = new AgentProfile(Path.Combine(root, "profile"));
        var target = Path.Combine(root, "installation", "Kage.exe");
        Directory.CreateDirectory(Path.GetDirectoryName(target)!); File.Copy(executable, target);
        // Keep this isolated fixture off GitHub and disable automatic main-process
        // recovery while explicitly exercising replacement from a command.
        using var updateLock = new FileStream(Path.Combine(Path.GetDirectoryName(target)!, "update.lock"), FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None);
        var listener = new TcpListener(IPAddress.Loopback, 0); listener.Start(); var port = ((IPEndPoint)listener.LocalEndpoint).Port; listener.Stop();
        profile.Store.Save(new AgentSettings(DirectPort: port));
        using var main = Process.Start(new ProcessStartInfo(target) { UseShellExecute = false, CreateNoWindow = true,
            ArgumentList = { "--background", "--data-dir", profile.Store.DirectoryPath } })!;
        var originalPID = main.Id;
        Process? host = null; Process? restarted = null; Process? nextHost = null;
        try
        {
            Check((await Ready(profile)).GetProperty("direct").GetProperty("listening").GetBoolean(), "Test Agent direct connection unavailable");
            Console.WriteLine("PASS: isolated Agent started");
            using var bootstrap = await Open(port); var computer = CodexJson.Text(await Receive(bootstrap), "computerId");
            var endpoint = await Call(bootstrap, computer, "commands.open", new { });
            host = Process.GetProcessById(endpoint.GetProperty("processId").GetInt32());
            var guardianExecutable = Path.Combine(Path.GetDirectoryName(target)!, "guardian", "Kage.Guardian.exe");
            Check(string.Equals(host.MainModule!.FileName, guardianExecutable, StringComparison.OrdinalIgnoreCase), "Commands did not run inside the guardian");
            var guardianStatus = AgentGuardianControl.Read<JsonElementBox>(AgentGuardianControl.FileFor(profile.Store.DirectoryPath, "status.json"));
            Check(guardianStatus?.ProcessId == host.Id, "Command endpoint PID differs from guardian PID");
            Check((await Call(bootstrap, computer, "commands.open", new { })).GetProperty("processId").GetInt32() == host.Id,
                "Opening commands started another guardian");
            Check(!Directory.Exists(Path.Combine(profile.Store.DirectoryPath, "command-runners")), "A separate command runner was created");
            Console.WriteLine("PASS: packaged command host shares the guardian PID and reuses it");
            var hostPort = endpoint.GetProperty("port").GetInt32();
            try { using var rejected = await Open(hostPort); throw new Exception("Unauthenticated executor connection accepted"); }
            catch (WebSocketException) { }
            using var socket = await Open(hostPort, CodexJson.Text(endpoint, "token")); await Receive(socket);
            var application = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(Path.GetFullPath(project).ToUpperInvariant())))[..16].ToLowerInvariant();
            var id = Guid.NewGuid().ToString();
            string PS(string value) => "'" + value.Replace("'", "''") + "'";
            // Pipe the GUI executable's output so PowerShell waits for the
            // restart helper, as the real installer does, before closing its job.
            var command = "Write-Output 'before replacement'; $ready=Join-Path $env:KAGE_COMMAND_TASK_DIRECTORY 'replacement-ready'; while (!(Test-Path -LiteralPath $ready)) { Start-Sleep -Milliseconds 100 }; $launch=(& $env:KAGE_COMMAND_EXECUTABLE --launch-agent --target " + PS(target) + " --data-dir " + PS(profile.Store.DirectoryPath) + " --json | Out-String) | ConvertFrom-Json; if (!$launch.ok) { throw $launch.error.message }; Write-Output 'after replacement'";
            await Call(socket, computer, "commands.start", new { requestId = id, applicationId = application, name = "isolated Agent replacement", command, timeoutSeconds = 30, allowBackgroundProcesses = false });
            await AgentPipeClient.TrySendAsync(profile, new AgentCommand("exit", new()));
            await main.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(10));
            main.Dispose();
            Console.WriteLine("PASS: old Agent stopped");
            // The guardian must allow the installed Agent binary to be replaced.
            var staged = Path.Combine(Path.GetDirectoryName(target)!, "Hako-new.exe");
            File.Copy(executable, staged);
            var replaceDeadline = DateTime.UtcNow.AddSeconds(10);
            while (true)
            {
                try { File.Move(staged, target, true); break; }
                catch (Exception error) when (error is IOException or UnauthorizedAccessException && DateTime.UtcNow < replaceDeadline) { await Task.Delay(100); }
            }
            File.WriteAllText(Path.Combine(profile.Store.DirectoryPath, "command-tasks", CommandHost.Scope(profile.Store), id, "replacement-ready"), "");
            var deadline = DateTime.UtcNow.AddSeconds(30); JsonElement result;
            do
            {
                result = await Call(socket, computer, "commands.read", new { taskId = id, cursor = 0 });
                if (CodexJson.Text(result.GetProperty("task"), "state") is not ("starting" or "running" or "stopping")) break;
                await Task.Delay(100);
            } while (DateTime.UtcNow < deadline);
            Check(CodexJson.Text(result.GetProperty("task"), "state") == "succeeded", "Replacement task failed: " + result);
            Check(CodexJson.Text(result, "output").Contains("after replacement"), "Lost independent task output");
            var status = await Ready(profile);
            restarted = Process.GetProcessById(status.GetProperty("processId").GetInt32());
            Check(restarted.Id != originalPID && !host.HasExited, "Executor or restarted Agent died with the old process/job");
            await Task.Delay(500);
            Check(!restarted.HasExited, "Restarted Agent remained inside the completed command's job");
            Console.WriteLine("PASS: guardian command authentication, Agent binary replacement, live socket after Agent exit, independent restart outside command job");

            var drainId = Guid.NewGuid().ToString();
            var taskDirectory = Path.Combine(profile.Store.DirectoryPath, "command-tasks", CommandHost.Scope(profile.Store), drainId);
            await Call(socket, computer, "commands.start", new { requestId = drainId, applicationId = application, name = "guardian update drain",
                command = "Set-Content -LiteralPath (Join-Path $env:KAGE_COMMAND_TASK_DIRECTORY 'ready') -Value ready; while (!(Test-Path -LiteralPath (Join-Path $env:KAGE_COMMAND_TASK_DIRECTORY 'release'))) { Start-Sleep -Milliseconds 100 }; Write-Output 'drained successfully'",
                timeoutSeconds = 40, allowBackgroundProcesses = false });
            await WaitFor(() => File.Exists(Path.Combine(taskDirectory, "ready")), "Command did not reach the drain gate");
            var previousTick = File.GetLastWriteTimeUtc(AgentGuardianControl.FileFor(profile.Store.DirectoryPath, "status.json"));
            await WaitFor(() => File.GetLastWriteTimeUtc(AgentGuardianControl.FileFor(profile.Store.DirectoryPath, "status.json")) > previousTick,
                "A running command blocked guardian polling");
            File.WriteAllText(AgentGuardianControl.FileFor(profile.Store.DirectoryPath, "stop"), "stop");
            await WaitFor(() => AgentGuardianControl.Read<CommandStatus>(AgentGuardianControl.FileFor(profile.Store.DirectoryPath, "commands-status.json"))?.State == "draining",
                "Guardian command host did not begin draining");
            Check(!host.HasExited && !restarted.HasExited, "Graceful guardian stop killed a running command or the Agent");
            Check(CodexJson.Text((await Call(socket, computer, "commands.read", new { taskId = drainId, cursor = 0 })).GetProperty("task"), "state") == "running",
                "Draining hid the running task");
            await socket.SendAsync(JsonSerializer.SerializeToUtf8Bytes(new { kind = "call", id = "reject-during-drain", computerId = computer,
                method = "commands.start", @params = new { requestId = Guid.NewGuid().ToString(), applicationId = application, name = "must reject", command = "exit 0", timeoutSeconds = 10, allowBackgroundProcesses = false } }, WorkshopProtocol.Json),
                WebSocketMessageType.Text, true, CancellationToken.None);
            Check(CodexJson.Text((await Receive(socket)).GetProperty("error"), "code") == "command_host_stopping", "Draining accepted new work");
            File.WriteAllText(Path.Combine(taskDirectory, "release"), "release");
            await host.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(15));
            Check(!File.Exists(Path.Combine(profile.Store.DirectoryPath, "command-host.dat")), "Stopped guardian left a live command endpoint");
            using (var completed = JsonDocument.Parse(File.ReadAllBytes(Path.Combine(taskDirectory, "state.json"))))
                Check(CodexJson.Text(completed.RootElement, "state") == "succeeded", "Guardian shutdown interrupted the running task");
            Check(File.ReadAllText(Path.Combine(taskDirectory, "output.log")).Contains("drained successfully"), "Guardian drain lost output");
            // A stopped guardian image can be replaced before the next command open.
            File.Copy(executable, guardianExecutable, true);
            using var freshBootstrap = await Open(port); var freshComputer = CodexJson.Text(await Receive(freshBootstrap), "computerId");
            var reopened = await Call(freshBootstrap, freshComputer, "commands.open", new { });
            nextHost = Process.GetProcessById(reopened.GetProperty("processId").GetInt32());
            Check(nextHost.Id != host.Id && !restarted.HasExited, "Guardian could not restart independently after replacement");
            using var freshCommands = await Open(reopened.GetProperty("port").GetInt32(), CodexJson.Text(reopened, "token")); await Receive(freshCommands);
            Check(CodexJson.Text((await Call(freshCommands, freshComputer, "commands.read", new { taskId = drainId, cursor = 0 })).GetProperty("task"), "state") == "succeeded",
                "Guardian replacement lost completed task history");
            Console.WriteLine("PASS: independent guardian polling, graceful drain, rejection of new work, completed output and history after guardian replacement");
        }
        catch (Exception error)
        {
            Console.Error.WriteLine("Command host check failed: " + error);
            var diagnostics = AgentGuardianControl.FileFor(profile.Store.DirectoryPath, "commands-status.json");
            if (File.Exists(diagnostics)) Console.Error.WriteLine(File.ReadAllText(diagnostics));
            throw;
        }
        finally
        {
            try { await AgentPipeClient.TrySendAsync(profile, new AgentCommand("exit", new())); } catch { }
            foreach (var process in new[] { main, restarted, host, nextHost })
                if (process != null) { try { if (!process.HasExited) process.Kill(true); await process.WaitForExitAsync(); } catch (InvalidOperationException) { } }
            restarted?.Dispose(); host?.Dispose(); nextHost?.Dispose(); main.Dispose();
            updateLock.Dispose();
            if (!Path.GetFullPath(root).StartsWith(Path.GetFullPath(Path.GetTempPath()) + "hako-command-host-", StringComparison.OrdinalIgnoreCase))
                throw new Exception("Unsafe command host fixture cleanup");
            for (var attempt = 0; attempt < 30; attempt++)
            {
                try { Directory.Delete(root, true); break; }
                catch (Exception error) when (error is IOException or UnauthorizedAccessException)
                { if (attempt == 29) Console.Error.WriteLine("Test cleanup deferred: " + root); else await Task.Delay(100); }
            }
        }
    }
    private sealed record JsonElementBox(int ProcessId);
    private sealed record CommandStatus(string State);
}
