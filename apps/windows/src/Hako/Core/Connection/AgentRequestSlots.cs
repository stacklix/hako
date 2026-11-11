using System;
using System.Threading;
using System.Threading.Tasks;

namespace Hako.Core;

internal sealed class AgentRequestSlots
{
    internal const int Limit = 16;
    internal const int WorkshopLimit = 12;
    private readonly object gate = new();
    private int active;
    private int workshop;

    public IDisposable? TryAcquire(string method)
    {
        var isWorkshop = method.StartsWith("action.codex.", StringComparison.Ordinal) ||
            (method.StartsWith("query.codex.", StringComparison.Ordinal) && method != "query.codex.usage");
        lock (gate)
        {
            // Background conversation reads must leave room for device monitoring.
            if (active >= Limit || isWorkshop && workshop >= WorkshopLimit) return null;
            active++;
            if (isWorkshop) workshop++;
            return new Lease(this, isWorkshop);
        }
    }

    private sealed class Lease(AgentRequestSlots owner, bool workshop) : IDisposable
    {
        private AgentRequestSlots? owner = owner;
        public void Dispose()
        {
            var current = Interlocked.Exchange(ref owner, null);
            if (current is null) return;
            lock (current.gate)
            {
                current.active--;
                if (workshop) current.workshop--;
            }
        }
    }

    internal static async Task<object?> ReadAsync(Func<CancellationToken, Task<object?>> read,
        CancellationToken token, TimeSpan? timeout = null)
    {
        using var budget = CancellationTokenSource.CreateLinkedTokenSource(token);
        budget.CancelAfter(timeout ?? TimeSpan.FromSeconds(8));
        try { return await read(budget.Token).WaitAsync(budget.Token); }
        catch (OperationCanceledException) when (!token.IsCancellationRequested)
        { throw new AgentActionException("query_timeout", "设备查询超时，请稍后刷新。"); }
    }
}
