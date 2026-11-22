using System;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Hako.Core;

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
            if ((await Read()).Points.Length != 0) throw new Exception("Empty history was not empty");
            // Start eight days ago and advance time: exercise both expired files and the boundary hour.
            now = now.AddDays(-8);
            await history.AppendAsync(new(now.ToUnixTimeMilliseconds(), 20, 30), default);
            now = now.AddDays(1).AddMinutes(-1);
            await history.AppendAsync(new(now.ToUnixTimeMilliseconds(), 40, 50), default);
            now = now.AddMinutes(2);
            await history.AppendAsync(new(now.ToUnixTimeMilliseconds(), 60, 70), default);
            now = now.AddDays(7).AddMinutes(-1);
            await history.AppendAsync(new(now.AddSeconds(-10).ToUnixTimeMilliseconds(), 10, 30), default);
            await history.AppendAsync(new(now.AddSeconds(-5).ToUnixTimeMilliseconds(), 90, 70), default);
            var week = await Read();
            if (week.Points.Sum(point => point.SampleCount) != 3 || Directory.GetFiles(directory, "*.bin").Length != 2)
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
            var restored = (ResourceHistoryResult)(await restarted.QueryAsync(JsonSerializer.SerializeToElement(new { }), default))!;
            if (restored.Points.Sum(point => point.SampleCount) != 3 || new FileInfo(active).Length % 24 != 0)
                throw new Exception("Restart or partial-record recovery failed");
            foreach (var json in new[] { "{\"rangeSeconds\":1}", "{\"rangeSeconds\":\"x\"}", "{\"unknown\":1}" })
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
            // Real background sampling runs independently of queries or a server connection.
            var live = new ResourceHistory(Path.Combine(directory, "live"));
            await using (var sampler = new ResourceHistorySampler(live))
            {
                sampler.Start();
                var deadline = DateTime.UtcNow.AddSeconds(45);
                ResourceHistoryResult result;
                do {
                    await Task.Delay(500);
                    result = (ResourceHistoryResult)(await live.QueryAsync(JsonSerializer.SerializeToElement(new { }), default))!;
                } while (result.Points.Length == 0 && DateTime.UtcNow < deadline);
                if (result.Points.Length == 0 || result.SamplingError is not null) throw new Exception("Background sampling failed: " + result.SamplingError);
            }
            Console.WriteLine("PASS: resource history autonomous sampling, disk retention, restart, range/peaks, reply budget, validation and cancellation");
        }
        finally { if (Directory.Exists(directory)) Directory.Delete(directory, true); }
    }
}
