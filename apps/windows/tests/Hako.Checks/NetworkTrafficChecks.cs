using System;
using System.Collections.Generic;
using System.Diagnostics;
using Hako.Platform;

internal static class NetworkTrafficChecks
{
    public static void Run()
    {
        static NetworkTraffic.Sample Sample(long timestamp, params (string Id, ulong Received, ulong Sent)[] values)
        {
            var interfaces = new Dictionary<string, NetworkTraffic.Counters>();
            foreach (var value in values) interfaces.Add(value.Id, new(value.Received, value.Sent));
            return new(interfaces, timestamp);
        }
        var start = Sample(0, ("ethernet", 1000, 2000), ("wifi", 4000, 5000));
        var end = Sample(Stopwatch.Frequency, ("ethernet", 3048, 3024), ("wifi", 5024, 5512));
        var result = NetworkTraffic.Measure(start, end);
        if (!result.Available || result.InterfaceCount != 2 || result.DownloadBytesPerSecond != 3072 || result.UploadBytesPerSecond != 1536)
            throw new Exception("Physical adapter speeds were not summed correctly");
        var slower = NetworkTraffic.Measure(start, end with { Timestamp = Stopwatch.Frequency * 2 });
        if (slower.DownloadBytesPerSecond != 1536 || slower.UploadBytesPerSecond != 768)
            throw new Exception("Network speed did not use the actual elapsed window");
        var idle = NetworkTraffic.Measure(start, start with { Timestamp = Stopwatch.Frequency });
        if (!idle.Available || idle.DownloadBytesPerSecond != 0 || idle.UploadBytesPerSecond != 0)
            throw new Exception("Idle adapter must report a genuine zero rate");
        foreach (var changed in new[] {
            Sample(Stopwatch.Frequency),
            Sample(Stopwatch.Frequency, ("other", 9999, 9999), ("wifi", 5024, 5512)),
            Sample(Stopwatch.Frequency, ("ethernet", 1, 3024), ("wifi", 5024, 5512)),
            Sample(Stopwatch.Frequency, ("ethernet", 3048, 1), ("wifi", 5024, 5512)),
            end with { Timestamp = 0 }, end with { Error = "unavailable" }
        })
        {
            var unavailable = NetworkTraffic.Measure(start, changed);
            if (unavailable.Available || unavailable.DownloadBytesPerSecond != null || unavailable.UploadBytesPerSecond != null
                || string.IsNullOrEmpty(unavailable.Message)) throw new Exception("Missing/reset counters must not appear as zero or a rate spike");
        }
        if (!NetworkTraffic.IsIncluded(6, 1) || !NetworkTraffic.IsIncluded(71, 1)
            || NetworkTraffic.IsIncluded(6, 0) || NetworkTraffic.IsIncluded(6, 3)
            || NetworkTraffic.IsIncluded(24, 1) || NetworkTraffic.IsIncluded(131, 1))
            throw new Exception("Virtual, filter, loopback or tunnel adapters were included");
        var large = NetworkTraffic.Measure(Sample(0, ("ethernet", ulong.MaxValue - 4096, ulong.MaxValue - 2048)),
            Sample(Stopwatch.Frequency, ("ethernet", ulong.MaxValue, ulong.MaxValue)));
        if (!large.Available || large.DownloadBytesPerSecond != 4096 || large.UploadBytesPerSecond != 2048)
            throw new Exception("64-bit network counters lost precision before differencing");
        if (NetworkTraffic.FormatRate(null) != "—" || NetworkTraffic.FormatRate(double.NaN) != "—"
            || !NetworkTraffic.FormatRate(1024).EndsWith("KiB/s", StringComparison.Ordinal))
            throw new Exception("Network rate units or missing values are invalid");
        var live = NetworkTraffic.Capture();
        if (live.Error != null) throw new Exception("Windows network counter read failed: " + live.Error);
        Console.WriteLine($"PASS: physical network filtering, 64-bit deltas, elapsed rate, idle/reset/missing/error handling; {live.Interfaces.Count} live physical adapter(s)");
    }
}
