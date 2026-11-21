using System;
using System.IO;
using System.Net.WebSockets;
using System.Security.Cryptography;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Hako.Core;
using Hako.Platform;

internal static class CommandRelayChecks
{
    private sealed class Executor : IWorkshopDispatcher
    {
        internal int Starts;
        internal JsonElement Last;
        internal TaskCompletionSource<bool> Waiting = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public void SetNotificationScope(string? scope) { }
        public Task WatchAsync(JsonElement value, Func<JsonElement, Task> publish, CancellationToken token) => Task.CompletedTask;
        public Task WatchTerminalsAsync(string scope, Func<WorkshopTerminal, Task> publish, CancellationToken token) => Task.CompletedTask;
        public Task AcknowledgeTerminalAsync(string scope, string id, string questionId, CancellationToken token) => Task.CompletedTask;
        public async Task<object?> CallAsync(string method, JsonElement parameters, CancellationToken token)
        {
            Last = parameters.Clone();
            if (method == "commands.start") Interlocked.Increment(ref Starts);
            if (method == "commands.stop") throw new WorkshopException("command_not_found", "测试任务不存在");
            if (parameters.TryGetProperty("wait", out _)) { Waiting.TrySetResult(true); await Task.Delay(30000, token); }
            return new { method, output = new string('汉', 8000) };
        }
    }
    private static void Check(bool value, string message) { if (!value) throw new Exception(message); }
    internal static async Task RunAsync()
    {
        var directory = Path.Combine(Path.GetTempPath(), "hako-command-relay-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        try
        {
            var executor = new Executor();
            var secret = Convert.ToHexString(RandomNumberGenerator.GetBytes(32));
            await using var host = new WorkshopLocalServer(executor, 0, () => "relay-fixture", directory, secret);
            using var self = System.Diagnostics.Process.GetCurrentProcess();
            CommandHost.Save(Path.Combine(directory, "command-host.dat"), DataProtection.Protect(JsonSerializer.SerializeToUtf8Bytes(
                new CommandHostEndpoint(host.Port, secret, self.Id, self.StartTime.ToUniversalTime().Ticks,
                    CommandHost.Scope(new AgentSettingsStore(directory))), WorkshopProtocol.Json)));
            await using var dispatcher = new WorkshopDispatcher(directory);
            await using var front = new WorkshopLocalServer(dispatcher, 0, () => "relay-fixture", directory);
            using var client = new ClientWebSocket();
            client.Options.Proxy = null;
            using var budget = new CancellationTokenSource(TimeSpan.FromSeconds(15));
            await client.ConnectAsync(new Uri($"ws://127.0.0.1:{front.Port}/workshop/v1"), budget.Token);
            async Task<JsonElement> Receive()
            {
                using var bytes = new MemoryStream(); var buffer = new byte[4096];
                WebSocketReceiveResult frame;
                do { frame = await client.ReceiveAsync(buffer, budget.Token); bytes.Write(buffer, 0, frame.Count); } while (!frame.EndOfMessage);
                using var json = JsonDocument.Parse(bytes.ToArray()); return json.RootElement.Clone();
            }
            await Receive();
            var id = Guid.NewGuid().ToString();
            await client.SendAsync(JsonSerializer.SerializeToUtf8Bytes(new { kind = "call", id, method = "commands.start",
                computerId = "relay-fixture", @params = new { requestId = id, name = "构建项目" } }), WebSocketMessageType.Text, true, budget.Token);
            var reply = await Receive();
            Check(CodexJson.Text(reply, "kind") == "result" && CodexJson.Text(reply, "id") == id, "Main LAN endpoint did not relay the request");
            Check(CodexJson.Text(reply.GetProperty("result"), "output").Length == 8000, "Fragmented Unicode output was lost");
            Check(executor.Starts == 1 && CodexJson.Text(executor.Last, "requestId") == id && CodexJson.Text(executor.Last, "name") == "构建项目",
                "Relaying changed the command identity/content or executed it twice");
            var args = JsonSerializer.SerializeToElement(new { });
            try { await dispatcher.CallAsync("commands.stop", args, budget.Token); throw new Exception("Lost executor failure"); }
            catch (WorkshopException error) when (error.Code == "command_not_found" && error.Message == "测试任务不存在") { }
            using (var cancel = new CancellationTokenSource())
            {
                var call = dispatcher.CallAsync("commands.start", JsonSerializer.SerializeToElement(new { wait = true }), cancel.Token);
                await executor.Waiting.Task.WaitAsync(budget.Token);
                cancel.Cancel();
                try { await call; throw new Exception("Relay ignored cancellation"); }
                catch (OperationCanceledException) { }
            }
            Check(executor.Starts == 2, "Cancelled command was replayed");
            new AgentSettingsStore(directory).Save(new AgentSettings(Username: "changed"));
            try { await dispatcher.CallAsync("commands.list", args, budget.Token); throw new Exception("Relay used an executor from another account"); }
            catch (WorkshopException error) when (error.Code == "command_context_changed") { }
            Console.WriteLine("PASS: commands use the main LAN endpoint; authenticated loopback relay preserves request identity, Unicode, failures, cancellation and account fences without replay");
        }
        finally
        {
            if (!Path.GetFullPath(directory).StartsWith(Path.Combine(Path.GetTempPath(), "hako-command-relay-"), StringComparison.OrdinalIgnoreCase))
                throw new Exception("Unsafe relay fixture cleanup");
            Directory.Delete(directory, true);
        }
    }
}
