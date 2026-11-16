using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Hako.Core;
using Hako.Platform;

internal static class GuardianBrokerChecks
{
    private static TaskCompletionSource<bool> Signal() => new(TaskCreationOptions.RunContinuationsAsynchronously);
    private static async Task Expect(string code, Func<Task> action)
    {
        try { await action(); throw new Exception("Expected " + code); }
        catch (AgentActionException error) when (error.Code == code) { }
    }
    internal static async Task RunAsync()
    {
        var profile = Path.Combine(Path.GetTempPath(), "hako-broker-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(profile);
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(30));
        var token = timeout.Token;
        var registry = Path.Combine(profile, "server.json");
        var marker = Path.Combine(profile, "started.txt");
        var registryData = new { version = 1, services = new[] { new { name = "fixture", port = 8100,
            startCommand = "Add-Content -LiteralPath '" + marker.Replace("'", "''") + "' -Value started", workingDirectory = profile } } };
        await File.WriteAllTextAsync(registry, JsonSerializer.Serialize(registryData), token);
        var services = new RegisteredServices(registry, _ => Task.FromResult(new ListenerSnapshot(DateTimeOffset.UtcNow.ToString("O"), [], [])),
            startupDirectory: Path.Combine(profile, "starts"));
        LocalRpcServer? main = null;
        try
        {
            await AgentVersionChecks.RunAsync(profile, token);
            var versionSource = new AgentVersions(profile, _ => Task.FromResult<GitHubAgentRelease?>(null));
            await using var dispatcher = new GuardianDispatcher(profile, services, versionSource);
            var empty = JsonSerializer.SerializeToElement(new { });
            var calls = 0;
            var mutation = Signal();
            var cancelled = Signal();
            main = new LocalRpcServer(LocalRpc.MainPipe(profile), async (request, publish, ct) =>
            {
                Interlocked.Increment(ref calls);
                if (request.Method.StartsWith("admin.", StringComparison.Ordinal)) throw new Exception("Admin leaked to main");
                if (request.Method == "action.git.commit")
                {
                    mutation.TrySetResult(true);
                    try { await Task.Delay(Timeout.Infinite, ct); }
                    finally { cancelled.TrySetResult(true); }
                    return;
                }
                if (request.Kind == "telemetry")
                {
                    // Concurrent producers must still emit intact, bounded frames.
                    await Task.WhenAll(Enumerable.Range(0, 64).Select(i => publish(new { index = i })));
                    return;
                }
                await publish(new { source = "main", method = request.Method, request.Parameters, request.Scope });
            });
            var values = await Task.WhenAll(Enumerable.Range(0, 20).Select(_ =>
                dispatcher.InvokeAsync("query.system.metrics", 1, empty, token)));
            if (values.Any(value => ((JsonElement)value!).GetProperty("source").GetString() != "main"))
                throw new Exception("Queries were not forwarded through the main pipe");
            var frames = new HashSet<int>();
            await LocalRpc.StreamAsync(LocalRpc.MainPipe(profile), LocalRpc.Request("telemetry"),
                value => { if (!frames.Add(value.GetProperty("index").GetInt32())) throw new Exception("Duplicate frame"); return Task.CompletedTask; }, token);
            if (frames.Count != 64) throw new Exception("Concurrent local stream frames were lost");

            var workshop = new GuardianWorkshopDispatcher(profile);
            workshop.SetNotificationScope("fixture-scope");
            var forwarded = (JsonElement)(await workshop.CallAsync("operation.read", JsonSerializer.SerializeToElement(new { operationId = "fixture" }), token))!;
            if (forwarded.GetProperty("scope").GetString() != "fixture-scope"
                || forwarded.GetProperty("parameters").GetProperty("operationId").GetString() != "fixture")
                throw new Exception("Workshop forwarding changed its scope or arguments");

            var action = dispatcher.InvokeAsync("action.git.commit", 1, empty, token);
            await mutation.Task.WaitAsync(token);
            var before = calls;
            await main.DisposeAsync(); main = null;
            await cancelled.Task.WaitAsync(token);
            await Expect("process_disconnected", async () => await action);
            await Expect("process_unavailable", async () => await dispatcher.InvokeAsync("query.system.metrics", 1, empty, token));

            // Admin reads and starts stay available with no main process at all.
            var versions = (AgentVersionSnapshot)(await dispatcher.InvokeAsync(AgentVersions.Command, 1, empty, token))!;
            if (versions.CurrentVersion != ServerCompatibility.AgentVersion || calls != before ||
                !dispatcher.Capabilities.Any(capability => capability.Name == AgentVersions.Command && capability.Version == 1))
                throw new Exception("Guardian version administration depends on the main process");
            var snapshot = (RegisteredServiceSnapshot)(await dispatcher.InvokeAsync(RegisteredServices.Command, 1, empty, token))!;
            if (snapshot.Services.Length != 1 || !snapshot.Services[0].CanStart) throw new Exception("Guardian lost service monitor while main stopped");
            var request = JsonSerializer.SerializeToElement(new { name = "fixture", requestId = Guid.NewGuid().ToString("D") });
            await dispatcher.InvokeAsync(RegisteredServices.StartCommand, 1, request, token);
            while (!File.Exists(marker) || Directory.GetFiles(Path.Combine(profile, "starts"), "*.exit", SearchOption.AllDirectories).Length == 0)
                await Task.Delay(50, token);
            await dispatcher.InvokeAsync(RegisteredServices.StartCommand, 1, request, token);
            if (File.ReadAllLines(marker).Length != 1 || calls != before) throw new Exception("Admin was forwarded or duplicate start executed");
            await Expect("unsupported_method", async () => await dispatcher.InvokeAsync("admin.unknown.execute", 1, empty, token));
            await Expect("unsupported_method", async () => await dispatcher.InvokeAsync(RegisteredServices.Command, 2, empty, token));
            await Expect("invalid_params", async () => await dispatcher.InvokeAsync(RegisteredServices.Command, 1, request, token));
            await Expect("invalid_params", async () => await dispatcher.InvokeAsync(AgentVersions.Command, 1, request, token));
            await Expect("unsupported_method", async () => await dispatcher.InvokeAsync(AgentVersions.Command, 2, empty, token));

            var observed = Signal();
            using (var streamStop = CancellationTokenSource.CreateLinkedTokenSource(token))
            {
                var telemetry = dispatcher.RunTelemetryAsync((method, data) =>
                {
                    if (method == RegisteredServices.Command && data.Result is not null) observed.TrySetResult(true);
                    return Task.CompletedTask;
                }, streamStop.Token);
                await observed.Task.WaitAsync(token);
                await streamStop.CancelAsync();
                try { await telemetry; } catch (OperationCanceledException) when (streamStop.IsCancellationRequested) { }
            }
            main = new LocalRpcServer(LocalRpc.MainPipe(profile), async (_, publish, _) =>
            { Interlocked.Increment(ref calls); await publish(new { source = "restarted" }); });
            var restored = (JsonElement)(await dispatcher.InvokeAsync("query.system.metrics", 1, empty, token))!;
            if (restored.GetProperty("source").GetString() != "restarted" || calls != before + 1)
                throw new Exception("Main reattachment replayed a mutation or failed to route new requests");
            await main.DisposeAsync(); main = null;

            // Disposing the main facade must not disconnect the guardian.
            await using var broker = new GuardianBroker(profile);
            var status = await LocalRpc.CallAsync(LocalRpc.GuardianPipe(profile), LocalRpc.Request("status"), token);
            if (status.GetProperty("connection").GetProperty("state").GetString() != "disconnected")
                throw new Exception("An unconfigured broker opened a connection");
            await Expect("unsupported_method", async () => await LocalRpc.CallAsync(LocalRpc.GuardianPipe(profile), LocalRpc.Request("agent", "query.all"), token));
        }
        finally
        {
            if (main is not null) await main.DisposeAsync();
            if (!Path.GetFullPath(profile).StartsWith(Path.GetFullPath(Path.GetTempPath()) + "hako-broker-", StringComparison.OrdinalIgnoreCase))
                throw new Exception("Unsafe broker fixture cleanup path");
            Directory.Delete(profile, true);
        }
        Console.WriteLine("PASS: guardian-only admin reads/starts/telemetry, query/action/workshop IPC, concurrent framing, cancellation, main reattachment and no mutation replay");
    }

    // The Go end-to-end fixture exercises the real runtime and broker together,
    // then stops/restarts only the main runtime while keeping the cloud peer alive.
    internal static async Task RunAgentAsync(string url, string account, string keyPath)
    {
        var profile = keyPath + ".profile";
        var store = new AgentSettingsStore(profile);
        store.Save(new AgentSettings(url, account, File.ReadAllText(keyPath)));
        AgentRuntime? main = null;
        await using var broker = new GuardianBroker(profile);
        try
        {
            var deadline = DateTime.UtcNow.AddSeconds(90);
            while (DateTime.UtcNow < deadline)
            {
                var paused = File.Exists(keyPath + ".pause-main");
                if (paused && main is not null) { await main.DisposeAsync(); main = null; }
                if (!paused && main is null) { main = new AgentRuntime(store, true); await main.InitializeAsync(false); }
                await File.WriteAllTextAsync(keyPath + ".main-state", main is null ? "stopped" : "running");
                await Task.Delay(50);
            }
        }
        finally { if (main is not null) await main.DisposeAsync(); }
    }
}
