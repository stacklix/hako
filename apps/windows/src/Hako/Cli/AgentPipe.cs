using System;
using System.IO;
using System.IO.Pipes;
using System.Threading;
using System.Threading.Tasks;

namespace Hako.Core;

public sealed class AgentPipeServer : IAsyncDisposable
{
    private readonly AgentProfile profile;
    private readonly AgentRuntime runtime;
    private readonly Action exit;
    private readonly CancellationTokenSource stopping = new();
    private readonly Task loop;
    public AgentPipeServer(AgentProfile profile, AgentRuntime runtime, Action exit)
    {
        this.profile = profile; this.runtime = runtime; this.exit = exit;
        loop = Task.Run(ListenAsync);
    }
    private async Task ListenAsync()
    {
        while (!stopping.IsCancellationRequested)
        {
            try
            {
                await using var pipe = new NamedPipeServerStream(profile.PipeName, PipeDirection.InOut, 1,
                    PipeTransmissionMode.Byte, PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
                await pipe.WaitForConnectionAsync(stopping.Token);
                using var deadline = CancellationTokenSource.CreateLinkedTokenSource(stopping.Token);
                deadline.CancelAfter(TimeSpan.FromSeconds(20));
                var request = await CliWire.ReadAsync<AgentCommand>(pipe, deadline.Token);
                var reply = await runtime.ExecuteAsync(request, deadline.Token);
                await CliWire.WriteAsync(pipe, reply, deadline.Token);
                if (request.Command == "exit" && reply.ExitCode == 0) exit();
            }
            catch (OperationCanceledException) when (stopping.IsCancellationRequested) { break; }
            catch (Exception error) when (error is IOException or InvalidDataException or OperationCanceledException or System.Text.Json.JsonException or UnauthorizedAccessException)
            {
                // Bound retries if another process owns the pipe or the transport is unavailable.
                try { await Task.Delay(50, stopping.Token); } catch (OperationCanceledException) { break; }
            }
        }
    }
    public async ValueTask DisposeAsync()
    {
        await stopping.CancelAsync();
        await loop;
        stopping.Dispose();
    }
}

public static class AgentPipeClient
{
    // Null means no connection was established. Never retry locally after sending a command.
    public static async Task<CommandReply?> TrySendAsync(AgentProfile profile, AgentCommand request, int connectTimeout = 150)
    {
        using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(25));
        await using var pipe = new NamedPipeClientStream(".", profile.PipeName, PipeDirection.InOut,
            PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
        try { await pipe.ConnectAsync(connectTimeout, deadline.Token); }
        catch (TimeoutException) { return null; }
        await CliWire.WriteAsync(pipe, request, deadline.Token);
        return await CliWire.ReadAsync<CommandReply>(pipe, deadline.Token);
    }
}
