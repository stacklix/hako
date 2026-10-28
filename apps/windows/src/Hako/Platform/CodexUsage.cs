using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace Hako.Platform;

public sealed record CodexUsageDay(string Date, long RequestCount, long InputTokens, long CachedInputTokens,
    long OutputTokens, long ReasoningOutputTokens, long TotalTokens, bool BreakdownAvailable);
public sealed record CodexUsageSnapshot(bool Available, string CollectedAt, string TimeZone,
    IReadOnlyList<CodexUsageDay> Days, int? RunningSessions, IReadOnlyList<string> Warnings);

public sealed class CodexUsage : IAsyncDisposable
{
    public sealed record TokenUsage(long Input, long Cached, long Output, long Reasoning, long Total, bool BreakdownAvailable = true);
    public sealed record RequestUsage(DateTimeOffset At, TokenUsage Usage, bool Estimated);
    public sealed class Cursor
    {
        public long Offset { get; set; }
        public string ThreadId { get; set; } = "";
        public string TurnId { get; set; } = "";
        public TokenUsage? Previous { get; set; }
    }
    public sealed class Checkpoint
    {
        public int Version { get; set; } = 3;
        public string Home { get; set; } = "";
        public Dictionary<string, Cursor> Files { get; set; } = new(StringComparer.OrdinalIgnoreCase);
        public Dictionary<string, RequestUsage> Requests { get; set; } = new();
        public Dictionary<string, DateTimeOffset> PreciseAliases { get; set; } = new();
        public DateTimeOffset? IncompleteAt { get; set; }
    }

    private readonly string home;
    private readonly string? cachePath;
    private readonly TimeZoneInfo zone;
    private readonly Func<DateTimeOffset> clock;
    private readonly SemaphoreSlim collection = new(1, 1);
    private readonly CancellationTokenSource stop = new();
    private Task? worker;
    private volatile CodexUsageSnapshot? snapshot;
    private Checkpoint checkpoint;
    private bool cacheInvalid;
    public CodexUsage(string? codexHome = null, string? cachePath = null, TimeZoneInfo? zone = null, Func<DateTimeOffset>? clock = null)
    {
        home = Path.GetFullPath(codexHome ?? Environment.GetEnvironmentVariable("CODEX_HOME")
            ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".codex"));
        this.cachePath = cachePath; this.zone = zone ?? TimeZoneInfo.Local; this.clock = clock ?? (() => DateTimeOffset.UtcNow);
        checkpoint = new Checkpoint { Home = home };
        if (cachePath is not null && File.Exists(cachePath))
        {
            try
            {
                var saved = JsonSerializer.Deserialize<Checkpoint>(File.ReadAllBytes(cachePath));
                if (saved?.Version == 3 && saved.Files is not null && saved.Requests is not null && saved.PreciseAliases is not null
                    && saved.Files.Values.All(c => c is not null && c.Offset >= 0)
                    && saved.Requests.Values.All(r => r is not null && r.Usage is not null)
                    && string.Equals(saved.Home, home, StringComparison.OrdinalIgnoreCase))
                {
                    checkpoint = saved;
                    checkpoint.Files = new(saved.Files, StringComparer.OrdinalIgnoreCase);
                }
                else cacheInvalid = true;
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException or JsonException) { cacheInvalid = true; }
        }
    }

    public void Start() => worker ??= Task.Run(async () =>
    {
        while (!stop.IsCancellationRequested)
        {
            try { await CollectAsync(stop.Token); }
            catch (OperationCanceledException) when (stop.IsCancellationRequested) { break; }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
            try { await Task.Delay(TimeSpan.FromSeconds(60), stop.Token); }
            catch (OperationCanceledException) { break; }
        }
    });

    public async Task<CodexUsageSnapshot> ReadAsync(CancellationToken token)
    {
        if (snapshot is { } previous && DateTimeOffset.TryParse(previous.CollectedAt, out var at)
            && clock() - at < TimeSpan.FromSeconds(30)) return WithRunning(previous, token);
        return await CollectAsync(token);
    }

    public async Task<CodexUsageSnapshot> CollectAsync(CancellationToken token)
    {
        await collection.WaitAsync(token);
        try
        {
            var now = clock();
            var today = DateOnly.FromDateTime(TimeZoneInfo.ConvertTime(now, zone).DateTime);
            var firstDay = today.AddDays(-6);
            var cutoff = new DateTimeOffset(TimeZoneInfo.ConvertTimeToUtc(firstDay.ToDateTime(TimeOnly.MinValue), zone));
            var warnings = new List<string>();
            if (cacheInvalid) warnings.Add("本地统计缓存不可用，已从现有 Codex 日志重建；已删除的日志无法回补。");
            var roots = new[] { Path.Combine(home, "sessions"), Path.Combine(home, "archived_sessions") };
            var available = roots.Any(Directory.Exists);
            if (!available) warnings.Add("未找到本机 Codex 会话日志；统计仅覆盖此前已采集的数据。");
            var paths = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (var root in roots.Where(Directory.Exists))
            {
                try
                {
                    foreach (var path in Directory.EnumerateFiles(root, "*.jsonl", new EnumerationOptions { RecurseSubdirectories = true, IgnoreInaccessible = false, AttributesToSkip = FileAttributes.ReparsePoint }))
                    { token.ThrowIfCancellationRequested(); paths.Add(path); }
                }
                catch (Exception e) when (e is IOException or UnauthorizedAccessException) { warnings.Add("部分 Codex 日志目录无法读取，统计可能不完整。"); }
            }
            foreach (var path in paths)
            {
                token.ThrowIfCancellationRequested();
                try
                {
                    var file = new FileInfo(path);
                    if (!checkpoint.Files.TryGetValue(path, out var cursor))
                    {
                        if (file.LastWriteTimeUtc < cutoff.UtcDateTime) continue;
                        checkpoint.Files[path] = cursor = new Cursor();
                    }
                    if (file.Length < cursor.Offset) checkpoint.Files[path] = cursor = new Cursor();
                    if (file.Length != cursor.Offset) await ScanAsync(path, cursor, cutoff, now, warnings, token);
                }
                catch (Exception e) when (e is IOException or UnauthorizedAccessException)
                { warnings.Add("部分 Codex 日志暂时无法读取，下次采集会重试。"); }
            }
            foreach (var key in checkpoint.Requests.Where(p => p.Value.At < cutoff).Select(p => p.Key).ToArray()) checkpoint.Requests.Remove(key);
            foreach (var key in checkpoint.PreciseAliases.Where(p => p.Value < cutoff).Select(p => p.Key).ToArray()) checkpoint.PreciseAliases.Remove(key);
            foreach (var path in checkpoint.Files.Keys.Where(p => !paths.Contains(p)).ToArray()) checkpoint.Files.Remove(path);
            if (checkpoint.IncompleteAt >= cutoff) warnings.Add("部分 Codex 日志记录格式无效，统计可能不完整。");
            else checkpoint.IncompleteAt = null;
            if (checkpoint.Requests.Values.Any(r => r.Estimated)) warnings.Add("部分旧版日志没有请求 ID，请求次数按用量更新估算。");
            if (checkpoint.Requests.Values.Any(r => !r.Usage.BreakdownAvailable)) warnings.Add("部分旧版记录只有 token 总量，输入/输出明细不完整。");
            var days = Enumerable.Range(0, 7).Select(i =>
            {
                var day = firstDay.AddDays(i);
                var requests = checkpoint.Requests.Values.Where(r => DateOnly.FromDateTime(TimeZoneInfo.ConvertTime(r.At, zone).DateTime) == day).ToArray();
                return new CodexUsageDay(day.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture), requests.LongLength,
                    requests.Sum(r => r.Usage.Input), requests.Sum(r => r.Usage.Cached), requests.Sum(r => r.Usage.Output),
                    requests.Sum(r => r.Usage.Reasoning), requests.Sum(r => r.Usage.Total), requests.All(r => r.Usage.BreakdownAvailable));
            }).ToArray();
            if (cachePath is not null)
            {
                var temporary = cachePath + ".tmp";
                try
                {
                    Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(cachePath))!);
                    await File.WriteAllBytesAsync(temporary, JsonSerializer.SerializeToUtf8Bytes(checkpoint), token);
                    File.Move(temporary, cachePath, true); cacheInvalid = false;
                }
                catch (Exception e) when (e is IOException or UnauthorizedAccessException) { warnings.Add("统计缓存保存失败，下次启动需重新读取日志。"); }
                finally { try { if (File.Exists(temporary)) File.Delete(temporary); } catch (IOException) { } }
            }
            var result = WithRunning(new(available, now.ToString("O"), zone.Id, days, null, warnings.Distinct().Take(6).ToArray()), token);
            snapshot = result;
            return result;
        }
        finally { collection.Release(); }
    }

    private CodexUsageSnapshot WithRunning(CodexUsageSnapshot value, CancellationToken token)
    {
        var count = RunningSessions(token);
        var warnings = value.Warnings.Where(w => w != "当前版本的 Codex 运行状态暂不可用。").ToList();
        if (count is null) warnings.Add("当前版本的 Codex 运行状态暂不可用。");
        return value with { RunningSessions = count, Warnings = warnings };
    }

    private async Task ScanAsync(string path, Cursor cursor, DateTimeOffset cutoff, DateTimeOffset now, List<string> warnings, CancellationToken token)
    {
        using var file = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete, 65536, true);
        file.Seek(cursor.Offset, SeekOrigin.Begin);
        var buffer = new byte[65536];
        using var line = new MemoryStream();
        long consumed = cursor.Offset;
        var oversized = false;
        int count;
        while ((count = await file.ReadAsync(buffer, token)) > 0)
        {
            var start = 0;
            while (start < count)
            {
                var newline = Array.IndexOf(buffer, (byte)'\n', start, count - start);
                var length = (newline < 0 ? count : newline) - start;
                consumed += length;
                if (!oversized && line.Length + length <= 4 * 1024 * 1024) line.Write(buffer, start, length);
                else oversized = true;
                if (newline < 0) break;
                consumed++;
                start = newline + 1;
                token.ThrowIfCancellationRequested();
                if (!oversized && line.Length > 0)
                {
                    try { Parse(line.GetBuffer().AsMemory(0, (int)line.Length), cursor, cutoff, now); }
                    catch (Exception e) when (e is JsonException or FormatException or InvalidOperationException or OverflowException)
                    { checkpoint.IncompleteAt = now; warnings.Add("部分 Codex 日志记录格式无效，统计可能不完整。"); }
                }
                // Oversized message bodies cannot be usage events; do not retain or parse their content.
                cursor.Offset = consumed; line.SetLength(0); oversized = false;
            }
        }
        // A partially written final line is intentionally retried from its beginning next time.
    }

    private void Parse(ReadOnlyMemory<byte> bytes, Cursor cursor, DateTimeOffset cutoff, DateTimeOffset now)
    {
        using var doc = JsonDocument.Parse(bytes);
        var row = doc.RootElement;
        if (!row.TryGetProperty("type", out var type) || !row.TryGetProperty("payload", out var payload) || payload.ValueKind != JsonValueKind.Object) return;
        switch (type.GetString())
        {
            case "session_meta":
                cursor.ThreadId = Text(payload, "id"); return;
            case "turn_context":
                cursor.TurnId = Text(payload, "turn_id"); return;
            case "token_usage_record":
                if (!payload.TryGetProperty("usage", out var usage) || Totals(usage) is not { } totals) return;
                var response = Text(payload, "response_id");
                if (response.Length == 0) return;
                var turn = Text(payload, "turn_id");
                if (turn.Length > 0) cursor.TurnId = turn;
                if (payload.TryGetProperty("thread_token_usage", out var cumulative) && Totals(cumulative) is { } threadTotals)
                {
                    cursor.Previous = threadTotals;
                    var alias = LegacyKey(cursor.ThreadId, turn, threadTotals);
                    checkpoint.Requests.Remove(alias);
                    if (DateTimeOffset.TryParse(Text(row, "timestamp"), out var aliasAt) && aliasAt >= cutoff)
                        checkpoint.PreciseAliases[alias] = aliasAt;
                }
                Add("response:" + response, row, totals, false, cutoff, now); return;
            case "event_msg":
                if (Text(payload, "type") == "task_started") { cursor.TurnId = Text(payload, "turn_id"); return; }
                if (Text(payload, "type") != "token_count" || !payload.TryGetProperty("info", out var info) || info.ValueKind != JsonValueKind.Object
                    || !info.TryGetProperty("total_token_usage", out var totalElement) || Totals(totalElement) is not { } total) return;
                var previous = cursor.Previous; cursor.Previous = total;
                if (previous == total || !info.TryGetProperty("last_token_usage", out var last) || Totals(last) is not { } delta) return;
                var legacyKey = LegacyKey(cursor.ThreadId, cursor.TurnId, total);
                if (!checkpoint.PreciseAliases.ContainsKey(legacyKey)) Add(legacyKey, row, delta, true, cutoff, now);
                return;
        }
    }

    private static string LegacyKey(string thread, string turn, TokenUsage total) =>
        "legacy:" + (turn.Length > 0 ? turn : thread) + ":" + total.Input + ":" + total.Cached + ":" + total.Output + ":" + total.Reasoning + ":" + total.Total;
    private void Add(string key, JsonElement row, TokenUsage usage, bool estimated, DateTimeOffset cutoff, DateTimeOffset now)
    {
        if (DateTimeOffset.TryParse(Text(row, "timestamp"), CultureInfo.InvariantCulture, DateTimeStyles.RoundtripKind, out var at)
            && at >= cutoff && at <= now.AddMinutes(5) && (!checkpoint.Requests.TryGetValue(key, out var previous)
                || (at >= previous.At && usage.Total >= previous.Usage.Total))) checkpoint.Requests[key] = new(at, usage, estimated);
    }
    private static string Text(JsonElement obj, string name) => obj.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String ? value.GetString()! : "";
    private static TokenUsage? Totals(JsonElement value)
    {
        if (value.ValueKind != JsonValueKind.Object) return null;
        long Read(string name) => value.TryGetProperty(name, out var n) && n.TryGetInt64(out var result) && result >= 0 ? result : throw new FormatException();
        var hasInput = value.TryGetProperty("input_tokens", out _); var hasOutput = value.TryGetProperty("output_tokens", out _);
        var input = hasInput ? Read("input_tokens") : 0; var output = hasOutput ? Read("output_tokens") : 0;
        var cached = value.TryGetProperty("cached_input_tokens", out _) ? Read("cached_input_tokens") : 0;
        var reasoning = value.TryGetProperty("reasoning_output_tokens", out _) ? Read("reasoning_output_tokens") : 0;
        var total = value.TryGetProperty("total_tokens", out _) ? Read("total_tokens") : hasInput && hasOutput ? checked(input + output) : throw new FormatException();
        return new(input, cached, output, reasoning, total, hasInput && hasOutput && cached <= input && reasoning <= output && total == checked(input + output));
    }

    private int? RunningSessions(CancellationToken token)
    {
        try
        {
            string? Database(string prefix) => Directory.Exists(home) ? Directory.EnumerateFiles(home, prefix + "_*.sqlite")
                .OrderByDescending(p => int.TryParse(Path.GetFileNameWithoutExtension(p).Substring(prefix.Length + 1), out var v) ? v : -1).FirstOrDefault() : null;
            var state = Database("state"); var history = Database("thread_history");
            if (state is null || history is null || !Directory.Exists(Path.Combine(home, "thread-writer-locks"))) return null;
            var userThreads = ReadOnlySqlite.Query(state, "SELECT id, source FROM threads", token)
                .Where(r => !r[1].Contains("subagent", StringComparison.OrdinalIgnoreCase) && !r[1].Contains("guardian", StringComparison.OrdinalIgnoreCase))
                .Select(r => r[0]).ToHashSet();
            var active = ReadOnlySqlite.Query(history, "SELECT DISTINCT thread_id FROM thread_turns WHERE status='inProgress' AND completed_at IS NULL", token);
            return active.Count(r => userThreads.Contains(r[0]) && WriterAlive(r[0]));
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or DllNotFoundException or EntryPointNotFoundException) { return null; }
    }
    private bool WriterAlive(string thread)
    {
        if (!Guid.TryParse(thread, out _)) return false;
        var path = Path.Combine(home, "thread-writer-locks", thread + ".lock");
        if (!File.Exists(path)) return false;
        using var file = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
        var overlap = new NativeOverlapped();
        if (LockFileEx(file.SafeFileHandle.DangerousGetHandle(), 3, 0, 1, 0, ref overlap))
        {
            UnlockFileEx(file.SafeFileHandle.DangerousGetHandle(), 0, 1, 0, ref overlap);
            return false;
        }
        var error = Marshal.GetLastWin32Error();
        if (error != 33) throw new IOException("Cannot inspect Codex writer lock.");
        return true;
    }
    [DllImport("kernel32", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool LockFileEx(IntPtr handle, uint flags, uint reserved, uint low, uint high, ref NativeOverlapped overlap);
    [DllImport("kernel32", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool UnlockFileEx(IntPtr handle, uint reserved, uint low, uint high, ref NativeOverlapped overlap);

    public async ValueTask DisposeAsync()
    {
        await stop.CancelAsync();
        if (worker is not null) await worker;
        stop.Dispose();
    }
}
