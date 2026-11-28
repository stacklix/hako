using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace Hako.Platform;

// Each retained process owns exactly one thread. Reservations also count toward
// the limit while starting or closing, so concurrent starts cannot oversubscribe.
internal sealed class WorkshopWorkers : IAsyncDisposable
{
    internal const int DefaultLimit = 4;
    internal const int DefaultWarmCount = 2;
    internal static readonly TimeSpan DefaultIdleTimeout = TimeSpan.FromMinutes(10);
    private readonly object gate = new();
    private readonly List<Entry> entries = new();
    private readonly Func<CancellationToken, Task<CodexAppServer>> start;
    private readonly int limit;
    private readonly TimeSpan idleTimeout;
    private readonly Func<long> clock;
    private readonly CancellationTokenSource stopping = new();
    private readonly Task reaper;
    private readonly Task warmer;
    private readonly int warmCount;
    private readonly Action<string, long, string>? log;
    private TaskCompletionSource changed = Signal();
    private bool disposed;

    internal sealed class Entry
    {
        internal CodexAppServer? Server;
        internal string? ThreadId;
        internal string Configuration = "";
        internal JsonElement Settings;
        internal bool Busy = true;
        internal bool Invalidated;
        internal long ReleasedAt;
    }

    internal sealed class Lease(WorkshopWorkers owner, Entry entry, bool reused, bool prewarmed = false) : IAsyncDisposable
    {
        internal CodexAppServer Server => entry.Server!;
        internal JsonElement Settings => entry.Settings;
        internal bool Reused => reused;
        internal bool Prewarmed => prewarmed;
        internal bool Retain { get; set; }
        internal void Bind(string threadId, JsonElement settings)
        {
            lock (owner.gate) { entry.ThreadId = threadId; entry.Settings = settings; owner.Pulse(); }
        }
        public ValueTask DisposeAsync() => new(owner.ReturnAsync(entry, Retain));
    }

    internal WorkshopWorkers(Func<CancellationToken, Task<CodexAppServer>> start,
        int limit = DefaultLimit, TimeSpan? idleTimeout = null, Func<long>? clock = null, TimeSpan? sweepInterval = null,
        int warmCount = 0, Action<string, long, string>? log = null)
    {
        if (limit < 1) throw new ArgumentOutOfRangeException(nameof(limit));
        if (warmCount < 0) throw new ArgumentOutOfRangeException(nameof(warmCount));
        this.start = start;
        this.limit = limit;
        this.idleTimeout = idleTimeout ?? DefaultIdleTimeout;
        if (this.idleTimeout <= TimeSpan.Zero) throw new ArgumentOutOfRangeException(nameof(idleTimeout));
        this.clock = clock ?? (() => Environment.TickCount64);
        this.warmCount = Math.Min(warmCount, limit);
        this.log = log;
        reaper = Task.Run(() => ReapAsync(sweepInterval ?? TimeSpan.FromSeconds(30)));
        warmer = this.warmCount == 0 ? Task.CompletedTask : Task.Run(WarmAsync);
    }

    private static TaskCompletionSource Signal() => new(TaskCreationOptions.RunContinuationsAsynchronously);
    private void Pulse()
    {
        var previous = changed;
        changed = Signal();
        previous.TrySetResult();
    }
    private bool Reusable(Entry entry) => !entry.Invalidated && entry.Server?.IsConnected == true &&
        (entry.ThreadId is null || clock() - entry.ReleasedAt < idleTimeout.TotalMilliseconds);

    internal int WarmReadyCount
    {
        get { lock (gate) return entries.Count(entry => !entry.Busy && entry.ThreadId is null && Reusable(entry)); }
    }

    internal bool OwnsThread(string threadId)
    {
        lock (gate) return entries.Any(entry => entry.ThreadId == threadId && entry.Server?.IsConnected == true);
    }

    internal async Task<Lease> AcquireAsync(string? threadId, string configuration, CancellationToken token)
    {
        using var lifetime = CancellationTokenSource.CreateLinkedTokenSource(token, stopping.Token);
        token = lifetime.Token;
        while (true)
        {
            Entry? selected;
            bool retiringOwner;
            Task wait;
            lock (gate)
            {
                token.ThrowIfCancellationRequested();
                ObjectDisposedException.ThrowIf(disposed, this);
                // Never assign another process to a thread while its previous
                // writer is in use or is still shutting down.
                var owned = threadId is null ? null : entries.FirstOrDefault(entry => entry.ThreadId == threadId);
                if (owned is { Busy: false } && owned.Configuration == configuration && Reusable(owned))
                {
                    owned.Busy = true;
                    return new(this, owned, true);
                }
                if (owned is null)
                {
                    var warm = entries.FirstOrDefault(entry => !entry.Busy && entry.ThreadId is null && Reusable(entry));
                    if (warm is not null)
                    {
                        warm.Busy = true;
                        warm.Configuration = configuration;
                        Pulse();
                        return new(this, warm, false, true);
                    }
                }
                retiringOwner = owned is { Busy: false };
                selected = owned is { Busy: false } ? owned : owned is not null ? null :
                    entries.Where(entry => !entry.Busy).OrderBy(entry => entry.ReleasedAt).FirstOrDefault();
                if (owned is null && entries.Count < limit)
                {
                    selected = new();
                    entries.Add(selected);
                }
                if (selected is not null) selected.Busy = true;
                wait = changed.Task;
            }
            if (selected is null) { await wait.WaitAsync(token); continue; }
            if (retiringOwner)
            {
                // Release the old writer before taking a pristine warm process.
                await ReturnAsync(selected, false);
                continue;
            }
            try
            {
                if (selected.Server is not null) await selected.Server.DisposeAsync();
                lock (gate)
                {
                    selected.Server = null;
                    selected.ThreadId = null;
                    selected.Invalidated = false;
                    selected.Configuration = configuration;
                }
                token.ThrowIfCancellationRequested();
                await StartEntryAsync(selected, token);
                token.ThrowIfCancellationRequested();
                return new(this, selected, false);
            }
            catch { await ReturnAsync(selected, false); throw; }
        }
    }

    private async Task StartEntryAsync(Entry entry, CancellationToken token)
    {
        var server = await start(token);
        lock (gate) entry.Server = server;
        server.Event += message =>
        {
            var method = CodexJson.Text(message, "method");
            var id = CodexJson.Text(CodexJson.Field(message, "params"), "threadId");
            lock (gate)
            {
                if (method == "hako/connectionClosed" ||
                    method is "thread/closed" or "thread/archived" && id == entry.ThreadId)
                { entry.Invalidated = true; Pulse(); }
            }
        };
        if (!server.IsConnected) throw new IOException("Codex closed during initialization.");
        token.ThrowIfCancellationRequested();
    }

    private async Task WarmAsync()
    {
        var failures = 0;
        try
        {
            while (true)
            {
                Entry? entry = null;
                var retire = false;
                Task wait;
                lock (gate)
                {
                    stopping.Token.ThrowIfCancellationRequested();
                    // Never evict a retained session just to fill the reserve.
                    entry = entries.FirstOrDefault(value => !value.Busy && value.ThreadId is null && !Reusable(value));
                    if (entry is not null) { entry.Busy = true; retire = true; }
                    else if (entries.Count < limit && entries.Count(value => value.ThreadId is null) < warmCount)
                    { entry = new(); entries.Add(entry); }
                    wait = changed.Task;
                }
                if (entry is null) { await wait.WaitAsync(stopping.Token); continue; }
                if (retire) { await ReturnAsync(entry, false); continue; }
                var elapsed = Stopwatch.StartNew();
                try
                {
                    await StartEntryAsync(entry, stopping.Token);
                    lock (gate) { entry.Busy = false; entry.ReleasedAt = clock(); Pulse(); }
                    failures = 0;
                    log?.Invoke("worker/prewarm", elapsed.ElapsedMilliseconds, "completed");
                }
                catch (Exception error)
                {
                    await ReturnAsync(entry, false);
                    if (stopping.IsCancellationRequested) throw new OperationCanceledException(stopping.Token);
                    log?.Invoke("worker/prewarm", elapsed.ElapsedMilliseconds, error.GetType().Name);
                    await Task.Delay(TimeSpan.FromSeconds(Math.Min(30, 1 << Math.Min(failures++, 5))), stopping.Token);
                }
            }
        }
        catch (OperationCanceledException) when (stopping.IsCancellationRequested) { }
    }

    private async Task ReturnAsync(Entry entry, bool retain)
    {
        lock (gate)
        {
            if (retain && !disposed && !entry.Invalidated && entry.ThreadId is not null && entry.Server?.IsConnected == true)
            {
                entry.ReleasedAt = clock();
                entry.Busy = false;
                Pulse();
                return;
            }
        }
        try { if (entry.Server is not null) await entry.Server.DisposeAsync(); }
        finally { lock (gate) { entries.Remove(entry); Pulse(); } }
    }

    internal async Task ReleaseIdleAsync(string threadId, CancellationToken token)
    {
        Entry? entry;
        lock (gate)
        {
            token.ThrowIfCancellationRequested();
            entry = entries.FirstOrDefault(value => value.ThreadId == threadId);
            if (entry is null) return;
            if (entry.Busy) throw new WorkshopException("codex_busy", "会话正在执行或回收，请稍后重试。");
            entry.Busy = true;
        }
        await ReturnAsync(entry, false);
    }

    internal async Task SweepAsync()
    {
        Entry[] expired;
        lock (gate)
        {
            expired = entries.Where(entry => !entry.Busy && !Reusable(entry)).ToArray();
            foreach (var entry in expired) entry.Busy = true;
        }
        await Task.WhenAll(expired.Select(entry => ReturnAsync(entry, false)));
    }

    private async Task ReapAsync(TimeSpan interval)
    {
        try
        {
            using var timer = new PeriodicTimer(interval);
            while (await timer.WaitForNextTickAsync(stopping.Token)) await SweepAsync();
        }
        catch (OperationCanceledException) when (stopping.IsCancellationRequested) { }
    }

    public async ValueTask DisposeAsync()
    {
        lock (gate) { disposed = true; Pulse(); }
        await stopping.CancelAsync();
        await Task.WhenAll(reaper, warmer);
        // CodeWorkshop has already joined all active workers at this point.
        Entry[] remaining;
        lock (gate) remaining = entries.ToArray();
        await Task.WhenAll(remaining.Select(entry => ReturnAsync(entry, false)));
        stopping.Dispose();
    }
}
