using System;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Hako.Platform;

namespace Hako.Core;

// WorkshopTerminal omits OperationId from the cloud result body. Preserve it
// separately on the local hop so the guardian can rebuild the cloud envelope.
internal sealed record LocalWorkshopTerminal(string OperationId, WorkshopTerminal Result);

internal sealed class GuardianWorkshopDispatcher(string profile) : IWorkshopDispatcher
{
    private string? scope;
    public void SetNotificationScope(string? value) => scope = value;
    public async Task<object?> CallAsync(string method, JsonElement parameters, CancellationToken token)
    {
        if (parameters.ValueKind != JsonValueKind.Object) throw CodexJson.Invalid();
        if (method == "commands.open")
        {
            CodexJson.Keys(parameters);
            return await CommandHost.OpenAsync(profile, token);
        }
        try { return await LocalRpc.CallAsync(LocalRpc.MainPipe(profile), new("workshop", method, 1, parameters, scope), token); }
        catch (AgentActionException error) { throw Failure(error); }
    }
    public async Task WatchAsync(JsonElement parameters, Func<JsonElement, Task> publish, CancellationToken token)
    {
        try { await LocalRpc.StreamAsync(LocalRpc.MainPipe(profile), new("workshop.watch", "", 1, parameters, scope), publish, token); }
        catch (AgentActionException error) { throw Failure(error); }
    }
    private static WorkshopException Failure(AgentActionException error) => new(error.Code,
        error.Code is "process_unavailable" or "process_disconnected"
            ? "电脑端会话服务暂时不可用，可能正在启动、更新或重启。请稍后重新同步；任务是否结束需恢复后确认。"
            : error.Message);
    public async Task WatchTerminalsAsync(string scope, Func<WorkshopTerminal, Task> publish, CancellationToken token)
    {
        while (!token.IsCancellationRequested)
        {
            try
            {
                await LocalRpc.StreamAsync(LocalRpc.MainPipe(profile), LocalRpc.Request("workshop.terminals", scope: scope),
                    value =>
                    {
                        var terminal = value.Deserialize<LocalWorkshopTerminal>(WorkshopProtocol.Json)!;
                        return publish(terminal.Result with { OperationId = terminal.OperationId });
                    }, token);
            }
            catch (AgentActionException) { /* Reattach this read-only stream when the main process returns. */ }
            await Task.Delay(1000, token);
        }
    }
    public async Task AcknowledgeTerminalAsync(string scope, string id, string questionId, CancellationToken token)
    {
        try { await LocalRpc.CallAsync(LocalRpc.MainPipe(profile), LocalRpc.Request("workshop.ack", parameters: new { id, questionId }, scope: scope), token); }
        catch (AgentActionException) { /* Unacknowledged durable terminals are delivered again after reattachment. */ }
    }
}
