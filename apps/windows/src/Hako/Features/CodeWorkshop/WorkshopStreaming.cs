using System;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Hako.Core;

namespace Hako.Platform;

internal sealed partial class CodeWorkshop
{
    // Capture the next signal before reading, so changes during the read or
    // publication cannot be lost. Recovery may await Codex and reacquire gate;
    // never hold the monitor while waiting for an asynchronous operation read.
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
            lock (gate) signal = changed.Task;
            var request = JsonSerializer.SerializeToElement(new { operationId = id, cursor }, WorkshopProtocol.Json);
            var page = JsonSerializer.SerializeToElement(await OperationAsync(request, lifetime.Token), WorkshopProtocol.Json);
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
