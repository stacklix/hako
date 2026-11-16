using System;
using System.Collections.Generic;
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
    internal LocalRpcServer(string name, Func<LocalRequest, Func<object?, Task>, CancellationToken, Task> handle)
    { this.name = name; this.handle = handle; accepting = AcceptAsync(); }

    private async Task AcceptAsync()
    {
        while (!stopping.IsCancellationRequested)
        {
            NamedPipeServerStream? pipe = null;
            var reserved = false;
            try
            {
                await slots.WaitAsync(stopping.Token);
                reserved = true;
                pipe = new NamedPipeServerStream(name, PipeDirection.InOut, 65, PipeTransmissionMode.Byte,
                    PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
                await pipe.WaitForConnectionAsync(stopping.Token);
                var accepted = pipe; pipe = null; reserved = false;
                var work = Task.Run(() => ServeAsync(accepted));
                lock (gate) clients.Add(work);
                _ = work.ContinueWith(_ => { lock (gate) clients.Remove(work); }, TaskScheduler.Default);
            }
            catch (OperationCanceledException) when (stopping.IsCancellationRequested) { break; }
            catch (IOException) { await Task.Delay(100); }
            finally { pipe?.Dispose(); if (reserved) slots.Release(); }
        }
    }
    private async Task ServeAsync(NamedPipeServerStream pipe)
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
            try
            {
                using var handshake = CancellationTokenSource.CreateLinkedTokenSource(call.Token);
                handshake.CancelAfter(TimeSpan.FromSeconds(5));
                var request = await CliWire.ReadAsync<LocalRequest>(pipe, handshake.Token);
                if (request.Parameters.ValueKind != JsonValueKind.Object) throw new AgentActionException("invalid_params", "本机请求参数必须是对象。");
                disconnected = Task.Run(async () =>
                {
                    try { if (await pipe.ReadAsync(new byte[1], call.Token) == 0) return; }
                    catch (Exception error) when (error is IOException or OperationCanceledException) { }
                    finally { await call.CancelAsync(); }
                });
                if (request.Kind is not ("telemetry" or "workshop.watch" or "workshop.terminals")) call.CancelAfter(TimeSpan.FromSeconds(20));
                await handle(request, value => Send(new LocalReply(JsonSerializer.SerializeToElement(value, AgentConnection.Json))), call.Token);
                await Send(new LocalReply(End: true));
            }
            catch (Exception error) when (error is not OperationCanceledException)
            {
                var failure = error is AgentActionException action ? new CapabilityError(action.Code, action.Message)
                    : error is Hako.Platform.WorkshopException workshop ? new CapabilityError(workshop.Code, workshop.Message)
                    : new CapabilityError("local_execution_failed", "本机进程执行失败。");
                try { await Send(new LocalReply(Error: failure, End: true)); }
                catch (Exception writeError) when (writeError is IOException or OperationCanceledException) { }
            }
            catch (OperationCanceledException) { }
            finally
            {
                await call.CancelAsync();
                if (disconnected is not null) await disconnected;
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

    internal static async Task<JsonElement> CallAsync(string name, LocalRequest request, CancellationToken token)
    {
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(token);
        deadline.CancelAfter(TimeSpan.FromSeconds(22));
        JsonElement? result = null;
        await StreamAsync(name, request, value => { result = value; return Task.CompletedTask; }, deadline.Token);
        return result ?? throw new AgentActionException("local_reply_missing", "本机进程未返回执行结果。");
    }
    internal static async Task StreamAsync(string name, LocalRequest request, Func<JsonElement, Task> publish, CancellationToken token)
    {
        await using var pipe = new NamedPipeClientStream(".", name, PipeDirection.InOut, PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
        try { await pipe.ConnectAsync(2000, token); }
        catch (Exception error) when (error is TimeoutException or IOException)
        { throw new AgentActionException("process_unavailable", "所需本机进程尚未运行。"); }
        try
        {
            await CliWire.WriteAsync(pipe, request, token);
            while (true)
            {
                var reply = await CliWire.ReadAsync<LocalReply>(pipe, token);
                if (reply.Error is { } error) throw new AgentActionException(error.Code, error.Message);
                if (reply.Result is { } result) await publish(result);
                if (reply.End) return;
            }
        }
        catch (IOException) { throw new AgentActionException("process_disconnected", "本机进程通信已中断；操作结果未确认，请查询状态，勿自动重试。"); }
    }
}
