using System;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Text.Json;

namespace Hako.Core;

// One writer per profile, created only after the Agent owns its instance mutex.
internal sealed class AgentLifecycleLog
{
    private sealed record Session(string Id, int ProcessId, DateTimeOffset StartedAt,
        DateTimeOffset LastHeartbeatAt, DateTimeOffset? EndedAt = null, string? ExitReason = null, int? ExitCode = null);

    private readonly object gate = new();
    private readonly string directory;
    private readonly string logPath;
    private readonly string statePath;
    private readonly long maxLogBytes;
    private readonly JsonSerializerOptions json = new() { PropertyNamingPolicy = JsonNamingPolicy.CamelCase };
    private Session session = new(Guid.NewGuid().ToString("N"), Environment.ProcessId, DateTimeOffset.UtcNow, DateTimeOffset.UtcNow);
    private bool fatal;
    private bool completed;
    private string? exitReason;

    internal AgentLifecycleLog(string profileDirectory, bool background, long maxLogBytes = 1_048_576)
    {
        directory = Path.Combine(profileDirectory, "logs");
        logPath = Path.Combine(directory, "agent-lifecycle.jsonl");
        statePath = Path.Combine(directory, "agent-session.json");
        this.maxLogBytes = maxLogBytes;
        TryWrite(() =>
        {
            Directory.CreateDirectory(directory);
            if (File.Exists(statePath))
            {
                try
                {
                    if (new FileInfo(statePath).Length > 16_384) throw new InvalidDataException();
                    var previous = JsonSerializer.Deserialize<Session>(File.ReadAllText(statePath), json);
                    if (previous is { EndedAt: null })
                        Append("previous_unclean_exit", new { previous });
                }
                catch (Exception error) when (error is JsonException or InvalidDataException)
                {
                    Append("previous_state_unreadable", new { type = error.GetType().FullName });
                }
            }
            SaveSession();
            Append("started", new
            {
                background,
                version = typeof(AgentLifecycleLog).Assembly.GetName().Version?.ToString(),
                runtime = Environment.Version.ToString()
            });
        });
    }

    internal void Ready() => TryWrite(() => Append("ready", null));

    internal void Heartbeat() => TryWrite(() =>
    {
        if (completed) return;
        session = session with { LastHeartbeatAt = DateTimeOffset.UtcNow };
        SaveSession();
        Append("heartbeat", null);
    });

    internal void ExitRequested(string reason) => TryWrite(() =>
    {
        exitReason ??= reason;
        Append("exit_requested", new { reason });
        session = session with { ExitReason = exitReason };
        SaveSession();
    });

    internal void Exception(string source, Exception? error, bool terminating) => TryWrite(() =>
    {
        fatal |= terminating;
        // Messages and exception data can contain credentials, command input or task text.
        Append("exception", new
        {
            source, terminating, type = error?.GetType().FullName, hResult = error?.HResult,
            stack = error?.StackTrace is { } stack ? stack[..Math.Min(stack.Length, 8192)] : null
        });
    });

    internal void ProcessExited(int exitCode) => TryWrite(() =>
    {
        if (!completed) Append("process_exit_without_shutdown", new { exitCode });
    });

    internal void Complete(int exitCode) => TryWrite(() =>
    {
        if (completed) return;
        Append("exited", new { exitCode, reason = exitReason ?? "application_shutdown", clean = !fatal && exitCode == 0 });
        if (!fatal && exitCode == 0)
        {
            session = session with { EndedAt = DateTimeOffset.UtcNow, ExitReason = exitReason ?? "application_shutdown", ExitCode = exitCode };
            SaveSession();
        }
        completed = true;
    });

    private void Append(string name, object? details)
    {
        if (File.Exists(logPath) && new FileInfo(logPath).Length >= maxLogBytes)
        {
            for (var i = 3; i >= 1; i--)
            {
                var source = i == 1 ? logPath : logPath + "." + (i - 1);
                if (File.Exists(source)) File.Move(source, logPath + "." + i, true);
            }
        }
        var bytes = Encoding.UTF8.GetBytes(JsonSerializer.Serialize(new
        {
            time = DateTimeOffset.UtcNow, sessionId = session.Id, processId = session.ProcessId,
            @event = name, details
        }, json) + "\n");
        using var stream = new FileStream(logPath, FileMode.Append, FileAccess.Write, FileShare.Read);
        stream.Write(bytes);
        stream.Flush(true);
    }

    private void SaveSession()
    {
        var temporary = statePath + ".tmp";
        try
        {
            using (var stream = new FileStream(temporary, FileMode.Create, FileAccess.Write, FileShare.None))
            {
                JsonSerializer.Serialize(stream, session, json);
                stream.Flush(true);
            }
            File.Move(temporary, statePath, true);
        }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }

    private void TryWrite(Action write)
    {
        lock (gate)
        {
            try { write(); }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException or System.Security.SecurityException)
            {
                Debug.WriteLine("Agent lifecycle log unavailable: " + error.GetType().Name);
            }
        }
    }
}
