using System;
using System.IO;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Hako.Platform;

namespace Hako.Core;

internal sealed record GuardianSnapshot(AgentConnection.ConnectionState Connection, string? CompatibilityWarning,
    string WorkshopState, string? ComputerId, string? Error = null);

internal sealed class GuardianBroker : IAsyncDisposable
{
    private readonly string profile;
    private readonly AgentSettingsStore store;
    private readonly GuardianDispatcher dispatcher;
    private readonly AgentConnection connection;
    private readonly WorkshopConnection workshop;
    private LocalRpcServer? rpc;
    private readonly SemaphoreSlim operations = new(1, 1);
    private readonly SemaphoreSlim workshopOpening = new(1, 1);
    private readonly CancellationTokenSource stopping = new();
    private Task watching = Task.CompletedTask;
    private string? activeScope, error;
    private string PausedPath => AgentGuardianControl.FileFor(profile, "connection-paused");
    internal GuardianBroker(string profile, bool start = true)
    {
        this.profile = profile; store = new AgentSettingsStore(profile);
        dispatcher = new GuardianDispatcher(profile);
        connection = new AgentConnection(dispatcher, OpenWorkshopAsync);
        workshop = new WorkshopConnection(new GuardianWorkshopDispatcher(profile), id =>
        {
            try { Directory.CreateDirectory(profile); File.WriteAllText(Path.Combine(profile, "workshop-computer-id.txt"), id); }
            catch (IOException) { }
        }, profileDirectory: profile);
        if (start) Start();
    }
    internal void Prepare()
    {
        var settings = store.Load();
        if (!File.Exists(PausedPath) && settings.Url.Length > 0 && settings.PrivateKey.Length > 0)
        {
            settings.Validate();
            using var key = System.Security.Cryptography.RSA.Create();
            key.ImportFromPem(settings.PrivateKey);
        }
    }
    internal void Start()
    {
        if (rpc is not null) throw new InvalidOperationException("Guardian broker already started.");
        rpc = new LocalRpcServer(LocalRpc.GuardianPipe(profile), HandleAsync, LocalRpcLog.ForProfile(profile, "guardian"));
        watching = Task.Run(WatchAsync);
    }
    private GuardianSnapshot Snapshot() => new(connection.Status, connection.CompatibilityWarning, workshop.State, workshop.ComputerId, error);
    private async Task HandleAsync(LocalRequest request, Func<object?, Task> publish, CancellationToken token)
    {
        if (request.Version != 1) throw new AgentActionException("unsupported_method", "不支持的本机通信版本。");
        if (request.Kind == "status") { await publish(Snapshot()); return; }
        if (request.Kind == "admin" && request.Method.StartsWith("admin.", StringComparison.Ordinal))
        { await publish(await dispatcher.InvokeAsync(request.Method, request.Version, request.Parameters, token)); return; }
        if (request.Kind is not ("connect" or "disconnect")) throw new AgentActionException("unsupported_method", "未知的守护请求。");
        await operations.WaitAsync(token);
        try
        {
            var enabled = request.Kind == "connect";
            var settings = store.Load();
            if (enabled) settings.Validate();
            if (enabled) File.Delete(PausedPath); else File.WriteAllText(PausedPath, "paused");
            await ApplyAsync(settings, enabled);
            await publish(Snapshot());
        }
        finally { operations.Release(); }
    }
    private async Task WatchAsync()
    {
        while (!stopping.IsCancellationRequested)
        {
            try
            {
                await operations.WaitAsync(stopping.Token);
                try
                {
                    var settings = store.Load();
                    await ApplyAsync(settings, !File.Exists(PausedPath) && settings.Url.Length > 0 && settings.PrivateKey.Length > 0);
                    error = null;
                }
                finally { operations.Release(); }
            }
            catch (OperationCanceledException) when (stopping.IsCancellationRequested) { break; }
            catch (Exception)
            {
                // A broken or cleared configuration must not leave credentials
                // from a previous account connected in the background.
                await operations.WaitAsync();
                try { await ApplyAsync(new AgentSettings(), false); }
                finally { operations.Release(); }
                error = "守护进程无法读取或应用服务器配置，请检查设置。";
            }
            try { await Task.Delay(500, stopping.Token); } catch (OperationCanceledException) { break; }
        }
    }
    private async Task ApplyAsync(AgentSettings settings, bool enabled)
    {
        if (enabled) settings.Validate();
        var scope = enabled ? CommandHost.Scope(profile, settings) : null;
        if (scope == activeScope) return;
        await connection.StopAsync(); await workshop.StopAsync(); activeScope = null;
        if (enabled)
        {
            try
            {
                await connection.StartAsync(settings);
                activeScope = scope;
            }
            catch { await connection.StopAsync(); await workshop.StopAsync(); throw; }
        }
    }
    private async Task OpenWorkshopAsync(CancellationToken token)
    {
        await workshopOpening.WaitAsync(token);
        try {
            if (workshop.State is "disconnected" or "authentication_failed") await workshop.StartAsync(store.Load());
            while (workshop.State != "connected") await Task.Delay(50, token);
        } finally { workshopOpening.Release(); }
    }
    public async ValueTask DisposeAsync()
    {
        await stopping.CancelAsync(); await watching;
        if (rpc is not null) await rpc.DisposeAsync();
        await workshop.DisposeAsync(); await connection.DisposeAsync();
        operations.Dispose(); stopping.Dispose();
    }
}
