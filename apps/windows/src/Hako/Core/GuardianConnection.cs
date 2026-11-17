using System;
using System.IO;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace Hako.Core;

// The main process exposes connection state to its UI but owns no server socket.
public sealed class GuardianConnection : IAsyncDisposable
{
    private readonly string profile;
    private readonly CancellationTokenSource stopping = new();
    private readonly object gate = new();
    private Task? watching;
    private Task? connecting;
    private CancellationTokenSource? attempt;
    public AgentConnection.ConnectionState Status { get; private set; } = new("disconnected", "未连接");
    public string? CompatibilityWarning { get; private set; }
    internal string WorkshopState { get; private set; } = "disconnected";
    internal string? ComputerId { get; private set; }
    public event Action<string>? StatusChanged;
    internal GuardianConnection(string profile) { this.profile = profile; }
    private async Task EnsureAsync(CancellationToken token)
    {
        await AgentGuardianControl.EnsureRunningAsync(profile, token);
        lock (gate) watching ??= Task.Run(WatchAsync);
    }
    public async Task StartAsync(AgentSettings settings)
    {
        settings.Validate();
        // A CLI connect immediately after background startup joins the same
        // initialization. The guardian reads the latest settings from disk.
        // Cancelling and awaiting that initialization can stall the CLI reply.
        if (connecting is { IsCompleted: false }) return;
        await CancelConnectAsync();
        attempt = CancellationTokenSource.CreateLinkedTokenSource(stopping.Token);
        var token = attempt.Token;
        Status = new("connecting", "正在连接守护进程…"); StatusChanged?.Invoke(Status.Message);
        lock (gate) watching ??= Task.Run(WatchAsync);
        // Publish the main CLI before waiting for guardian replacement. The old
        // guardian may be completing this main-process update transaction.
        connecting = Task.Run(async () =>
        {
            try
            {
                await EnsureAsync(token);
                Update(await LocalRpc.CallAsync(LocalRpc.GuardianPipe(profile), LocalRpc.Request("connect"), token));
            }
            catch (OperationCanceledException) when (token.IsCancellationRequested) { }
            catch (Exception)
            { Status = new("guardian_unavailable", "守护进程暂不可用，请检查守护状态。"); StatusChanged?.Invoke(Status.Message); }
        });
    }
    private async Task CancelConnectAsync()
    {
        if (attempt is null) return;
        await attempt.CancelAsync();
        if (connecting is not null) await connecting;
        attempt.Dispose(); attempt = null; connecting = null;
    }
    public async Task StopAsync()
    {
        await CancelConnectAsync();
        Directory.CreateDirectory(AgentGuardianControl.DirectoryFor(profile));
        File.WriteAllText(AgentGuardianControl.FileFor(profile, "connection-paused"), "paused");
        try { Update(await LocalRpc.CallAsync(LocalRpc.GuardianPipe(profile), LocalRpc.Request("disconnect"), stopping.Token)); }
        catch (AgentActionException error) when (error.Code == "process_unavailable")
        {
            Status = new("disconnected", "未连接"); CompatibilityWarning = null; WorkshopState = "disconnected";
            StatusChanged?.Invoke(Status.Message);
        }
    }
    internal async Task<T> AdminAsync<T>(string method, object parameters, CancellationToken token)
    {
        await EnsureAsync(token);
        var value = await LocalRpc.CallAsync(LocalRpc.GuardianPipe(profile), LocalRpc.Request("admin", method, parameters), token);
        return value.Deserialize<T>(AgentConnection.Json) ?? throw new InvalidOperationException("守护进程返回的数据无效。");
    }
    private void Update(JsonElement result)
    {
        var value = result.Deserialize<GuardianSnapshot>(AgentConnection.Json)!;
        var next = value.Error is null ? value.Connection : new AgentConnection.ConnectionState("configuration_error", value.Error);
        var changed = Status != next || CompatibilityWarning != value.CompatibilityWarning;
        Status = next; CompatibilityWarning = value.CompatibilityWarning;
        WorkshopState = value.WorkshopState; ComputerId = value.ComputerId;
        if (changed) StatusChanged?.Invoke(Status.Message);
    }
    private async Task WatchAsync()
    {
        while (!stopping.IsCancellationRequested)
        {
            try { Update(await LocalRpc.CallAsync(LocalRpc.GuardianPipe(profile), LocalRpc.Request("status"), stopping.Token)); }
            catch (OperationCanceledException) when (stopping.IsCancellationRequested) { break; }
            catch (Exception)
            {
                Status = connecting is { IsCompleted: false } ? new("connecting", "守护进程正在启动或更新，等待就绪。")
                    : new("guardian_unavailable", "守护进程暂不可用，等待恢复。");
                StatusChanged?.Invoke(Status.Message);
            }
            try { await Task.Delay(500, stopping.Token); } catch (OperationCanceledException) { break; }
        }
    }
    public async ValueTask DisposeAsync()
    {
        await stopping.CancelAsync();
        await CancelConnectAsync();
        if (watching is not null) await watching;
        stopping.Dispose();
    }
}
