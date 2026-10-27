using System;
using System.Collections.Generic;
using System.Linq;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Hako.Platform;

namespace Hako.Core;

public sealed record AgentMethod(string Name, int Version);

public sealed class AgentActionException(string code, string message) : Exception(message)
{
    public string Code { get; } = code;
}

// Register actions here; their parameters and results never need a server model.
public sealed class AgentDispatcher
{
    private sealed record Action(int Version, Func<JsonElement, CancellationToken, Task<object?>> Invoke);
    private readonly Dictionary<string, Action> actions;
    public IReadOnlyList<AgentMethod> Methods => actions.Select(entry => new AgentMethod(entry.Key, entry.Value.Version)).ToArray();
    public event System.Action<Metrics>? MetricsReceived;

    public AgentDispatcher(SystemMetrics metrics)
    {
        actions = new()
        {
            ["system.metrics"] = new(1, async (parameters, token) =>
            {
                if (parameters.EnumerateObject().Any())
                    throw new AgentActionException("invalid_params", "system.metrics 不接受参数。");
                try
                {
                    var result = await metrics.SampleAsync(token);
                    MetricsReceived?.Invoke(result);
                    return result;
                }
                catch (Exception e) when (e is not OperationCanceledException)
                { throw new AgentActionException("sample_failed", "设备采样失败。"); }
            })
        };
    }

    public Task<object?> InvokeAsync(string method, JsonElement parameters, CancellationToken token)
    {
        if (!actions.TryGetValue(method, out var action))
            throw new AgentActionException("unsupported_method", "设备不支持此动作。");
        if (parameters.ValueKind != JsonValueKind.Object)
            throw new AgentActionException("invalid_params", "动作参数必须是 JSON 对象。");
        return action.Invoke(parameters, token);
    }
}
