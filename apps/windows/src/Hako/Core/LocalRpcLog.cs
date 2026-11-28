using System;
using System.Collections.Concurrent;
using System.Diagnostics;
using System.IO;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Threading;

namespace Hako.Core;

// One bounded, private log per process role. Never records request parameters,
// scope, response bodies, pipe identities, credentials or exception messages.
internal sealed class LocalRpcLog
{
    private static readonly ConcurrentDictionary<string, LocalRpcLog> logs = new(StringComparer.OrdinalIgnoreCase);
    private readonly object gate = new();
    private readonly string path;
    private LocalRpcLog(string path) { this.path = path; }
    internal static LocalRpcLog ForProfile(string profile, string role) =>
        logs.GetOrAdd(Path.Combine(Path.GetFullPath(profile), "logs", "local-rpc-" + role + ".jsonl"), path => new(path));
    private static string? Identifier(string? value) => value is null ? null :
        Regex.IsMatch(value, @"\A[a-zA-Z0-9_.-]{1,80}\z") ? value : "other";

    internal void Write(string stage, long elapsedMs = 0, LocalRequest? request = null,
        int? active = null, int? streams = null, Exception? error = null)
    {
        try
        {
            ThreadPool.GetAvailableThreads(out var availableWorkers, out var availableIo);
            ThreadPool.GetMaxThreads(out var maxWorkers, out _);
            var record = JsonSerializer.Serialize(new {
                time = DateTimeOffset.UtcNow, processId = Environment.ProcessId, stage, elapsedMs,
                kind = Identifier(request?.Kind), method = Identifier(request?.Method), active, streams,
                availableWorkers, busyWorkers = maxWorkers - availableWorkers, availableIo,
                pendingWork = ThreadPool.PendingWorkItemCount,
                exceptionType = error?.GetType().Name, hResult = error?.HResult
            });
            lock (gate)
            {
                Directory.CreateDirectory(Path.GetDirectoryName(path)!);
                if (File.Exists(path) && new FileInfo(path).Length >= 1_048_576) File.Move(path, path + ".previous", true);
                File.AppendAllText(path, record + "\n");
            }
        }
        catch (Exception failure) when (failure is IOException or UnauthorizedAccessException)
        { Debug.WriteLine(failure.GetType().Name); }
    }
}
