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
    internal static async Task RunAsync(string executable, string project)
    {
        var root = Path.Combine(Path.GetTempPath(), "hako-command-host-" + Guid.NewGuid().ToString("N"));
        var profile = new AgentProfile(Path.Combine(root, "profile"));
        var target = Path.Combine(root, "installation", "Hako.exe");
        Directory.CreateDirectory(Path.GetDirectoryName(target)!); File.Copy(executable, target);
        var listener = new TcpListener(IPAddress.Loopback, 0); listener.Start(); var port = ((IPEndPoint)listener.LocalEndpoint).Port; listener.Stop();
        profile.Store.Save(new AgentSettings(DirectPort: port));
        using var main = Process.Start(new ProcessStartInfo(target) { UseShellExecute = false, CreateNoWindow = true,
            ArgumentList = { "--background", "--data-dir", profile.Store.DirectoryPath } })!;
        var originalPID = main.Id;
        Process? host = null; Process? restarted = null;
        try
        {
            Check((await Ready(profile)).GetProperty("direct").GetProperty("listening").GetBoolean(), "Test Agent direct connection unavailable");
            Console.WriteLine("PASS: isolated Agent started");
            using var bootstrap = await Open(port); var computer = CodexJson.Text(await Receive(bootstrap), "computerId");
            var endpoint = await Call(bootstrap, computer, "commands.open", new { });
            host = Process.GetProcessById(endpoint.GetProperty("processId").GetInt32());
            Console.WriteLine("PASS: independent host started");
            Check(!string.Equals(host.MainModule!.FileName, target, StringComparison.OrdinalIgnoreCase), "Executor locks the installed Agent");
            var hostPort = endpoint.GetProperty("port").GetInt32();
            try { using var rejected = await Open(hostPort); throw new Exception("Unauthenticated executor connection accepted"); }
            catch (WebSocketException) { }
            using var socket = await Open(hostPort, CodexJson.Text(endpoint, "token")); await Receive(socket);
            var application = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(Path.GetFullPath(project).ToUpperInvariant())))[..16].ToLowerInvariant();
            var id = Guid.NewGuid().ToString();
            string PS(string value) => "'" + value.Replace("'", "''") + "'";
            var command = "Write-Output 'before replacement'; $ready=Join-Path $env:HAKO_COMMAND_TASK_DIRECTORY 'replacement-ready'; while (!(Test-Path -LiteralPath $ready)) { Start-Sleep -Milliseconds 100 }; & $env:HAKO_COMMAND_EXECUTABLE --launch-agent --target " + PS(target) + " --data-dir " + PS(profile.Store.DirectoryPath) + " --json; Write-Output 'after replacement'";
            await Call(socket, computer, "commands.start", new { requestId = id, applicationId = application, name = "isolated Agent replacement", command, timeoutSeconds = 30, allowBackgroundProcesses = false });
            await AgentPipeClient.TrySendAsync(profile, new AgentCommand("exit", new()));
            await main.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(10));
            main.Dispose();
            Console.WriteLine("PASS: old Agent stopped");
            // The cached executor must allow the installed binary to be replaced.
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
            Console.WriteLine("PASS: packaged executor authentication, cached binary replacement, live socket after Agent exit, independent restart outside command job");
        }
        catch (Exception error)
        {
            Console.Error.WriteLine("Command host check failed: " + error);
            var diagnostics = Path.Combine(profile.Store.DirectoryPath, "command-host-error.log");
            if (File.Exists(diagnostics)) Console.Error.WriteLine(File.ReadAllText(diagnostics));
            throw;
        }
        finally
        {
            try { await AgentPipeClient.TrySendAsync(profile, new AgentCommand("exit", new())); } catch { }
            foreach (var process in new[] { main, restarted, host })
                if (process != null) { try { if (!process.HasExited) process.Kill(true); await process.WaitForExitAsync(); } catch (InvalidOperationException) { } }
            restarted?.Dispose(); host?.Dispose(); main.Dispose();
            for (var attempt = 0; attempt < 30; attempt++)
            {
                try { Directory.Delete(root, true); break; }
                catch (Exception error) when (error is IOException or UnauthorizedAccessException)
                { if (attempt == 29) Console.Error.WriteLine("Test cleanup deferred: " + root); else await Task.Delay(100); }
            }
        }
    }
}
