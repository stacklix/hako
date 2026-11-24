using System;
using System.Globalization;
using System.IO;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace Hako.Platform;

// Last model request size is context occupancy. Session-wide cumulative usage
// includes repeated cached input and must never be used as the context size.
internal sealed record WorkshopContextUsage(long? UsedTokens, long? ModelContextWindow, long UpdatedAt)
{
    internal static WorkshopContextUsage FromUsage(JsonElement usage, long at, bool persisted = false)
    {
        var last = CodexJson.Field(usage, persisted ? "last_token_usage" : "last");
        var used = CodexJson.Field(last, persisted ? "total_tokens" : "totalTokens");
        var window = CodexJson.Field(usage, persisted ? "model_context_window" : "modelContextWindow");
        return new(used.TryGetNonnegativeInt64(), window.TryGetPositiveInt64(), at);
    }
}

internal static class WorkshopContextNumbers
{
    internal static long? TryGetNonnegativeInt64(this JsonElement value) =>
        value.ValueKind == JsonValueKind.Number && value.TryGetInt64(out var number) && number >= 0 ? number : null;
    internal static long? TryGetPositiveInt64(this JsonElement value) => value.TryGetNonnegativeInt64() is > 0 and var number ? number : null;
}

internal sealed partial class CodeWorkshop
{
    // Read only the bounded tail of the native rollout identified by thread/read.
    // This never resumes a thread or acquires its writer, including external turns.
    internal async Task<WorkshopContextUsage?> ReadContextUsageAsync(string threadId, string path, CancellationToken token)
    {
        try
        {
            if (!Path.IsPathFullyQualified(path) || !Path.GetFileName(path).EndsWith(threadId + ".jsonl", StringComparison.OrdinalIgnoreCase) ||
                !SafePath(path, home)) return null;
            await using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete,
                65536, FileOptions.Asynchronous | FileOptions.RandomAccess);
            var length = stream.Length;
            for (var tail = 65536; ; tail = Math.Min(8 * 1024 * 1024, tail * 4))
            {
                var start = Math.Max(0, length - tail);
                stream.Position = start;
                var bytes = new byte[checked((int)(length - start))];
                await stream.ReadExactlyAsync(bytes, token);
                // Ignore an unfinished trailing row and a partial first row.
                var end = Array.LastIndexOf(bytes, (byte)'\n');
                while (end > 0)
                {
                    token.ThrowIfCancellationRequested();
                    var previous = Array.LastIndexOf(bytes, (byte)'\n', end - 1);
                    if (previous < 0 && start > 0) break;
                    var offset = previous + 1;
                    try
                    {
                        using var document = JsonDocument.Parse(bytes.AsMemory(offset, end - offset));
                        var row = document.RootElement;
                        if (DateTimeOffset.TryParse(CodexJson.Text(row, "timestamp"), CultureInfo.InvariantCulture,
                            DateTimeStyles.RoundtripKind, out var at))
                        {
                            if (CodexJson.Text(row, "type") == "compacted") return new(null, null, at.ToUnixTimeMilliseconds());
                            var payload = CodexJson.Field(row, "payload");
                            var info = CodexJson.Field(payload, "info");
                            if (CodexJson.Text(row, "type") == "event_msg" && CodexJson.Text(payload, "type") == "token_count" &&
                                info.ValueKind == JsonValueKind.Object)
                                return WorkshopContextUsage.FromUsage(info, at.ToUnixTimeMilliseconds(), persisted: true);
                        }
                    }
                    catch (JsonException) { }
                    end = previous;
                }
                if (start == 0 || tail == 8 * 1024 * 1024) break;
            }
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or ArgumentException or NotSupportedException)
        { queryLog.Write("context/read", 0, 0, error.GetType().Name); }
        return null;
    }

    private WorkshopContextUsage? ContextUsage(string threadId, WorkshopContextUsage? native = null)
    {
        // Caller holds gate. A live worker can be ahead of the flushed rollout.
        foreach (var job in jobs.Values)
            if (job.ThreadId == threadId && job.ContextUsage is { } usage && (native is null || usage.UpdatedAt > native.UpdatedAt))
                native = usage;
        return native;
    }
}
