using System;
using System.Collections.Generic;
using System.Linq;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Hako.Platform;

namespace Hako.Core;

public sealed record AgentCapability(string Name, int Version);
public sealed record CapabilityError(string Code, string Message);
public sealed record CapabilityData(int Version, [property: System.Text.Json.Serialization.JsonIgnore(Condition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull)] JsonElement? Result = null,
    [property: System.Text.Json.Serialization.JsonIgnore(Condition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull)] CapabilityError? Error = null);
public sealed record QueryData(Dictionary<string, CapabilityData> Data);

public sealed class AgentActionException(string code, string message) : Exception(message)
{
    public string Code { get; } = code;
}

// Queries are data providers; actions are invoked explicitly and never by query.all.
public sealed class AgentDispatcher
{
    private sealed record Handler(int Version, Func<JsonElement, CancellationToken, Task<object?>> Invoke);
    private readonly Dictionary<string, Handler> queries;
    private readonly Dictionary<string, Handler> actions;
    public IReadOnlyList<AgentCapability> Capabilities => queries.Concat(actions)
        .Select(entry => new AgentCapability(entry.Key, entry.Value.Version)).ToArray();
    public event Action<Metrics>? MetricsReceived;

    public AgentDispatcher(SystemMetrics metrics, HttpConnectivity? connectivity = null, CodexUsage? codexUsage = null)
    {
        var codex = codexUsage ?? new CodexUsage();
        queries = new()
        {
            ["query.system.metrics"] = new(1, async (parameters, token) =>
            {
                if (parameters.EnumerateObject().Any())
                    throw new AgentActionException("invalid_params", "query.system.metrics 不接受参数。");
                try
                {
                    var result = await metrics.SampleAsync(token);
                    MetricsReceived?.Invoke(result);
                    return result;
                }
                catch (Exception e) when (e is not OperationCanceledException)
                { throw new AgentActionException("sample_failed", "系统指标采样失败。"); }
            }),
            ["query.codex.usage"] = new(1, async (parameters, token) =>
            {
                if (parameters.EnumerateObject().Any())
                    throw new AgentActionException("invalid_params", "query.codex.usage 不接受参数。");
                return await codex.ReadAsync(token);
            }),
            ["query.network.listeners"] = new(1, async (parameters, token) =>
            {
                if (parameters.EnumerateObject().Any())
                    throw new AgentActionException("invalid_params", "query.network.listeners 不接受参数。");
                return await new NetworkListeners().ReadAsync(token);
            })
        };
        var probe = connectivity ?? new HttpConnectivity();
        actions = new()
        {
            ["action.network.http.check"] = new(1, async (parameters, token) => await probe.CheckAsync(parameters, token))
        };
    }

    public async Task<object?> InvokeAsync(string method, int version, JsonElement parameters, CancellationToken token)
    {
        if (parameters.ValueKind != JsonValueKind.Object)
            throw new AgentActionException("invalid_params", "命令参数必须是 JSON 对象。");
        if (method == "query.all" && version == 1)
        {
            if (parameters.EnumerateObject().Any())
                throw new AgentActionException("invalid_params", "query.all 不接受参数。");
            using var budget = CancellationTokenSource.CreateLinkedTokenSource(token);
            budget.CancelAfter(TimeSpan.FromSeconds(8));
            var data = new Dictionary<string, CapabilityData>();
            var remaining = 60 * 1024;
            foreach (var (name, query) in queries)
            {
                CapabilityData item;
                try { item = new(query.Version, JsonSerializer.SerializeToElement(await query.Invoke(parameters, budget.Token), AgentConnection.Json)); }
                catch (AgentActionException e) { item = new(query.Version, Error: new(e.Code, e.Message)); }
                catch (OperationCanceledException) when (!token.IsCancellationRequested)
                { item = new(query.Version, Error: new("query_timeout", "数据采集超时。")); }
                catch (Exception e) when (e is not OperationCanceledException)
                { item = new(query.Version, Error: new("query_failed", "数据采集失败。")); }
                var size = JsonSerializer.SerializeToUtf8Bytes(item, AgentConnection.Json).Length + name.Length + 8;
                if (size > remaining - 256 * (queries.Count - data.Count))
                {
                    item = new(query.Version, Error: new("result_too_large", "数据超出消息大小限制。"));
                    size = JsonSerializer.SerializeToUtf8Bytes(item, AgentConnection.Json).Length + name.Length + 8;
                }
                remaining -= size;
                data.Add(name, item);
            }
            return new QueryData(data);
        }
        if (!queries.TryGetValue(method, out var action) && !actions.TryGetValue(method, out action))
            throw new AgentActionException("unsupported_method", "设备不支持此命令或版本。");
        if (action.Version != version)
            throw new AgentActionException("unsupported_method", "设备不支持此命令或版本。");
        return await action.Invoke(parameters, token);
    }
}
