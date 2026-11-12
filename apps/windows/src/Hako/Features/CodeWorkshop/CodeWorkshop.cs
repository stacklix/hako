using System;
using System.Collections.Generic;
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
    string Preview, long UpdatedAt, string State, string? OperationId, string? CompletionId = null);
internal sealed record WorkshopEvent(string Kind, string Id, string Text, string Role = "", string State = "", bool Truncated = false, string? ReplacesId = null, WorkshopAsyncQuestion[]? Questions = null, string? QuestionId = null);
internal sealed record WorkshopAsyncQuestion(string Title, string[] Options);
internal sealed record WorkshopArtifact(string Id, string Name, string Path, string ThreadId);

internal sealed partial class CodeWorkshop : IAsyncDisposable
{
    private readonly string root;
    private readonly string home;
    private readonly string storage;
    private readonly object gate = new();
    private readonly SemaphoreSlim metadataGate = new(1, 1);
    private readonly CancellationTokenSource stopping = new();
    private CodexAppServer? metadata;
    private readonly Func<CancellationToken, Task<CodexAppServer>> startServer;
    private readonly Dictionary<string, WorkshopJob> jobs = new();
    private readonly Dictionary<string, WorkshopArtifact> artifacts = new();
    private readonly HashSet<string> changingArchive = new();
    private bool recovered;

    public CodeWorkshop(string storage, string? root = null, string? codexHome = null,
        Func<CancellationToken, Task<CodexAppServer>>? startServer = null)
    {
        this.startServer = startServer ?? (token => CodexAppServer.StartAsync(token));
        this.storage = Path.GetFullPath(storage);
        this.root = Path.GetFullPath(root ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Code"));
        home = Path.GetFullPath(codexHome ?? Environment.GetEnvironmentVariable("CODEX_HOME") ??
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".codex"));
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
        await metadataGate.WaitAsync(token);
        try
        {
            metadata ??= await startServer(token);
            try { return await metadata.RequestAsync(method, parameters, token); }
            catch (Exception e) when (e is IOException or TimeoutException)
            {
                await metadata.DisposeAsync(); metadata = null;
                throw new WorkshopException("codex_connection_closed", "Codex 连接中断，请重新读取会话。");
            }
        }
        finally { metadataGate.Release(); }
    }

    public async Task<object?> CatalogAsync(JsonElement parameters, CancellationToken token)
    {
        CodexJson.Keys(parameters, "cursor", "archived");
        var archiveFilter = CodexJson.Field(parameters, "archived");
        if (archiveFilter.ValueKind is not (JsonValueKind.Undefined or JsonValueKind.True or JsonValueKind.False)) throw CodexJson.Invalid();
        lock (gate) RecoverJobs();
        var response = await ReadAsync("thread/list", new
        {
            limit = 30, cursor = CodexJson.Text(parameters, "cursor") is { Length: > 0 } cursor ? cursor : null,
            sortKey = "updated_at", archived = archiveFilter.ValueKind == JsonValueKind.True,
            modelProviders = Array.Empty<string>(), sourceKinds = new[] { "cli", "vscode", "appServer", "exec" }
        }, token);
        var applications = DiscoverApplications();
        var sessions = new List<WorkshopSession>();
        foreach (var thread in CodexJson.Items(CodexJson.Field(response, "data")))
        {
            var cwd = CodexJson.Text(thread, "cwd");
            var application = ApplicationFor(cwd);
            if (application is null) continue;
            if (applications.All(value => value.Id != application.Id)) applications.Add(application);
            var id = CodexJson.Text(thread, "id");
            var name = CodexJson.Text(thread, "name");
            var preview = CodexJson.Clip(CodexJson.Text(thread, "preview"), 240);
            var summary = await LatestSummaryAsync(id, token);
            var updated = CodexJson.Field(thread, "updatedAt");
            WorkshopJob? operation;
            string operationState;
            lock (gate)
            {
                operation = jobs.Values.Where(job => job.ThreadId == id).OrderByDescending(job => job.StartedAt).ThenByDescending(job => job.QueueOrder).FirstOrDefault();
                var current = operation is null ? null : CurrentJob(RootJob(operation));
                operationState = current is not null && (current.Active || current.State is "queued" or "paused")
                    ? current.State : summary.State;
            }
            // A thread-level active flag can outlive its turn. Keep the latest
            // turn's terminal state unless an actual local job is still active.
            sessions.Add(new(id, CodexJson.Clip(name.Length > 0 ? name : preview.Length > 0 ? preview : "未命名会话", 120),
                application.Id, cwd, summary.Preview, updated.TryGetInt64(out var time) ? time : 0,
                operationState, operation?.RootId ?? operation?.Id, operationState == "completed" ? summary.CompletionId : null));
        }
        return new { applications, sessions, nextCursor = CodexJson.Text(response, "nextCursor") is { Length: > 0 } next ? next : null };
    }

    internal sealed record ThreadSummary(string Preview, string State, string? CompletionId);

    internal static ThreadSummary SummarizeTurn(JsonElement turn)
    {
        var lastMessage = CodexJson.Items(CodexJson.Field(turn, "items")).Reverse().Select(Item)
            .FirstOrDefault(item => item?.Role is "user" or "assistant");
        var preview = lastMessage is null ? "" : CodexJson.Clip(Regex.Replace(lastMessage.Text, @"\s+", " ").Trim(), 240);
        var status = CodexJson.Text(turn, "status");
        var state = status == "inProgress" ? "running" : status.Length == 0 ? "idle" : status;
        var turnId = CodexJson.Text(turn, "id");
        return new(preview, state, status == "completed" && turnId.Length > 0 ? turnId : null);
    }

    private async Task<ThreadSummary> LatestSummaryAsync(string threadId, CancellationToken token)
    {
        var page = await ReadAsync("thread/turns/list", new { threadId, limit = 1, sortDirection = "desc", itemsView = "summary" }, token);
        var latest = SummarizeTurn(CodexJson.Items(CodexJson.Field(page, "data")).FirstOrDefault());
        var cursor = CodexJson.Text(page, "nextCursor");
        // A turn containing only tools still uses the last actual chat message.
        for (var pages = 1; latest.Preview.Length == 0 && cursor.Length > 0 && pages < 8; pages++)
        {
            var older = await ReadAsync("thread/turns/list", new { threadId, limit = 1, sortDirection = "desc", itemsView = "summary", cursor }, token);
            latest = latest with { Preview = SummarizeTurn(CodexJson.Items(CodexJson.Field(older, "data")).FirstOrDefault()).Preview };
            var next = CodexJson.Text(older, "nextCursor");
            if (next == cursor) break;
            cursor = next;
        }
        return latest;
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
        var before = cursor.Length == 0 ? int.MaxValue : int.TryParse(cursor, out var parsed) && parsed >= 0 ? parsed : throw CodexJson.Invalid();
        var thread = await ThreadAsync(id, true, token);
        var cwd = CodexJson.Text(thread, "cwd");
        var turns = CodexJson.Items(CodexJson.Field(thread, "turns")).ToArray();
        var items = turns
            .SelectMany(turn => CodexJson.Items(CodexJson.Field(turn, "items"))).ToArray();
        foreach (var item in items) DiscoverItemArtifacts(id, cwd, item);
        WorkshopJob[] sent;
        // Steer submits input to the existing turn without starting a new one.
        lock (gate) sent = jobs.Values.Where(job => job.ThreadId == id && (job.Submitted || job.State == "steered"))
            .OrderBy(job => job.QueueOrder).ToArray();
        var used = new HashSet<string>();
        var events = turns.SelectMany(turn => CodexJson.Items(CodexJson.Field(turn, "items"))
            .Select(item => HistoryItem(item, CodexJson.Text(turn, "id"), sent, used))).OfType<WorkshopEvent>().ToArray();
        var end = Math.Min(before, events.Length);
        var page = new List<WorkshopEvent>();
        var bytes = 0;
        var start = end;
        while (start > 0 && page.Count < 12)
        {
            var entry = events[start - 1];
            var size = JsonSerializer.SerializeToUtf8Bytes(entry, WorkshopProtocol.Json).Length;
            if (bytes + size > 38 * 1024 && page.Count > 0) break;
            page.Insert(0, entry); bytes += size; start--;
        }
        WorkshopArtifact[] files;
        string? operationId;
        lock (gate)
        {
            files = artifacts.Values.Where(value => value.ThreadId == id).Take(20).ToArray();
            var latest = jobs.Values.Where(job => job.ThreadId == id).OrderByDescending(job => job.StartedAt).ThenByDescending(job => job.QueueOrder).FirstOrDefault();
            operationId = latest?.RootId ?? latest?.Id;
        }
        var completionId = turns.Length == 0 ? null : SummarizeTurn(turns[^1]).CompletionId;
        object Page() => new { threadId = id, cwd, entries = page, artifacts = files, nextCursor = start > 0 ? start.ToString() : null, operationId, completionId };
        while (JsonSerializer.SerializeToUtf8Bytes(Page(), WorkshopProtocol.Json).Length > 56 * 1024 && files.Length > 0)
            files = files[..^1];
        return Page();
    }

    internal static WorkshopEvent? Item(JsonElement item)
    {
        var type = CodexJson.Text(item, "type");
        var id = CodexJson.Text(item, "id");
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
        return new(type is "commandExecution" or "fileChange" or "plan" ? type : "item", id, CodexJson.Clip(text, 8000), role, CodexJson.Text(item, "status"), text.Length > 8000, Questions: questions.Length > 0 ? questions : null);
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
            lock (gate) artifacts[id] = new(id, Path.GetFileNameWithoutExtension(path), path, threadId);
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
            await HistoryAsync(JsonSerializer.SerializeToElement(new { threadId = thread }), token);
            lock (gate) artifacts.TryGetValue(id, out artifact);
        }
        if (artifact is null || artifact.ThreadId != thread) throw new WorkshopException("codex_artifact_missing", "原型文件已变化，请刷新会话。");
        var cwd = CodexJson.Text(await ThreadAsync(thread, false, token), "cwd");
        if (!SafePath(artifact.Path, cwd) && !SafePath(artifact.Path, Path.Combine(home, "visualizations"))) throw CodexJson.Invalid();
        if (new FileInfo(artifact.Path).Length > 2 * 1024 * 1024) throw new WorkshopException("codex_artifact_large", "原型超过 2 MB，无法在手机中预览。");
        var data = await File.ReadAllBytesAsync(artifact.Path, token);
        var revision = Convert.ToHexString(SHA256.HashData(data)).ToLowerInvariant();
        var expected = CodexJson.Text(parameters, "revision");
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
        lock (gate) running = jobs.Values.Select(job => job.Worker).OfType<Task>().ToArray();
        await Task.WhenAll(running);
        await metadataGate.WaitAsync();
        try { if (metadata is not null) await metadata.DisposeAsync(); metadata = null; }
        finally { metadataGate.Release(); }
        stopping.Dispose();
    }
}
