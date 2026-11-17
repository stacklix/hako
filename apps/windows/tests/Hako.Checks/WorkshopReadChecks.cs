using System;
using System.IO;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Hako.Platform;

internal static class WorkshopReadChecks
{
    internal static async Task RunAsync()
    {
        var reads = new WorkshopReads();
        var release = new TaskCompletionSource<JsonElement>(TaskCreationOptions.RunContinuationsAsynchronously);
        var calls = 0;
        Task<JsonElement> Read() { Interlocked.Increment(ref calls); return release.Task; }
        using var cancelled = new CancellationTokenSource();
        var first = reads.RunAsync("same", Read, cancelled.Token);
        var second = reads.RunAsync("same", Read, default);
        if (calls != 1) throw new Exception("Overlapping queries were not joined");
        cancelled.Cancel();
        try { await first; throw new Exception("Cancelled reader was not released"); }
        catch (OperationCanceledException) { }
        if (second.IsCompleted) throw new Exception("One client cancelled another client's read");
        var result = JsonSerializer.SerializeToElement(new { value = 1 });
        release.SetResult(result);
        await second;
        await reads.RunAsync("same", Read, default);
        if (calls != 2) throw new Exception("A fresh query reused a completed result");

        var bothStarted = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var started = 0;
        async Task<JsonElement> Concurrent()
        {
            if (Interlocked.Increment(ref started) == 2) bothStarted.SetResult();
            await bothStarted.Task;
            return result;
        }
        await Task.WhenAll(reads.RunAsync("one", Concurrent, default), reads.RunAsync("two", Concurrent, default))
            .WaitAsync(TimeSpan.FromSeconds(3));
        try { await reads.RunAsync("failure", () => Task.FromException<JsonElement>(new IOException("fixture")), default); }
        catch (IOException) { }
        if ((await reads.RunAsync("failure", () => Task.FromResult(result), default)).GetProperty("value").GetInt32() != 1)
            throw new Exception("A failed read remained cached");
        Console.WriteLine("PASS: joined reads, independent cancellation, concurrent keys and failure eviction");
    }
}
