using System;
using System.Linq;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace Hako.Platform;

internal sealed record WorkshopSubagent(string Id, string Name, string Role, string Task, string State,
    string Model, string ReasoningEffort, long UpdatedAt);

internal sealed partial class CodeWorkshop
{
    internal static bool IsDirectSubagent(JsonElement thread, string parent) =>
        CodexJson.Text(thread, "parentThreadId") == parent &&
        CodexJson.Field(CodexJson.Field(thread, "source"), "subAgent").ValueKind == JsonValueKind.Object;

    internal static WorkshopSubagent Subagent(JsonElement thread, string state)
    {
        var id = CodexJson.Text(thread, "id");
        var name = CodexJson.Text(thread, "agentNickname");
        var updated = CodexJson.Field(thread, "updatedAt");
        return new(id, CodexJson.Clip(name.Length > 0 ? name : "子代理", 80),
            CodexJson.Clip(CodexJson.Text(thread, "agentRole"), 60),
            CodexJson.Clip(CodexJson.Text(thread, "preview"), 160), state,
            CodexJson.Clip(CodexJson.Text(thread, "model"), 80),
            CodexJson.Clip(CodexJson.Text(thread, "reasoningEffort"), 20),
            updated.ValueKind == JsonValueKind.Number && updated.TryGetInt64(out var time) ? time : 0);
    }

    private async Task<string> SubagentParentAsync(JsonElement parameters, CancellationToken token)
    {
        var id = ThreadId(parameters);
        var parent = await ThreadAsync(id, false, token);
        if (ApplicationFor(CodexJson.Text(parent, "cwd"))?.Id != CodexJson.Required(parameters, "applicationId", 100))
            throw new WorkshopException("codex_workspace_invalid", "主会话与所选项目不一致。");
        return id;
    }

    public async Task<object?> SubagentsAsync(JsonElement parameters, CancellationToken token)
    {
        CodexJson.Keys(parameters, "threadId", "applicationId", "cursor");
        var parent = await SubagentParentAsync(parameters, token);
        var cursor = CodexJson.Text(parameters, "cursor");
        if (cursor.Length > 8192) throw CodexJson.Invalid();
        // Ask Codex to filter by the actual parent, rather than scanning unrelated sessions.
        var page = await ReadAsync("thread/list", new { parentThreadId = parent, limit = 20,
            cursor = cursor.Length == 0 ? null : cursor, sortKey = "updated_at", sortDirection = "desc",
            sourceKinds = new[] { "subAgentThreadSpawn" }, modelProviders = Array.Empty<string>(), useStateDbOnly = true }, token);
        var threads = CodexJson.Items(CodexJson.Field(page, "data")).Where(thread => IsDirectSubagent(thread, parent)).Take(20).ToArray();
        var agents = new WorkshopSubagent[threads.Length];
        await Parallel.ForEachAsync(Enumerable.Range(0, threads.Length),
            new ParallelOptions { MaxDegreeOfParallelism = 4, CancellationToken = token }, async (index, cancellation) =>
        {
            var turn = await ReadAsync("thread/turns/list", new { threadId = CodexJson.Text(threads[index], "id"),
                limit = 1, sortDirection = "desc", itemsView = "summary" }, cancellation);
            agents[index] = Subagent(threads[index], SummarizeTurn(CodexJson.Items(CodexJson.Field(turn, "data")).FirstOrDefault()).State);
        });
        return new { agents, nextCursor = CodexJson.Text(page, "nextCursor") is { Length: > 0 } next ? next : null };
    }

    public async Task<object?> SubagentReadAsync(JsonElement parameters, CancellationToken token)
    {
        CodexJson.Keys(parameters, "threadId", "applicationId", "agentId", "cursor");
        var parent = await SubagentParentAsync(parameters, token);
        var id = CodexJson.Required(parameters, "agentId", 100);
        if (!Guid.TryParse(id, out _)) throw CodexJson.Invalid();
        var thread = await ThreadAsync(id, false, token);
        if (!IsDirectSubagent(thread, parent))
            throw new WorkshopException("codex_subagent_invalid", "该子代理不属于当前会话。");
        return await HistoryAsync(JsonSerializer.SerializeToElement(new { threadId = id,
            cursor = CodexJson.Text(parameters, "cursor") }, WorkshopProtocol.Json), token);
    }
}
