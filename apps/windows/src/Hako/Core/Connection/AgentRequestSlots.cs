using System;
using System.Threading;
using System.Threading.Tasks;

namespace Hako.Core;

internal sealed class AgentRequestSlots
{
    internal const int Limit = 16;
    private readonly object gate = new();
    private int active;

    public IDisposable? TryAcquire()
    {
        lock (gate)
        {
            // Code Workshop owns a different connection and does not consume these slots.
            if (active >= Limit) return null;
            active++;
            return new Lease(this);
        }
    }

    private sealed class Lease(AgentRequestSlots owner) : IDisposable
    {
        private AgentRequestSlots? owner = owner;
        public void Dispose()
        {
            var current = Interlocked.Exchange(ref owner, null);
            if (current is null) return;
            lock (current.gate)
            {
                current.active--;
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
