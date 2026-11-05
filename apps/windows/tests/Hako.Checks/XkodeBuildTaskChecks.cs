using System;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Hako.Core;
using Hako.Platform;

internal static class XkodeBuildTaskChecks
{
    public static async Task RunAsync()
    {
        const string id = "7f21a9d47f21a9d47f21a9d47f21a9d4";
        var task = $$$"""
            {"id":"{{{id}}}","application":{"project":"C:\\private\\Hako.xcodeproj","target":"Hako"},
             "state":"running","created_utc":"2026-11-05T02:42:00Z","started_utc":"2026-11-05T02:43:00Z","current_stage":"build",
             "cancellation_requested":false,"logs":{"stderr":"C:\\private\\build.log"},
             "stages":{"preflight":{"state":"succeeded","elapsed_seconds":1.25,"logs":"private"},
                       "build":{"state":"running","started_utc":"2026-11-05T02:42:00+08:00"},
                       "sign":{"state":"succeeded","started_utc":"2026-11-05T02:43:00+08:00","finished_utc":"2026-11-05T02:43:03+08:00"},
                       "install":{"state":"skipped"}} }
            """;
        var calls = 0;
        var queued = false;
        var dispatcher = new AgentDispatcher(new SystemMetrics(), null, null, new XkodeBuildTasks((operation, target, _) =>
        {
            calls++;
            if (operation == "list" && target is null) return Task.FromResult("{\"tasks\":[" + task + "]}");
            if (target != id) throw new Exception("Task ID changed");
            if (queued && operation == "cancel") return Task.FromResult(task.Replace("running", "cancelled"));
            if (operation == "status") return Task.FromResult(task.Replace("\"state\":\"running\",\"created_utc\"",
                "\"state\":\"succeeded\",\"finished_utc\":\"2026-11-05T02:44:30Z\",\"created_utc\""));
            return Task.FromResult(operation == "cancel" ? task.Replace("false", "true") : task);
        }));
        async Task<JsonElement> Invoke(string parameters)
        {
            using var input = JsonDocument.Parse(parameters);
            var result = await dispatcher.InvokeAsync(XkodeBuildTasks.Method, 1, input.RootElement, CancellationToken.None);
            return JsonSerializer.SerializeToElement(result, AgentConnection.Json);
        }
        var list = await Invoke("""{"operation":"list"}""");
        var entry = list.GetProperty("tasks")[0];
        if (entry.GetProperty("project").GetString() != "Hako" || list.GetRawText().Contains("private") ||
            entry.GetProperty("cancellationRequested").GetBoolean() || entry.GetProperty("stages").ValueKind != JsonValueKind.Null)
            throw new Exception("Task list contains incorrect or private data");
        foreach (var invalid in new[] { """{"operation":"submit"}""", """{"operation":"cancel","id":"--help"}""",
            """{"operation":"list","id":null}""", """{"operation":"status","id":"7f21a9d4"}""" })
        {
            try { await Invoke(invalid); throw new Exception("Invalid xkode operation accepted"); }
            catch (AgentActionException error) when (error.Code == "invalid_params") { }
        }
        var cancel = await Invoke($$"""{"operation":"cancel","id":"{{id}}"}""");
        if (calls != 2 || cancel.GetProperty("state").GetString() != "running" ||
            !cancel.GetProperty("cancellationRequested").GetBoolean() ||
            cancel.GetProperty("elapsedSeconds").GetDouble() < 0)
            throw new Exception("Cancellation request was mistaken for a terminal state");
        var stages = cancel.GetProperty("stages");
        if (stages[0].GetProperty("name").GetString() != "preflight" ||
            stages[0].GetProperty("elapsedSeconds").GetDouble() != 1.25 ||
            stages[1].GetProperty("elapsedSeconds").GetDouble() < 0 ||
            stages[2].GetProperty("elapsedSeconds").GetDouble() != 3 ||
            stages[3].GetProperty("elapsedSeconds").ValueKind != JsonValueKind.Null ||
            cancel.GetRawText().Contains("private"))
            throw new Exception("Task detail contains incorrect or private stage data");
        queued = true;
        var queuedCancellation = await Invoke($$"""{"operation":"cancel","id":"{{id}}"}""");
        if (queuedCancellation.GetProperty("state").GetString() != "cancelled" ||
            queuedCancellation.GetProperty("elapsedSeconds").ValueKind != JsonValueKind.Null ||
            queuedCancellation.GetProperty("stages")[1].GetProperty("elapsedSeconds").ValueKind != JsonValueKind.Null ||
            queuedCancellation.GetProperty("cancellationRequested").GetBoolean())
            throw new Exception("Queued cancellation was not reflected as terminal");
        var completed = await Invoke($$"""{"operation":"status","id":"{{id}}"}""");
        if (completed.GetProperty("elapsedSeconds").GetDouble() != 90)
            throw new Exception("Total elapsed time must exclude time spent in the queue");
        Console.WriteLine("PASS: xkode action params, task list projection and cancellation state");
    }
}
