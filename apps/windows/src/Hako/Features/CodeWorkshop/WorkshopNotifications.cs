using System;
using System.Collections.Generic;
using System.Linq;
using System.Text.Json.Serialization;
using System.Threading;
using System.Threading.Tasks;

namespace Hako.Platform;

internal sealed record WorkshopTerminal([property: JsonIgnore] string OperationId, string State, long FinishedAt);

internal sealed partial class CodeWorkshop
{
    private string? notificationScope;
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
                    .OrderBy(job => job.FinishedAt).Select(job => new WorkshopTerminal(job.Id, job.State, job.FinishedAt)).ToArray();
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
