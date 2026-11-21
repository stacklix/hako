using System;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Hako.Core;
using Hako.Platform;

internal static class ServiceMonitorChecks
{
    private sealed class Handler(Func<HttpRequestMessage, CancellationToken, Task<HttpResponseMessage>> send) : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token) => send(request, token);
    }
    private sealed class UnreadBody : HttpContent
    {
        protected override Task SerializeToStreamAsync(Stream stream, TransportContext? context) => throw new Exception("Probe read response body");
        protected override bool TryComputeLength(out long length) { length = 0; return false; }
    }
    private static ListenerPort Port(int port, string address = "127.0.0.1", string protocol = "TCP") =>
        new(protocol, port, [new(123, "fixture", null, null, [address])]);

    public static async Task RunAsync()
    {
        var directory = Path.Combine(Path.GetTempPath(), "hako-services-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        var registry = Path.Combine(directory, "server.json");
        var startup = Path.Combine(directory, "startups");
        var now = DateTimeOffset.UtcNow.ToString("O");
        ListenerSnapshot listeners = new(now, [], []);
        var expectedProbePath = "/";
        using var monitor = new RegisteredServices(registry, _ => Task.FromResult(listeners), new Handler(async (request, token) =>
        {
            if (request.Method != HttpMethod.Get || request.RequestUri!.AbsolutePath != expectedProbePath || request.Headers.Authorization is not null)
                throw new Exception("Probe must be a credential-free GET of the configured path");
            var port = request.RequestUri.Port;
            if (port == 8106) await Task.Delay(Timeout.Infinite, token);
            if (port == 8104) throw new HttpRequestException("fixture connection refused");
            if (port == 8103 && request.RequestUri.Host != "192.168.0.10") throw new Exception("LAN-only listener was probed through loopback");
            if (port == 8105 && request.RequestUri.Host != "[::1]") throw new Exception("IPv6 wildcard was not mapped to IPv6 loopback");
            return new HttpResponseMessage((HttpStatusCode)(port == 8101 ? 404 : port == 8102 ? 503 : port == 8108 ? 302 : 200)) { Content = new UnreadBody() };
        }), TimeSpan.FromMilliseconds(100), startup);
        async Task Registry(object[] services) => await File.WriteAllTextAsync(registry, JsonSerializer.Serialize(new { version = 1, services }));
        async Task ExpectError(string code, Func<Task> action)
        {
            try { await action(); throw new Exception("Expected " + code); }
            catch (AgentActionException error) when (error.Code == code) { }
        }
        try
        {
            await ExpectError("registry_missing", async () => await monitor.ReadAsync(default));
            await Registry([]);
            if ((await monitor.ReadAsync(default)).Services.Length != 0) throw new Exception("Empty registry was not preserved");
            await Registry(Enumerable.Range(8100, 8).Select(port => (object)new { name = "service-" + port, port,
                description = "fixture", startCommand = "throw 'not for monitoring'", script = "private", token = "not-exported" }).ToArray());
            listeners = new(now, [Port(8100), Port(8101), Port(8102), Port(8103, "192.168.0.10"), Port(8104), Port(8105, "::"), Port(8106), Port(8107, protocol: "UDP")], []);
            var snapshot = await monitor.ReadAsync(default);
            var expected = new[] { "responding", "responding", "http_error", "responding", "unreachable", "responding", "unreachable", "stopped" };
            if (!snapshot.Services.Select(service => service.Status).SequenceEqual(expected))
                throw new Exception("Service status classification failed: " + string.Join(",", snapshot.Services.Select(service => service.Status)));
            if (!snapshot.Services[^1].CanStart || snapshot.Services.Take(7).Any(service => service.CanStart))
                throw new Exception("Only stopped registered services may be started");
            var serialized = JsonSerializer.Serialize(snapshot, AgentConnection.Json);
            if (serialized.Contains("not-exported") || serialized.Contains("not for monitoring") || serialized.Contains("private"))
                throw new Exception("Private registry fields or commands leaked into monitoring payload");
            listeners = new(now, [], ["TCP IPv6 端口读取失败，结果可能不完整。"]);
            if ((await monitor.ReadAsync(default)).Services.Any(service => service.Status != "unknown" || service.CanStart))
                throw new Exception("An incomplete listener table must not mark services stopped/startable");
            foreach (var path in new[] { "/health", "/status/ready" })
            {
                expectedProbePath = path;
                await Registry(new[] { 8100, 8101, 8102, 8108 }.Select(port => (object)new { name = "health-" + port, port, healthPath = path }).ToArray());
                listeners = new(now, [Port(8100), Port(8101), Port(8102), Port(8108)], []);
                var health = await monitor.ReadAsync(default);
                if (!health.Services.Select(service => service.Status).SequenceEqual(["responding", "responding", "http_error", "responding"])
                    || health.Services.Any(service => !service.Http!.Url.EndsWith(path, StringComparison.Ordinal)))
                    throw new Exception("Health probes must use the registered path without changing HTTP status semantics or falling back to root");
            }
            expectedProbePath = "/";
            foreach (var path in new object?[] { null, 7, "", "health", "http://example.org/health", "//example.org/health", "/\\example.org", "/health?token=private", "/health#fragment", "/health\r\nInjected: value", "/" + new string('x', 1000) })
            {
                await Registry([new { name = "invalid-health", port = 8100, healthPath = path }]);
                await ExpectError("registry_invalid", async () => await monitor.ReadAsync(default));
            }
            foreach (var json in new[] { "{", "{\"version\":\"1\",\"services\":[]}", "{\"version\":2,\"services\":[]}",
                "{\"version\":1,\"services\":[{\"name\":\"bad\",\"port\":65536}]}",
                "{\"version\":1,\"services\":[{\"name\":\"same\",\"port\":1},{\"name\":\"same\",\"port\":2}]}" })
            {
                await File.WriteAllTextAsync(registry, json);
                await ExpectError("registry_invalid", async () => await monitor.ReadAsync(default));
            }
            await File.WriteAllTextAsync(registry, new string(' ', 256 * 1024 + 1));
            await ExpectError("registry_invalid", async () => await monitor.ReadAsync(default));
            var marker = Path.Combine(directory, "launches.txt");
            var command = "Add-Content -LiteralPath '" + marker.Replace("'", "''") + "' -Value launched\nStart-Sleep -Milliseconds 900";
            await Registry([new { name = "launch", port = 8100, startCommand = command, workingDirectory = directory }]);
            listeners = new(now, [], []);
            using var cancelled = new CancellationTokenSource(); cancelled.Cancel();
            try { await monitor.ReadAsync(cancelled.Token); throw new Exception("Cancelled query completed"); }
            catch (OperationCanceledException) { }
            var requestID = Guid.NewGuid().ToString("D");
            var parameters = JsonSerializer.SerializeToElement(new { name = "launch", requestId = requestID });
            var reply = await monitor.StartAsync(parameters, default);
            if (reply.State != "starting") throw new Exception("Launch did not return submitted state");
            var repeated = await monitor.StartAsync(JsonSerializer.SerializeToElement(new { name = "launch", requestId = Guid.NewGuid().ToString("D") }), default);
            if (repeated.State != "starting") throw new Exception("Concurrent start was not deduplicated");
            var deadline = DateTime.UtcNow.AddSeconds(10);
            while (DateTime.UtcNow < deadline && (await monitor.ReadAsync(default)).Services[0].Startup?.State == "starting") await Task.Delay(100);
            var complete = (await monitor.ReadAsync(default)).Services[0];
            if (complete.Startup?.State != "exited" || !complete.CanStart || !File.Exists(marker) || File.ReadAllLines(marker).Length != 1)
                throw new Exception("Real detached startup or completion tracking failed");
            using var reopened = new RegisteredServices(registry, _ => Task.FromResult(listeners), startupDirectory: startup);
            if ((await reopened.StartAsync(parameters, default)).State != "exited" || File.ReadAllLines(marker).Length != 1)
                throw new Exception("A replay after Agent restart executed the command twice");
            var scope = Directory.GetDirectories(startup).Single();
            var latest = Directory.GetFiles(scope, "service-*.json").Single();
            File.Delete(Path.Combine(scope, requestID + ".exit"));
            var recovered = (await monitor.ReadAsync(default)).Services[0];
            if (recovered.Startup?.State != "exited" || !recovered.CanStart)
                throw new Exception("An exited process without a completion receipt must not permanently block restart");
            if ((await reopened.StartAsync(parameters, default)).State != "exited" || File.ReadAllLines(marker).Length != 1)
                throw new Exception("Recovering a missing completion receipt must preserve request replay protection");
            var originalReceipt = await File.ReadAllTextAsync(latest);
            using (var current = Process.GetCurrentProcess())
            {
                async Task Receipt(long? ticks) => await File.WriteAllTextAsync(latest, JsonSerializer.Serialize(new {
                    name = "launch", requestId = requestID, state = "submitted", requestedAt = now,
                    processId = current.Id, processStartedAt = ticks
                }));
                await Receipt(current.StartTime.ToUniversalTime().Ticks);
                if ((await monitor.ReadAsync(default)).Services[0].CanStart)
                    throw new Exception("A live startup process must still block a duplicate start");
                await Receipt(current.StartTime.ToUniversalTime().Ticks - 1);
                if (!(await monitor.ReadAsync(default)).Services[0].CanStart)
                    throw new Exception("A reused process ID must not be treated as the original startup process");
                await Receipt(null);
                var unknown = (await monitor.ReadAsync(default)).Services[0];
                if (unknown.CanStart || unknown.Startup?.State != "unknown")
                    throw new Exception("Missing process identity must not authorize another start");
            }
            await File.WriteAllTextAsync(latest, originalReceipt);
            listeners = new(now, [], ["TCP IPv6 端口读取失败，结果可能不完整。"]);
            if ((await monitor.ReadAsync(default)).Services[0].CanStart)
                throw new Exception("A recovered process must not bypass an incomplete listener table");
            listeners = new(now, [Port(8100)], []);
            if ((await monitor.StartAsync(JsonSerializer.SerializeToElement(new { name = "launch", requestId = Guid.NewGuid().ToString("D") }), default)).State != "already_listening")
                throw new Exception("An occupied port did not prevent launch");
            listeners = new(now, [], []);
            var retry = await monitor.StartAsync(JsonSerializer.SerializeToElement(new { name = "launch", requestId = Guid.NewGuid().ToString("D") }), default);
            if (retry.State != "starting") throw new Exception("A confirmed exited startup must allow a new request");
            deadline = DateTime.UtcNow.AddSeconds(10);
            while (DateTime.UtcNow < deadline && (await monitor.ReadAsync(default)).Services[0].Startup?.State == "starting") await Task.Delay(100);
            if (File.ReadAllLines(marker).Length != 2 || (await monitor.ReadAsync(default)).Services[0].Startup?.State != "exited")
                throw new Exception("Recovered startup did not run exactly one additional command");
            await ExpectError("invalid_params", async () => await monitor.StartAsync(JsonSerializer.SerializeToElement(new { name = "launch", requestId = requestID, command = "injected" }), default));
            await ExpectError("service_not_registered", async () => await monitor.StartAsync(JsonSerializer.SerializeToElement(new { name = "absent", requestId = Guid.NewGuid().ToString("D") }), default));
            listeners = new(now, [], []);
            await Registry([new { name = "no-command", port = 8100 }]);
            await ExpectError("start_command_missing", async () => await monitor.StartAsync(JsonSerializer.SerializeToElement(new { name = "no-command", requestId = Guid.NewGuid().ToString("D") }), default));
            Console.WriteLine("PASS: service registry reload/validation/privacy, health probes, detached startup, missing completion recovery, PID reuse, restart replay and duplicate/occupied-port protection");
        }
        finally
        {
            var expectedRoot = Path.GetFullPath(Path.GetTempPath()) + "hako-services-";
            if (!Path.GetFullPath(directory).StartsWith(expectedRoot, StringComparison.OrdinalIgnoreCase)) throw new Exception("Unsafe fixture cleanup");
            Directory.Delete(directory, true);
        }
    }
}
