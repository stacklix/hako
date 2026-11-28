using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.IO.Pipes;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace Hako.Core;

internal sealed record LocalRequest(string Kind, string Method, int Version, JsonElement Parameters, string? Scope = null);
internal sealed record LocalReply(JsonElement? Result = null, CapabilityError? Error = null, bool End = false);

// Each call has its own current-user-only pipe connection. Mutations are never
// replayed; closing a stream cancels its server work and releases its slot.
internal sealed class LocalRpcServer : IAsyncDisposable
{
    private readonly string name;
    private readonly Func<LocalRequest, Func<object?, Task>, CancellationToken, Task> handle;
    private readonly CancellationTokenSource stopping = new();
    private readonly SemaphoreSlim slots = new(64, 64);
    private readonly HashSet<Task> clients = new();
    private readonly object gate = new();
    private readonly Task accepting;
    private readonly LocalRpcLog? log;
    private int active, streams;
    internal LocalRpcServer(string name, Func<LocalRequest, Func<object?, Task>, CancellationToken, Task> handle,
        LocalRpcLog? log = null)
    {
        this.name = name; this.handle = handle; this.log = log;
        // The main Agent creates this server on its WPF dispatcher. Accepting
        // must keep running while that dispatcher is busy updating the UI.
        accepting = Task.Run(AcceptAsync);
    }

    private async Task AcceptAsync()
    {
        while (!stopping.IsCancellationRequested)
        {
            NamedPipeServerStream? pipe = null;
            var reserved = false;
            try
            {
                var capacityWait = Stopwatch.StartNew();
                if (slots.CurrentCount == 0) log?.Write("capacity_exhausted", active: Volatile.Read(ref active), streams: Volatile.Read(ref streams));
                await slots.WaitAsync(stopping.Token);
                if (capacityWait.ElapsedMilliseconds >= 250) log?.Write("capacity_wait", capacityWait.ElapsedMilliseconds,
                    active: Volatile.Read(ref active), streams: Volatile.Read(ref streams));
                reserved = true;
                pipe = new NamedPipeServerStream(name, PipeDirection.InOut, 65, PipeTransmissionMode.Byte,
                    PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
                await pipe.WaitForConnectionAsync(stopping.Token);
                var accepted = pipe; pipe = null; reserved = false;
                var scheduledAt = Stopwatch.GetTimestamp();
                Interlocked.Increment(ref active);
                var work = Task.Run(() => ServeAsync(accepted, scheduledAt));
                lock (gate) clients.Add(work);
                _ = work.ContinueWith(completed =>
                {
                    lock (gate) clients.Remove(completed);
                    if (completed.Exception is { } error)
                        log?.Write("handler_fault", error: error.Flatten().InnerExceptions[0]);
                }, TaskScheduler.Default);
            }
            catch (OperationCanceledException) when (stopping.IsCancellationRequested) { break; }
            catch (IOException error) { log?.Write("accept_failed", error: error); await Task.Delay(100); }
            finally { pipe?.Dispose(); if (reserved) slots.Release(); }
        }
    }
    private async Task ServeAsync(NamedPipeServerStream pipe, long scheduledAt)
    {
        await using (pipe)
        using (var call = CancellationTokenSource.CreateLinkedTokenSource(stopping.Token))
        using (var writing = new SemaphoreSlim(1, 1))
        {
            async Task Send(LocalReply reply)
            {
                using var deadline = CancellationTokenSource.CreateLinkedTokenSource(call.Token);
                deadline.CancelAfter(TimeSpan.FromSeconds(5));
                await writing.WaitAsync(deadline.Token);
                try { await CliWire.WriteAsync(pipe, reply, deadline.Token); }
                finally { writing.Release(); }
            }
            Task? disconnected = null;
            LocalRequest? request = null;
            var isStream = false;
            var elapsed = Stopwatch.StartNew();
            var stage = "handshake";
            try
            {
                var dispatchMs = (long)Stopwatch.GetElapsedTime(scheduledAt).TotalMilliseconds;
                if (dispatchMs >= 250) log?.Write("dispatch_slow", dispatchMs, active: Volatile.Read(ref active), streams: Volatile.Read(ref streams));
                using var handshake = CancellationTokenSource.CreateLinkedTokenSource(call.Token);
                handshake.CancelAfter(TimeSpan.FromSeconds(5));
                request = await CliWire.ReadAsync<LocalRequest>(pipe, handshake.Token);
                if (request.Parameters.ValueKind != JsonValueKind.Object) throw new AgentActionException("invalid_params", "本机请求参数必须是对象。");
                isStream = request.Kind is "telemetry" or "workshop.watch" or "workshop.terminals";
                if (isStream) Interlocked.Increment(ref streams);
                disconnected = Task.Run(async () =>
                {
                    try { if (await pipe.ReadAsync(new byte[1], call.Token) == 0) return; }
                    catch (Exception error) when (error is IOException or OperationCanceledException) { }
                    finally { await call.CancelAsync(); }
                });
                if (!isStream) call.CancelAfter(TimeSpan.FromSeconds(20));
                stage = "execute";
                await handle(request, value => Send(new LocalReply(JsonSerializer.SerializeToElement(value, AgentConnection.Json))), call.Token);
                stage = "finish";
                await Send(new LocalReply(End: true));
                if (!isStream && elapsed.ElapsedMilliseconds >= 1000) log?.Write("request_slow", elapsed.ElapsedMilliseconds, request,
                    Volatile.Read(ref active), Volatile.Read(ref streams));
            }
            catch (Exception error) when (error is not OperationCanceledException)
            {
                log?.Write(stage + "_failed", elapsed.ElapsedMilliseconds, request, Volatile.Read(ref active), Volatile.Read(ref streams), error);
                var failure = error is AgentActionException action ? new CapabilityError(action.Code, action.Message)
                    : error is Hako.Platform.WorkshopException workshop ? new CapabilityError(workshop.Code, workshop.Message)
                    : new CapabilityError("local_execution_failed", "本机进程执行失败。");
                try { await Send(new LocalReply(Error: failure, End: true)); }
                catch (Exception writeError) when (writeError is IOException or OperationCanceledException) { }
            }
            catch (OperationCanceledException)
            {
                if (!isStream && !stopping.IsCancellationRequested && elapsed.ElapsedMilliseconds >= 1000)
                    log?.Write(stage + "_cancelled", elapsed.ElapsedMilliseconds, request, Volatile.Read(ref active), Volatile.Read(ref streams));
            }
            finally
            {
                await call.CancelAsync();
                if (disconnected is not null) await disconnected;
                if (isStream) Interlocked.Decrement(ref streams);
                Interlocked.Decrement(ref active);
                slots.Release();
            }
        }
    }
    public async ValueTask DisposeAsync()
    {
        await stopping.CancelAsync();
        await accepting;
        Task[] pending; lock (gate) pending = [.. clients];
        await Task.WhenAll(pending);
        slots.Dispose(); stopping.Dispose();
    }
}

internal static class LocalRpc
{
    internal static string MainPipe(string profile) => new AgentProfile(profile).PipeName + ".rpc";
    internal static string GuardianPipe(string profile) => new AgentProfile(profile).PipeName + ".guardian";
    internal static LocalRequest Request(string kind, string method = "", object? parameters = null, int version = 1, string? scope = null) =>
        new(kind, method, version, JsonSerializer.SerializeToElement(parameters ?? new { }, AgentConnection.Json), scope);

    internal static async Task<JsonElement> CallAsync(string name, LocalRequest request, CancellationToken token, LocalRpcLog? log = null)
    {
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(token);
        deadline.CancelAfter(TimeSpan.FromSeconds(22));
        JsonElement? result = null;
        await StreamAsync(name, request, value => { result = value; return Task.CompletedTask; }, deadline.Token, log);
        return result ?? throw new AgentActionException("local_reply_missing", "本机进程未返回执行结果。");
    }
    internal static async Task StreamAsync(string name, LocalRequest request, Func<JsonElement, Task> publish, CancellationToken token, LocalRpcLog? log = null)
    {
        await using var pipe = new NamedPipeClientStream(".", name, PipeDirection.InOut, PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
        var elapsed = Stopwatch.StartNew();
        try { await pipe.ConnectAsync(2000, token); }
        catch (Exception error) when (error is TimeoutException or IOException)
        {
            log?.Write("connect_failed", elapsed.ElapsedMilliseconds, request, error: error);
            throw new AgentActionException("process_unavailable", "本机通信暂时未能接入，请稍后查询状态。");
        }
        catch (OperationCanceledException)
        {
            if (elapsed.ElapsedMilliseconds >= 1000) log?.Write("connect_cancelled", elapsed.ElapsedMilliseconds, request);
            throw;
        }
        if (elapsed.ElapsedMilliseconds >= 250) log?.Write("connect_slow", elapsed.ElapsedMilliseconds, request);
        var stage = "send";
        try
        {
            await CliWire.WriteAsync(pipe, request, token);
            stage = "reply";
            while (true)
            {
                var reply = await CliWire.ReadAsync<LocalReply>(pipe, token);
                if (reply.Error is { } error) throw new AgentActionException(error.Code, error.Message);
                if (reply.Result is { } result) await publish(result);
                if (reply.End) return;
            }
        }
        catch (IOException error)
        {
            log?.Write(stage + "_disconnected", elapsed.ElapsedMilliseconds, request, error: error);
            throw new AgentActionException("process_disconnected", "本机进程通信已中断；操作结果未确认，请查询状态，勿自动重试。");
        }
        catch (OperationCanceledException)
        {
            if (elapsed.ElapsedMilliseconds >= 1000 && request.Kind is not ("workshop.watch" or "workshop.terminals" or "telemetry"))
                log?.Write(stage + "_cancelled", elapsed.ElapsedMilliseconds, request);
            throw;
        }
    }
}
