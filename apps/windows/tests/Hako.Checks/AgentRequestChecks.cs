using System;
using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;
using Hako.Core;

internal static class AgentRequestChecks
{
    internal static async Task RunAsync()
    {
        foreach (var json in new[] { "{}", "{\"method\":false,\"version\":1,\"params\":{}}",
            "{\"method\":\"admin.services.status\",\"version\":\"next\",\"params\":{}}",
            "{\"method\":\"query.all\",\"version\":1,\"params\":[],\"extra\":true}" })
        {
            using var invalid = System.Text.Json.JsonDocument.Parse(json);
            try { AgentConnection.ReadRequest(invalid.RootElement); throw new Exception("Device accepted invalid command schema"); }
            catch (AgentActionException error) when (error.Code == "invalid_request") { }
        }
        var slots = new AgentRequestSlots();
        var requests = new List<IDisposable>();
        for (var i = 0; i < 16; i++) requests.Add(slots.TryAcquire() ?? throw new Exception("Device capacity below sixteen"));
        if (slots.TryAcquire() is not null) throw new Exception("Device request bound exceeded");
        requests[0].Dispose(); requests[0].Dispose();
        using var replacement = slots.TryAcquire() ?? throw new Exception("Device slot was not released");
        if (slots.TryAcquire() is not null) throw new Exception("Double disposal released an extra slot");
        foreach (var lease in requests) lease.Dispose();
        await using var dispatcher = new AgentDispatcher(new Hako.Platform.SystemMetrics());
        using var empty = System.Text.Json.JsonDocument.Parse("{}");
        try { await dispatcher.InvokeAsync("action.codex.turn.start",1,empty.RootElement,default); throw new Exception("Device dispatcher exposed Code Workshop"); }
        catch (AgentActionException error) when (error.Code == "unsupported_method") { }

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
        Console.WriteLine("PASS: independent device capacity excludes Code Workshop; query deadlines and cancellation release blocked reads");
    }
}
