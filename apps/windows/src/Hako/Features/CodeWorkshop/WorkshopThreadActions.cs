using System;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace Hako.Platform;

internal sealed partial class CodeWorkshop
{
    public async Task<object?> RenameAsync(JsonElement parameters, CancellationToken token)
    {
        CodexJson.Keys(parameters, "threadId", "applicationId", "name");
        var id = ThreadId(parameters);
        var name = CodexJson.Required(parameters, "name", 120).Trim();
        if (name.Length == 0 || name.Any(char.IsControl)) throw CodexJson.Invalid();
        var thread = await ThreadAsync(id, false, token);
        if (ApplicationFor(CodexJson.Text(thread, "cwd"))?.Id != CodexJson.Required(parameters, "applicationId", 100))
            throw new WorkshopException("codex_workspace_invalid", "会话与所选项目不一致，请刷新列表。");
        await ReadAsync("thread/name/set", new { threadId = id, name }, token);
        lock (gate)
        {
            RecoverJobs();
            foreach (var job in jobs.Values.Where(job => job.ThreadId == id)) { job.SessionName = name; Persist(job); }
        }
        return new { threadId = id, name };
    }

    public async Task<object?> CompactAsync(JsonElement parameters, CancellationToken token)
    {
        CodexJson.Keys(parameters, "threadId", "applicationId", "requestId", "permission");
        var threadId = ThreadId(parameters);
        var id = OperationId(parameters, "requestId");
        var applicationId = CodexJson.Required(parameters, "applicationId", 100);
        var permission = CodexJson.Required(parameters, "permission", 20);
        if (permission is not ("ask" or "auto" or "full" or "custom")) throw CodexJson.Invalid();
        var fingerprint = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes("compact\n" + applicationId + "\n" + threadId + "\n" + permission)));
        lock (gate)
        {
            RecoverJobs();
            if (jobs.ContainsKey(id) || System.IO.File.Exists(JobPath(id)))
            {
                var old = GetJob(id);
                if (old.Fingerprint != fingerprint) throw new WorkshopException("codex_request_conflict", "请求 ID 已用于其他操作。");
                return Summary(old);
            }
            if (changingArchive.Contains(threadId) || jobs.Values.Any(job => job.ThreadId == threadId &&
                (job.Active || job.State is "queued" or "paused" or "steering")))
                throw new WorkshopException("codex_busy", "请先结束当前任务并处理排队消息，再压缩上下文。");
            changingArchive.Add(threadId);
        }
        try
        {
            var thread = await ThreadAsync(threadId, false, token);
            var cwd = CodexJson.Text(thread, "cwd");
            if (ApplicationFor(cwd)?.Id != applicationId)
                throw new WorkshopException("codex_workspace_invalid", "会话与所选项目不一致，请刷新列表。");
            if (CodexJson.Text(CodexJson.Field(thread, "status"), "type") == "active")
                throw new WorkshopException("codex_busy", "会话仍在执行任务，请结束后再压缩。");
            token.ThrowIfCancellationRequested();
            lock (gate)
            {
                var job = new WorkshopJob { Id = id, Fingerprint = fingerprint, ApplicationId = applicationId,
                    Cwd = cwd, ThreadId = threadId, IsCompaction = true, Permission = permission,
                    SessionName = NotificationText(CodexJson.Text(thread, "name"), 120), QueueOrder = DateTime.UtcNow.Ticks };
                Persist(job);
                jobs.Add(id, job);
                Append(job, new("notice", id, "正在压缩上下文…"));
                job.Worker = Task.Run(() => ExecuteAsync(job, "", "", "", permission, [], ""));
                return Summary(job);
            }
        }
        finally { lock (gate) changingArchive.Remove(threadId); }
    }
}
