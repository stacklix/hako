using System;
using System.IO;
using System.Linq;
using System.Net.Http;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Hako.Core;
using Hako.Platform;

internal static class AgentLanChecks
{
    internal static async Task RunInstalledAsync(string profile)
    {
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(15));
        var state = await LocalRpc.CallAsync(LocalRpc.MainPipe(profile),
            new("agent", AgentLanEndpoint.Command, 1, JsonSerializer.SerializeToElement(new { })), timeout.Token);
        if (!state.GetProperty("enabled").GetBoolean()) throw new Exception("Installed LAN listener is disabled.");
        var key = Convert.FromBase64String(state.GetProperty("token").GetString()!);
        var port = state.GetProperty("port").GetInt32();
        var address = state.GetProperty("addresses").EnumerateArray().Select(item => item.GetString())
            .FirstOrDefault(value => System.Net.IPAddress.TryParse(value, out var parsed) && AgentLanEndpoint.IsPrivateIPv4(parsed))
            ?? throw new Exception("Installed Kage did not advertise a private IPv4 address.");
        var id = Guid.NewGuid().ToString();
        var plain = JsonSerializer.SerializeToUtf8Bytes(new { id, timestamp = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds(),
            method = "query.all", version = 1, @params = new { } });
        using var http = new HttpClient(new SocketsHttpHandler { UseProxy = false, AllowAutoRedirect = false });
        using var content = new StringContent(JsonSerializer.Serialize(new { version = 1,
            payload = Convert.ToBase64String(AgentLanEndpoint.Seal(key, plain, "request")) }), Encoding.UTF8, "application/json");
        using var response = await http.PostAsync($"http://{address}:{port}/agent/v1/query", content, timeout.Token);
        response.EnsureSuccessStatusCode();
        using var wire = JsonDocument.Parse(await response.Content.ReadAsByteArrayAsync(timeout.Token));
        using var result = JsonDocument.Parse(AgentLanEndpoint.Open(key,
            Convert.FromBase64String(wire.RootElement.GetProperty("payload").GetString()!), "response"));
        var entries = result.RootElement.GetProperty("result").GetProperty("data");
        if (result.RootElement.GetProperty("id").GetString() != id || !entries.TryGetProperty("query.system.metrics", out _)
            || entries.TryGetProperty("query.codex.usage", out _)) throw new Exception("Installed LAN aggregate returned invalid state/history.");
        Console.WriteLine($"Installed Kage LAN encrypted aggregate passed on port {port}; private IPv4 interfaces={state.GetProperty("addresses").GetArrayLength()}; credentials omitted.");
    }
    private sealed class Dispatcher : IAgentDispatcher
    {
        public int Calls;
        public System.Collections.Generic.IReadOnlyList<AgentCapability> Capabilities => [new("query.fixture", 1)];
        public Task<object?> InvokeAsync(string method, int version, JsonElement parameters, CancellationToken token)
        { Calls++; return Task.FromResult<object?>(new { value = "局域网数据", method }); }
        public Task RunTelemetryAsync(Func<string, CapabilityData, Task> publish, CancellationToken token) => Task.CompletedTask;
        public ValueTask DisposeAsync() => ValueTask.CompletedTask;
    }
    internal static async Task RunAsync()
    {
        var vector = Convert.FromBase64String("AAECAwQFBgcICQoLC0OYO6aXrWj+bOfn0J0eAvG7p0CVCCsC7CiLRe9PkYVIZxJY51fa");
        var vectorKey = System.Linq.Enumerable.Range(0, 32).Select(value => (byte)value).ToArray();
        if (Encoding.UTF8.GetString(AgentLanEndpoint.Open(vectorKey, vector, "request")) != "LAN cross-platform test")
            throw new Exception("LAN cross-platform vector failed.");
        var dispatcher = new Dispatcher();
        var lan = new AgentLanEndpoint(dispatcher);
        var directory = Path.Combine(Path.GetTempPath(), "hako-lan-" + Guid.NewGuid().ToString("N"));
        try
        {
            await using var workshop = new WorkshopDispatcher(directory);
            await using var server = new WorkshopLocalServer(workshop, 0, () => "fixture", directory, lan: lan);
            lan.Port = server.Port;
            var key = Convert.FromBase64String(JsonSerializer.SerializeToElement(lan.Snapshot()).GetProperty("token").GetString()!);
            using var http = new HttpClient(new SocketsHttpHandler { UseProxy = false, AllowAutoRedirect = false }) { Timeout = TimeSpan.FromSeconds(4) };
            var id = Guid.NewGuid().ToString();
            byte[] Body(string method, long? timestamp = null, byte[]? secret = null) => JsonSerializer.SerializeToUtf8Bytes(new {
                version = 1, payload = Convert.ToBase64String(AgentLanEndpoint.Seal(secret ?? key,
                    JsonSerializer.SerializeToUtf8Bytes(new { id, timestamp = timestamp ?? DateTimeOffset.UtcNow.ToUnixTimeMilliseconds(), method, version = 1, @params = new { } }), "request")) });
            async Task<JsonElement> Send(byte[] body)
            {
                using var content = new ByteArrayContent(body);
                using var response = await http.PostAsync($"http://127.0.0.1:{server.Port}/agent/v1/query", content);
                response.EnsureSuccessStatusCode();
                using var wire = JsonDocument.Parse(await response.Content.ReadAsByteArrayAsync());
                var encrypted = Convert.FromBase64String(wire.RootElement.GetProperty("payload").GetString()!);
                return JsonDocument.Parse(AgentLanEndpoint.Open(key, encrypted, "response")).RootElement.Clone();
            }
            var result = await Send(Body("query.fixture"));
            if (result.GetProperty("id").GetString() != id || result.GetProperty("result").GetProperty("value").GetString() != "局域网数据")
                throw new Exception("LAN encryption or correlation failed.");
            foreach (var method in new[] { "action.sms.send", "admin.services.start" })
                if ((await Send(Body(method))).GetProperty("error").GetProperty("code").GetString() != "query_only")
                    throw new Exception("LAN executed a non-query command.");
            if (dispatcher.Calls != 1) throw new Exception("Rejected LAN action reached the dispatcher.");
            foreach (var body in new[] { Body("query.fixture", 1), Body("query.fixture", secret: new byte[32]), Encoding.UTF8.GetBytes("{}") })
            {
                try { await Send(body); throw new Exception("Unauthenticated/expired LAN request accepted."); }
                catch (HttpRequestException) { }
            }
            var sealedBytes = AgentLanEndpoint.Seal(key, "hello"u8.ToArray(), "request");
            try { AgentLanEndpoint.Open(key, sealedBytes, "response"); throw new Exception("Reflected LAN response accepted."); }
            catch (CryptographicException) { }
            sealedBytes[^1] ^= 1;
            try { AgentLanEndpoint.Open(key, sealedBytes, "request"); throw new Exception("Modified ciphertext accepted."); }
            catch (CryptographicException) { }
            Console.WriteLine("LAN query roundtrip, authentication, action boundary, expiry and tamper checks passed.");
        }
        finally
        {
            if (Directory.Exists(directory) && Path.GetFileName(directory).StartsWith("hako-lan-", StringComparison.Ordinal)) Directory.Delete(directory, true);
        }
    }
}
