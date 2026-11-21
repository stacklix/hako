using System;
using System.IO;
using System.Threading.Tasks;
using Hako.Core;

namespace Hako.Platform;

internal sealed class WorkshopService : IAsyncDisposable
{
    internal WorkshopDispatcher Dispatcher { get; }
    private readonly GuardianConnection cloud;
    private readonly string directory;
    private readonly string identityFile;
    private string? computerId;
    private WorkshopLocalServer? local;
    private readonly AgentLanEndpoint? lan;
    internal string? ConfigurationError { get; set; }
    internal WorkshopService(string dataDirectory, GuardianConnection connection, AgentLanEndpoint? lan = null)
    {
        this.lan = lan;
        directory = dataDirectory;
        identityFile = Path.Combine(directory, "workshop-computer-id.txt");
        if (File.Exists(identityFile)) computerId = File.ReadAllText(identityFile).Trim();
        Dispatcher = new WorkshopDispatcher(directory);
        cloud = connection;
    }
    internal object Status => new { connectionState = cloud.WorkshopState, computerId = cloud.ComputerId, direct = DirectStatus, error = ConfigurationError };
    internal object DirectStatus => new { listening = local != null, port = local?.Port ?? 0 };
    internal WorkshopRegistration Registration => WorkshopRegistration.Snapshot(local?.Port ?? 0);
    internal async Task ConfigureLocalAsync(int port)
    {
        if (port is < 0 or > 65535) throw new ArgumentException("代码工坊直连端口无效。");
        if ((local?.Port ?? 0) == port) { ConfigurationError = null; return; }
        if (lan != null) lan.Port = 0;
        if (local != null) { await local.DisposeAsync(); local = null; }
        if (port != 0) local = new WorkshopLocalServer(Dispatcher, port, () => cloud.ComputerId ?? computerId, directory, lan: lan);
        if (lan != null) lan.Port = local?.Port ?? 0;
        ConfigurationError = null;
    }
    public async ValueTask DisposeAsync()
    {
        if (lan != null) lan.Port = 0;
        if (local != null) await local.DisposeAsync();
        await Dispatcher.DisposeAsync();
    }
}
