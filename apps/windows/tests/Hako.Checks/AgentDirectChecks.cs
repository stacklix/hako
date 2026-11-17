using System;
using System.IO;
using System.Net;
using System.Net.Http;
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
        var bytes = JsonSerializer.SerializeToUtf8Bytes(value, WorkshopProtocol.Json);
        await socket.SendAsync(bytes, WebSocketMessageType.Text, true, CancellationToken.None);
    }
    private static async Task<ClientWebSocket> Open(int port, string path)
    {
        var socket = new ClientWebSocket();
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(3));
        await socket.ConnectAsync(new Uri($"ws://127.0.0.1:{port}{path}"), timeout.Token);
        Check((await Receive(socket)).GetProperty("kind").GetString() == "welcome", "Direct handshake did not become ready");
        return socket;
    }
    private static async Task CheckHealth(HttpClient http, string address, string? credential = null)
    {
        using var request = new HttpRequestMessage(HttpMethod.Get, address + "/health");
        if (credential is not null) request.Headers.Add("X-Hako-Command", credential);
        using var response = await http.SendAsync(request);
        Check(response.StatusCode == HttpStatusCode.OK && response.Content.Headers.ContentType?.MediaType == "application/json"
            && response.Headers.CacheControl?.NoStore == true, "Health endpoint did not return non-cacheable JSON with HTTP 200");
        Check(await response.Content.ReadAsStringAsync() == "{\"status\":\"ok\"}", "Health endpoint exposed unexpected data");
    }
    private static async Task CheckRejected(HttpClient http, HttpRequestMessage request)
    {
        using (request)
        {
            try { using var response = await http.SendAsync(request); throw new Exception("Invalid HTTP request was accepted"); }
            catch (HttpRequestException) { }
        }
    }
    public static async Task RunAsync()
    {
        var directory = Path.Combine(Path.GetTempPath(), "hako-direct-" + Guid.NewGuid().ToString("N"));
        var storage = Path.Combine(directory, "code-workshop");
        Directory.CreateDirectory(storage);
        var id = Guid.NewGuid().ToString();
        File.WriteAllBytes(Path.Combine(storage, id + ".json"), JsonSerializer.SerializeToUtf8Bytes(new WorkshopJob {
            Id = id, State = "completed", ApplicationId = "fixture", Cwd = directory, ThreadId = Guid.NewGuid().ToString(), TurnId = "done"
        }, WorkshopProtocol.Json));
        File.WriteAllText(Path.Combine(storage, id + ".jsonl"), JsonSerializer.Serialize(new WorkshopEvent("delta", "answer", "Live text", "assistant"), WorkshopProtocol.Json) + "\n", new UTF8Encoding(false));
        try
        {
            await using var dispatcher = new WorkshopDispatcher(directory);
            await using var server = new WorkshopLocalServer(dispatcher, 0, () => "PC", directory);
            using var http = new HttpClient(new HttpClientHandler { UseProxy = false, AllowAutoRedirect = false }) { Timeout = TimeSpan.FromSeconds(3) };
            var origin = $"http://127.0.0.1:{server.Port}";
            await CheckHealth(http, origin);
            await CheckHealth(http, $"http://[::1]:{server.Port}");
            await CheckRejected(http, new HttpRequestMessage(HttpMethod.Get, origin + "/"));
            await CheckRejected(http, new HttpRequestMessage(HttpMethod.Post, origin + "/health"));
            var browserHealth = new HttpRequestMessage(HttpMethod.Get, origin + "/health");
            browserHealth.Headers.Add("Origin", "https://example.org");
            await CheckRejected(http, browserHealth);
            var registry = Path.Combine(directory, "server.json");
            await File.WriteAllTextAsync(registry, JsonSerializer.Serialize(new { version = 1, services = new[] {
                new { name = "direct-health", port = server.Port, healthPath = "/health" }
            } }));
            using (var monitor = new RegisteredServices(registry, _ => Task.FromResult(new ListenerSnapshot(DateTimeOffset.UtcNow.ToString("O"),
                [new("TCP", server.Port, [new(Environment.ProcessId, "fixture", null, null, ["0.0.0.0", "::"])])], [])), startupDirectory: Path.Combine(directory, "startups")))
            {
                var status = (await monitor.ReadAsync(default)).Services[0];
                Check(status.Status == "responding" && status.Http?.StatusCode == 200 && status.Http.Url == origin + "/health",
                    "Registered service monitoring did not reach the real LAN health endpoint");
            }
            using var socket = await Open(server.Port, "/workshop/v1");
            await Send(socket, new { id = "list", kind = "call", method = "computers.list", @params = new { } });
            var list = await Receive(socket);
            Check(list.GetProperty("result").GetProperty("computers")[0].GetProperty("id").GetString() == "PC", "LAN discovery required cloud authentication");
            await Send(socket, new { id = "operation", kind = "call", computerId = "PC", method = "operation.read", @params = new { operationId = id } });
            var reply = await Receive(socket);
            var page = reply.GetProperty("result");
            var cursor = page.GetProperty("cursor").GetInt64();
            Check(page.GetProperty("events")[0].GetProperty("text").GetString() == "Live text", "Direct query lost response data");
            await Send(socket, new { id = "shared-watch", kind = "watch", computerId = "PC", operationId = id, cursor = 0 });
            var multiplexed = await Receive(socket);
            Check(multiplexed.GetProperty("kind").GetString() == "event" && multiplexed.GetProperty("id").GetString() == "shared-watch" &&
                multiplexed.GetProperty("result").GetProperty("cursor").GetInt64() == cursor, "LAN shared subscription lost its identity or cursor");
            await Send(socket, new { id = "shared-watch", kind = "unwatch" });
            Check((await Receive(socket)).GetProperty("kind").GetString() == "unwatched", "LAN unsubscribe not acknowledged");
            await Send(socket, new { id = "shared-resume", kind = "watch", computerId = "PC", operationId = id, cursor });
            Check((await Receive(socket)).GetProperty("result").GetProperty("events").GetArrayLength() == 0,
                "LAN subscription on reused socket duplicated consumed events");
            await Send(socket, new { id = "shared-resume", kind = "unwatch" });
            _ = await Receive(socket);
            using var pushed = await Open(server.Port, $"/workshop/v1/events/{id}/0");
            var update = await Receive(pushed);
            Check(update.GetProperty("kind").GetString() == "event" && update.GetProperty("result").GetProperty("cursor").GetInt64() == cursor,
                "Direct subscription did not push missed events");
            using var resumed = await Open(server.Port, $"/workshop/v1/events/{id}/{cursor}");
            Check((await Receive(resumed)).GetProperty("result").GetProperty("events").GetArrayLength() == 0,
                "Direct reconnect duplicated a consumed delta");
            await Send(socket, new { id = "wrong-agent", kind = "call", computerId = "OtherPC", method = "operation.read", @params = new { operationId = id } });
            Check((await Receive(socket)).GetProperty("error").GetProperty("code").GetString() == "computer_changed", "Wrong host was allowed to execute a cached request");
            await Send(socket, new { id = "other-app", kind = "call", computerId = "PC", method = "action.git.commit", @params = new { } });
            Check((await Receive(socket)).GetProperty("error").GetProperty("code").GetString() == "unsupported_method", "LAN endpoint exposed sibling actions");
            using var browser = new ClientWebSocket();
            browser.Options.SetRequestHeader("Origin", "https://example.org");
            try { await browser.ConnectAsync(new Uri($"ws://127.0.0.1:{server.Port}/workshop/v1"), CancellationToken.None); throw new Exception("Browser origin accepted"); }
            catch (WebSocketException) { }
            Check(!WorkshopLocalServer.IsLANPeer(IPAddress.Parse("8.8.8.8")) && !WorkshopLocalServer.IsLANPeer(IPAddress.Parse("2001:4860:4860::8888")), "Non-LAN peers allowed");
            await using var protectedServer = new WorkshopLocalServer(dispatcher, 0, () => "PC", directory, "fixture-credential");
            var protectedOrigin = $"http://127.0.0.1:{protectedServer.Port}";
            await CheckRejected(http, new HttpRequestMessage(HttpMethod.Get, protectedOrigin + "/health"));
            var incorrect = new HttpRequestMessage(HttpMethod.Get, protectedOrigin + "/health");
            incorrect.Headers.Add("X-Hako-Command", "incorrect");
            await CheckRejected(http, incorrect);
            await CheckHealth(http, protectedOrigin, "fixture-credential");
            using var protectedSocket = new ClientWebSocket();
            protectedSocket.Options.SetRequestHeader("X-Hako-Command", "fixture-credential");
            using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(3));
            await protectedSocket.ConnectAsync(new Uri($"ws://127.0.0.1:{protectedServer.Port}/workshop/v1"), timeout.Token);
            Check((await Receive(protectedSocket)).GetProperty("kind").GetString() == "welcome", "Credentialed WebSocket upgrade failed after health routing");
        }
        finally { Directory.Delete(directory, true); }
        foreach (var value in new[] { "-1", "65536", "abc" })
        {
            try { CliParser.Parse(["config", "set", "--direct-port", value]); throw new Exception("Invalid port accepted"); }
            catch (CliUsageException) { }
        }
        Check(CliParser.Parse(["config", "set", "--direct-port", "8005"]).Request!.Options["direct-port"] == "8005", "Missing direct CLI configuration");
        Console.WriteLine("PASS: IPv4/IPv6 HTTP health, real registered service probe, credential protection, LAN discovery/queries/push, cursor resume, host binding, native-client restriction and port validation");
    }
}
