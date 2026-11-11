using System;
using System.IO;
using System.Net;
using System.Net.WebSockets;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Hako.Core;
using Hako.Platform;

internal static class AgentDirectChecks
{
    private static void Check(bool value, string message) { if (!value) throw new Exception(message); }
    private static async Task<JsonElement> Receive(ClientWebSocket socket)
    {
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(3));
        using var bytes = new MemoryStream();
        var buffer = new byte[8192];
        while (true)
        {
            var frame = await socket.ReceiveAsync(buffer, timeout.Token);
            if (frame.MessageType != WebSocketMessageType.Text) throw new Exception("Expected a JSON frame");
            bytes.Write(buffer, 0, frame.Count);
            if (frame.EndOfMessage) return JsonDocument.Parse(bytes.ToArray()).RootElement.Clone();
        }
    }
    private static async Task Send(ClientWebSocket socket, object value)
    {
        var bytes = JsonSerializer.SerializeToUtf8Bytes(value, AgentConnection.Json);
        await socket.SendAsync(bytes, WebSocketMessageType.Text, true, CancellationToken.None);
    }
    private static async Task<ClientWebSocket> Open(int port, string path)
    {
        var socket = new ClientWebSocket();
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(3));
        await socket.ConnectAsync(new Uri($"ws://127.0.0.1:{port}{path}"), timeout.Token);
        Check((await Receive(socket)).GetProperty("type").GetString() == "ready", "Direct handshake did not become ready");
        return socket;
    }
    public static async Task RunAsync()
    {
        var directory = Path.Combine(Path.GetTempPath(), "hako-direct-" + Guid.NewGuid().ToString("N"));
        var storage = Path.Combine(directory, "code-workshop");
        Directory.CreateDirectory(storage);
        var id = Guid.NewGuid().ToString();
        File.WriteAllBytes(Path.Combine(storage, id + ".json"), JsonSerializer.SerializeToUtf8Bytes(new WorkshopJob {
            Id = id, State = "completed", ApplicationId = "fixture", Cwd = directory, ThreadId = Guid.NewGuid().ToString(), TurnId = "done"
        }, AgentConnection.Json));
        File.WriteAllText(Path.Combine(storage, id + ".jsonl"), JsonSerializer.Serialize(new WorkshopEvent("delta", "answer", "Live text", "assistant"), AgentConnection.Json) + "\n", new UTF8Encoding(false));
        try
        {
            await using var dispatcher = new AgentDispatcher(new SystemMetrics(), dataDirectory: directory);
            await using var server = new AgentDirectServer(dispatcher, 0, () => "PC", directory);
            using var socket = await Open(server.Port, "/agents");
            await Send(socket, new { id = "list", type = "list" });
            var list = await Receive(socket);
            Check(list.GetProperty("body").GetProperty("agents")[0].GetProperty("id").GetString() == "PC", "LAN discovery required cloud authentication");
            await Send(socket, new { id = "operation", type = "request", agentId = "PC", body = new { method = "query.codex.operation", version = 1, @params = new { operationId = id } } });
            var reply = await Receive(socket);
            var page = reply.GetProperty("body").GetProperty("result");
            var cursor = page.GetProperty("cursor").GetInt64();
            Check(page.GetProperty("events")[0].GetProperty("text").GetString() == "Live text", "Direct query lost response data");
            using var pushed = await Open(server.Port, $"/workshop/{id}/0");
            var update = await Receive(pushed);
            Check(update.GetProperty("type").GetString() == "update" && update.GetProperty("body").GetProperty("result").GetProperty("cursor").GetInt64() == cursor,
                "Direct subscription did not push missed events");
            using var resumed = await Open(server.Port, $"/workshop/{id}/{cursor}");
            Check((await Receive(resumed)).GetProperty("body").GetProperty("result").GetProperty("events").GetArrayLength() == 0,
                "Direct reconnect duplicated a consumed delta");
            await Send(socket, new { id = "wrong-agent", type = "request", agentId = "OtherPC", body = new { method = "query.codex.operation", version = 1, @params = new { operationId = id } } });
            Check((await Receive(socket)).GetProperty("body").GetProperty("error").GetProperty("code").GetString() == "agent_changed", "Wrong host was allowed to execute a cached request");
            await Send(socket, new { id = "other-app", type = "request", agentId = "PC", body = new { method = "action.git.commit", version = 1, @params = new { } } });
            Check((await Receive(socket)).GetProperty("body").GetProperty("error").GetProperty("code").GetString() == "unsupported_method", "LAN endpoint exposed sibling actions");
            using var browser = new ClientWebSocket();
            browser.Options.SetRequestHeader("Origin", "https://example.org");
            try { await browser.ConnectAsync(new Uri($"ws://127.0.0.1:{server.Port}/agents"), CancellationToken.None); throw new Exception("Browser origin accepted"); }
            catch (WebSocketException) { }
            Check(!AgentDirectServer.IsLANPeer(IPAddress.Parse("8.8.8.8")) && !AgentDirectServer.IsLANPeer(IPAddress.Parse("2001:4860:4860::8888")), "Non-LAN peers allowed");
        }
        finally { Directory.Delete(directory, true); }
        foreach (var value in new[] { "-1", "65536", "abc" })
        {
            try { CliParser.Parse(["config", "set", "--direct-port", value]); throw new Exception("Invalid port accepted"); }
            catch (CliUsageException) { }
        }
        Check(CliParser.Parse(["config", "set", "--direct-port", "8005"]).Request!.Options["direct-port"] == "8005", "Missing direct CLI configuration");
        Console.WriteLine("PASS: unauthenticated LAN discovery/queries/push, cursor resume, host binding, native-client restriction and port validation");
    }
}
