using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace Hako.Core;

internal sealed class XkodeBuildTasks(Func<string, string?, CancellationToken, Task<string>>? run = null)
{
    internal const string Method = "action.xkode.tasks.manage";
    private const int ListBudget = 48 * 1024;
    private readonly Func<string, string?, CancellationToken, Task<string>> runCommand = run ?? RunAsync;

    internal sealed record BuildTask(string Id, string Project, string? Target, string State,
        string CreatedAt, string? CurrentStage, bool CancellationRequested, string? ReplacedBy, string? FailedStage,
        List<BuildStage>? Stages, double? ElapsedSeconds);
    internal sealed record BuildStage(string Name, string State, double? ElapsedSeconds);
    internal sealed record TaskList(List<BuildTask> Tasks, bool Truncated);

    internal async Task<object?> InvokeAsync(JsonElement parameters, CancellationToken token)
    {
        var operation = StringValue(parameters, "operation");
        var id = StringValue(parameters, "id");
        var fields = parameters.EnumerateObject().Count();
        if ((operation == "list" && fields == 1) ||
            ((operation is "status" or "cancel") && fields == 2 && IsTaskId(id)))
        {
            try
            {
                using var document = JsonDocument.Parse(await runCommand(operation, id, token));
                if (operation == "list") return ReadList(document.RootElement);
                var task = ReadTask(document.RootElement, includeStages: true);
                if (task.Id == id) return task;
            }
            catch (Exception error) when (error is JsonException or InvalidDataException)
            {
                // The CLI may have executed a cancellation before the response was lost.
                throw new AgentActionException("xkode_invalid_result", "xkode 返回的数据无效，请查询任务状态。");
            }
            throw new AgentActionException("xkode_invalid_result", "xkode 返回了不同的任务 ID。");
        }
        throw new AgentActionException("invalid_params", "需要 list，或带完整任务 ID 的 status / cancel。");
    }

    private static TaskList ReadList(JsonElement response)
    {
        if (response.ValueKind != JsonValueKind.Object || !response.TryGetProperty("tasks", out var items)
            || items.ValueKind != JsonValueKind.Array) throw new InvalidDataException();
        var tasks = new List<BuildTask>();
        var remaining = ListBudget;
        foreach (var item in items.EnumerateArray())
        {
            var task = ReadTask(item);
            remaining -= JsonSerializer.SerializeToUtf8Bytes(task, AgentConnection.Json).Length + 1;
            if (remaining < 0) return new(tasks, true);
            tasks.Add(task);
        }
        return new(tasks, false);
    }

    private static BuildTask ReadTask(JsonElement task, bool includeStages = false)
    {
        var id = StringValue(task, "id");
        var state = StringValue(task, "state");
        var created = StringValue(task, "created_utc");
        if (!IsTaskId(id) || string.IsNullOrEmpty(state) || string.IsNullOrEmpty(created))
            throw new InvalidDataException();
        var project = "未命名工程";
        string? target = null;
        if (task.TryGetProperty("application", out var app))
        {
            var path = StringValue(app, "project");
            if (!string.IsNullOrEmpty(path))
            {
                var name = Path.GetFileName(path.Replace('\\', '/').TrimEnd('/'));
                if (name.Equals("project.pbxproj", StringComparison.OrdinalIgnoreCase))
                    name = Path.GetFileName(Path.GetDirectoryName(path.Replace('\\', '/'))) ?? name;
                if (!string.IsNullOrEmpty(name)) project = Path.GetFileNameWithoutExtension(name);
            }
            target = Limit(StringValue(app, "target"));
        }
        var requested = task.TryGetProperty("cancellation_requested", out var flag) && flag.ValueKind == JsonValueKind.True;
        var replacedBy = StringValue(task, "replaced_by");
        var failedStage = task.TryGetProperty("error", out var error) ? StringValue(error, "stage") : null;
        var now = DateTimeOffset.UtcNow;
        return new(id!, Limit(project)!, target, Limit(state)!, Limit(created)!, Limit(StringValue(task, "current_stage")),
            requested, IsTaskId(replacedBy) ? replacedBy : null, Limit(failedStage),
            includeStages ? ReadStages(task, state, now) : null,
            includeStages ? ReadElapsed(task, state == "running" ? now : null) : null);
    }

    private static List<BuildStage>? ReadStages(JsonElement task, string taskState, DateTimeOffset now)
    {
        if (!task.TryGetProperty("stages", out var stages) || stages.ValueKind != JsonValueKind.Object)
            return null;

        var result = new List<BuildStage>();
        foreach (var stage in stages.EnumerateObject().Take(16))
        {
            var state = StringValue(stage.Value, "state");
            if (stage.Name.Length is 0 or > 96 || string.IsNullOrEmpty(state)) continue;

            double? elapsed = null;
            if (stage.Value.TryGetProperty("elapsed_seconds", out var value) && value.ValueKind == JsonValueKind.Number &&
                value.TryGetDouble(out var seconds) && seconds >= 0 && seconds <= TimeSpan.MaxValue.TotalSeconds)
            {
                elapsed = seconds;
            }
            else
                elapsed = ReadElapsed(stage.Value, taskState == "running" && state == "running" ? now : null);
            result.Add(new(stage.Name, Limit(state)!, elapsed));
        }
        return result;
    }

    private static double? ReadElapsed(JsonElement item, DateTimeOffset? now)
    {
        if (!DateTimeOffset.TryParse(StringValue(item, "started_utc"), CultureInfo.InvariantCulture,
                DateTimeStyles.AssumeUniversal, out var started)) return null;
        if (DateTimeOffset.TryParse(StringValue(item, "finished_utc"), CultureInfo.InvariantCulture,
                DateTimeStyles.AssumeUniversal, out var finished))
            return finished >= started ? (finished - started).TotalSeconds : null;
        return now is { } current ? Math.Max(0, (current - started).TotalSeconds) : null;
    }

    private static string? Limit(string? text) => text is { Length: > 96 } ? text[..96] : text;

    private static string? StringValue(JsonElement value, string key) =>
        value.ValueKind == JsonValueKind.Object && value.TryGetProperty(key, out var field) && field.ValueKind == JsonValueKind.String
            ? field.GetString() : null;

    private static bool IsTaskId(string? id) => id is { Length: 32 } &&
        id.All(character => character is >= '0' and <= '9' or >= 'a' and <= 'f');

    private static string? FindExecutable()
    {
        foreach (var entry in (Environment.GetEnvironmentVariable("PATH") ?? "").Split(Path.PathSeparator))
        {
            var directory = entry.Trim().Trim('"');
            if (!Path.IsPathFullyQualified(directory)) continue;
            var candidate = Path.Combine(directory, "xkode.exe");
            if (File.Exists(candidate)) return candidate;
        }
        return null;
    }

    private static async Task<string> RunAsync(string operation, string? id, CancellationToken token)
    {
        var executable = FindExecutable() ?? throw new AgentActionException("xkode_unavailable", "本地 Agent 找不到 xkode.exe，请检查 Windows PATH。");
        var start = new ProcessStartInfo(executable)
        {
            UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true,
            StandardOutputEncoding = Encoding.UTF8, StandardErrorEncoding = Encoding.UTF8
        };
        start.ArgumentList.Add("tasks");
        start.ArgumentList.Add(operation);
        if (id is not null) start.ArgumentList.Add(id);
        using var process = new Process { StartInfo = start };
        using var budget = CancellationTokenSource.CreateLinkedTokenSource(token);
        budget.CancelAfter(TimeSpan.FromSeconds(7));
        token.ThrowIfCancellationRequested();
        try { process.Start(); }
        catch (Win32Exception) { throw new AgentActionException("xkode_unavailable", "本地 Agent 无法启动 xkode.exe。"); }
        try
        {
            var output = process.StandardOutput.ReadToEndAsync(budget.Token);
            var error = process.StandardError.ReadToEndAsync(budget.Token);
            await Task.WhenAll(output, error, process.WaitForExitAsync(budget.Token));
            if (process.ExitCode != 0)
                throw new AgentActionException("xkode_failed", "xkode 命令未成功，请在构建机检查 xkode tasks。");
            return await output;
        }
        catch (OperationCanceledException)
        {
            try { process.Kill(entireProcessTree: true); }
            catch (Exception error) when (error is InvalidOperationException or Win32Exception or AggregateException) { }
            token.ThrowIfCancellationRequested();
            throw new AgentActionException("xkode_timeout", "xkode 响应超时，请先查询任务状态。");
        }
    }
}
