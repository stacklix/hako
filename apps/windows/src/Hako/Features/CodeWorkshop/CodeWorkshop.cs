using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using Hako.Core;

namespace Hako.Platform;

internal sealed record WorkshopApplication(string Id, string Name, string Path);
internal sealed record WorkshopSession(string Id, string Title, string ApplicationId, string Cwd,
    string Preview, long UpdatedAt, string State, string? OperationId, string? CompletionId = null, long LastSentAt = 0, WorkshopThreadAccess? Access = null, string? ParentThreadId = null);
internal sealed record WorkshopEvent(string Kind, string Id, string Text, string Role = "", string State = "", bool Truncated = false, string? ReplacesId = null, WorkshopAsyncQuestion[]? Questions = null, string? QuestionId = null,
    string? TurnId = null, long? StartedAtMs = null, long? CompletedAtMs = null, WorkshopTurn? Turn = null, WorkshopPlanStep[]? Plan = null,
    WorkshopAgentActivity[]? Agents = null);
internal sealed record WorkshopPlanStep(string Step, string Status);
internal sealed record WorkshopAgentActivity(string AgentId, string Name, string Action, string Task, string State, string Summary,
    WorkshopTurn? Turn = null);
internal sealed record WorkshopTurn(string Id, string State, long? StartedAt, long? CompletedAt, long? DurationMs);
internal sealed record WorkshopAsyncQuestion(string Title, string[] Options);
internal sealed record WorkshopArtifact(string Id, string Name, string Path, string ThreadId);

internal sealed partial class CodeWorkshop : IAsyncDisposable
{
    private readonly string root;
    private readonly string home;
    private readonly string storage;
    private readonly object gate = new();
    private readonly SemaphoreSlim metadataGate = new(1, 1);
    private readonly WorkshopReads reads = new();
    private readonly WorkshopQueryLog queryLog;
    private readonly Dictionary<string, (JsonElement Thread, JsonElement Turn, JsonElement Page, string Cursor, long Saved)> historyPages = new();
    private readonly Dictionary<string, TurnSummaryPage> turnSummaryPages = new();
    private sealed class TurnSummaryPage
    {
        public Dictionary<string, WorkshopTurn> Turns { get; } = new();
        public string? Cursor { get; set; }
        public bool Complete { get; set; }
        public long Saved { get; } = Environment.TickCount64;
        public string Latest { get; set; } = "";
    }
    private readonly CancellationTokenSource stopping = new();
    private CodexAppServer? metadata;
    private readonly Func<CancellationToken, Task<CodexAppServer>> startServer;
    private readonly WorkshopWorkers workers;
    private readonly Dictionary<string, WorkshopJob> jobs = new();
    private readonly Dictionary<string, WorkshopArtifact> artifacts = new();
    private readonly Dictionary<string, string> artifactRoots = new();
    private readonly WorkshopDownloadCache downloads = new();
    private readonly HashSet<string> changingArchive = new();
    private bool recovered;
    private readonly Func<string, CodexWriterState> readWriter;

    public CodeWorkshop(string storage, string? root = null, string? codexHome = null,
        Func<CancellationToken, Task<CodexAppServer>>? startServer = null, Func<string, CodexWriterState>? readWriter = null,
        int workerLimit = WorkshopWorkers.DefaultLimit, TimeSpan? workerIdleTimeout = null, int workerWarmCount = 0)
    {
        this.startServer = startServer ?? (token => CodexAppServer.StartAsync(token));
        this.storage = Path.GetFullPath(storage);
        queryLog = new WorkshopQueryLog(this.storage);
        this.root = Path.GetFullPath(root ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Code"));
        home = Path.GetFullPath(codexHome ?? Environment.GetEnvironmentVariable("CODEX_HOME") ??
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".codex"));
        this.readWriter = readWriter ?? (thread => CodexWriterLock.Read(home, thread));
        workers = new(this.startServer, workerLimit, workerIdleTimeout, warmCount: workerWarmCount,
            log: (method, elapsed, outcome) => queryLog.Write(method, 0, elapsed, outcome));
    }

    private void RecoverJobs()
    {
        if (recovered) return;
        if (Directory.Exists(storage))
            foreach (var file in Directory.EnumerateFiles(this.storage, "*.json").OrderByDescending(File.GetLastWriteTimeUtc))
            {
                if (!Guid.TryParse(Path.GetFileNameWithoutExtension(file), out var id)) continue;
                try { GetJob(id.ToString("D")); }
                catch (Exception e) when (e is IOException or JsonException or UnauthorizedAccessException) { }
            }
        recovered = true;
    }

    private async Task<JsonElement> ReadAsync(string method, object parameters, CancellationToken token)
    {
        if (method.EndsWith("/read", StringComparison.Ordinal) || method.EndsWith("/list", StringComparison.Ordinal))
            return await reads.RunAsync(method + "\n" + JsonSerializer.Serialize(parameters, WorkshopProtocol.Json),
                () => ReadCoreAsync(method, parameters, stopping.Token), token);
        return await ReadCoreAsync(method, parameters, token);
    }

    private async Task<JsonElement> ReadCoreAsync(string method, object parameters, CancellationToken token)
    {
        using var budget = CancellationTokenSource.CreateLinkedTokenSource(token);
        budget.CancelAfter(TimeSpan.FromSeconds(8));
        var watch = Stopwatch.StartNew();
        long waitMs = -1;
        var outcome = "completed";
        CodexAppServer? server = null;
        try
        {
            await metadataGate.WaitAsync(budget.Token);
            try { server = metadata ??= await startServer(budget.Token); }
            finally { metadataGate.Release(); waitMs = watch.ElapsedMilliseconds; }
            // CodexAppServer already correlates concurrent RPCs by ID. The gate
            // protects initialization/replacement, never the duration of a query.
            return await server.RequestAsync(method, parameters, budget.Token);
        }
        catch (Exception error) when (error is TimeoutException || error is OperationCanceledException && !token.IsCancellationRequested)
        {
            outcome = "query_timeout";
            // A slow read does not prove that the shared connection is broken.
            throw new WorkshopException("query_timeout", "电脑读取会话数据超时，最新消息与任务状态尚未同步；请重新同步确认结果，勿重复发送原消息。");
        }
        catch (IOException)
        {
            outcome = "codex_connection_closed";
            await metadataGate.WaitAsync(token);
            try
            {
                if (server is not null && ReferenceEquals(metadata, server))
                { metadata = null; await server.DisposeAsync(); }
            }
            finally { metadataGate.Release(); }
            throw new WorkshopException("codex_connection_closed", "电脑端的会话读取连接已中断，请重新同步确认任务结果。");
        }
        catch { outcome = "cancelled_or_failed"; throw; }
        finally
        {
            if (waitMs < 0) waitMs = watch.ElapsedMilliseconds;
            queryLog.Write(method, waitMs, watch.ElapsedMilliseconds - waitMs, outcome);
        }
    }

    internal sealed record ThreadSummary(string Preview, string State, string? CompletionId, string TurnId, JsonElement UserInput = default);

    internal static ThreadSummary ReconcileSummary(ThreadSummary summary, WorkshopJob? current)
    {
        if (current is null) return summary;
        if (current.Active || current.State is "queued" or "paused")
            return summary with { State = current.State, CompletionId = null };
        // The metadata connection can retain an in-progress snapshot after the
        // worker has exited. Its matching terminal job is authoritative, while
        // a different turn may have been started outside this Agent.
        if (!string.IsNullOrEmpty(current.TurnId) && current.TurnId == summary.TurnId &&
            current.State is "completed" or "failed" or "interrupted")
            return summary with { State = current.State, CompletionId = current.State == "completed" ? current.TurnId : null };
        return summary;
    }

    internal static ThreadSummary SummarizeTurn(JsonElement turn)
    {
        var lastMessage = CodexJson.Items(CodexJson.Field(turn, "items")).Reverse().Select(Item)
            .FirstOrDefault(item => item?.Role is "user" or "assistant");
        var preview = lastMessage is null ? "" : CodexJson.Clip(Regex.Replace(lastMessage.Text, @"\s+", " ").Trim(), 240);
        var status = CodexJson.Text(turn, "status");
        var state = status == "inProgress" ? "running" : status.Length == 0 ? "idle" : status;
        var turnId = CodexJson.Text(turn, "id");
        var user = CodexJson.Items(CodexJson.Field(turn, "items")).LastOrDefault(item => CodexJson.Text(item, "type") == "userMessage");
        return new(preview, state, status == "completed" && turnId.Length > 0 ? turnId : null, turnId, user);
    }

    private async Task<ThreadSummary> LatestSummaryAsync(string threadId, CancellationToken token)
    {
        var page = await ReadAsync("thread/turns/list", new { threadId, limit = 1, sortDirection = "desc", itemsView = "summary" }, token);
        var latest = SummarizeTurn(CodexJson.Items(CodexJson.Field(page, "data")).FirstOrDefault());
        string? cursor = null;
        var seen = new HashSet<string>();
        // Turn summaries omit intervening Steers and commentary. Read actual
        // items backwards so a later message in the same turn wins as well.
        do
        {
            var items = await ReadAsync("thread/items/list", new { threadId, limit = 32, sortDirection = "desc", cursor }, token);
            var message = CodexJson.Items(CodexJson.Field(items, "data")).Select(entry => Item(CodexJson.Field(entry, "item")))
                .FirstOrDefault(item => item?.Role is "user" or "assistant" && !string.IsNullOrWhiteSpace(item.Text));
            if (message is not null)
                return latest with { Preview = CodexJson.Clip(Regex.Replace(message.Text, @"\s+", " ").Trim(), 240) };
            cursor = CodexJson.Text(items, "nextCursor");
            if (cursor.Length > 0 && !seen.Add(cursor))
                throw new WorkshopException("codex_catalog_cursor", "会话消息游标未前进，请重新刷新。");
        } while (cursor.Length > 0);
        return latest with { Preview = "" };
    }

    public async Task<object?> ArchiveAsync(JsonElement parameters, CancellationToken token)
    {
        CodexJson.Keys(parameters, "threadId", "archived");
        var id = ThreadId(parameters);
        var value = CodexJson.Field(parameters, "archived");
        if (value.ValueKind is not (JsonValueKind.True or JsonValueKind.False)) throw CodexJson.Invalid();
        var archived = value.GetBoolean();
        token.ThrowIfCancellationRequested();
        lock (gate)
        {
            RecoverJobs();
            if (changingArchive.Contains(id) || archived && jobs.Values.Any(job => job.ThreadId == id &&
                (job.Active || job.State is "queued" or "paused" or "steering")))
                throw new WorkshopException("codex_busy", "请先结束任务并处理排队消息，再归档会话。");
            changingArchive.Add(id);
        }
        try
        {
            if (archived) await workers.ReleaseIdleAsync(id, token);
            var thread = await ThreadAsync(id, false, token);
            if (archived && CodexJson.Text(CodexJson.Field(thread, "status"), "type") == "active")
                throw new WorkshopException("codex_busy", "会话仍在执行任务，请结束后再归档。");
            await ReadAsync(archived ? "thread/archive" : "thread/unarchive", new { threadId = id }, token);
            return new { threadId = id, archived };
        }
        finally { lock (gate) changingArchive.Remove(id); }
    }

    private List<WorkshopApplication> DiscoverApplications()
    {
        if (!Directory.Exists(root)) return [];
        return Directory.EnumerateDirectories(root).Where(directory =>
            !IsReparse(directory) && (Directory.Exists(Path.Combine(directory, ".git")) || File.Exists(Path.Combine(directory, ".git"))))
            .Order(StringComparer.OrdinalIgnoreCase).Take(100).Select(Application).ToList();
    }

    private static WorkshopApplication Application(string directory) => new(
        Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(directory.ToUpperInvariant())))[..16].ToLowerInvariant(),
        Path.GetFileName(directory), directory);

    private WorkshopApplication? ApplicationFor(string cwd)
    {
        if (string.IsNullOrWhiteSpace(cwd) || !Path.IsPathFullyQualified(cwd)) return null;
        var path = Path.GetFullPath(cwd);
        var relative = Path.GetRelativePath(root, path);
        if (relative == "." || relative.StartsWith("..", StringComparison.Ordinal) || Path.IsPathRooted(relative)) return null;
        var application = Path.Combine(root, relative.Split(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar)[0]);
        if (!Directory.Exists(path) || !SafePath(path, root)) return null;
        return Application(application);
    }

    internal string ResolveApplication(string id) => DiscoverApplications().FirstOrDefault(value => value.Id == id)?.Path
        ?? throw new WorkshopException("codex_application_missing", "项目目录已变化，请刷新应用列表。");

    private async Task<JsonElement> ThreadAsync(string id, bool history, CancellationToken token)
    {
        var response = await ReadAsync("thread/read", new { threadId = id, includeTurns = history }, token);
        var thread = CodexJson.Field(response, "thread");
        if (ApplicationFor(CodexJson.Text(thread, "cwd")) is null)
            throw new WorkshopException("codex_workspace_invalid", "此会话不在当前电脑的 Code 项目目录中。");
        return thread;
    }

    public async Task<object?> HistoryAsync(JsonElement parameters, CancellationToken token)
    {
        CodexJson.Keys(parameters, "threadId", "cursor");
        lock (gate) RecoverJobs();
        var id = ThreadId(parameters);
        var cursor = CodexJson.Text(parameters, "cursor");
        var position = cursor.Length == 0 ? new HistoryPosition(id, "", 0, "", [], "") : HistoryPosition.Parse(cursor, id);
        JsonElement thread = default;
        JsonElement turn = default;
        JsonElement upstream = default;
        lock (gate)
            if (cursor.Length > 0 && historyPages.TryGetValue(id, out var cached) &&
                Environment.TickCount64 - cached.Saved < 30_000)
            {
                thread = cached.Thread; turn = cached.Turn;
                if (cached.Cursor == position.Cursor) upstream = cached.Page;
            }
        var itemsPage = upstream.ValueKind == JsonValueKind.Undefined
            ? ReadAsync("thread/items/list", new { threadId = id, limit = 64, sortDirection = "desc",
                cursor = position.Cursor.Length == 0 ? null : position.Cursor }, token) : Task.FromResult(upstream);
        if (thread.ValueKind == JsonValueKind.Undefined)
        {
            var metadata = ThreadAsync(id, false, token);
            var latest = ReadAsync("thread/turns/list", new { threadId = id, limit = 1,
                sortDirection = "desc", itemsView = "summary" }, token);
            await Task.WhenAll(metadata, latest, itemsPage);
            thread = await metadata;
            turn = CodexJson.Items(CodexJson.Field(await latest, "data")).FirstOrDefault();
        }
        upstream = await itemsPage;
        var cwd = CodexJson.Text(thread, "cwd");
        var items = CodexJson.Items(CodexJson.Field(upstream, "data")).ToArray();
        try { await RecoverUnknownAsync(id, token); }
        catch (Exception error) when (!token.IsCancellationRequested && error is not OutOfMemoryException)
        { queryLog.Write("history/reconcile", 0, 0, error.GetType().Name); }
        var nativeCursor = position.Cursor;
        var offset = position.Offset;
        var visited = new HashSet<string>();
        async Task OlderPage()
        {
            var olderCursor = CodexJson.Text(upstream, "nextCursor");
            if (olderCursor.Length == 0 || !visited.Add(olderCursor))
                throw new WorkshopException("codex_history_cursor", "会话历史已变化，请重新刷新。");
            nativeCursor = olderCursor;
            upstream = await ReadAsync("thread/items/list", new { threadId = id, limit = 64, sortDirection = "desc", cursor = nativeCursor }, token);
            items = CodexJson.Items(CodexJson.Field(upstream, "data")).ToArray();
        }
        if (position.Anchor.Length > 0)
        {
            // A fresh head read (or restart) can replace the cached source page.
            // Locate its original first item before applying the local offset;
            // newly appended items must not shift an existing history cursor.
            int anchor;
            while ((anchor = Array.FindIndex(items, item => HistoryAnchor(item) == position.Anchor)) < 0) await OlderPage();
            offset += anchor;
        }
        while (offset >= items.Length && CodexJson.Text(upstream, "nextCursor").Length > 0)
        {
            offset -= items.Length;
            await OlderPage();
        }
        if (offset > items.Length) throw CodexJson.Invalid();
        lock (gate)
        {
            if (!historyPages.ContainsKey(id) && historyPages.Count >= 4)
                historyPages.Remove(historyPages.MinBy(value => value.Value.Saved).Key);
            historyPages[id] = (thread, turn, upstream, nativeCursor, Environment.TickCount64);
        }
        var sidechat = SidechatRoot(id);
        var inheritedTurn = sidechat?.InheritedTurnId;
        var sidechatInitializing = sidechat is not null && inheritedTurn is null;
        foreach (var item in items.TakeWhile(item => !sidechatInitializing && (string.IsNullOrEmpty(inheritedTurn) || CodexJson.Text(item, "turnId") != inheritedTurn)))
        {
            DiscoverItemArtifacts(id, cwd, CodexJson.Field(item, "item"));
            RememberImageSources(id, CodexJson.Field(item, "item"));
        }
        WorkshopJob[] sent;
        // Steer submits input to the existing turn without starting a new one.
        lock (gate) sent = jobs.Values.Where(job => job.ThreadId == id && (job.Submitted || job.State == "steered"))
            .OrderByDescending(job => job.QueueOrder).ToArray();
        var used = position.Used.ToHashSet();
        var currentTurn = position.Turn;
        var page = new List<WorkshopEvent>();
        var bytes = 0;
        var reachedParent = sidechatInitializing;
        while (!reachedParent && offset < items.Length && page.Count < 12)
        {
            var item = items[offset];
            var itemTurn = CodexJson.Text(item, "turnId");
            if (!string.IsNullOrEmpty(inheritedTurn) && itemTurn == inheritedTurn) { reachedParent = true; break; }
            var nextUsed = itemTurn == currentTurn ? new HashSet<string>(used) : new HashSet<string>();
            var entry = HistoryItem(CodexJson.Field(item, "item"), itemTurn, sent, nextUsed);
            if (entry is null) { offset++; used = nextUsed; currentTurn = itemTurn; continue; }
            entry = WithItemTiming(entry, item, itemTurn);
            var plan = entry.Role == "user" ? sent.FirstOrDefault(job => job.Id == entry.Id && job.TurnId == itemTurn && job.Plan is not null)?.Plan : null;
            var size = JsonSerializer.SerializeToUtf8Bytes(entry, WorkshopProtocol.Json).Length;
            if (plan is not null) size += JsonSerializer.SerializeToUtf8Bytes(plan, WorkshopProtocol.Json).Length;
            if (bytes + size > 38 * 1024 && page.Count > 0) break;
            if (plan is not null && !page.Any(value => value.Id == plan.Id)) page.Insert(0, plan);
            page.Insert(0, entry); bytes += size; offset++; used = nextUsed; currentTurn = itemTurn;
        }
        var turnSummaries = await ReadTurnSummariesAsync(id, page.Select(entry => entry.TurnId).OfType<string>().ToHashSet(), turn, token);
        page = page.Select(entry => entry.TurnId is not null && turnSummaries.TryGetValue(entry.TurnId, out var summary)
            ? entry with { Turn = summary } : entry).ToList();
        WorkshopArtifact[] files;
        string? operationId;
        lock (gate)
        {
            files = artifacts.Values.Where(value => value.ThreadId == id).Take(20).ToArray();
            var latest = jobs.Values.Where(job => job.ThreadId == id).OrderByDescending(job => job.StartedAt).ThenByDescending(job => job.QueueOrder).FirstOrDefault();
            operationId = latest?.RootId ?? latest?.Id;
        }
        var completionId = SummarizeTurn(turn).CompletionId;
        var nativeUsage = cursor.Length == 0 ? await ReadContextUsageAsync(id, CodexJson.Text(thread, "path"), token) : null;
        WorkshopContextUsage? contextUsage;
        lock (gate) contextUsage = ContextUsage(id, nativeUsage);
        var older = CodexJson.Text(upstream, "nextCursor");
        var nextCursor = offset < items.Length ? new HistoryPosition(id, nativeCursor, offset, currentTurn, used.ToArray(), HistoryAnchor(items[0])).Encode() :
            older.Length > 0 ? new HistoryPosition(id, older, 0, currentTurn, used.ToArray(), "").Encode() : null;
        if (reachedParent) nextCursor = null;
        if (nextCursor == cursor) throw new WorkshopException("codex_history_cursor", "会话历史游标未前进，请重新刷新。");
        object Page() => new { threadId = id, parentThreadId = SidechatRoot(id)?.ParentThreadId, cwd, entries = page, artifacts = files, nextCursor, operationId, completionId,
            model = CodexJson.Text(thread, "model"), reasoningEffort = CodexJson.Text(thread, "reasoningEffort"), access = ThreadAccess(id), contextUsage };
        while (JsonSerializer.SerializeToUtf8Bytes(Page(), WorkshopProtocol.Json).Length > 56 * 1024 && files.Length > 0)
            files = files[..^1];
        return Page();
    }

    // Keep receipt matching across item-page boundaries, including identical
    // Steers in the same turn. No cursor requires hydrating an entire transcript.
    private static string HistoryAnchor(JsonElement item) => CodexJson.Text(item, "turnId") + "\n" + CodexJson.Text(CodexJson.Field(item, "item"), "id");
    private sealed record HistoryPosition(string ThreadId, string Cursor, int Offset, string Turn, string[] Used, string Anchor)
    {
        public string Encode() => Convert.ToBase64String(JsonSerializer.SerializeToUtf8Bytes(this, WorkshopProtocol.Json));
        public static HistoryPosition Parse(string value, string thread)
        {
            try
            {
                if (value.Length > 8192) throw new FormatException();
                var position = JsonSerializer.Deserialize<HistoryPosition>(Convert.FromBase64String(value), WorkshopProtocol.Json);
                if (position is null || position.ThreadId != thread || position.Cursor is null || position.Offset < 0 ||
                    position.Turn is null || position.Anchor is null || position.Used is null || position.Used.Length > 128 || position.Used.Any(value => value is null)) throw new FormatException();
                return position;
            }
            catch (Exception error) when (error is FormatException or JsonException) { throw CodexJson.Invalid(); }
        }
    }

    internal static bool ReconcileTurn(WorkshopJob job, JsonElement[] turns)
    {
        if (job.State != "unknown" || string.IsNullOrEmpty(job.TurnId)) return false;
        var turn = turns.FirstOrDefault(value => CodexJson.Text(value, "id") == job.TurnId);
        var state = CodexJson.Text(turn, "status");
        if (state is not ("completed" or "interrupted" or "failed")) return false;
        job.State = state; job.Outcome = state;
        var finished = CodexJson.Field(turn, "completedAt");
        if (finished.ValueKind == JsonValueKind.Number && finished.TryGetInt64(out var completedAt) && completedAt > 0 && completedAt <= long.MaxValue / 1000)
            job.FinishedAt = completedAt * 1000;
        job.Message = state == "failed" ? CodexJson.Clip(CodexJson.Text(CodexJson.Field(turn, "error"), "message"), 1000) : null;
        var reply = CodexJson.Items(CodexJson.Field(turn, "items")).LastOrDefault(value => CodexJson.Text(value, "type") == "agentMessage");
        job.ReplySummary = NotificationText(CodexJson.Text(reply, "text"), 240);
        return true;
    }

    internal static WorkshopEvent? Item(JsonElement item)
    {
        var type = CodexJson.Text(item, "type");
        var id = CodexJson.Text(item, "id");
        if (type is "collabAgentToolCall" or "subAgentActivity") return AgentActivity(item);
        string text;
        var role = "";
        switch (type)
        {
            case "userMessage":
                role = "user";
                text = string.Join("\n", CodexJson.Items(CodexJson.Field(item, "content"))
                    .Where(value => CodexJson.Text(value, "type") == "text").Select(value => CodexJson.Text(value, "text")));
                var imageCount = CodexJson.Items(CodexJson.Field(item, "content")).Count(value => CodexJson.Text(value, "type") is "image" or "localImage");
                if (imageCount > 0) text += $"\n[图片 × {imageCount}]";
                break;
            case "imageGeneration":
                role = "assistant";
                text = CodexJson.Text(item, "status") == "completed"
                    ? CodexJson.Text(item, "savedPath").Length > 0 ? "[图片 × 1]" : "图片未保存到电脑，暂时无法读取。"
                    : CodexJson.Text(item, "status") == "failed" ? "图片生成失败。" : "正在生成图片…";
                break;
            case "agentMessage": role = "assistant"; text = CodexJson.Text(item, "text"); break;
            case "commandExecution": text = CodexJson.Text(item, "command") + "\n" + CodexJson.Text(item, "aggregatedOutput"); break;
            case "fileChange":
                text = string.Join("\n\n", CodexJson.Items(CodexJson.Field(item, "changes")).Select(change =>
                    CodexJson.Text(change, "path") + "\n" + CodexJson.Text(change, "diff")));
                break;
            case "plan": text = CodexJson.Text(item, "text"); break;
            default: return null;
        }
        var questions = CodexJson.Text(item, "delivery") == "async" ? CodexJson.Items(CodexJson.Field(item, "questions"))
            .Take(3).Select(question => new WorkshopAsyncQuestion(CodexJson.Clip(CodexJson.Text(question, "title"), 600),
                CodexJson.Items(CodexJson.Field(question, "options")).Where(option => option.ValueKind == JsonValueKind.String)
                    .Take(8).Select(option => CodexJson.Clip(option.GetString()!, 120)).ToArray()))
            .Where(question => !string.IsNullOrWhiteSpace(question.Title)).ToArray() : [];
        return new(type is "commandExecution" or "fileChange" or "plan" or "imageGeneration" ? type : "item", id, CodexJson.Clip(text, 8000), role, CodexJson.Text(item, "status"), text.Length > 8000, Questions: questions.Length > 0 ? questions : null);
    }

    internal static WorkshopEvent? AgentActivity(JsonElement item)
    {
        var id = CodexJson.Text(item, "id");
        if (id.Length == 0) return null;
        if (CodexJson.Text(item, "type") == "subAgentActivity")
        {
            var agent = CodexJson.Text(item, "agentThreadId");
            if (!Guid.TryParse(agent, out _)) return null;
            var action = CodexJson.Text(item, "kind");
            var state = action switch { "started" => "starting", "completed" => "completed", "interrupted" => "interrupted", _ => "" };
            return new("subagents", id, "", Agents: [new(agent, "", action, "", state, "")]);
        }
        var states = CodexJson.Field(item, "agentsStates");
        var activity = CodexJson.Text(item, "tool");
        var agents = CodexJson.Items(CodexJson.Field(item, "receiverThreadIds"))
            .Where(value => value.ValueKind == JsonValueKind.String && Guid.TryParse(value.GetString(), out _))
            .Select(value => value.GetString()!).Distinct().Take(8).Select(agent => {
                var native = CodexJson.Field(states, agent);
                var state = CodexJson.Text(native, "status") switch {
                    "pendingInit" => "starting", "errored" => "failed", "shutdown" => "closed", "notFound" => "unknown",
                    "running" => "running", "completed" => "completed", "interrupted" => "interrupted", _ => ""
                };
                return new WorkshopAgentActivity(agent, "", activity, CodexJson.Clip(CodexJson.Text(item, "prompt"), 300),
                    state, CodexJson.Clip(CodexJson.Text(native, "message"), 300));
            }).ToArray();
        return agents.Length == 0 ? null : new("subagents", id, "", Agents: agents);
    }

    internal static WorkshopEvent? PlanUpdated(JsonElement parameters)
    {
        var turn = CodexJson.Text(parameters, "turnId");
        if (turn.Length == 0) return null;
        var steps = CodexJson.Items(CodexJson.Field(parameters, "plan")).Take(32)
            .Select(value => new WorkshopPlanStep(CodexJson.Clip(CodexJson.Text(value, "step"), 256), CodexJson.Text(value, "status")))
            .Where(value => !string.IsNullOrWhiteSpace(value.Step) && value.Status is "pending" or "inProgress" or "completed").ToArray();
        return new("plan", "plan-" + turn, CodexJson.Clip(CodexJson.Text(parameters, "explanation"), 600),
            TurnId: turn, Plan: steps);
    }

    internal static WorkshopEvent WithItemTiming(WorkshopEvent entry, JsonElement envelope, string? turnId) => entry with {
        TurnId = string.IsNullOrEmpty(turnId) ? null : turnId,
        StartedAtMs = CodexJson.Field(envelope, "startedAtMs").TryGetPositiveInt64(),
        CompletedAtMs = CodexJson.Field(envelope, "completedAtMs").TryGetPositiveInt64()
    };

    internal static WorkshopTurn TurnSummary(JsonElement turn) => new(CodexJson.Text(turn, "id"), CodexJson.Text(turn, "status"),
        CodexJson.Field(turn, "startedAt").TryGetPositiveInt64(), CodexJson.Field(turn, "completedAt").TryGetPositiveInt64(),
        CodexJson.Field(turn, "durationMs").ValueKind == JsonValueKind.Number && CodexJson.Field(turn, "durationMs").TryGetInt64(out var duration) && duration >= 0 ? duration : null);

    private async Task<Dictionary<string, WorkshopTurn>> ReadTurnSummariesAsync(string threadId, HashSet<string> needed,
        JsonElement latest, CancellationToken token)
    {
        var head = TurnSummary(latest);
        TurnSummaryPage cache;
        lock (gate)
        {
            var identity = head.Id + "|" + head.State;
            if (!turnSummaryPages.TryGetValue(threadId, out cache!) || Environment.TickCount64 - cache.Saved >= 30_000 || cache.Latest != identity)
            {
                if (turnSummaryPages.Count >= 4) turnSummaryPages.Remove(turnSummaryPages.MinBy(value => value.Value.Saved).Key);
                turnSummaryPages[threadId] = cache = new() { Latest = identity };
            }
            if (head.Id.Length > 0) cache.Turns[head.Id] = head;
        }
        // Read summaries only; older item pages continue from the same cached turn cursor.
        var visited = new HashSet<string>();
        while (true)
        {
            string? cursor;
            lock (gate)
            {
                if (needed.All(id => cache.Turns.ContainsKey(id)) || cache.Complete) break;
                cursor = cache.Cursor;
            }
            if (!visited.Add(cursor ?? "")) throw new WorkshopException("codex_history_cursor", "轮次摘要游标未前进，请重新刷新。");
            var result = await ReadAsync("thread/turns/list", new { threadId, limit = 32, sortDirection = "desc", itemsView = "summary", cursor }, token);
            lock (gate)
            {
                if (cache.Cursor != cursor) continue;
                foreach (var value in CodexJson.Items(CodexJson.Field(result, "data")))
                {
                    var summary = TurnSummary(value);
                    if (summary.Id.Length > 0) cache.Turns[summary.Id] = summary;
                }
                var next = CodexJson.Text(result, "nextCursor");
                if (next.Length > 0 && next == cache.Cursor) throw new WorkshopException("codex_history_cursor", "轮次摘要游标未前进，请重新刷新。");
                cache.Cursor = next.Length > 0 ? next : null;
                cache.Complete = cache.Cursor is null;
            }
        }
        lock (gate) return new(cache.Turns);
    }

    internal static WorkshopEvent? HistoryItem(JsonElement item, string turnId, WorkshopJob[] sent, HashSet<string> used)
    {
        var entry = Item(item);
        if (entry?.Role != "user") return entry;
        var clientId = CodexJson.Text(item, "clientUserMessageId");
        var job = sent.FirstOrDefault(job => !used.Contains(job.Id) &&
            (job.Id == clientId || job.Id == entry.Id ||
             turnId.Length > 0 && job.TurnId == turnId &&
             entry.Text == job.InputMessage + (job.ImageIds.Length > 0 ? $"\n[图片 × {job.ImageIds.Length}]" : "")));
        if (job is null) return entry;
        used.Add(job.Id);
        return entry with { Id = job.Id, ReplacesId = entry.Id == job.Id ? null : entry.Id, QuestionId = job.QuestionId };
    }

    private void DiscoverArtifacts(string threadId, string cwd, IEnumerable<WorkshopEvent> entries)
    {
        foreach (var entry in entries)
        {
            foreach (Match match in Regex.Matches(entry.Text, "visualize(\\{[^\\r\\n]*?\\})"))
            {
                try
                {
                    using var json = JsonDocument.Parse(match.Groups[1].Value);
                    RegisterArtifact(threadId, cwd, CodexJson.Text(json.RootElement, "path"));
                }
                catch (JsonException) { }
            }
            foreach (Match match in Regex.Matches(entry.Text, @"(?:[A-Za-z]:[/\\]|/)[^\r\n<>""|]*?\.html?\b"))
                RegisterArtifact(threadId, cwd, match.Value);
        }
    }

    private void DiscoverItemArtifacts(string threadId, string cwd, JsonElement item)
    {
        if (CodexJson.Text(item, "type") == "agentMessage")
            DiscoverArtifacts(threadId, cwd, [new("item", CodexJson.Text(item, "id"), CodexJson.Text(item, "text"), "assistant")]);
        foreach (var change in CodexJson.Items(CodexJson.Field(item, "changes")))
            RegisterArtifact(threadId, cwd, CodexJson.Text(change, "path"));
    }

    private void RegisterArtifact(string threadId, string cwd, string candidate)
    {
        try
        {
            candidate = Uri.UnescapeDataString(candidate).Trim();
            if (candidate.Length == 0) return;
            if (candidate.Length > 3 && candidate[0] == '/' && candidate[2] == ':') candidate = candidate[1..];
            var path = Path.GetFullPath(candidate, cwd);
            if (!new[] { ".html", ".htm" }.Contains(Path.GetExtension(path).ToLowerInvariant())) return;
            var visualizations = Path.Combine(home, "visualizations");
            if (!SafePath(path, cwd) && !SafePath(path, visualizations)) return;
            if (!File.Exists(path)) return;
            var id = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(threadId + "\n" + path.ToUpperInvariant())))[..24].ToLowerInvariant();
            lock (gate)
            {
                artifacts[id] = new(id, Path.GetFileNameWithoutExtension(path), path, threadId);
                artifactRoots[id] = cwd;
            }
        }
        catch (Exception e) when (e is IOException or ArgumentException or UnauthorizedAccessException) { }
    }

    public async Task<object?> ArtifactAsync(JsonElement parameters, CancellationToken token)
    {
        CodexJson.Keys(parameters, "threadId", "artifactId", "offset", "revision");
        var thread = ThreadId(parameters);
        var id = CodexJson.Required(parameters, "artifactId", 24);
        WorkshopArtifact? artifact;
        lock (gate) artifacts.TryGetValue(id, out artifact);
        if (artifact is null)
        {
            string? cursor = null;
            var seen = new HashSet<string>();
            do
            {
                var page = JsonSerializer.SerializeToElement(await HistoryAsync(JsonSerializer.SerializeToElement(new { threadId = thread, cursor }), token), WorkshopProtocol.Json);
                lock (gate) artifacts.TryGetValue(id, out artifact);
                cursor = CodexJson.Text(page, "nextCursor");
            } while (artifact is null && cursor.Length > 0 && seen.Add(cursor));
        }
        if (artifact is null || artifact.ThreadId != thread) throw new WorkshopException("codex_artifact_missing", "原型文件已变化，请刷新会话。");
        string cwd;
        lock (gate) cwd = artifactRoots[id];
        if (!SafePath(artifact.Path, cwd) && !SafePath(artifact.Path, Path.Combine(home, "visualizations"))) throw CodexJson.Invalid();
        if (new FileInfo(artifact.Path).Length > 2 * 1024 * 1024) throw new WorkshopException("codex_artifact_large", "原型超过 2 MB，无法在手机中预览。");
        var expected = CodexJson.Text(parameters, "revision");
        var snapshot = await downloads.ReadAsync("artifact:" + id, expected, () => File.ReadAllBytesAsync(artifact.Path, token), token);
        var data = snapshot.Data;
        if (data.Length > 2 * 1024 * 1024) throw new WorkshopException("codex_artifact_large", "原型超过 2 MB，无法在手机中预览。");
        var revision = snapshot.Revision;
        if (expected.Length > 0 && expected != revision) throw new WorkshopException("codex_artifact_changed", "原型在加载期间已更新，请重新打开。");
        var offsetValue = CodexJson.Field(parameters, "offset");
        var offset = offsetValue.ValueKind == JsonValueKind.Undefined ? 0 : offsetValue.TryGetInt32(out var number) ? number : -1;
        if (offset < 0 || offset > data.Length) throw CodexJson.Invalid();
        var count = Math.Min(24 * 1024, data.Length - offset);
        return new { artifact.Id, artifact.Name, revision, offset, total = data.Length, content = Convert.ToBase64String(data, offset, count), nextOffset = offset + count };
    }

    private static string ThreadId(JsonElement parameters)
    {
        var id = CodexJson.Required(parameters, "threadId", 36);
        return Guid.TryParse(id, out _) ? id : throw CodexJson.Invalid();
    }

    private static bool IsReparse(string path) => (File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0;
    private static bool SafePath(string path, string parent)
    {
        parent = Path.GetFullPath(parent).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
        path = Path.GetFullPath(path);
        if (!path.StartsWith(parent, StringComparison.OrdinalIgnoreCase)) return false;
        for (var current = path; current.Length >= parent.Length; current = Path.GetDirectoryName(current)!)
            if (IsReparse(current)) return false;
        return !IsReparse(parent.TrimEnd(Path.DirectorySeparatorChar));
    }

    public async ValueTask DisposeAsync()
    {
        await stopping.CancelAsync();
        Task[] running;
        lock (gate) running = jobs.Values.Select(job => job.Worker)
            .Concat(subagentTasks.Values.Select(index => index.Worker)).OfType<Task>().ToArray();
        await Task.WhenAll(running);
        lock (gate) running = jobs.Values.Select(job => job.PredictionWork).OfType<Task>().ToArray();
        await Task.WhenAll(running);
        await workers.DisposeAsync();
        await metadataGate.WaitAsync();
        try { if (metadata is not null) await metadata.DisposeAsync(); metadata = null; }
        finally { metadataGate.Release(); }
        stopping.Dispose();
    }
}
