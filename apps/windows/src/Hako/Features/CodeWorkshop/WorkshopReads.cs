using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace Hako.Platform;

// A cancelled reader must not cancel a read shared with another client. Only
// overlapping reads are joined; completed results are never reused as fresh data.
internal sealed class WorkshopReads
{
    private readonly object gate = new();
    private readonly Dictionary<string, Task<JsonElement>> pending = new();

    internal Task<JsonElement> RunAsync(string key, Func<Task<JsonElement>> read, CancellationToken token)
    {
        token.ThrowIfCancellationRequested();
        Task<JsonElement> task;
        lock (gate)
        {
            if (!pending.TryGetValue(key, out task!))
            {
                var completion = new TaskCompletionSource<JsonElement>(TaskCreationOptions.RunContinuationsAsynchronously);
                task = completion.Task;
                pending.Add(key, task);
                _ = CompleteAsync(key, read, completion);
            }
        }
        return task.WaitAsync(token);
    }

    private async Task CompleteAsync(string key, Func<Task<JsonElement>> read, TaskCompletionSource<JsonElement> completion)
    {
        try
        {
            var result = await read();
            lock (gate) pending.Remove(key);
            completion.TrySetResult(result);
        }
        catch (Exception error)
        {
            lock (gate) pending.Remove(key);
            // Observe the failure even if all callers cancelled their own waits.
            completion.TrySetException(error);
            _ = completion.Task.Exception;
        }
    }
}

internal sealed class WorkshopQueryLog(string storage)
{
    private readonly object gate = new();
    internal void Write(string method, long waitMs, long readMs, string outcome)
    {
        try
        {
            lock (gate)
            {
                Directory.CreateDirectory(storage);
                var path = Path.Combine(storage, "queries.jsonl");
                if (File.Exists(path) && new FileInfo(path).Length >= 1_048_576)
                    File.Move(path, path + ".previous", true);
                // No parameters, conversation content, credentials or response bodies.
                File.AppendAllText(path, JsonSerializer.Serialize(new {
                    time = DateTimeOffset.UtcNow, method, waitMs, readMs, outcome
                }) + "\n");
            }
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        { Debug.WriteLine(error.GetType().Name); }
    }
}
