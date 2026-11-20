using System;
using System.Collections.Generic;
using System.Linq;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace Hako.Platform;

internal sealed partial class CodeWorkshop
{
    private readonly Dictionary<string, long> recoveryAttempts = new();
    private readonly HashSet<string> recoveringThreads = new();

    // Recovery uses Codex's persisted clientId, never prompt text or "the latest
    // turn". Identical prompts and newer external turns must stay independent.
    private async Task RecoverUnknownAsync(string threadId, CancellationToken token)
    {
        WorkshopJob[] pending;
        lock (gate)
        {
            RecoverJobs();
            pending = jobs.Values.Where(job => job.ThreadId == threadId && job.State == "unknown" && job.Submitted).ToArray();
            if (pending.Length == 0 || recoveringThreads.Contains(threadId) ||
                recoveryAttempts.TryGetValue(threadId, out var last) && Environment.TickCount64 - last < 3000) return;
            recoveringThreads.Add(threadId);
            recoveryAttempts[threadId] = Environment.TickCount64;
        }
        using var budget = CancellationTokenSource.CreateLinkedTokenSource(token);
        budget.CancelAfter(TimeSpan.FromSeconds(15));
        try
        {
            var requests = pending.Where(job => !job.IsCompaction).Select(job => job.Id).ToHashSet();
            var matched = new Dictionary<string, string>();
            string? cursor = null;
            var visited = new HashSet<string>();
            for (var pageNumber = 0; requests.Count > 0 && pageNumber < 32; pageNumber++)
            {
                var page = await ReadAsync("thread/items/list", new { threadId, limit = 64, sortDirection = "desc", cursor }, budget.Token);
                foreach (var entry in CodexJson.Items(CodexJson.Field(page, "data")))
                {
                    var item = CodexJson.Field(entry, "item");
                    var clientId = CodexJson.Text(item, "clientId");
                    var turnId = CodexJson.Text(entry, "turnId");
                    if (CodexJson.Text(item, "type") == "userMessage" && turnId.Length > 0 && requests.Remove(clientId))
                        matched[clientId] = turnId;
                }
                cursor = CodexJson.Text(page, "nextCursor");
                if (cursor.Length == 0 || !visited.Add(cursor)) break;
            }
            lock (gate)
            {
                foreach (var job in pending.Where(job => job.State == "unknown"))
                    if (matched.TryGetValue(job.Id, out var turnId) && job.TurnId != turnId)
                    { job.TurnId = turnId; Persist(job); }
            }
            var targets = pending.Where(job => matched.ContainsKey(job.Id) || job.IsCompaction && job.TurnId is not null)
                .Select(job => job.TurnId!).ToHashSet();
            cursor = null; visited.Clear();
            for (var pageNumber = 0; targets.Count > 0 && pageNumber < 32; pageNumber++)
            {
                var page = await ReadAsync("thread/turns/list", new { threadId, limit = 32, sortDirection = "desc", itemsView = "notLoaded", cursor }, budget.Token);
                foreach (var summary in CodexJson.Items(CodexJson.Field(page, "data")))
                {
                    var turnId = CodexJson.Text(summary, "id");
                    if (!targets.Remove(turnId) || CodexJson.Text(summary, "status") is not ("completed" or "failed" or "interrupted")) continue;
                    // Read real final messages for notifications, not display summaries.
                    JsonElement[] actual = [];
                    string? replyCursor = null;
                    var replyPages = new HashSet<string>();
                    for (var replyPage = 0; replyPage < 32; replyPage++)
                    {
                        var replies = await ReadAsync("thread/items/list", new { threadId, turnId, limit = 64, sortDirection = "desc", cursor = replyCursor }, budget.Token);
                        actual = CodexJson.Items(CodexJson.Field(replies, "data"))
                            .Where(entry => CodexJson.Text(entry, "turnId") == turnId)
                            .Select(entry => CodexJson.Field(entry, "item")).Reverse().ToArray();
                        replyCursor = CodexJson.Text(replies, "nextCursor");
                        if (actual.Any(item => CodexJson.Text(item, "type") == "agentMessage") || replyCursor.Length == 0 || !replyPages.Add(replyCursor)) break;
                    }
                    var turn = JsonSerializer.SerializeToElement(new {
                        id = turnId, status = CodexJson.Text(summary, "status"), items = actual,
                        error = CodexJson.Field(summary, "error").ValueKind == JsonValueKind.Object ? CodexJson.Field(summary, "error") : (JsonElement?)null,
                        completedAt = CodexJson.Field(summary, "completedAt").ValueKind == JsonValueKind.Number ? CodexJson.Field(summary, "completedAt") : (JsonElement?)null
                    }, WorkshopProtocol.Json);
                    lock (gate)
                    {
                        foreach (var job in pending.Where(job => job.State == "unknown" && job.TurnId == turnId &&
                            (matched.ContainsKey(job.Id) || job.IsCompaction)))
                            if (ReconcileTurn(job, [turn]))
                            { Persist(job); if (job.RootId is not null) AppendFollowup(job); }
                    }
                }
                cursor = CodexJson.Text(page, "nextCursor");
                if (cursor.Length == 0 || !visited.Add(cursor)) break;
            }
            queryLog.Write("operation/reconcile", 0, 0, matched.Count > 0 ? "matched" : "unconfirmed");
        }
        finally { lock (gate) recoveringThreads.Remove(threadId); }
    }
}
