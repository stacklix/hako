using System;
using System.IO;
using System.Linq;
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
        var downloads = new WorkshopDownloadCache();
        var loads = 0;
        byte[] content = [1, 2, 3];
        Task<byte[]> Load() { Interlocked.Increment(ref loads); return Task.FromResult(content); }
        var snapshot = await downloads.ReadAsync("image", "", Load, default);
        content = [4, 5, 6];
        var chunks = await Task.WhenAll(System.Linq.Enumerable.Range(0, 16).Select(_ =>
            downloads.ReadAsync("image", snapshot.Revision, Load, default)));
        if (loads != 1 || System.Linq.Enumerable.Any(chunks, chunk => !chunk.Data.AsSpan().SequenceEqual(new byte[] { 1, 2, 3 })))
            throw new Exception("Parallel chunks reread or mixed a modified file into an immutable download");
        var updated = await downloads.ReadAsync("image", "", Load, default);
        if (loads != 2 || updated.Revision == snapshot.Revision) throw new Exception("Reopening a download hid a new revision");
        for (var index = 0; index < 5; index++) await downloads.ReadAsync("other-" + index, "", Load, default);
        var beforeReload = loads;
        await downloads.ReadAsync("image", updated.Revision, Load, default);
        if (loads != beforeReload + 1) throw new Exception("Download cache did not evict old snapshots");
        Console.WriteLine("PASS: joined reads, independent cancellation, concurrent keys and failure eviction");
    }
}
