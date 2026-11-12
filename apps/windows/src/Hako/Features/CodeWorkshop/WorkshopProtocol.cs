using System;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace Hako.Platform;

internal sealed class WorkshopException(string code, string message) : Exception(message)
{
    public string Code { get; } = code;
}

internal sealed record WorkshopError(string Code, string Message);

internal static class WorkshopProtocol
{
    internal const string Name = "hako.workshop/1";
    internal const int RequestLimit = 16;
    internal static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web);
    internal static object Welcome(string computerId) => new { kind = "welcome", protocol = Name, computerId };
    internal static WorkshopError Failure(Exception error) => error is WorkshopException failure
        ? new(failure.Code, failure.Message) : new("execution_failed", "代码工坊请求失败，请检查电脑端状态。");
}

internal sealed class WorkshopDispatcher : IAsyncDisposable
{
    private readonly CodeWorkshop workshop;
    private readonly string directory;
    internal CommandTasks? Commands { get; }
    internal WorkshopDispatcher(string dataDirectory, bool commandsOnly = false)
    {
        directory = dataDirectory;
        workshop = new CodeWorkshop(System.IO.Path.Combine(dataDirectory, "code-workshop"));
        if (commandsOnly) Commands = new CommandTasks(dataDirectory, workshop);
    }
    public async ValueTask DisposeAsync()
    {
        if (Commands is not null) await Commands.DisposeAsync();
        await workshop.DisposeAsync();
    }
    internal void SetNotificationScope(string? scope) => workshop.SetNotificationScope(scope);
    internal Task WatchTerminalsAsync(string scope, Func<WorkshopTerminal, Task> publish, CancellationToken token) =>
        Commands is null ? workshop.WatchTerminalsAsync(scope, publish, token) : Task.Delay(Timeout.Infinite, token);
    internal void AcknowledgeTerminal(string scope, string id, string questionId = "") => workshop.AcknowledgeTerminal(scope, id, questionId);
    internal Task WatchAsync(JsonElement parameters, Func<JsonElement, Task> publish, CancellationToken token) =>
        workshop.WatchOperationAsync(parameters, publish, token);

    internal async Task<object?> CallAsync(string method, JsonElement parameters, CancellationToken token)
    {
        if (parameters.ValueKind != JsonValueKind.Object) throw CodexJson.Invalid();
        if (Commands is not null) return await Commands.CallAsync(method, parameters, token);
        if (method == "commands.open")
        {
            CodexJson.Keys(parameters);
            try { return await CommandHost.OpenAsync(directory, token); }
            catch (System.ComponentModel.Win32Exception error) { throw new WorkshopException("command_host_start_failed", $"独立执行器启动失败（Windows {error.NativeErrorCode}）。"); }
            catch (System.IO.IOException error) { throw new WorkshopException("command_host_start_failed", error.Message); }
        }
        Func<JsonElement, CancellationToken, Task<object?>> handler = method switch
        {
            "applications.list" => workshop.CatalogAsync, "models.list" => workshop.ModelsAsync,
            "history.read" => workshop.HistoryAsync, "operation.read" => workshop.OperationAsync,
            "artifact.read" => workshop.ArtifactAsync, "image.read" => workshop.ImageAsync,
            "turn.start" => workshop.StartAsync, "turn.stop" => workshop.StopAsync,
            "thread.archive" => workshop.ArchiveAsync, "image.upload" => workshop.UploadImageAsync,
            "message.queue" => workshop.QueueAsync, "message.update" => workshop.UpdateMessageAsync,
            "message.cancel" => workshop.CancelMessageAsync, "message.steer" => workshop.SteerMessageAsync,
            "approval.reply" => workshop.AnswerAsync,
            _ => throw new WorkshopException("unsupported_method", "代码工坊不支持此操作。")
        };
        if (!method.EndsWith(".list", StringComparison.Ordinal) && !method.EndsWith(".read", StringComparison.Ordinal))
            return await handler(parameters, token);
        using var budget = CancellationTokenSource.CreateLinkedTokenSource(token);
        budget.CancelAfter(TimeSpan.FromSeconds(8));
        try { return await handler(parameters, budget.Token).WaitAsync(budget.Token); }
        catch (OperationCanceledException) when (!token.IsCancellationRequested)
        { throw new WorkshopException("query_timeout", "代码工坊查询超时，请稍后刷新。"); }
    }
}
