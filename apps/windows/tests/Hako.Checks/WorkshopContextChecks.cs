using System;
using System.Collections.Generic;
using System.IO;
using System.Reflection;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Hako.Platform;

internal static class WorkshopContextChecks
{
    private static JsonElement Json(object value) => JsonSerializer.SerializeToElement(value, WorkshopProtocol.Json);
    private static void Check(bool value, string message) { if (!value) throw new Exception(message); }

    internal static async Task RunAsync()
    {
        var directory = Path.Combine(Path.GetTempPath(), "hako-context-" + Guid.NewGuid().ToString("N"));
        var home = Path.Combine(directory, "codex");
        var storage = Path.Combine(directory, "state");
        Directory.CreateDirectory(home); Directory.CreateDirectory(storage);
        var thread = Guid.NewGuid().ToString("D");
        var path = Path.Combine(home, "rollout-" + thread + ".jsonl");
        var at = DateTimeOffset.UtcNow.AddMinutes(-1);
        object Row(long used, long? window = 160000) => new { timestamp = at, type = "event_msg", payload = new {
            type = "token_count", info = new { last_token_usage = new { total_tokens = used },
                total_token_usage = new { total_tokens = 999999999 }, model_context_window = window } } };
        try
        {
            await using var service = new CodeWorkshop(storage, directory, home);
            await File.WriteAllTextAsync(path, Json(Row(67200)).GetRawText() + "\n" + "{unfinished");
            var restored = await service.ReadContextUsageAsync(thread, path, default);
            Check(restored?.UsedTokens == 67200 && restored.ModelContextWindow == 160000 && restored.UpdatedAt == at.ToUnixTimeMilliseconds(),
                "Native context must restore the last request, not cumulative session usage, ignoring an unfinished tail");
            Check(await service.ReadContextUsageAsync(Guid.NewGuid().ToString("D"), path, default) is null,
                "Another thread's rollout was accepted");
            var outside = Path.Combine(directory, "outside-" + thread + ".jsonl");
            File.Copy(path, outside);
            Check(await service.ReadContextUsageAsync(thread, outside, default) is null, "Context read escaped Codex home");
            await File.AppendAllTextAsync(path, "}\n" + Json(new { timestamp = at.AddSeconds(1), type = "compacted", payload = new { } }).GetRawText() + "\n");
            var compacted = await service.ReadContextUsageAsync(thread, path, default);
            Check(compacted is { UsedTokens: null, ModelContextWindow: null }, "Compaction retained obsolete occupancy");
            await File.AppendAllTextAsync(path, Json(Row(1200)).GetRawText() + "\n");
            Check((await service.ReadContextUsageAsync(thread, path, default))?.UsedTokens == 1200,
                "A reduced context after compaction was rejected");
            await File.WriteAllTextAsync(path, Json(Row(1)).GetRawText() + "\n" + new string('x', 8 * 1024 * 1024) + "\n");
            Check(await service.ReadContextUsageAsync(thread, path, default) is null, "Context lookup exceeded its bounded tail");
            using var cancelled = new CancellationTokenSource(); cancelled.Cancel();
            try { await service.ReadContextUsageAsync(thread, path, cancelled.Token); throw new Exception("Context lookup ignored cancellation"); }
            catch (OperationCanceledException) { }

            var job = new WorkshopJob { Id = Guid.NewGuid().ToString("D"), ApplicationId = "fixture", ThreadId = thread,
                TurnId = "current", State = "running", Submitted = true };
            var jobs = (Dictionary<string, WorkshopJob>)typeof(CodeWorkshop).GetField("jobs", BindingFlags.Instance | BindingFlags.NonPublic)!.GetValue(service)!;
            jobs.Add(job.Id, job);
            var receive = typeof(CodeWorkshop).GetMethod("Receive", BindingFlags.Instance | BindingFlags.NonPublic)!;
            void Usage(long used, long? window = 160000, string? forThread = null, string turn = "current") =>
                receive.Invoke(service, [job, Json(new { method = "thread/tokenUsage/updated", @params = new {
                    threadId = forThread ?? thread, turnId = turn, tokenUsage = new { last = new { totalTokens = used },
                        total = new { totalTokens = 999999999 }, modelContextWindow = window } } })]);
            var ready = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            var updated = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            using var life = new CancellationTokenSource();
            var watch = service.WatchOperationAsync(Json(new { operationId = job.Id, cursor = 0L }), page => {
                ready.TrySetResult();
                if (CodexJson.Field(CodexJson.Field(page.GetProperty("operation"), "contextUsage"), "usedTokens").TryGetNonnegativeInt64() == 67200)
                    updated.TrySetResult();
                return Task.CompletedTask;
            }, life.Token);
            await ready.Task.WaitAsync(TimeSpan.FromSeconds(3));
            Usage(67200);
            await updated.Task.WaitAsync(TimeSpan.FromSeconds(3));
            Check(job.ContextUsage?.UsedTokens == 67200, "Live context used session-wide cumulative usage");
            var persisted = JsonSerializer.Deserialize<WorkshopJob>(File.ReadAllBytes(Path.Combine(storage, job.Id + ".json")), WorkshopProtocol.Json)!;
            Check(persisted.ContextUsage == job.ContextUsage, "Live context was not durable");
            Usage(1, forThread: Guid.NewGuid().ToString("D")); Usage(2, turn: "old-turn");
            Check(job.ContextUsage?.UsedTokens == 67200, "Foreign thread or previous-turn usage replaced the current context");
            Usage(100, window: null);
            Check(job.ContextUsage is { UsedTokens: 100, ModelContextWindow: null }, "Unknown model window was fabricated");
            receive.Invoke(service, [job, Json(new { method = "item/started", @params = new { threadId = thread, turnId = "current",
                item = new { id = "compact", type = "contextCompaction" } } })]);
            Check(job.ContextUsage is { UsedTokens: null, ModelContextWindow: null }, "Live compaction did not invalidate the previous context");
            Usage(1200);
            Check(job.ContextUsage?.UsedTokens == 1200, "Reduced live occupancy was not accepted");
            job.Submitted = false; Usage(500, turn: "restored-turn");
            Check(job.ContextUsage?.UsedTokens == 500, "Usage replayed on resume was discarded with old task events");
            life.Cancel();
            try { await watch; } catch (OperationCanceledException) { }
        }
        finally { Directory.Delete(directory, recursive: true); }
        Console.WriteLine("PASS: context restoration, bounded reads, isolation, live push, persistence, unknown windows and compaction");
    }
}
