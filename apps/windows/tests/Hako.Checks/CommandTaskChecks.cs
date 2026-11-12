using System;
using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Hako.Core;
using Hako.Platform;

internal static class CommandTaskChecks
{
    private static JsonElement Json(object? value) => JsonSerializer.SerializeToElement(value, WorkshopProtocol.Json);
    private static void Check(bool value, string message) { if (!value) throw new Exception(message); }
    private static async Task<JsonElement> Call(CommandTasks tasks, string method, object value) => Json(await tasks.CallAsync(method, Json(value), CancellationToken.None));
    private static async Task<JsonElement> Finish(CommandTasks tasks, string id)
    {
        var deadline = DateTime.UtcNow.AddSeconds(20);
        while (true)
        {
            var page = await Call(tasks, "commands.read", new { taskId = id, cursor = 0 });
            if (CodexJson.Text(CodexJson.Field(page, "task"), "state") is not ("starting" or "running" or "stopping")) return page;
            if (DateTime.UtcNow > deadline) throw new Exception("Command task did not finish");
            await Task.Delay(50);
        }
    }
    internal static async Task RunAsync()
    {
        var root = Path.Combine(Path.GetTempPath(), "hako-command-tests-" + Guid.NewGuid().ToString("N"));
        var profile = Path.Combine(root, "profile");
        var project = Path.Combine(root, "repo with spaces");
        Directory.CreateDirectory(Path.Combine(project, ".git"));
        Directory.CreateDirectory(profile);
        Console.WriteLine("Command test profile: " + profile);
        var application = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(project.ToUpperInvariant())))[..16].ToLowerInvariant();
        await using var projects = new CodeWorkshop(Path.Combine(profile, "code-workshop"), root);
        try
        {
            await using var tasks = new CommandTasks(profile, projects);
            var id = Guid.NewGuid().ToString();
            var start = new { requestId = id, applicationId = application, name = "Unicode output", command = "Add-Content -LiteralPath 'count.txt' -Value once; Write-Output '你好🙂'; [Console]::Error.WriteLine('stderr'); exit 7", timeoutSeconds = 10 };
            await Call(tasks, "commands.start", start);
            await Call(tasks, "commands.start", start);
            var completed = await Finish(tasks, id);
            Check(CodexJson.Text(CodexJson.Field(completed, "task"), "state") == "failed" && CodexJson.Field(completed, "task").GetProperty("exitCode").GetInt32() == 7, "Exit code lost");
            Check(CodexJson.Text(completed, "output").Contains("你好🙂") && CodexJson.Text(completed, "output").Contains("stderr"), "Command output lost: " + completed);
            Check(File.ReadAllLines(Path.Combine(project, "count.txt")).Length == 1, "Duplicate request executed twice");
            Console.WriteLine("PASS: output and idempotency");
            try
            {
                await Call(tasks, "commands.start", new { requestId = id, applicationId = application, name = "changed", command = "exit 0", timeoutSeconds = 10 });
                throw new Exception("Conflicting request accepted");
            }
            catch (WorkshopException error) when (error.Code == "command_request_conflict") { }
            var cursor = completed.GetProperty("cursor").GetInt64();
            Check(CodexJson.Text(await Call(tasks, "commands.read", new { taskId = id, cursor }), "output") == "", "Cursor replay duplicated output");
            Check(CodexJson.Text(await Call(tasks, "commands.stop", new { taskId = id }), "state") == "failed", "Stopping a finished task changed its result");

            var unicode = Guid.NewGuid().ToString();
            await Call(tasks, "commands.start", new { requestId = unicode, applicationId = application, name = "paged Unicode", command = "[Console]::Write(('a'*2047)+'🙂'+('中🙂'*4000))", timeoutSeconds = 10 });
            var unicodePage = await Finish(tasks, unicode); var text = new StringBuilder();
            do
            {
                text.Append(CodexJson.Text(unicodePage, "output"));
                if (!unicodePage.GetProperty("hasMore").GetBoolean()) break;
                unicodePage = await Call(tasks, "commands.read", new { taskId = unicode, cursor = unicodePage.GetProperty("cursor").GetInt64() });
            } while (true);
            Check(text.ToString() == new string('a', 2047) + "🙂" + string.Concat(System.Linq.Enumerable.Repeat("中🙂", 4000)), "UTF-8 cursor pages corrupted Unicode");

            var escaping = Guid.NewGuid().ToString();
            await Call(tasks, "commands.start", new { requestId = escaping, applicationId = application, name = "JSON frame budget", command = "#" + new string('<', 7000) + "\n[Console]::Write(([string][char]1)*12000)", timeoutSeconds = 10 });
            var escapedPage = await Finish(tasks, escaping); var escaped = new StringBuilder();
            do
            {
                Check(JsonSerializer.SerializeToUtf8Bytes(escapedPage, WorkshopProtocol.Json).Length < 64 * 1024 - 256, "Command log exceeded the wire frame limit");
                escaped.Append(CodexJson.Text(escapedPage, "output"));
                if (!escapedPage.GetProperty("hasMore").GetBoolean()) break;
                escapedPage = await Call(tasks, "commands.read", new { taskId = escaping, cursor = escapedPage.GetProperty("cursor").GetInt64() });
            } while (true);
            Check(escaped.ToString() == new string((char)1, 12000), "Escaped log bytes were lost");

            var cancelled = Guid.NewGuid().ToString();
            await Call(tasks, "commands.start", new { requestId = cancelled, applicationId = application, name = "cancel", command = "Start-Sleep -Seconds 30", timeoutSeconds = 40 });
            await Call(tasks, "commands.stop", new { taskId = cancelled });
            Check(CodexJson.Text(CodexJson.Field(await Finish(tasks, cancelled), "task"), "state") == "cancelled", "Cancellation not persisted");
            Console.WriteLine("PASS: cancellation");

            var timed = Guid.NewGuid().ToString();
            await Call(tasks, "commands.start", new { requestId = timed, applicationId = application, name = "timeout", command = "Start-Sleep -Seconds 30", timeoutSeconds = 1 });
            Check(CodexJson.Text(CodexJson.Field(await Finish(tasks, timed), "task"), "state") == "timed_out", "Timeout not enforced");
            Console.WriteLine("PASS: timeout");

            var critical = Guid.NewGuid().ToString();
            await Call(tasks, "commands.start", new { requestId = critical, applicationId = application, name = "installation transaction", command = "Set-Content -LiteralPath (Join-Path $env:HAKO_COMMAND_TASK_DIRECTORY 'installing') -Value active; Start-Sleep -Seconds 2; Write-Output 'installation finished'", timeoutSeconds = 1 });
            var installation = await Finish(tasks, critical);
            Check(CodexJson.Text(installation, "output").Contains("installation finished"), "Timeout killed an installation transaction");

            try { await Call(tasks, "commands.read", new { taskId = Guid.NewGuid().ToString(), cursor = 0 }); throw new Exception("Missing task accepted"); }
            catch (WorkshopException error) when (error.Code == "command_not_found") { }
            var list = await Call(tasks, "commands.list", new { applicationId = application });
            Check(list.GetProperty("tasks").GetArrayLength() == 6, "Task history not persisted");
            Check(!list.GetProperty("tasks")[0].TryGetProperty("command", out _), "History repeated full commands and can overflow the wire frame");
        }
        finally { Directory.Delete(root, true); }
        Console.WriteLine("PASS: real shell output/exit codes, duplicate request isolation, cursor resume, cancellation, timeout and installation transaction survival");
    }
}
