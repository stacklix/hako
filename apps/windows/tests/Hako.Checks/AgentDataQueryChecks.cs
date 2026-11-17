using System;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Net.Http;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Hako.Core;

internal static class AgentDataQueryChecks
{
    private sealed class Handler(Func<HttpRequestMessage, Task<HttpResponseMessage>> respond) : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token) => respond(request);
    }
    private static void Check(bool value, string message) { if (!value) throw new Exception(message); }
    public static async Task RunAsync()
    {
        using var rsa = RSA.Create(2048);
        var settings = new AgentSettings("https://example.com", "owner", rsa.ExportPkcs8PrivateKeyPem());
        var nonces = new HashSet<string>();
        Handler Server(string operation, string sql, HttpStatusCode status = HttpStatusCode.OK, string result = "{\"columns\":[\"v\"],\"rows\":[[1]],\"hasMore\":true}") => new(async request => {
            Check(request.RequestUri?.AbsoluteUri == "https://example.com/api/v1/agents/data-query", "Wrong endpoint");
            Check(!request.Headers.Contains("Origin"), "Native query must not send browser Origin");
            using var envelope = JsonDocument.Parse(await request.Content!.ReadAsByteArrayAsync());
            var body = envelope.RootElement;
            var payload = body.GetProperty("payload").GetString()!;
            var keyId = body.GetProperty("keyId").GetString()!;
            var proof = Encoding.UTF8.GetBytes("hako-agent-data/v1\nhttps://example.com\nowner\n" + keyId + "\n" + payload);
            Check(rsa.VerifyData(proof, Convert.FromBase64String(body.GetProperty("signature").GetString()!), HashAlgorithmName.SHA256, RSASignaturePadding.Pss), "Invalid RSA signature");
            using var decoded = JsonDocument.Parse(Convert.FromBase64String(payload));
            Check(decoded.RootElement.GetProperty("operation").GetString() == operation && decoded.RootElement.GetProperty("sql").GetString() == sql, "Query payload changed");
            var nonce = decoded.RootElement.GetProperty("nonce").GetString()!;
            Check(nonce.Length == 43 && nonces.Add(nonce), "Missing fresh proof nonce");
            Check(Math.Abs(decoded.RootElement.GetProperty("issuedAt").GetInt64() - DateTimeOffset.UtcNow.ToUnixTimeSeconds()) < 5, "Missing proof timestamp");
            return new HttpResponseMessage(status) { Content = new StringContent(result, Encoding.UTF8, "application/json") };
        });
        var query = CliParser.Parse(["server", "query", "--sql", "SELECT 1", "--limit", "1", "--offset", "2", "--json"]).Request!;
        var reply = await AgentDataQuery.ExecuteAsync(settings, query, CancellationToken.None, Server("query", "SELECT 1"));
        Check(reply.ExitCode == 0 && reply.Data!.Value.GetProperty("hasMore").GetBoolean(), "Query response/pagination lost");
        reply = await AgentDataQuery.ExecuteAsync(settings, query, CancellationToken.None, Server("query", "SELECT 1", HttpStatusCode.Forbidden, "{\"error\":\"agent_data_query_disabled\"}"));
        Check(reply.ExitCode == 1 && reply.ErrorCode == "agent_data_query_disabled" && reply.Text.Contains("管理员"), "Permission failure not explained");
        reply = await AgentDataQuery.ExecuteAsync(settings, query, CancellationToken.None, Server("query", "SELECT 1", HttpStatusCode.Redirect));
        Check(reply.ExitCode == 1 && reply.Text.Contains("重定向"), "Redirect was accepted");
        var schema = CliParser.Parse(["server", "schema"]).Request!;
        Check((await AgentDataQuery.ExecuteAsync(settings, schema, CancellationToken.None, Server("schema", ""))).ExitCode == 0, "Schema query failed");
        var path = Path.Combine(Path.GetTempPath(), "hako-query-" + Guid.NewGuid().ToString("N") + ".sql");
        try {
            await File.WriteAllTextAsync(path, "SELECT '中文'", new UTF8Encoding(false));
            var fileQuery = CliParser.Parse(["server", "query", "--sql-file", path]).Request!;
            Check((await AgentDataQuery.ExecuteAsync(settings, fileQuery, CancellationToken.None, Server("query", "SELECT '中文'"))).ExitCode == 0, "UTF-8 SQL file failed");
        } finally { File.Delete(path); }
        foreach (var args in new[] {
            new[] {"server", "query"}, new[] {"server", "query", "--sql", "SELECT 1", "--sql-file", "file"},
            new[] {"server", "query", "--sql", "SELECT 1", "--limit", "201"}, new[] {"server", "query", "--sql", "SELECT 1", "--offset", "-1"},
            new[] {"server", "schema", "--sql", "SELECT 1"}
        }) {
            try { CliParser.Parse(args); throw new Exception("Invalid server query arguments accepted"); } catch (CliUsageException) { }
        }
        Console.WriteLine("PASS: Agent CLI data query proof, read-only API transport, permission errors, redirects, schema, UTF-8 SQL and pagination");
    }
}
