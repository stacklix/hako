using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;

namespace Hako.Platform;

internal sealed record WorkshopTerminal([property: JsonIgnore] string OperationId, string State, long FinishedAt,
    string ProjectName, string SessionName, string Summary);

internal sealed partial class CodeWorkshop
{
    private string? notificationScope;
    internal static string NotificationText(string value, int limit)
    {
        // The excerpt comes from an assistant message, never tool output or input.
        value = Regex.Replace(value, "visualize[^\\r\\n]*?", "");
        value = Regex.Replace(value, @"\s+", " ").Trim();
        var runes = value.EnumerateRunes().Where(rune => !Rune.IsControl(rune)).Take(limit + 1).ToArray();
        return string.Concat(runes.Take(runes.Length > limit ? limit - 1 : limit).Select(rune => rune.ToString())).Trim()
            + (runes.Length > limit ? "…" : "");
    }
    private WorkshopTerminal Terminal(WorkshopJob job)
    {
        var project = NotificationText(ApplicationFor(job.Cwd)?.Name ?? Path.GetFileName(job.Cwd.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar)), 80);
        var session = NotificationText(job.SessionName, 120);
        return new(job.Id, job.State, job.FinishedAt, project.Length > 0 ? project : "未命名项目",
            session.Length > 0 ? session : "未命名会话", NotificationText(job.ReplySummary, 240));
    }
    internal static bool TerminalState(string state) => state is "completed" or "failed" or "interrupted" or "unknown";
    internal void SetNotificationScope(string? scope) { lock (gate) notificationScope = scope; }
    internal void AcknowledgeTerminal(string scope, string id)
    {
        lock (gate)
        {
            if (jobs.TryGetValue(id, out var job) && job.NotificationScope == scope && TerminalState(job.State) && !job.NotificationAcknowledged)
            { job.NotificationAcknowledged = true; Persist(job); }
        }
    }
    internal async Task WatchTerminalsAsync(string scope, Func<WorkshopTerminal, Task> publish, CancellationToken token)
    {
        using var lifetime = CancellationTokenSource.CreateLinkedTokenSource(token, stopping.Token);
        token = lifetime.Token;
        var attempted = new Dictionary<string, DateTimeOffset>();
        while (true)
        {
            token.ThrowIfCancellationRequested();
            Task signal;
            WorkshopTerminal[] pending;
            lock (gate)
            {
                RecoverJobs();
                signal = changed.Task;
                pending = jobs.Values.Where(job => job.NotificationScope == scope && TerminalState(job.State) && !job.NotificationAcknowledged && job.FinishedAt > 0)
                    .OrderBy(job => job.FinishedAt).Select(Terminal).ToArray();
            }
            foreach (var key in attempted.Keys.Except(pending.Select(value => value.OperationId)).ToArray()) attempted.Remove(key);
            var now = DateTimeOffset.UtcNow;
            foreach (var item in pending)
            {
                if (attempted.TryGetValue(item.OperationId, out var at) && now - at < TimeSpan.FromSeconds(10)) continue;
                await publish(item);
                attempted[item.OperationId] = DateTimeOffset.UtcNow;
            }
            if (pending.Length == 0) await signal.WaitAsync(token);
            else
            {
                var delay = attempted.Values.Min() + TimeSpan.FromSeconds(10) - DateTimeOffset.UtcNow;
                if (delay > TimeSpan.Zero) await Task.WhenAny(signal, Task.Delay(delay, token)).WaitAsync(token);
            }
        }
    }
}
