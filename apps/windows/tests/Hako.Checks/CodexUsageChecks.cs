using System;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Hako.Platform;

internal static class CodexUsageChecks
{
    private static object Tokens(long input = 100, long output = 10) => new { input_tokens = input, cached_input_tokens = input / 5, output_tokens = output, reasoning_output_tokens = output / 2, total_tokens = input + output };
    private static string Usage(string id, string timestamp, long input = 100, long output = 10) => JsonSerializer.Serialize(new
    {
        timestamp, type = "token_usage_record", payload = new { response_id = id, turn_id = "turn-A", usage = Tokens(input, output), thread_token_usage = Tokens(input, output) }
    });
    private static string Legacy(string timestamp, long input) => JsonSerializer.Serialize(new
    {
        timestamp, type = "event_msg", payload = new { type = "token_count", info = new { total_token_usage = Tokens(input), last_token_usage = Tokens() } }
    });
    public static async Task RunAsync()
    {
        var directory = Path.Combine(Path.GetTempPath(), "hako-codex-usage-" + Guid.NewGuid().ToString("N"));
        var home = Path.Combine(directory, "codex");
        var sessions = Path.Combine(home, "sessions"); var archive = Path.Combine(home, "archived_sessions");
        Directory.CreateDirectory(sessions); Directory.CreateDirectory(archive);
        var cache = Path.Combine(directory, "cache.json");
        var now = DateTimeOffset.Parse("2026-10-28T12:00:00Z");
        var zone = TimeZoneInfo.CreateCustomTimeZone("Test/Plus8", TimeSpan.FromHours(8), "Test", "Test");
        var path = Path.Combine(sessions, "test.jsonl");
        await File.WriteAllTextAsync(path, string.Join("\n", new[] {
            "{\"type\":\"session_meta\",\"payload\":{\"id\":\"session-A\"}}",
            Usage("too-old", "2026-10-21T15:59:59Z"),
            Usage("first", "2026-10-21T16:00:00Z"),
            Usage("today", "2026-10-27T16:01:00Z"),
            Legacy("2026-10-27T16:01:00Z", 100),
            "{\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"content\":\"PRIVATE_BODY_MUST_NOT_BE_SAVED\"}}"
        }) + "\n");
        await File.WriteAllTextAsync(Path.Combine(archive, "duplicate.jsonl"), Usage("today", "2026-10-27T16:01:00Z") + "\n" + Usage("child", "2026-10-28T01:00:00Z", 50, 5) + "\n");
        await using (var collector = new CodexUsage(home, cache, zone, () => now))
        {
            var result = await collector.CollectAsync(CancellationToken.None);
            if (!result.Available || result.Days.Count != 7 || result.Days[0].Date != "2026-10-22"
                || result.Days[0].RequestCount != 1 || result.Days[6].RequestCount != 2 || result.Days[6].TotalTokens != 165
                || result.Days[6].InputTokens != 150 || result.RunningSessions is not null || result.Warnings.Any(w => w.Contains("估算")))
                throw new Exception("Codex daily boundaries, response deduplication, subset tokens or missing runtime status are incorrect");
            await File.AppendAllTextAsync(path, Usage("today", "2026-10-28T01:00:00Z", 120, 12) + "\n");
            if ((await collector.CollectAsync(CancellationToken.None)).Days[6].TotalTokens != 187)
                throw new Exception("Final usage update for the same response was lost or double-counted");
            var partial = Usage("partial", "2026-10-28T12:00:01Z");
            await File.AppendAllTextAsync(path, partial[..(partial.Length / 2)]);
            if ((await collector.CollectAsync(CancellationToken.None)).Days[6].RequestCount != 2)
                throw new Exception("Partially written JSONL record was counted");
            await File.AppendAllTextAsync(path, partial[(partial.Length / 2)..] + "\ninvalid-json\n");
            result = await collector.CollectAsync(CancellationToken.None);
            if (result.Days[6].RequestCount != 3 || !result.Warnings.Any(w => w.Contains("格式无效")))
                throw new Exception("Append recovery or malformed record reporting failed");
            using var cancellation = new CancellationTokenSource(); cancellation.Cancel();
            try { await collector.CollectAsync(cancellation.Token); throw new Exception("Cancellation ignored"); }
            catch (OperationCanceledException) { }
        }
        var stored = await File.ReadAllTextAsync(cache);
        if (stored.Contains("PRIVATE_BODY") || stored.Contains("response_item")) throw new Exception("Conversation body persisted in statistics cache");
        File.Delete(path);
        await using (var resumed = new CodexUsage(home, cache, zone, () => now))
        {
            var result = await resumed.CollectAsync(CancellationToken.None);
            if (result.Days[6].RequestCount != 3 || result.Days[0].RequestCount != 1)
                throw new Exception("Persisted statistics were lost after source deletion or restart");
            now = now.AddDays(8);
            if ((await resumed.CollectAsync(CancellationToken.None)).Days.Any(d => d.RequestCount != 0))
                throw new Exception("Statistics older than seven local dates were retained");
        }
        var legacyHome = Path.Combine(directory, "legacy"); Directory.CreateDirectory(Path.Combine(legacyHome, "sessions"));
        var legacy = "{\"type\":\"event_msg\",\"payload\":{\"type\":\"task_started\",\"turn_id\":\"legacy-turn\"}}\n"
            + Legacy("2026-11-05T01:00:00Z", 100) + "\n" + Legacy("2026-11-05T01:00:01Z", 100) + "\n"
            + Legacy("2026-11-05T01:00:02Z", 200) + "\n";
        await File.WriteAllTextAsync(Path.Combine(legacyHome, "sessions", "one.jsonl"), legacy);
        await File.WriteAllTextAsync(Path.Combine(legacyHome, "sessions", "fork.jsonl"), legacy);
        foreach (var log in Directory.EnumerateFiles(Path.Combine(legacyHome, "sessions"))) File.SetLastWriteTimeUtc(log, now.UtcDateTime);
        await using (var collector = new CodexUsage(legacyHome, zone: zone, clock: () => now))
        {
            var result = await collector.CollectAsync(CancellationToken.None);
            if (result.Days.Sum(d => d.RequestCount) != 2 || !result.Warnings.Any(w => w.Contains("估算")))
                throw new Exception("Legacy cumulative duplicates or inherited fork records were double-counted");
            await File.AppendAllTextAsync(Path.Combine(legacyHome, "sessions", "one.jsonl"),
                "{\"timestamp\":\"2026-11-05T01:05:00Z\",\"type\":\"token_usage_record\",\"payload\":{\"response_id\":\"total-only\",\"usage\":{\"total_tokens\":999}}}\n");
            result = await collector.CollectAsync(CancellationToken.None);
            if (result.Days[^1].TotalTokens != 1219 || result.Days[^1].RequestCount != 3 || result.Days[^1].BreakdownAvailable)
                throw new Exception("Legacy total-only usage must preserve request/total counts without inventing a breakdown");
        }
        var mixedHome = Path.Combine(directory, "mixed"); Directory.CreateDirectory(Path.Combine(mixedHome, "sessions"));
        var modernPath = Path.Combine(mixedHome, "sessions", "modern.jsonl");
        await File.WriteAllTextAsync(modernPath, Usage("mixed-response", "2026-11-05T01:00:00Z") + "\n");
        File.SetLastWriteTimeUtc(modernPath, now.UtcDateTime);
        await using (var collector = new CodexUsage(mixedHome, zone: zone, clock: () => now))
        {
            await collector.CollectAsync(CancellationToken.None);
            var inherited = Path.Combine(mixedHome, "sessions", "inherited.jsonl");
            await File.WriteAllTextAsync(inherited, "{\"type\":\"event_msg\",\"payload\":{\"type\":\"task_started\",\"turn_id\":\"turn-A\"}}\n" + Legacy("2026-11-05T01:00:00Z", 100) + "\n");
            File.SetLastWriteTimeUtc(inherited, now.UtcDateTime);
            if ((await collector.CollectAsync(CancellationToken.None)).Days.Sum(d => d.RequestCount) != 1)
                throw new Exception("An inherited legacy token event duplicated an already known exact request");
        }
        await File.WriteAllTextAsync(cache, "{\"Version\":1,\"Files\":null}");
        await using (var collector = new CodexUsage(home, cache, zone, () => now))
            if (!(await collector.CollectAsync(CancellationToken.None)).Warnings.Any(w => w.Contains("缓存不可用")))
                throw new Exception("Invalid cache was silently accepted");
        await CheckRunningSessions(home, zone, now);
        Console.WriteLine("PASS: Codex seven-day requests/tokens, timezone boundaries, exact/legacy deduplication, partial writes, persistence, retention, privacy and live/stale session locks");
    }

    private static async Task CheckRunningSessions(string home, TimeZoneInfo zone, DateTimeOffset now)
    {
        var active = Guid.NewGuid().ToString(); var stale = Guid.NewGuid().ToString(); var guardian = Guid.NewGuid().ToString();
        CreateDatabase(Path.Combine(home, "state_5.sqlite"), "CREATE TABLE threads(id TEXT,source TEXT);"
            + $"INSERT INTO threads VALUES('{active}','vscode'),('{stale}','cli'),('{guardian}','{{\"subagent\":{{\"other\":\"guardian\"}}}}');");
        CreateDatabase(Path.Combine(home, "thread_history_1.sqlite"), "CREATE TABLE thread_turns(thread_id TEXT,status TEXT,completed_at INTEGER);"
            + $"INSERT INTO thread_turns VALUES('{active}','inProgress',NULL),('{active}','inProgress',NULL),('{stale}','inProgress',NULL),('{guardian}','inProgress',NULL);");
        var locks = Path.Combine(home, "thread-writer-locks"); Directory.CreateDirectory(locks);
        using var activeLock = new FileStream(Path.Combine(locks, active + ".lock"), FileMode.Create, FileAccess.ReadWrite, FileShare.ReadWrite | FileShare.Delete);
        using var guardianLock = new FileStream(Path.Combine(locks, guardian + ".lock"), FileMode.Create, FileAccess.ReadWrite, FileShare.ReadWrite | FileShare.Delete);
        activeLock.Lock(0, 1); guardianLock.Lock(0, 1);
        await using var collector = new CodexUsage(home, zone: zone, clock: () => now);
        if ((await collector.CollectAsync(CancellationToken.None)).RunningSessions != 1)
            throw new Exception("Current active session count includes stale/subagent rows or duplicate turns");
        activeLock.Unlock(0, 1);
        if ((await collector.ReadAsync(CancellationToken.None)).RunningSessions != 0)
            throw new Exception("Released writer lock did not clear stale inProgress metadata");
        guardianLock.Unlock(0, 1);
    }
    private static void CreateDatabase(string path, string sql)
    {
        IntPtr db = IntPtr.Zero;
        try
        {
            if (sqlite3_open(path, out db) != 0 || sqlite3_exec(db, sql, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero) != 0)
                throw new Exception("Cannot create synthetic Codex metadata fixture");
        }
        finally { if (db != IntPtr.Zero) sqlite3_close(db); }
    }
    [DllImport("winsqlite3", CallingConvention = CallingConvention.Cdecl)] private static extern int sqlite3_open([MarshalAs(UnmanagedType.LPUTF8Str)] string path, out IntPtr db);
    [DllImport("winsqlite3", CallingConvention = CallingConvention.Cdecl)] private static extern int sqlite3_exec(IntPtr db, [MarshalAs(UnmanagedType.LPUTF8Str)] string sql, IntPtr callback, IntPtr arg, IntPtr error);
    [DllImport("winsqlite3", CallingConvention = CallingConvention.Cdecl)] private static extern int sqlite3_close(IntPtr db);
}
