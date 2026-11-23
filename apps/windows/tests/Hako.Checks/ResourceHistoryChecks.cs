using System;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Hako.Core;
using Hako.Platform;

internal static class ResourceHistoryChecks
{
    public static async Task RunAsync()
    {
        var directory = Path.Combine(Path.GetTempPath(), "kage-resource-check-" + Guid.NewGuid().ToString("N"));
        var now = new DateTimeOffset(2026, 11, 22, 12, 30, 0, TimeSpan.Zero);
        var history = new ResourceHistory(directory, () => now);
        async Task<ResourceHistoryResult> Read(int range = 604800) => (ResourceHistoryResult)(await history.QueryAsync(
            JsonSerializer.SerializeToElement(new { rangeSeconds = range }), default))!;
        try
        {
            if (ResourceHistory.IntervalSeconds != 1 || ResourceHistory.FlushIntervalSeconds != 300)
                throw new Exception("Sampling or batch interval is incorrect");
            if ((await Read()).Points.Length != 0) throw new Exception("Empty history was not empty");
            // Start eight days ago and advance time: exercise both expired files and the boundary hour.
            now = now.AddDays(-8);
            await history.AppendAsync(new(now.ToUnixTimeMilliseconds(), 20, 30), default);
            if (Directory.Exists(directory)) throw new Exception("Append wrote a sample before the batch flush");
            await history.FlushAsync(default);
            now = now.AddDays(1).AddMinutes(-1);
            await history.AppendAsync(new(now.ToUnixTimeMilliseconds(), 40, 50), default);
            await history.FlushAsync(default);
            now = now.AddMinutes(2);
            await history.AppendAsync(new(now.ToUnixTimeMilliseconds(), 60, 70), default);
            await history.FlushAsync(default);
            now = now.AddDays(7).AddMinutes(-1);
            var before = Directory.GetFiles(directory, "*.bin").Sum(path => new FileInfo(path).Length);
            await history.AppendAsync(new(now.AddSeconds(-10).ToUnixTimeMilliseconds(), 10, 30), default);
            await history.AppendAsync(new(now.AddSeconds(-5).ToUnixTimeMilliseconds(), 90, 70), default);
            var week = await Read();
            if (Directory.GetFiles(directory, "*.bin").Sum(path => new FileInfo(path).Length) != before)
                throw new Exception("Append/query wrote a sample before the batch flush");
            if (week.Points.Sum(point => point.SampleCount) != 3)
                throw new Exception("Buffered samples were not queryable before the flush");
            await history.FlushAsync(default);
            if (Directory.GetFiles(directory, "*.bin").Length != 2)
                throw new Exception("Seven-day retention did not remove expired files/records");
            if (Directory.GetFiles(directory, "*.bin").Sum(path => new FileInfo(path).Length) != 3 * 24)
                throw new Exception("Expired boundary records remain on disk");
            var hour = await Read(3600);
            if (hour.Points.Sum(point => point.SampleCount) != 2 || hour.Points.Max(point => point.CpuMaxPercent) != 90)
                throw new Exception("History range or peak aggregation failed");
            // Restart without a cache and preserve durable samples; ignore/recover a partial write.
            var active = Directory.GetFiles(directory, "*.bin").OrderBy(path => path).Last();
            using (var tail = new FileStream(active, FileMode.Append)) tail.WriteByte(1);
            var restarted = new ResourceHistory(directory, () => now);
            await restarted.AppendAsync(new(now.ToUnixTimeMilliseconds(), 0, 0), default);
            await restarted.FlushAsync(default);
            var restored = (ResourceHistoryResult)(await restarted.QueryAsync(JsonSerializer.SerializeToElement(new { }), default))!;
            if (restored.Points.Sum(point => point.SampleCount) != 3 || new FileInfo(active).Length % 24 != 0)
                throw new Exception("Restart or partial-record recovery failed");
            foreach (var json in new[] { "{\"rangeSeconds\":1}", "{\"rangeSeconds\":1801}", "{\"rangeSeconds\":\"x\"}", "{\"unknown\":1}" })
            {
                try { await history.QueryAsync(JsonDocument.Parse(json).RootElement, default); throw new Exception("Invalid history params accepted"); }
                catch (AgentActionException error) when (error.Code == "invalid_params") { }
            }
            for (int i = 0; i < 500; i++)
                await history.AppendAsync(new(now.AddSeconds(-i * 5).ToUnixTimeMilliseconds(), i % 100, 50), default);
            var dense = await Read(3600);
            if (dense.Points.Length > 240 || JsonSerializer.SerializeToUtf8Bytes(dense, AgentConnection.Json).Length > 60000)
                throw new Exception("History exceeded the device message budget");
            using var cancelled = new CancellationTokenSource(); cancelled.Cancel();
            try { await history.QueryAsync(JsonSerializer.SerializeToElement(new { }), cancelled.Token); throw new Exception("History ignored cancellation"); }
            catch (OperationCanceledException) { }
            await history.FlushAsync(default);
            var persisted = Directory.GetFiles(directory, "*.bin").Sum(path => new FileInfo(path).Length);
            await history.FlushAsync(default);
            if (Directory.GetFiles(directory, "*.bin").Sum(path => new FileInfo(path).Length) != persisted)
                throw new Exception("Repeated flush duplicated accepted samples");

            // A failed batch must preserve every buffered sample for a later successful flush.
            var blocked = Path.Combine(directory, "blocked"); File.WriteAllText(blocked, "not a directory");
            var retry = new ResourceHistory(blocked, () => now);
            await retry.AppendAsync(new(now.ToUnixTimeMilliseconds(), 11, 22), default);
            try { await retry.FlushAsync(default); throw new Exception("Expected a write failure"); }
            catch (IOException) { }
            var retained = (ResourceHistoryResult)(await retry.QueryAsync(JsonSerializer.SerializeToElement(new { }), default))!;
            if (retained.Points.Sum(point => point.SampleCount) != 1 || retained.SamplingError is null)
                throw new Exception("Failed flush lost buffered data or hid the error");
            File.Delete(blocked); await retry.FlushAsync(default);
            var recovered = new ResourceHistory(blocked, () => now);
            if (((ResourceHistoryResult)(await recovered.QueryAsync(JsonSerializer.SerializeToElement(new { }), default))!).Points.Sum(point => point.SampleCount) != 1)
                throw new Exception("Retry did not persist the retained sample exactly once");

            await SharedSamplingAsync(Path.Combine(directory, "shared"), now);
            await FiveSecondAveragesAsync(Path.Combine(directory, "rolling"), now);
            await ShortRangesAsync(Path.Combine(directory, "short"), now);

            // Real background sampling runs once per second independently of queries or a server connection.
            var live = new ResourceHistory(Path.Combine(directory, "live"));
            await using (var sampler = new ResourceHistorySampler(live, new SystemMetrics()))
            {
                sampler.Start();
                var deadline = DateTime.UtcNow.AddSeconds(45);
                ResourceHistoryResult result;
                do {
                    await Task.Delay(500);
                    result = (ResourceHistoryResult)(await live.QueryAsync(JsonSerializer.SerializeToElement(new { }), default))!;
                } while (result.Points.Sum(point => point.SampleCount) < 3 && DateTime.UtcNow < deadline);
                if (result.Points.Sum(point => point.SampleCount) < 3 || result.SamplingError is not null) throw new Exception("Background sampling failed: " + result.SamplingError);
                if (Directory.Exists(Path.Combine(directory, "live"))) throw new Exception("Background sampler wrote before the five-minute batch");
            }
            if (!Directory.GetFiles(Path.Combine(directory, "live"), "*.bin").Any()) throw new Exception("Orderly shutdown did not flush samples");
            Console.WriteLine("PASS: one-second shared sampling, memory/disk merge, batched writes, failed-flush retry, shutdown, retention, peaks and cancellation");
        }
        finally { if (Directory.Exists(directory)) Directory.Delete(directory, true); }
    }

    private static async Task ShortRangesAsync(string directory, DateTimeOffset now)
    {
        var history = new ResourceHistory(directory, () => now);
        foreach (var offset in new long[] { -1800001, -1800000, -900001, -900000, -1, 0, 1000 })
            await history.AppendAsync(new(now.ToUnixTimeMilliseconds() + offset, 50, 60), default);
        foreach (var (range, bucket, samples) in new[] { (900, 4, 3), (1800, 8, 5) })
        {
            var result = (ResourceHistoryResult)(await history.QueryAsync(JsonSerializer.SerializeToElement(new { rangeSeconds = range }), default))!;
            if (result.To - result.From != range * 1000L || result.BucketSeconds != bucket
                || result.Points.Sum(point => point.SampleCount) != samples || result.Points.Length > 240
                || result.Points.Any(point => point.Timestamp < result.From || point.Timestamp > result.To))
                throw new Exception("Short history range boundaries, warmup exclusion or bucket resolution are incorrect");
        }
    }

    private static async Task FiveSecondAveragesAsync(string directory, DateTimeOffset now)
    {
        async Task<ResourceHistoryResult> Read(ResourceHistory history) => (ResourceHistoryResult)(await history.QueryAsync(
            JsonSerializer.SerializeToElement(new { rangeSeconds = 3600 }), default))!;
        var start = now.AddSeconds(-300).ToUnixTimeMilliseconds();
        var spike = new ResourceHistory(Path.Combine(directory, "spike"), () => now);
        for (int second = -4; second < 15; second++)
        {
            await spike.AppendAsync(new(start + second * 1000, second == 5 ? 100 : 0, second == 5 ? 90 : 40), default);
            if (second == 2) await spike.FlushAsync(default);
        }
        var spikePoint = (await Read(spike)).Points.Single(point => point.Timestamp == start);
        if (spikePoint.SampleCount != 15 || Math.Abs(spikePoint.CpuUsagePercent - 100.0 / 15) > 0.0001
            || spikePoint.CpuMaxPercent != 100 || spikePoint.CpuSmoothedMaxPercent != 20 || spikePoint.MemorySmoothedMaxPercent != 50)
            throw new Exception("A one-second spike was not averaged over five seconds across disk and memory samples");

        var sustained = new ResourceHistory(Path.Combine(directory, "sustained"), () => now);
        // Reverse insertion must not alter time-based sliding windows.
        for (int second = 14; second >= -4; second--)
            await sustained.AppendAsync(new(start + second * 1000, second is >= 5 and <= 9 ? 100 : 0, 50), default);
        if ((await Read(sustained)).Points.Single(point => point.Timestamp == start).CpuSmoothedMaxPercent != 100)
            throw new Exception("Five seconds of sustained load was incorrectly suppressed");

        var boundary = new ResourceHistory(Path.Combine(directory, "boundary"), () => now);
        var from = now.AddHours(-1).ToUnixTimeMilliseconds();
        for (int second = -5; second < 0; second++)
            await boundary.AppendAsync(new(from + second * 1000, 100, 50), default);
        await boundary.AppendAsync(new(from, 0, 0), default);
        var boundaryPoint = (await Read(boundary)).Points.Single();
        if (boundaryPoint.SampleCount != 1 || boundaryPoint.CpuUsagePercent != 0 || boundaryPoint.CpuMaxPercent != 0
            || boundaryPoint.CpuSmoothedMaxPercent != 80 || boundaryPoint.MemorySmoothedMaxPercent != 40)
            throw new Exception("A window at the query boundary lost its lookback or counted warmup samples in the displayed averages");

        var gap = new ResourceHistory(Path.Combine(directory, "gap"), () => now);
        await gap.AppendAsync(new(start - 6000, 100, 100), default);
        await gap.AppendAsync(new(start, 0, 0), default);
        var gapPoint = (await Read(gap)).Points.Single(point => point.Timestamp == start);
        if (gapPoint.CpuSmoothedMaxPercent != 0 || gapPoint.MemorySmoothedMaxPercent != 0)
            throw new Exception("A five-second window included stale samples across a sampling gap");

        var full = new ResourceHistory(Path.Combine(directory, "full"), () => now);
        for (int bucket = 0; bucket < 240; bucket++)
            await full.AppendAsync(new(from + bucket * 15000 + 100, Math.PI * 10, Math.E * 10), default);
        var fullResult = await Read(full);
        if (fullResult.Points.Length != 240 || JsonSerializer.SerializeToUtf8Bytes(fullResult, AgentConnection.Json).Length > 60000)
            throw new Exception("Full-precision rolling history exceeded the device message budget");
    }

    private static async Task SharedSamplingAsync(string directory, DateTimeOffset now)
    {
        var first = new TaskCompletionSource<Metrics>(TaskCreationOptions.RunContinuationsAsynchronously);
        int calls = 0;
        var metrics = new SystemMetrics(async token => {
            if (Interlocked.Increment(ref calls) == 1) return await first.Task.WaitAsync(token);
            await Task.Delay(Timeout.Infinite, token); throw new OperationCanceledException(token);
        });
        var history = new ResourceHistory(directory, () => now);
        await using (var sampler = new ResourceHistorySampler(history, metrics))
        {
            sampler.Start();
            var requests = Enumerable.Range(0, 20).Select(_ => metrics.SampleAsync(default)).ToArray();
            using var cancellation = new CancellationTokenSource(); cancellation.Cancel();
            try { await metrics.SampleAsync(cancellation.Token); throw new Exception("Cancelled reader was accepted"); }
            catch (OperationCanceledException) { }
            var value = new Metrics(25, 50, 50, 100, now.ToString("O"), 1000);
            first.SetResult(value);
            var replies = await Task.WhenAll(requests).WaitAsync(TimeSpan.FromSeconds(5));
            if (replies.Any(reply => !ReferenceEquals(reply, value)) || !ReferenceEquals(await metrics.SampleAsync(default), value) || calls > 2)
                throw new Exception("Concurrent real-time readers did not share the sampling source");
            var result = (ResourceHistoryResult)(await history.QueryAsync(JsonSerializer.SerializeToElement(new { }), default))!;
            if (result.Points.Sum(point => point.SampleCount) != 1 || result.Points.Single().CpuUsagePercent != value.CpuUsagePercent)
                throw new Exception("History did not record the exact real-time sample once");
        }
        var restarted = new ResourceHistory(directory, () => now);
        if (((ResourceHistoryResult)(await restarted.QueryAsync(JsonSerializer.SerializeToElement(new { }), default))!).Points.Sum(point => point.SampleCount) != 1)
            throw new Exception("Shared sampler did not preserve the pending sample on shutdown");
    }
}
