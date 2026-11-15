using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace Hako.Platform;

internal sealed partial class CodeWorkshop
{
    internal sealed record CatalogRow(JsonElement Thread, WorkshopApplication Application, long LastSentAt)
    {
        public string Id => CodexJson.Text(Thread, "id");
    }
    private sealed record CatalogPosition(long LastSentAt, string Id, bool Archived);

    // QueueOrder is assigned when the computer accepts a send and remains
    // unchanged when that queued send starts, completes, or is read again.
    internal static long CatalogSendTime(JsonElement thread, ThreadSummary? summary, WorkshopJob[] sent)
    {
        var recency = CodexJson.Field(thread, "recencyAt");
        var time = recency.ValueKind == JsonValueKind.Number && recency.TryGetInt64(out var value) ? value : 0;
        if (summary is not null)
        {
            var user = HistoryItem(summary.UserInput, summary.TurnId,
                sent.OrderByDescending(job => job.QueueOrder).ToArray(), new HashSet<string>());
            var matching = user is null ? null : sent.FirstOrDefault(job => job.Id == user.Id);
            if (matching is not null) time = AcceptedAt(matching);
        }
        return Math.Max(time, sent.Select(AcceptedAt).DefaultIfEmpty(0).Max());
    }

    private static long AcceptedAt(WorkshopJob job) => job.QueueOrder <= DateTime.UnixEpoch.Ticks ? 0 :
        (job.QueueOrder - DateTime.UnixEpoch.Ticks) / TimeSpan.TicksPerSecond;

    internal static (CatalogRow[] Rows, string? NextCursor) CatalogPage(IEnumerable<CatalogRow> rows, string cursor, bool archived)
    {
        CatalogPosition? position = null;
        if (cursor.Length > 0)
        {
            try
            {
                if (cursor.Length > 512) throw new FormatException();
                position = JsonSerializer.Deserialize<CatalogPosition>(Convert.FromBase64String(cursor), WorkshopProtocol.Json);
                if (position is null || position.Archived != archived || position.LastSentAt < 0 || !Guid.TryParse(position.Id, out _))
                    throw new FormatException();
            }
            catch (Exception error) when (error is FormatException or JsonException) { throw CodexJson.Invalid(); }
        }
        var page = rows.Where(row => position is null || row.LastSentAt < position.LastSentAt ||
                row.LastSentAt == position.LastSentAt && StringComparer.Ordinal.Compare(row.Id, position.Id) > 0)
            .OrderByDescending(row => row.LastSentAt).ThenBy(row => row.Id, StringComparer.Ordinal).Take(31).ToArray();
        var selected = page.Take(30).ToArray();
        var next = page.Length > 30 ? Convert.ToBase64String(JsonSerializer.SerializeToUtf8Bytes(
            new CatalogPosition(selected[^1].LastSentAt, selected[^1].Id, archived), WorkshopProtocol.Json)) : null;
        return (selected, next);
    }

    public async Task<object?> CatalogAsync(JsonElement parameters, CancellationToken token)
    {
        CodexJson.Keys(parameters, "cursor", "archived");
        var filter = CodexJson.Field(parameters, "archived");
        if (filter.ValueKind is not (JsonValueKind.Undefined or JsonValueKind.True or JsonValueKind.False)) throw CodexJson.Invalid();
        var archived = filter.ValueKind == JsonValueKind.True;
        var applications = DiscoverApplications();
        var candidates = new Dictionary<string, (JsonElement Thread, WorkshopApplication Application)>();
        string? next = null;
        var visited = new HashSet<string>();
        // Read lightweight metadata before paging: an accepted queued message
        // can promote a thread that was on any upstream page. Full turns are
        // read only for our own sends and for the selected display page.
        do
        {
            token.ThrowIfCancellationRequested();
            var page = await ReadAsync("thread/list", new { limit = 100, cursor = next, sortKey = "recency_at", sortDirection = "desc",
                archived, useStateDbOnly = true, modelProviders = Array.Empty<string>(),
                sourceKinds = new[] { "cli", "vscode", "appServer", "exec" } }, token);
            foreach (var thread in CodexJson.Items(CodexJson.Field(page, "data")))
            {
                var application = ApplicationFor(CodexJson.Text(thread, "cwd"));
                if (application is not null) candidates[CodexJson.Text(thread, "id")] = (thread, application);
            }
            next = CodexJson.Text(page, "nextCursor");
            if (next.Length > 0 && !visited.Add(next)) throw new WorkshopException("codex_catalog_cursor", "会话列表游标未前进，请重新刷新。");
        } while (next.Length > 0);

        Dictionary<string, WorkshopJob[]> sent;
        lock (gate)
        {
            RecoverJobs();
            sent = jobs.Values.Where(job => job.ThreadId is not null).GroupBy(job => job.ThreadId!)
                .ToDictionary(group => group.Key, group => group.ToArray());
        }
        var summaries = new Dictionary<string, ThreadSummary>();
        var rows = new List<CatalogRow>();
        foreach (var (id, candidate) in candidates)
        {
            ThreadSummary? summary = null;
            if (sent.ContainsKey(id)) summaries[id] = summary = await LatestSummaryAsync(id, token);
            rows.Add(new(candidate.Thread, candidate.Application, CatalogSendTime(candidate.Thread, summary, sent.GetValueOrDefault(id) ?? [])));
        }
        var selected = CatalogPage(rows, CodexJson.Text(parameters, "cursor"), archived);
        var sessions = new List<WorkshopSession>();
        foreach (var row in selected.Rows)
        {
            if (applications.All(value => value.Id != row.Application.Id)) applications.Add(row.Application);
            var summary = summaries.GetValueOrDefault(row.Id) ?? await LatestSummaryAsync(row.Id, token);
            WorkshopJob? operation;
            lock (gate)
            {
                operation = jobs.Values.Where(job => job.ThreadId == row.Id).OrderByDescending(job => job.StartedAt).ThenByDescending(job => job.QueueOrder).FirstOrDefault();
                summary = ReconcileSummary(summary, operation is null ? null : CurrentJob(RootJob(operation)));
            }
            var name = CodexJson.Text(row.Thread, "name");
            var preview = CodexJson.Text(row.Thread, "preview");
            sessions.Add(new(row.Id, CodexJson.Clip(name.Length > 0 ? name : preview.Length > 0 ? preview : "未命名会话", 120),
                row.Application.Id, CodexJson.Text(row.Thread, "cwd"), summary.Preview,
                CodexJson.Field(row.Thread, "updatedAt").GetInt64(), summary.State, operation?.RootId ?? operation?.Id,
                summary.CompletionId, row.LastSentAt));
        }
        return new { applications, sessions, nextCursor = selected.NextCursor };
    }
}
