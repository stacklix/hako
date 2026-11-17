using System;
using System.Collections.Generic;
using System.Collections.Concurrent;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Security.Cryptography;
using System.Text;
using System.Threading;

namespace Hako.Platform;

internal sealed class WorkshopDiagnosticReports
{
    private static readonly ConcurrentDictionary<string, WorkshopDiagnosticReports> instances = new(StringComparer.OrdinalIgnoreCase);
    internal static WorkshopDiagnosticReports ForProfile(string profile) => instances.GetOrAdd(Path.GetFullPath(profile), value => new(value));
    private readonly object gate = new();
    private readonly Mutex processGate;
    private readonly string path, cursorPath;
    private readonly HashSet<string> received = new();
    private readonly Queue<string> recent = new();
    internal long ServerCursor { get; private set; }
    internal WorkshopDiagnosticReports(string profile)
    {
        processGate = new Mutex(false, "Local\\Hako.WorkshopDiagnostics." + Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(Path.GetFullPath(profile).ToUpperInvariant())))[..32]);
        path = Path.Combine(profile, "logs", "remote-workshop.jsonl");
        cursorPath = path + ".server-cursor";
        try
        {
            if (File.Exists(cursorPath) && long.TryParse(File.ReadAllText(cursorPath), out var saved)) ServerCursor = saved;
            foreach (var file in new[] { path + ".previous", path })
            {
                if (!File.Exists(file) || new FileInfo(file).Length > 1_100_000) continue;
                foreach (var line in File.ReadLines(file))
                {
                    try { using var row = JsonDocument.Parse(line); if (row.RootElement.TryGetProperty("id", out var id) && id.ValueKind == JsonValueKind.String) Remember(id.GetString()!); }
                    catch (JsonException) { }
                }
            }
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { /* Reporting remains independent of Agent startup. */ }
    }
    private void Remember(string id)
    {
        if (!received.Add(id)) return;
        recent.Enqueue(id);
        while (recent.Count > 2048) received.Remove(recent.Dequeue());
    }
    private bool Append(string id, string source, JsonElement payload)
    {
        if (received.Contains(id)) return false;
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        if (File.Exists(path) && new FileInfo(path).Length >= 1_048_576) File.Move(path, path + ".previous", true);
        File.AppendAllText(path, JsonSerializer.Serialize(new { receivedAt = DateTimeOffset.UtcNow, id, source, payload }, WorkshopProtocol.Json) + "\n");
        Remember(id);
        return true;
    }
    internal object AppendIOS(JsonElement parameters)
    {
        CodexJson.Keys(parameters, "records");
        var records = parameters.GetProperty("records");
        if (records.ValueKind != JsonValueKind.Array || records.GetArrayLength() > 8) throw CodexJson.Invalid();
        // Validate the entire batch before writing; persist only typed metadata.
        var prepared = new List<(string Id, JsonElement Payload)>();
        foreach (var row in records.EnumerateArray())
        {
            CodexJson.Keys(row, "id", "time", "event", "detail");
            if (!Guid.TryParse(CodexJson.Text(row, "id"), out var id) || !row.GetProperty("time").TryGetDateTimeOffset(out var time)) throw CodexJson.Invalid();
            var name = CodexJson.Text(row, "event");
            if (name is not ("connected" or "closed" or "disconnected" or "connection_failed" or "request_failed" or "subscription_failed" or "sync_failed" or "sync_recovered")) throw CodexJson.Invalid();
            var detail = CodexJson.Text(row, "detail");
            if (detail.Length > 1800) throw CodexJson.Invalid();
            var metadata = new Dictionary<string, object>();
            foreach (var part in detail.Split(';', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries))
            {
                var pair = part.Split('=', 2);
                if (pair.Length != 2) continue;
                if (pair[0] is "connection" or "subscription" or "request" or "operation")
                { if (Guid.TryParse(pair[1], out var value)) metadata[pair[0]] = value.ToString(); }
                else if (pair[0] is "closeCode" or "uptimeMs" or "pending" or "subscriptions" or "downtimeMs" or "elapsedMs" or "cursor" or "failures")
                { if (long.TryParse(pair[1], NumberStyles.Integer, CultureInfo.InvariantCulture, out var value)) metadata[pair[0]] = value; }
                else if (pair[0] == "error" && Regex.IsMatch(pair[1], @"^(cancelled|(NSURLErrorDomain|NSPOSIXErrorDomain|NSCocoaErrorDomain|other)/-?\d+|workshop/(query_timeout|process_unavailable|process_disconnected|computer_offline|workshop_timeout|workshop_busy|workshop_disconnected|codex_connection_closed|stream_overflow|invalid_request|unsupported_method|other))$"))
                    metadata["error"] = pair[1];
            }
            prepared.Add(("ios:" + id.ToString(), JsonSerializer.SerializeToElement(new { time, @event = name, metadata }, WorkshopProtocol.Json)));
        }
        lock (gate)
        {
            EnterProcessGate();
            try { foreach (var row in prepared) Append(row.Id, "ios", row.Payload); }
            finally { processGate.ReleaseMutex(); }
        }
        return new { accepted = prepared.Count };
    }
    internal void AppendServer(JsonElement records)
    {
        if (records.ValueKind != JsonValueKind.Array || records.GetArrayLength() > 16) throw CodexJson.Invalid();
        lock (gate)
        {
            EnterProcessGate();
            try {
            foreach (var row in records.EnumerateArray())
            {
                var sequence = row.GetProperty("sequence").GetInt64();
                if (sequence <= ServerCursor) continue;
                var payload = row.GetProperty("payload");
                CodexJson.Keys(payload, "time", "connectionId", "role", "event", "elapsedMs", "errorClass", "timeout", "closeCode");
                if (payload.GetRawText().Length > 4096) throw CodexJson.Invalid();
                Append("server:" + sequence.ToString(CultureInfo.InvariantCulture), "server", payload);
                var temporary = cursorPath + ".tmp";
                File.WriteAllText(temporary, sequence.ToString(CultureInfo.InvariantCulture));
                File.Move(temporary, cursorPath, true);
                ServerCursor = sequence;
            }
            } finally { processGate.ReleaseMutex(); }
        }
    }
    private void EnterProcessGate()
    {
        try { if (!processGate.WaitOne(TimeSpan.FromSeconds(2))) throw new IOException("Diagnostic writer busy"); }
        catch (AbandonedMutexException) { /* This process now owns the mutex. */ }
    }
}
