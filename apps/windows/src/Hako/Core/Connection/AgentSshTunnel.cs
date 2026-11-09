using System;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Threading;
using System.Threading.Channels;
using System.Threading.Tasks;

namespace Hako.Core;

internal sealed class AgentSshTunnel : IAsyncDisposable
{
    private const int ChunkSize = 4096;
    private readonly CancellationTokenSource lifetime;
    private readonly Channel<byte[]> input = Channel.CreateBounded<byte[]>(32);
    private readonly Task running;
    public string Id { get; }

    public AgentSshTunnel(string id, Func<object, CancellationToken, Task> send, CancellationToken connection)
    {
        Id = id;
        lifetime = CancellationTokenSource.CreateLinkedTokenSource(connection);
        running = RunAsync(send, lifetime.Token);
    }

    public bool TryWrite(byte[] data) =>
        data.Length is > 0 and <= ChunkSize && input.Writer.TryWrite(data);

    public async ValueTask DisposeAsync()
    {
        await lifetime.CancelAsync();
        try { await running; }
        finally { lifetime.Dispose(); }
    }

    private async Task RunAsync(Func<object, CancellationToken, Task> send, CancellationToken token)
    {
        try
        {
            using var tcp = new TcpClient { NoDelay = true };
            using (var deadline = CancellationTokenSource.CreateLinkedTokenSource(token))
            {
                deadline.CancelAfter(TimeSpan.FromSeconds(5));
                await tcp.ConnectAsync(IPAddress.Loopback, 22, deadline.Token);
            }
            using var stream = tcp.GetStream();
            using var io = CancellationTokenSource.CreateLinkedTokenSource(token);
            var outgoing = RelayOutputAsync(stream, send, io.Token);
            var incoming = RelayInputAsync(stream, io.Token);
            await Task.WhenAny(outgoing, incoming);
            await io.CancelAsync();
            await Task.WhenAll(outgoing, incoming);
        }
        catch (Exception error) when (error is IOException or SocketException or OperationCanceledException) { }
        finally { input.Writer.TryComplete(); }
        if (!token.IsCancellationRequested)
            await send(new { type = "ssh_closed", id = Id }, token);
    }

    private async Task RelayOutputAsync(NetworkStream stream, Func<object, CancellationToken, Task> send, CancellationToken token)
    {
        var buffer = new byte[ChunkSize];
        while (true)
        {
            var count = await stream.ReadAsync(buffer, token);
            if (count == 0) return;
            await send(new { type = "ssh_data", id = Id, data = buffer.AsSpan(0, count).ToArray() }, token);
        }
    }

    private async Task RelayInputAsync(NetworkStream stream, CancellationToken token)
    {
        await foreach (var data in input.Reader.ReadAllAsync(token))
            await stream.WriteAsync(data, token);
    }
}
