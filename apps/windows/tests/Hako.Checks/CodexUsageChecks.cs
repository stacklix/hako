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
    private static string Message(string id, string timestamp, string turn = "turn-A", string[]? kinds = null) => JsonSerializer.Serialize(new
    {
        timestamp, type = "response_item", payload = new { type = "message", role = "user", id,
            internal_chat_message_metadata_passthrough = JsonSerializer.Serialize(new { turn_id = turn,
                create_time = DateTimeOffset.Parse(timestamp).ToUnixTimeMilliseconds() / 1000.0, content_item_kinds = kinds ?? new[] { "user.text" } }) }
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
            Message("old-human", "2026-10-21T15:59:59Z", "old-turn"),
            Usage("too-old", "2026-10-21T15:59:59Z"),
            Message("first-human", "2026-10-21T16:00:00Z", "first-turn"),
            Usage("first", "2026-10-21T16:00:00Z"),
            "{\"timestamp\":\"2026-10-27T16:01:00Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"task_started\",\"turn_id\":\"turn-A\"}}",
            Message("auto-context", "2026-10-27T16:01:00Z", kinds: new[] { "agents_md.instructions", "environments.environment_context" }),
            Message("today-human", "2026-10-27T16:01:00Z", kinds: new[] { "user.text", "user.image", "user.image" }),
            Usage("today", "2026-10-27T16:01:00Z"),
            Legacy("2026-10-27T16:01:00Z", 100),
            "{\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"content\":\"PRIVATE_BODY_MUST_NOT_BE_SAVED\"}}"
        }) + "\n");
        await File.WriteAllTextAsync(Path.Combine(archive, "duplicate.jsonl"), Message("today-human", "2026-10-27T16:01:00Z") + "\n"
            + Usage("today", "2026-10-27T16:01:00Z") + "\n"
            + "{\"type\":\"session_meta\",\"payload\":{\"source\":{\"subagent\":{\"other\":\"guardian\"}}}}\n"
            + Message("internal-human-role", "2026-10-28T01:00:00Z") + "\n" + Usage("child", "2026-10-28T01:00:00Z", 50, 5) + "\n");
        await using (var collector = new CodexUsage(home, cache, zone, () => now))
        {
            var result = await collector.CollectAsync(CancellationToken.None);
            if (!result.Available || result.Days.Count != 7 || result.Days[0].Date != "2026-10-22"
                || result.RequestCountKind != "user_messages" || result.Days[0].RequestCount != 1 || result.Days[6].RequestCount != 1 || result.Days[6].TotalTokens != 165
                || result.Days[6].InputTokens != 150 || result.RunningSessions is not null || result.RunningSessionDetails is not null || result.Warnings.Any(w => w.Contains("估算")))
                throw new Exception("Codex daily boundaries, response deduplication, subset tokens or missing runtime status are incorrect");
            await File.AppendAllTextAsync(path, Usage("another-model-request", "2026-10-28T00:10:00Z", 40, 4) + "\n");
            result = await collector.CollectAsync(CancellationToken.None);
            if (result.Days[6].RequestCount != 1 || result.Days[6].TotalTokens != 209)
                throw new Exception("Multiple model iterations must not increase the number of user calls");
            await File.AppendAllTextAsync(path, Message("steer-human", "2026-10-28T00:30:00Z") + "\n");
            await File.AppendAllTextAsync(path, Usage("today", "2026-10-28T01:00:00Z", 120, 12) + "\n");
            result = await collector.CollectAsync(CancellationToken.None);
            if (result.Days[6].TotalTokens != 231 || result.Days[6].RequestCount != 2)
                throw new Exception("Final usage update for the same response was lost or double-counted");
            var partial = Message("partial-human", "2026-10-28T12:00:01Z", "second-turn");
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
        var oldCache = System.Text.Json.Nodes.JsonNode.Parse(stored)!;
        oldCache["Version"] = 3;
        oldCache.AsObject().Remove("UserCalls"); oldCache.AsObject().Remove("UserTurns"); oldCache.AsObject().Remove("TaskStarts");
        var oldCachePath = Path.Combine(directory, "old-cache.json");
        await File.WriteAllTextAsync(oldCachePath, oldCache.ToJsonString());
        await using (var migrated = new CodexUsage(home, oldCachePath, zone, () => now))
        {
            var migratedResult = await migrated.CollectAsync(CancellationToken.None);
            if (migratedResult.Days[0].TotalTokens != 110 || migratedResult.Days[6].TotalTokens != 231
                || migratedResult.Days[6].RequestCount != 1 || !migratedResult.Warnings.Any(w => w.Contains("调用数已改")))
                throw new Exception("Count migration must preserve deleted-source token history and rebuild only real user messages");
        }
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
        var legacy = "{\"timestamp\":\"2026-11-05T01:00:00Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"task_started\",\"turn_id\":\"legacy-turn\"}}\n"
            + Legacy("2026-11-05T01:00:00Z", 100) + "\n" + Legacy("2026-11-05T01:00:01Z", 100) + "\n"
            + Legacy("2026-11-05T01:00:02Z", 200) + "\n";
        await File.WriteAllTextAsync(Path.Combine(legacyHome, "sessions", "one.jsonl"), legacy);
        await File.WriteAllTextAsync(Path.Combine(legacyHome, "sessions", "fork.jsonl"), legacy);
        foreach (var log in Directory.EnumerateFiles(Path.Combine(legacyHome, "sessions"))) File.SetLastWriteTimeUtc(log, now.UtcDateTime);
        await using (var collector = new CodexUsage(legacyHome, zone: zone, clock: () => now))
        {
            var result = await collector.CollectAsync(CancellationToken.None);
            if (result.Days.Sum(d => d.RequestCount) != 1 || !result.Warnings.Any(w => w.Contains("估算")))
                throw new Exception("Legacy cumulative duplicates or inherited fork records were double-counted");
            await File.AppendAllTextAsync(Path.Combine(legacyHome, "sessions", "one.jsonl"),
                "{\"timestamp\":\"2026-11-05T01:05:00Z\",\"type\":\"token_usage_record\",\"payload\":{\"response_id\":\"total-only\",\"usage\":{\"total_tokens\":999}}}\n");
            result = await collector.CollectAsync(CancellationToken.None);
            if (result.Days[^1].TotalTokens != 1219 || result.Days[^1].RequestCount != 1 || result.Days[^1].BreakdownAvailable)
                throw new Exception("Legacy total-only usage must preserve request/total counts without inventing a breakdown");
        }
        var mixedHome = Path.Combine(directory, "mixed"); Directory.CreateDirectory(Path.Combine(mixedHome, "sessions"));
        var modernPath = Path.Combine(mixedHome, "sessions", "modern.jsonl");
        await File.WriteAllTextAsync(modernPath, Message("mixed-human", "2026-11-05T01:00:00Z") + "\n" + Usage("mixed-response", "2026-11-05T01:00:00Z") + "\n");
        File.SetLastWriteTimeUtc(modernPath, now.UtcDateTime);
        await using (var collector = new CodexUsage(mixedHome, zone: zone, clock: () => now))
        {
            await collector.CollectAsync(CancellationToken.None);
            var inherited = Path.Combine(mixedHome, "sessions", "inherited.jsonl");
            await File.WriteAllTextAsync(inherited, "{\"timestamp\":\"2026-11-05T01:00:00Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"task_started\",\"turn_id\":\"turn-A\"}}\n" + Legacy("2026-11-05T01:00:00Z", 100) + "\n");
            File.SetLastWriteTimeUtc(inherited, now.UtcDateTime);
            if ((await collector.CollectAsync(CancellationToken.None)).Days.Sum(d => d.RequestCount) != 1)
                throw new Exception("An inherited legacy token event duplicated an already known exact request");
        }
        await File.WriteAllTextAsync(cache, "{\"Version\":1,\"Files\":null}");
        await using (var collector = new CodexUsage(home, cache, zone, () => now))
            if (!(await collector.CollectAsync(CancellationToken.None)).Warnings.Any(w => w.Contains("缓存不可用")))
                throw new Exception("Invalid cache was silently accepted");
        await CheckMirroredUsage(directory, zone, now);
        await CheckRunningSessions(home, zone, now);
        Console.WriteLine("PASS: Codex seven-day requests/tokens, timezone boundaries, exact/legacy deduplication, partial writes, persistence, retention, privacy and live/stale session locks");
    }

    private static async Task CheckMirroredUsage(string directory, TimeZoneInfo zone, DateTimeOffset now)
    {
        var home = Path.Combine(directory, "mirrors"); Directory.CreateDirectory(Path.Combine(home, "sessions"));
        var path = Path.Combine(home, "sessions", "one.jsonl"); var cache = Path.Combine(directory, "mirrors.json");
        string Exact(string id, string at, string turn) => JsonSerializer.Serialize(new { timestamp = at, type = "token_usage_record",
            payload = new { response_id = id, turn_id = turn, usage = Tokens(), thread_token_usage = Tokens(9000, 900) } });
        await File.WriteAllTextAsync(path,
            "{\"type\":\"session_meta\",\"payload\":{\"id\":\"mirror-session\"}}\n"
            + "{\"type\":\"turn_context\",\"payload\":{\"turn_id\":\"turn-A\"}}\n"
            + Legacy("2026-11-05T01:00:00Z", 100) + "\n" + Exact("one", "2026-11-05T01:00:02Z", "turn-A") + "\n"
            + "{\"type\":\"turn_context\",\"payload\":{\"turn_id\":\"turn-B\"}}\n"
            + "{\"timestamp\":\"2026-11-05T01:00:03Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"input_tokens\":100,\"cached_input_tokens\":20,\"output_tokens\":10,\"reasoning_output_tokens\":5,\"total_tokens\":110},\"last_token_usage\":{\"total_tokens\":55}}}}\n"
            + Legacy("2026-11-05T01:00:04Z", 200) + "\n");
        File.SetLastWriteTimeUtc(path, now.UtcDateTime);
        await using (var collector = new CodexUsage(home, cache, zone, () => now))
        {
            var result = await collector.CollectAsync(CancellationToken.None);
            if (result.Days[^1].TotalTokens != 220 || !result.Days[^1].BreakdownAvailable || result.Warnings.Any(w => w.Contains("只有 token 总量")))
                throw new Exception("Divergent cumulative streams or a replayed zero-breakdown snapshot inflated usage");
            await File.AppendAllTextAsync(path, Exact("two", "2026-11-05T01:00:05Z", "turn-B") + "\n"
                + Legacy("2026-11-05T01:00:06Z", 300) + "\n");
            result = await collector.CollectAsync(CancellationToken.None);
            if (result.Days[^1].TotalTokens != 330)
                throw new Exception("Matching a mirror also removed a separate legacy request with identical token values");
            await File.AppendAllTextAsync(path, Exact("three", "2026-11-05T01:00:07Z", "turn-B") + "\n");
            result = await collector.CollectAsync(CancellationToken.None);
            if (result.Days[^1].TotalTokens != 330 || result.Warnings.Any(w => w.Contains("日志更新记录")))
                throw new Exception("A delayed precise response did not replace its compatibility mirror");
        }
        await using (var collector = new CodexUsage(home, cache, zone, () => now))
            if ((await collector.CollectAsync(CancellationToken.None)).Days[^1].TotalTokens != 330)
                throw new Exception("Mirror pairing was not stable across cached restarts");
        var old = System.Text.Json.Nodes.JsonNode.Parse(await File.ReadAllTextAsync(cache))!;
        old["Version"] = 4;
        foreach (var item in old["Requests"]!.AsObject())
        { item.Value!.AsObject().Remove("TurnId"); item.Value.AsObject().Remove("PreviousUsages"); }
        old["Requests"]!["legacy:turn-B:100:20:10:5:110"] = System.Text.Json.Nodes.JsonNode.Parse(
            "{\"At\":\"2026-11-05T01:00:03Z\",\"Usage\":{\"Input\":0,\"Cached\":0,\"Output\":0,\"Reasoning\":0,\"Total\":55,\"BreakdownAvailable\":false},\"Estimated\":true}");
        old["Requests"]!["response:deleted-source"] = System.Text.Json.Nodes.JsonNode.Parse(
            "{\"At\":\"2026-11-05T01:00:00Z\",\"Usage\":{\"Input\":7,\"Cached\":0,\"Output\":3,\"Reasoning\":0,\"Total\":10,\"BreakdownAvailable\":true},\"Estimated\":false}");
        await File.WriteAllTextAsync(cache, old.ToJsonString());
        File.SetLastWriteTimeUtc(path, now.UtcDateTime);
        await using (var collector = new CodexUsage(home, cache, zone, () => now))
        {
            var result = await collector.CollectAsync(CancellationToken.None);
            if (result.Days[^1].TotalTokens != 340 || !result.Days[^1].BreakdownAvailable || !result.Warnings.Any(w => w.Contains("去重规则")))
                throw new Exception("Old cache replay failed to repair duplicates while retaining deleted-source usage");
        }
        Console.WriteLine("PASS: divergent usage streams, replay snapshots, one-to-one mirrors, identical real requests, delayed responses and cache repair");
    }

    private static async Task CheckRunningSessions(string home, TimeZoneInfo zone, DateTimeOffset now)
    {
        var active = Guid.NewGuid().ToString(); var stale = Guid.NewGuid().ToString(); var guardian = Guid.NewGuid().ToString();
        var state = Path.Combine(home, "state_5.sqlite");
        CreateDatabase(state, "CREATE TABLE threads(id TEXT,source TEXT,thread_source TEXT,name TEXT,title TEXT,cwd TEXT);"
            + $"INSERT INTO threads VALUES('{active}','vscode','user','调整图表','PRIVATE_INITIAL_PROMPT', 'C:\\Users\\private-user\\Code\\hako\\'),"
            + $"('{stale}','cli','user','stale','PRIVATE_INITIAL_PROMPT','C:\\private'),"
            + $"('{guardian}','vscode','guardian_review','internal','PRIVATE_INITIAL_PROMPT','C:\\private');");
        CreateDatabase(Path.Combine(home, "thread_history_1.sqlite"), "CREATE TABLE thread_turns(thread_id TEXT,status TEXT,completed_at INTEGER);"
            + $"INSERT INTO thread_turns VALUES('{active}','inProgress',NULL),('{active}','inProgress',NULL),('{stale}','inProgress',NULL),('{guardian}','inProgress',NULL);");
        var locks = Path.Combine(home, "thread-writer-locks"); Directory.CreateDirectory(locks);
        using var activeLock = new FileStream(Path.Combine(locks, active + ".lock"), FileMode.Create, FileAccess.ReadWrite, FileShare.ReadWrite | FileShare.Delete);
        using var guardianLock = new FileStream(Path.Combine(locks, guardian + ".lock"), FileMode.Create, FileAccess.ReadWrite, FileShare.ReadWrite | FileShare.Delete);
        activeLock.Lock(0, 1); guardianLock.Lock(0, 1);
        await using var collector = new CodexUsage(home, zone: zone, clock: () => now);
        var result = await collector.CollectAsync(CancellationToken.None);
        if (result.RunningSessions != 1 || result.RunningSessionDetails?.Single() != new CodexRunningSession("调整图表", "hako"))
            throw new Exception("Current active session count includes stale/subagent rows or duplicate turns");
        var payload = JsonSerializer.Serialize(result);
        if (payload.Contains(active) || payload.Contains("private-user") || payload.Contains("PRIVATE_INITIAL_PROMPT"))
            throw new Exception("Runtime details leaked an internal identifier, full path or initial prompt");
        // Updating only the display name must be visible even while the daily snapshot is cached.
        CreateDatabase(state, $"UPDATE threads SET name='新标题' WHERE id='{active}';");
        if ((await collector.ReadAsync(CancellationToken.None)).RunningSessionDetails?.Single().Title != "新标题")
            throw new Exception("Runtime title did not refresh with the current session status");
        activeLock.Unlock(0, 1);
        result = await collector.ReadAsync(CancellationToken.None);
        if (result.RunningSessions != 0 || result.RunningSessionDetails?.Count != 0)
            throw new Exception("Released writer lock did not clear stale inProgress metadata");
        guardianLock.Unlock(0, 1);
        // Older schema still supports the count, without using the initial request as a title.
        CreateDatabase(Path.Combine(home, "state_6.sqlite"), "CREATE TABLE threads(id TEXT,source TEXT,title TEXT);"
            + $"INSERT INTO threads VALUES('{active}','cli','PRIVATE_INITIAL_PROMPT');");
        activeLock.Lock(0, 1);
        result = await collector.ReadAsync(CancellationToken.None);
        if (result.RunningSessionDetails?.Single() != new CodexRunningSession("未命名会话", "未关联项目"))
            throw new Exception("Older metadata schema lost live sessions or exposed the initial message as a title");
        activeLock.Unlock(0, 1);
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
