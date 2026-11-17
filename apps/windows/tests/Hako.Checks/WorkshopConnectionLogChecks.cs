using System;
using System.IO;
using System.Net.WebSockets;
using System.Text.Json;
using Hako.Platform;

internal static class WorkshopConnectionLogChecks
{
    internal static void Run()
    {
        var directory = Path.Combine(Path.GetTempPath(), "hako-connection-log-" + Guid.NewGuid().ToString("N"));
        try
        {
            var log = new WorkshopConnectionLog(directory, false, maximumBytes: 1);
            log.Write("test-connection", "disconnected", "serve", 100, 1, error: new WebSocketException("secret-token-and-message"), closeCode: WebSocketCloseStatus.PolicyViolation);
            log.Write("replacement", "connected", "serve", 1, 2, downtimeMs: 3000);
            var path = Path.Combine(directory, "logs", "workshop-connection.jsonl");
            var previous = File.ReadAllText(path + ".previous");
            if (previous.Contains("secret-token-and-message")) throw new Exception("Connection log leaked exception text");
            using var failed = JsonDocument.Parse(previous);
            if (failed.RootElement.GetProperty("closeCode").GetInt32() != 1008 || failed.RootElement.GetProperty("connectionId").GetString() != "test-connection")
                throw new Exception("Connection failure identity or close code missing");
            using var recovered = JsonDocument.Parse(File.ReadAllText(path));
            if (recovered.RootElement.GetProperty("downtimeMs").GetInt32() != 3000) throw new Exception("Recovery duration missing");
            var reports = new WorkshopDiagnosticReports(directory);
            using var batch = JsonDocument.Parse(JsonSerializer.Serialize(new { records = new[] { new {
                id = Guid.NewGuid(), time = DateTimeOffset.UtcNow, @event = "disconnected",
                detail = "error=NSURLErrorDomain/-1005; authorization=secret-token; connection=" + Guid.NewGuid()
            } } }));
            reports.AppendIOS(batch.RootElement);
            reports.AppendIOS(batch.RootElement);
            var remotePath = Path.Combine(directory, "logs", "remote-workshop.jsonl");
            var remoteLines = File.ReadAllLines(remotePath);
            if (remoteLines.Length != 1 || remoteLines[0].Contains("secret-token")) throw new Exception("Remote report deduplication or metadata filtering failed");
            var restarted = new WorkshopDiagnosticReports(directory);
            restarted.AppendIOS(batch.RootElement);
            if (File.ReadAllLines(remotePath).Length != 1) throw new Exception("Remote report deduplication was not durable");
            using var serverBatch = JsonDocument.Parse("""[{"sequence":12,"payload":{"time":"2026-11-17T00:00:00Z","connectionId":"fixture","role":"client","event":"read_failed","elapsedMs":10}}]""");
            reports.AppendServer(serverBatch.RootElement);
            reports.AppendServer(serverBatch.RootElement);
            if (new WorkshopDiagnosticReports(directory).ServerCursor != 12 || File.ReadAllLines(remotePath).Length != 2)
                throw new Exception("Server report replay or durable cursor failed");
            Console.WriteLine("PASS: connection log privacy, close code, recovery duration and rotation");
        }
        finally { if (Directory.Exists(directory)) Directory.Delete(directory, true); }
    }
}
