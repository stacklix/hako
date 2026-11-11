using System;
using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;
using Hako.Core;

internal static class AgentRequestChecks
{
    internal static async Task RunAsync()
    {
        var slots = new AgentRequestSlots();
        var workshop = new List<IDisposable>();
        for (var i = 0; i < 12; i++)
            workshop.Add(slots.TryAcquire(i % 2 == 0 ? "query.codex.history" : "action.codex.turn.start")
                ?? throw new Exception("Workshop capacity below twelve"));
        if (slots.TryAcquire("query.codex.history") is not null) throw new Exception("Workshop occupied the monitoring reserve");
        var monitors = new List<IDisposable>();
        for (var i = 0; i < 3; i++)
            monitors.Add(slots.TryAcquire("query.all") ?? throw new Exception("Monitoring reserve below four"));
        var monitoring = slots.TryAcquire("query.codex.usage") ?? throw new Exception("Monitoring starved behind workshop reads");
        if (slots.TryAcquire("query.all") is not null) throw new Exception("Total request bound exceeded");
        monitoring.Dispose();
        monitoring.Dispose();
        using (slots.TryAcquire("query.all") ?? throw new Exception("Monitoring slot was not released"))
            if (slots.TryAcquire("query.system.metrics") is not null) throw new Exception("Double disposal freed an extra slot");
        workshop[0].Dispose();
        using var replacement = slots.TryAcquire("query.codex.history") ?? throw new Exception("Workshop slot was not released");
        foreach (var lease in workshop) lease.Dispose();
        foreach (var lease in monitors) lease.Dispose();

        var stalled = new TaskCompletionSource<object?>(TaskCreationOptions.RunContinuationsAsynchronously);
        CancellationToken queryToken = default;
        try
        {
            await AgentRequestSlots.ReadAsync(token => { queryToken = token; return stalled.Task; }, default, TimeSpan.FromMilliseconds(50));
            throw new Exception("Non-responsive query did not time out");
        }
        catch (AgentActionException error) when (error.Code == "query_timeout")
        {
            if (!queryToken.IsCancellationRequested) throw new Exception("Query timeout did not cancel underlying work");
        }
        finally { stalled.TrySetResult(null); }

        using var cancellation = new CancellationTokenSource();
        var cancelled = AgentRequestSlots.ReadAsync(async token =>
        {
            await Task.Delay(Timeout.InfiniteTimeSpan, token);
            return null;
        }, cancellation.Token);
        cancellation.Cancel();
        try { await cancelled; throw new Exception("Connection cancellation was ignored"); }
        catch (OperationCanceledException) when (cancellation.IsCancellationRequested) { }
        if (!Equals(await AgentRequestSlots.ReadAsync(_ => Task.FromResult<object?>(42), default), 42))
            throw new Exception("Successful query result changed");
        Console.WriteLine("PASS: workshop concurrency reserves monitoring capacity; query deadlines and cancellation release blocked reads");
    }
}
