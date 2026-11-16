using System;
using System.Collections.Generic;
using System.Linq;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Hako.Platform;

namespace Hako.Core;

internal sealed class GuardianDispatcher(string profile, RegisteredServices? registeredServices = null, AgentVersions? agentVersions = null) : IAgentDispatcher
{
    private readonly RegisteredServices services = registeredServices ?? new RegisteredServices();
    private readonly AgentVersions versions = agentVersions ?? new AgentVersions(profile);
    public IReadOnlyList<AgentCapability> Capabilities => [.. AgentDispatcher.MainCapabilities,
        new(RegisteredServices.Command, 1), new(RegisteredServices.StartCommand, 1), new(AgentVersions.Command, 1)];

    public async Task<object?> InvokeAsync(string method, int version, JsonElement parameters, CancellationToken token)
    {
        if (parameters.ValueKind != JsonValueKind.Object) throw new AgentActionException("invalid_params", "命令参数必须是 JSON 对象。");
        if (method.StartsWith("admin.", StringComparison.Ordinal) && (version != 1 || !Capabilities.Any(value => value.Name == method && value.Version == version)))
            throw new AgentActionException("unsupported_method", "设备不支持此命令或版本。");
        if (method == RegisteredServices.Command)
        {
            if (parameters.EnumerateObject().Any()) throw new AgentActionException("invalid_params", "admin.services.status 不接受参数。");
            return await services.ReadAsync(token);
        }
        if (method == RegisteredServices.StartCommand)
        {
            if (System.IO.File.Exists(AgentGuardianControl.FileFor(profile, "stop")))
                throw new AgentActionException("guardian_stopping", "守护进程正在退出，请稍后再启动服务。");
            return await services.StartAsync(parameters, token);
        }
        if (method == AgentVersions.Command)
        {
            if (parameters.EnumerateObject().Any()) throw new AgentActionException("invalid_params", "admin.agent.versions 不接受参数。");
            return await versions.ReadAsync(token);
        }
        // Administrative methods never cross the main-process boundary.
        if (!method.StartsWith("query.", StringComparison.Ordinal) && !method.StartsWith("action.", StringComparison.Ordinal))
            throw new AgentActionException("unsupported_method", "未知的守护管理命令。");
        return await LocalRpc.CallAsync(LocalRpc.MainPipe(profile), new("agent", method, version, parameters), token);
    }
    public async Task RunTelemetryAsync(Func<string, CapabilityData, Task> publish, CancellationToken token)
    {
        using var lifetime = CancellationTokenSource.CreateLinkedTokenSource(token);
        var main = MainTelemetryAsync(publish, lifetime.Token);
        var admin = AdminTelemetryAsync(publish, lifetime.Token);
        try { await Task.WhenAny(main, admin); }
        finally { await lifetime.CancelAsync(); await Task.WhenAll(main, admin); }
    }
    private async Task MainTelemetryAsync(Func<string, CapabilityData, Task> publish, CancellationToken token)
    {
        while (!token.IsCancellationRequested)
        {
            try
            {
                await LocalRpc.StreamAsync(LocalRpc.MainPipe(profile), LocalRpc.Request("telemetry"), value =>
                    publish(value.GetProperty("method").GetString()!, value.GetProperty("data").Deserialize<CapabilityData>(AgentConnection.Json)!), token);
            }
            catch (AgentActionException error)
            {
                foreach (var method in new[] { "query.system.metrics", "query.codex.usage", "query.network.listeners" })
                    await publish(method, new(1, Error: new(error.Code, error.Message)));
            }
            await Task.Delay(2000, token);
        }
    }
    private async Task AdminTelemetryAsync(Func<string, CapabilityData, Task> publish, CancellationToken token)
    {
        using var timer = new PeriodicTimer(TimeSpan.FromSeconds(10));
        do
        {
            CapabilityData data;
            try { data = new(1, JsonSerializer.SerializeToElement(await services.ReadAsync(token), AgentConnection.Json)); }
            catch (AgentActionException error) { data = new(1, Error: new(error.Code, error.Message)); }
            catch (Exception error) when (error is not OperationCanceledException) { data = new(1, Error: new("query_failed", "服务监控采集失败。")); }
            await publish(RegisteredServices.Command, data);
        } while (await timer.WaitForNextTickAsync(token));
    }
    public ValueTask DisposeAsync() { services.Dispose(); versions.Dispose(); return ValueTask.CompletedTask; }
}
