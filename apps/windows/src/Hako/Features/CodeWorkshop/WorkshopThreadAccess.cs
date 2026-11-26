using System;
using System.Linq;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Hako.Core;

namespace Hako.Platform;

internal sealed record WorkshopThreadAccess(string State, long CheckedAt);

internal sealed partial class CodeWorkshop
{
    private WorkshopThreadAccess ThreadAccess(string threadId)
    {
        lock (gate)
        {
            var state = jobs.Values.Any(job => job.ThreadId == threadId && job.OwnsThreadWriter) ? "workshop" :
                // Codex can acquire its byte lock before acknowledging resume.
                // Until that RPC finishes, neither ownership nor an external
                // conflict has been established; report uncertainty without blocking input.
                jobs.Values.Any(job => job.ThreadId == threadId && job.AcquiringThreadWriter) ? "unknown" :
                readWriter(threadId) switch { CodexWriterState.Free => "available", CodexWriterState.Held => "occupied", _ => "unknown" };
            return new(state, DateTimeOffset.UtcNow.ToUnixTimeMilliseconds());
        }
    }

    private void RequireThreadAccess(string? threadId)
    {
        if (threadId is null || threadId.Length == 0) return;
        var access = ThreadAccess(threadId);
        if (access.State == "occupied") throw new WorkshopException("codex_thread_occupied", "其他客户端占用此会话，请释放后再发送。文字和图片已保留。");
    }

    public async Task<object?> ThreadAccessAsync(JsonElement parameters, CancellationToken token)
    {
        CodexJson.Keys(parameters, "threadId", "applicationId");
        var id = ThreadId(parameters);
        var thread = await ThreadAsync(id, false, token);
        if (ApplicationFor(CodexJson.Text(thread, "cwd"))?.Id != CodexJson.Required(parameters, "applicationId", 100))
            throw new WorkshopException("codex_workspace_invalid", "会话与所选项目不一致，请刷新列表。");
        token.ThrowIfCancellationRequested();
        lock (gate) { RecoverJobs(); return ThreadAccess(id); }
    }
}
