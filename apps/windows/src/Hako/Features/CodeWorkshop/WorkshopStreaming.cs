using System;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Hako.Core;

namespace Hako.Platform;

internal sealed partial class CodeWorkshop
{
    // All mutations and snapshot reads hold gate. Capture the next signal before
    // reading, so an event arriving during publication cannot be lost.
    private TaskCompletionSource<bool> changed = NewSignal();
    private static TaskCompletionSource<bool> NewSignal() => new(TaskCreationOptions.RunContinuationsAsynchronously);
    private void SignalChange()
    {
        var previous = changed;
        changed = NewSignal();
        previous.TrySetResult(true);
    }

    internal async Task WatchOperationAsync(JsonElement parameters, Func<JsonElement, Task> publish, CancellationToken token)
    {
        CodexJson.Keys(parameters, "operationId", "cursor");
        var id = OperationId(parameters);
        var cursor = CodexJson.Field(parameters, "cursor").GetInt64();
        using var lifetime = CancellationTokenSource.CreateLinkedTokenSource(token, stopping.Token);
        string? previous = null;
        while (true)
        {
            lifetime.Token.ThrowIfCancellationRequested();
            Task signal;
            JsonElement page;
            lock (gate)
            {
                signal = changed.Task;
                var request = JsonSerializer.SerializeToElement(new { operationId = id, cursor }, AgentConnection.Json);
                page = JsonSerializer.SerializeToElement(OperationAsync(request, lifetime.Token).GetAwaiter().GetResult(), AgentConnection.Json);
            }
            var payload = page.GetRawText();
            if (payload != previous) { await publish(page); previous = payload; }
            cursor = page.GetProperty("cursor").GetInt64();
            if (page.GetProperty("hasMore").GetBoolean()) continue;
            await signal.WaitAsync(lifetime.Token);
            // Coalesce token bursts without polling or delaying status recovery.
            await Task.Delay(25, lifetime.Token);
        }
    }
}
