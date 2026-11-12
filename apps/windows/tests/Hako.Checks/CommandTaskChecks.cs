using System;
using System.Diagnostics;
using System.Collections.Generic;
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
    private static async Task WaitForFile(string path)
    {
        var deadline = DateTime.UtcNow.AddSeconds(10);
        while (!File.Exists(path))
        {
            if (DateTime.UtcNow > deadline) throw new Exception("Command child did not reach " + Path.GetFileName(path));
            await Task.Delay(50);
        }
    }
    private static async Task CheckBackgroundProcess(CommandTasks tasks, string application, string project, bool allowBackgroundProcesses, string ending)
    {
        var id = Guid.NewGuid().ToString();
        var prefix = Path.Combine(project, id);
        var ready = prefix + ".ready"; var release = prefix + ".release"; var done = prefix + ".done";
        var childFile = prefix + ".ps1"; var pidFile = prefix + ".pid";
        static string Quote(string value) => "'" + value.Replace("'", "''") + "'";
        File.WriteAllText(childFile, $"Set-Content -LiteralPath {Quote(ready)} -Value ready\nwhile (!(Test-Path -LiteralPath {Quote(release)})) {{ Start-Sleep -Milliseconds 50 }}\nSet-Content -LiteralPath {Quote(done)} -Value done\n");
        var childArguments = "-NoProfile -NonInteractive -File \"" + childFile + "\"";
        var command = "$child = Start-Process -FilePath (Join-Path $PSHOME 'pwsh.exe') -WindowStyle Hidden -PassThru " +
            $"-ArgumentList {Quote(childArguments)} -RedirectStandardOutput {Quote(prefix + ".out")} -RedirectStandardError {Quote(prefix + ".err")}\n" +
            $"Set-Content -LiteralPath {Quote(pidFile)} -Value $child.Id\n" +
            $"while (!(Test-Path -LiteralPath {Quote(ready)})) {{ Start-Sleep -Milliseconds 50 }}\n" +
            (ending == "complete" ? "exit 0" : "Start-Sleep -Seconds 30");
        Process? child = null;
        try
        {
            Console.WriteLine($"Checking child lifetime: background={allowBackgroundProcesses}, ending={ending}");
            await Call(tasks, "commands.start", new { requestId = id, applicationId = application, name = "Background process " + ending,
                command, timeoutSeconds = ending == "timeout" ? 5 : 20, allowBackgroundProcesses });
            await WaitForFile(ready);
            child = Process.GetProcessById(int.Parse(File.ReadAllText(pidFile).Trim()));
            if (ending == "cancel") await Call(tasks, "commands.stop", new { taskId = id });
            var page = await Finish(tasks, id);
            var state = CodexJson.Field(page, "task");
            var expected = ending == "complete" ? "succeeded" : ending == "cancel" ? "cancelled" : "timed_out";
            Check(CodexJson.Text(state, "state") == expected, "Submitting command did not " + ending);
            Check(state.GetProperty("allowBackgroundProcesses").GetBoolean() == allowBackgroundProcesses, "Task lost its submitted background option");
            if (allowBackgroundProcesses)
            {
                Check(!child.HasExited, "Background child died after command " + ending);
                File.WriteAllText(release, "continue");
                await WaitForFile(done);
                await child.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(5));
                Check(File.ReadAllText(done).Trim() == "done", "Background child could not finish independently");
            }
            else
            {
                await child.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(5));
                Check(!File.Exists(done), "Ordinary command left a child running after " + ending);
            }
        }
        finally
        {
            if (child is null && File.Exists(pidFile))
            {
                try { child = Process.GetProcessById(int.Parse(File.ReadAllText(pidFile).Trim())); } catch (ArgumentException) { }
            }
            if (child is not null)
            {
                if (!child.HasExited) child.Kill();
                await child.WaitForExitAsync(); child.Dispose();
            }
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
            var start = new { requestId = id, applicationId = application, name = "Unicode output", command = "Add-Content -LiteralPath 'count.txt' -Value once; Write-Output '你好🙂'; [Console]::Error.WriteLine('stderr'); exit 7", timeoutSeconds = 10, allowBackgroundProcesses = false };
            await Call(tasks, "commands.start", start);
            await Call(tasks, "commands.start", start);
            var completed = await Finish(tasks, id);
            Check(CodexJson.Text(CodexJson.Field(completed, "task"), "state") == "failed" && CodexJson.Field(completed, "task").GetProperty("exitCode").GetInt32() == 7, "Exit code lost");
            Check(CodexJson.Text(completed, "output").Contains("你好🙂") && CodexJson.Text(completed, "output").Contains("stderr"), "Command output lost: " + completed);
            Check(File.ReadAllLines(Path.Combine(project, "count.txt")).Length == 1, "Duplicate request executed twice");
            Console.WriteLine("PASS: output and idempotency");
            try
            {
                await Call(tasks, "commands.start", new { requestId = id, applicationId = application, name = "changed", command = "exit 0", timeoutSeconds = 10, allowBackgroundProcesses = false });
                throw new Exception("Conflicting request accepted");
            }
            catch (WorkshopException error) when (error.Code == "command_request_conflict") { }
            try
            {
                await Call(tasks, "commands.start", new { requestId = id, applicationId = application, start.name, start.command,
                    start.timeoutSeconds, allowBackgroundProcesses = true });
                throw new Exception("Retry changed the submitted background option");
            }
            catch (WorkshopException error) when (error.Code == "command_request_conflict") { }
            var cursor = completed.GetProperty("cursor").GetInt64();
            Check(CodexJson.Text(await Call(tasks, "commands.read", new { taskId = id, cursor }), "output") == "", "Cursor replay duplicated output");
            Check(CodexJson.Text(await Call(tasks, "commands.stop", new { taskId = id }), "state") == "failed", "Stopping a finished task changed its result");

            var unicode = Guid.NewGuid().ToString();
            await Call(tasks, "commands.start", new { requestId = unicode, applicationId = application, name = "paged Unicode", command = "[Console]::Write(('a'*2047)+'🙂'+('中🙂'*4000))", timeoutSeconds = 10, allowBackgroundProcesses = false });
            var unicodePage = await Finish(tasks, unicode); var text = new StringBuilder();
            do
            {
                text.Append(CodexJson.Text(unicodePage, "output"));
                if (!unicodePage.GetProperty("hasMore").GetBoolean()) break;
                unicodePage = await Call(tasks, "commands.read", new { taskId = unicode, cursor = unicodePage.GetProperty("cursor").GetInt64() });
            } while (true);
            Check(text.ToString() == new string('a', 2047) + "🙂" + string.Concat(System.Linq.Enumerable.Repeat("中🙂", 4000)), "UTF-8 cursor pages corrupted Unicode");

            var escaping = Guid.NewGuid().ToString();
            await Call(tasks, "commands.start", new { requestId = escaping, applicationId = application, name = "JSON frame budget", command = "#" + new string('<', 7000) + "\n[Console]::Write(([string][char]1)*12000)", timeoutSeconds = 10, allowBackgroundProcesses = false });
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
            await Call(tasks, "commands.start", new { requestId = cancelled, applicationId = application, name = "cancel", command = "Start-Sleep -Seconds 30", timeoutSeconds = 40, allowBackgroundProcesses = false });
            await Call(tasks, "commands.stop", new { taskId = cancelled });
            Check(CodexJson.Text(CodexJson.Field(await Finish(tasks, cancelled), "task"), "state") == "cancelled", "Cancellation not persisted");
            Console.WriteLine("PASS: cancellation");

            var timed = Guid.NewGuid().ToString();
            await Call(tasks, "commands.start", new { requestId = timed, applicationId = application, name = "timeout", command = "Start-Sleep -Seconds 30", timeoutSeconds = 1, allowBackgroundProcesses = false });
            Check(CodexJson.Text(CodexJson.Field(await Finish(tasks, timed), "task"), "state") == "timed_out", "Timeout not enforced");
            Console.WriteLine("PASS: timeout");

            var critical = Guid.NewGuid().ToString();
            await Call(tasks, "commands.start", new { requestId = critical, applicationId = application, name = "installation transaction", command = "Set-Content -LiteralPath (Join-Path $env:HAKO_COMMAND_TASK_DIRECTORY 'installing') -Value active; Start-Sleep -Seconds 2; Write-Output 'installation finished'", timeoutSeconds = 1, allowBackgroundProcesses = false });
            var installation = await Finish(tasks, critical);
            Check(CodexJson.Text(installation, "output").Contains("installation finished"), "Timeout killed an installation transaction");

            foreach (var invalid in new object?[] { "missing", null, "false", 0 })
            {
                var parameters = new Dictionary<string, object?> { ["requestId"] = Guid.NewGuid().ToString(),
                    ["applicationId"] = application, ["name"] = "Invalid option", ["command"] = "exit 0", ["timeoutSeconds"] = 10 };
                // A missing field and non-boolean values must both be rejected.
                if (!Equals(invalid, "missing")) parameters["allowBackgroundProcesses"] = invalid;
                try { await Call(tasks, "commands.start", parameters); throw new Exception("Invalid background option was accepted"); }
                catch (WorkshopException error) when (error.Code == "invalid_params") { }
            }

            foreach (var background in new[] { false, true })
                foreach (var ending in new[] { "complete", "cancel", "timeout" })
                    await CheckBackgroundProcess(tasks, application, project, background, ending);
            Console.WriteLine("PASS: child lifetime after completion, cancellation and timeout in ordinary and background modes");

            try { await Call(tasks, "commands.read", new { taskId = Guid.NewGuid().ToString(), cursor = 0 }); throw new Exception("Missing task accepted"); }
            catch (WorkshopException error) when (error.Code == "command_not_found") { }
            var list = await Call(tasks, "commands.list", new { applicationId = application });
            Check(list.GetProperty("tasks").GetArrayLength() == 12, "Task history not persisted or an invalid request created a task");
            Check(!list.GetProperty("tasks")[0].TryGetProperty("command", out _), "History repeated full commands and can overflow the wire frame");
        }
        finally { Directory.Delete(root, true); }
        Console.WriteLine("PASS: real shell output/exit codes, duplicate request isolation, cursor resume, cancellation, timeout and installation transaction survival");
    }
}
