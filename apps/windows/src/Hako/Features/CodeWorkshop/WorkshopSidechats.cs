using System;
using System.Collections.Generic;
using System.Linq;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace Hako.Platform;

internal sealed partial class CodeWorkshop
{
    private WorkshopJob? SidechatRoot(string? threadId)
    {
        if (string.IsNullOrEmpty(threadId)) return null;
        lock (gate)
        {
            RecoverJobs();
            return jobs.Values.FirstOrDefault(job => job.ThreadId == threadId && job.ParentThreadId is not null);
        }
    }

    public async Task<object?> SidechatsAsync(JsonElement parameters, CancellationToken token)
    {
        CodexJson.Keys(parameters, "threadId", "applicationId", "cursor");
        var parentId = ThreadId(parameters);
        var applicationId = CodexJson.Required(parameters, "applicationId", 100);
        var cursor = CodexJson.Text(parameters, "cursor");
        if (cursor.Length > 0 && !Guid.TryParse(cursor, out _)) throw CodexJson.Invalid();
        var parent = await ThreadAsync(parentId, false, token);
        if (ApplicationFor(CodexJson.Text(parent, "cwd"))?.Id != applicationId)
            throw new WorkshopException("codex_workspace_invalid", "主会话与所选项目不一致。");
        WorkshopJob[] children;
        bool more;
        lock (gate)
        {
            RecoverJobs();
            var position = cursor.Length == 0 ? null : jobs.GetValueOrDefault(cursor);
            if (cursor.Length > 0 && (position is null || position.ParentThreadId != parentId || position.ApplicationId != applicationId)) throw CodexJson.Invalid();
            var page = jobs.Values.Where(job => job.ParentThreadId == parentId && job.ThreadId is not null &&
                    (position is null || job.QueueOrder < position.QueueOrder || job.QueueOrder == position.QueueOrder && StringComparer.Ordinal.Compare(job.Id, position.Id) > 0))
                .OrderByDescending(job => job.QueueOrder).ThenBy(job => job.Id, StringComparer.Ordinal).Take(31).ToArray();
            more = page.Length > 30;
            children = page.Take(30).ToArray();
        }
        var sessions = new WorkshopSession[children.Length];
        await Parallel.ForEachAsync(Enumerable.Range(0, children.Length),
            new ParallelOptions { MaxDegreeOfParallelism = 4, CancellationToken = token }, async (index, cancellation) =>
        {
            var root = children[index];
            var id = root.ThreadId!;
            var thread = await ThreadAsync(id, false, cancellation);
            var summary = await LatestSummaryAsync(id, cancellation);
            if (!root.Submitted || summary.TurnId == root.InheritedTurnId) summary = summary with { Preview = root.InputMessage };
            WorkshopJob latest;
            lock (gate)
            {
                latest = jobs.Values.Where(job => job.ThreadId == id).MaxBy(job => job.QueueOrder)!;
                summary = ReconcileSummary(summary, CurrentJob(RootJob(latest)));
            }
            var title = CodexJson.Text(thread, "name");
            sessions[index] = new(id, CodexJson.Clip(title.Length > 0 ? title : root.SessionName, 120), applicationId, root.Cwd,
                summary.Preview, CodexJson.Field(thread, "updatedAt").GetInt64(), summary.State,
                latest.RootId ?? latest.Id, summary.CompletionId, AcceptedAt(latest), ThreadAccess(id), parentId);
        });
        var count = sessions.Length;
        object Result() => new { sessions = sessions.Take(count).ToArray(),
            nextCursor = (more || count < sessions.Length) && count > 0 ? children[count - 1].Id : null };
        while (count > 1 && JsonSerializer.SerializeToUtf8Bytes(Result(), WorkshopProtocol.Json).Length > 56 * 1024) count--;
        if (JsonSerializer.SerializeToUtf8Bytes(Result(), WorkshopProtocol.Json).Length > 56 * 1024)
            throw new WorkshopException("codex_sidechat_too_large", "侧聊记录过大，无法读取列表。");
        return Result();
    }
}
