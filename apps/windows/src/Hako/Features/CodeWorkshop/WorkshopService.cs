using System;
using System.IO;
using System.Threading.Tasks;
using Hako.Core;

namespace Hako.Platform;

internal sealed class WorkshopService : IAsyncDisposable
{
    private readonly WorkshopDispatcher dispatcher;
    private readonly WorkshopConnection cloud;
    private readonly string directory;
    private readonly string identityFile;
    private string? computerId;
    private WorkshopLocalServer? local;
    internal string? ConfigurationError { get; set; }
    internal WorkshopService(string dataDirectory)
    {
        directory = dataDirectory;
        identityFile = Path.Combine(directory, "workshop-computer-id.txt");
        if (File.Exists(identityFile)) computerId = File.ReadAllText(identityFile).Trim();
        dispatcher = new WorkshopDispatcher(directory);
        cloud = new WorkshopConnection(dispatcher, id =>
        {
            computerId = id;
            try { Directory.CreateDirectory(directory); File.WriteAllText(identityFile, id); } catch (IOException) { }
        });
    }
    internal object Status => new { connectionState = cloud.State, computerId = cloud.ComputerId, direct = DirectStatus, error = ConfigurationError };
    internal object DirectStatus => new { listening = local != null, port = local?.Port ?? 0 };
    internal Task StartAsync(AgentSettings settings) => cloud.StartAsync(settings);
    internal Task StopAsync() => cloud.StopAsync();
    internal async Task ConfigureLocalAsync(int port)
    {
        if (port is < 0 or > 65535) throw new ArgumentException("代码工坊直连端口无效。");
        if ((local?.Port ?? 0) == port) { ConfigurationError = null; return; }
        if (local != null) { await local.DisposeAsync(); local = null; }
        if (port != 0) local = new WorkshopLocalServer(dispatcher, port, () => computerId, directory);
        ConfigurationError = null;
    }
    public async ValueTask DisposeAsync()
    {
        await cloud.DisposeAsync();
        if (local != null) await local.DisposeAsync();
        await dispatcher.DisposeAsync();
    }
}
