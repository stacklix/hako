using System;
using System.Diagnostics;
using System.IO;
using System.Threading;
using System.Threading.Tasks;

namespace Hako.Core;

// Standby initializes the runtime, credentials and dispatchers without owning
// the normal pipe, command supervisor or server connections. Only one owner
// may activate them, after the retiring guardian has drained its work.
internal static class GuardianHandoff
{
    internal sealed record Ready(int ProcessId, string Nonce, DateTimeOffset ReadyAt);
    internal static string ExecutableFor(string canonical, string hash) =>
        Path.Combine(Path.GetDirectoryName(canonical)!, "warm", hash, "Hako.Guardian.exe");
    internal static string PipeFor(string profile, string nonce) => LocalRpc.GuardianPipe(profile) + ".handoff." + nonce;
    internal static string ReadyPath(string profile) => AgentGuardianControl.FileFor(profile, "standby.json");

    internal static async Task RunAsync(string configuration, string nonce, int parentId)
    {
        if (!Guid.TryParseExact(nonce, "N", out _) || parentId <= 0) throw new InvalidDataException("Invalid guardian handoff.");
        var options = AgentGuardianControl.Read<AgentGuardianOptions>(configuration) ?? throw new InvalidDataException("Missing guardian configuration.");
        options.Validate();
        using var parent = Process.GetProcessById(parentId);
        var activated = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var broker = new GuardianBroker(options.ProfileDirectory, start: false);
        var transferred = false;
        try
        {
            broker.Prepare();
            await using var control = new LocalRpcServer(PipeFor(options.ProfileDirectory, nonce), async (request, publish, token) =>
            {
                if (request.Kind != "activate" || request.Version != 1) throw new InvalidDataException("Invalid activation request.");
                await publish(new { processId = Environment.ProcessId });
                activated.TrySetResult();
            });
            AgentGuardianControl.Write(ReadyPath(options.ProfileDirectory), new Ready(Environment.ProcessId, nonce, DateTimeOffset.UtcNow));
            // A failed/abandoned updater must not leave a dormant process behind.
            while (!activated.Task.IsCompleted)
            {
                if (parent.HasExited) return;
                await Task.WhenAny(activated.Task, Task.Delay(100));
            }
            transferred = true;
            await AgentGuardian.RunAsync(configuration, prepared: broker);
        }
        finally { if (!transferred) await broker.DisposeAsync(); }
    }
}
