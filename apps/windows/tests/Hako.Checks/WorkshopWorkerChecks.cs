using System;
using System.Collections.Concurrent;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Hako.Core;
using Hako.Platform;

internal static class WorkshopWorkerChecks
{
    private static JsonElement Json(object value) => JsonSerializer.SerializeToElement(value, WorkshopProtocol.Json);
    private static void Check(bool value, string message) { if (!value) throw new Exception(message); }
    private static bool Alive(int pid)
    {
        try { using var process = Process.GetProcessById(pid); return !process.HasExited; }
        catch (ArgumentException) { return false; }
    }
    private static async Task<int> Pid(CodexAppServer server) => (await server.RequestAsync("probe", new { }, default)).GetProperty("pid").GetInt32();

    internal static async Task MeasureStartupAsync()
    {
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(90));
        var cold = new double[2];
        await using (var pool = new WorkshopWorkers(token => CodexAppServer.StartAsync(token), 2))
        {
            for (var index = 0; index < cold.Length; index++)
            {
                var clock = Stopwatch.StartNew();
                await using var lease = await pool.AcquireAsync(null, "measure", timeout.Token);
                cold[index] = clock.Elapsed.TotalMilliseconds;
            }
        }
        var warm = new double[2];
        var warming = Stopwatch.StartNew();
        await using (var pool = new WorkshopWorkers(token => CodexAppServer.StartAsync(token), 2, warmCount: 2))
        {
            while (pool.WarmReadyCount != 2) await Task.Delay(10, timeout.Token);
            warming.Stop();
            var clock = Stopwatch.StartNew();
            await using var first = await pool.AcquireAsync(null, "measure", timeout.Token);
            warm[0] = clock.Elapsed.TotalMilliseconds;
            clock.Restart();
            await using var second = await pool.AcquireAsync(null, "measure", timeout.Token);
            warm[1] = clock.Elapsed.TotalMilliseconds;
            Check(first.Prewarmed && second.Prewarmed, "Live measurement did not acquire initialized resident processes");
        }
        Console.WriteLine(JsonSerializer.Serialize(new { coldAcquireMs = cold, warmAcquireMs = warm,
            backgroundWarmupMs = warming.Elapsed.TotalMilliseconds, scope = "Process startup and initialize only; no threads or model requests" }));
    }

    internal static async Task RunAsync()
    {
        var directory = Path.Combine(Path.GetTempPath(), "hako-workers-" + Guid.NewGuid().ToString("N"));
        var code = Path.Combine(directory, "Code");
        var project = Path.Combine(code, "fixture");
        Directory.CreateDirectory(Path.Combine(project, ".git"));
        var starts = 0;
        Task<CodexAppServer> Start(CancellationToken token)
        {
            Interlocked.Increment(ref starts);
            var start = new ProcessStartInfo(Environment.ProcessPath!);
            if (Path.GetFileNameWithoutExtension(Environment.ProcessPath!) == "dotnet") start.ArgumentList.Add(typeof(Program).Assembly.Location);
            start.ArgumentList.Add("--workshop-worker-fixture");
            start.Environment["HAKO_WORKER_PROJECT"] = project;
            start.Environment["HAKO_WORKER_LOG"] = directory;
            return CodexAppServer.StartAsync(token, start);
        }
        try
        {
            long now = 0;
            var pids = new ConcurrentBag<int>();
            await using (var pool = new WorkshopWorkers(Start, 2, TimeSpan.FromMilliseconds(100), () => now, TimeSpan.FromHours(1)))
            {
                var first = await pool.AcquireAsync(null, "auto", default);
                var firstPid = await Pid(first.Server); pids.Add(firstPid);
                first.Bind("first", Json(new { model = "test" })); first.Retain = true;
                await first.DisposeAsync();
                Check(pool.OwnsThread("first") && Alive(firstPid), "Idle retained process released thread ownership");
                var reused = await pool.AcquireAsync("first", "auto", default);
                Check(reused.Reused && await Pid(reused.Server) == firstPid && starts == 1, "Same thread did not reuse its process");
                now = 1000;
                await pool.SweepAsync();
                Check(Alive(firstPid), "Active/waiting process was reclaimed");
                reused.Retain = true; await reused.DisposeAsync();
                await pool.SweepAsync();
                Check(Alive(firstPid), "Idle timeout was measured from startup instead of the end of work");
                now++;
                var second = await pool.AcquireAsync("second", "auto", default);
                var secondPid = await Pid(second.Server); pids.Add(secondPid);
                second.Bind("second", Json(new { })); second.Retain = true; await second.DisposeAsync();
                var third = await pool.AcquireAsync("third", "auto", default);
                var thirdPid = await Pid(third.Server); pids.Add(thirdPid);
                third.Bind("third", Json(new { }));
                Check(!Alive(firstPid) && Alive(secondPid) && starts == 3, "Capacity eviction did not close the oldest idle process first");
                var busySecond = await pool.AcquireAsync("second", "auto", default);
                using (var cancel = new CancellationTokenSource())
                {
                    var pending = pool.AcquireAsync("fourth", "auto", cancel.Token);
                    await Task.Delay(100);
                    Check(!pending.IsCompleted && starts == 3, "Busy processes were evicted or the hard process limit was exceeded");
                    cancel.Cancel();
                    try { await pending; throw new Exception("Cancelled capacity wait started work"); }
                    catch (OperationCanceledException) { }
                }
                busySecond.Retain = true; await busySecond.DisposeAsync();
                third.Retain = true; await third.DisposeAsync();
                // A permission/configuration change must not inherit stale privileges.
                var changed = await pool.AcquireAsync("second", "ask", default);
                Check(!changed.Reused && !Alive(secondPid), "Changed permissions reused stale thread settings");
                pids.Add(await Pid(changed.Server));
                changed.Bind("second", Json(new { })); changed.Retain = true; await changed.DisposeAsync();
                now += 200;
                await pool.SweepAsync();
                Check(!pool.OwnsThread("second") && !pool.OwnsThread("third") && pids.All(pid => !Alive(pid)), "Expired idle processes or writers leaked");
                var crashed = await pool.AcquireAsync("crashed", "auto", default);
                var crashedPid = await Pid(crashed.Server);
                crashed.Bind("crashed", Json(new { })); crashed.Retain = true;
                try { await crashed.Server.RequestAsync("exit", new { }, default); } catch (IOException) { }
                await crashed.DisposeAsync();
                var replacement = await pool.AcquireAsync("crashed", "auto", default);
                Check(!replacement.Reused && await Pid(replacement.Server) != crashedPid, "Disconnected process was reused");
                await replacement.DisposeAsync();
                var shutdown = await pool.AcquireAsync("shutdown", "auto", default);
                var shutdownPid = await Pid(shutdown.Server); pids.Add(shutdownPid);
                shutdown.Bind("shutdown", Json(new { })); shutdown.Retain = true; await shutdown.DisposeAsync();
            }
            Check(pids.All(pid => !Alive(pid)), "Pool shutdown left a retained process running");

            var attempts = 0;
            await using (var failedStart = new WorkshopWorkers(token => ++attempts == 1
                ? Task.FromException<CodexAppServer>(new IOException("fixture startup failure")) : Start(token), 1))
            {
                try { await failedStart.AcquireAsync(null, "auto", default); throw new Exception("Startup failure was hidden"); }
                catch (IOException) { }
                using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(5));
                await using var retry = await failedStart.AcquireAsync(null, "auto", timeout.Token);
                Check(attempts == 2, "Failed startup leaked its process reservation");
            }
            await using (var timed = new WorkshopWorkers(Start, 1, TimeSpan.FromMilliseconds(40), sweepInterval: TimeSpan.FromMilliseconds(10)))
            {
                var lease = await timed.AcquireAsync(null, "auto", default);
                var pid = await Pid(lease.Server);
                lease.Bind("timer", Json(new { })); lease.Retain = true; await lease.DisposeAsync();
                using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(5));
                while (Alive(pid) || timed.OwnsThread("timer")) await Task.Delay(10, timeout.Token);
                Check(!timed.OwnsThread("timer"), "Background idle reaper did not release the thread");
            }

            var applicationId = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(project.ToUpperInvariant())))[..16].ToLowerInvariant();
            var storage = Path.Combine(directory, "state");
            async Task<JsonElement> Wait(CodeWorkshop service, string id, string expected)
            {
                using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(12));
                while (true)
                {
                    var page = Json((await service.OperationAsync(Json(new { operationId = id }), timeout.Token))!);
                    var operation = page.GetProperty("operation");
                    var state = CodexJson.Text(operation, "state");
                    if (state == expected) return operation;
                    if (state is "failed" or "unknown") throw new Exception("Worker failed: " + operation);
                    await Task.Delay(10, timeout.Token);
                }
            }
            await using (var service = new CodeWorkshop(storage, code, directory, Start, _ => CodexWriterState.Held, workerLimit: 1))
            {
                async Task<(string Job, string Thread)> Send(string? thread, string message = "complete")
                {
                    var id = Guid.NewGuid().ToString();
                    await service.StartAsync(Json(new { requestId = id, applicationId, threadId = thread, message }), default);
                    var done = await Wait(service, id, message == "wait" ? "waiting" : "completed");
                    return (id, CodexJson.Text(done, "threadId"));
                }
                var first = await Send(null);
                using (var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(5)))
                {
                    JsonElement prediction;
                    do
                    {
                        await Task.Delay(10, timeout.Token);
                        var page = Json((await service.OperationAsync(Json(new { operationId = first.Job }), timeout.Token))!);
                        var operation = page.GetProperty("operation");
                        prediction = CodexJson.Field(operation, "prediction");
                        if (prediction.ValueKind != JsonValueKind.Null)
                            Check(CodexJson.Text(prediction, "sourceTurnId") == CodexJson.Text(operation, "turnId"), "Prediction crossed turn boundaries");
                    } while (CodexJson.Text(prediction, "text") != "查看修改");
                }
                // The fixture reports Held even while idle, matching a real retained writer.
                var access = Json((await service.ThreadAccessAsync(Json(new { threadId = first.Thread, applicationId }), default))!);
                Check(CodexJson.Text(access, "state") == "workshop", "Idle owned writer was mistaken for an external client");
                var before = starts;
                await Send(first.Thread);
                Check(starts == before, "Second round restarted the worker or metadata process");
                var queuedId = Guid.NewGuid().ToString();
                var waiting = await Send(first.Thread, "wait");
                await service.QueueAsync(Json(new { operationId = waiting.Job, requestId = queuedId, message = "complete" }), default);
                var approval = Json((await service.OperationAsync(Json(new { operationId = waiting.Job }), default))!).GetProperty("approvals")[0];
                await service.AnswerAsync(Json(new { operationId = waiting.Job, approvalId = approval.GetProperty("id").GetString(), decision = "accept" }), default);
                await Wait(service, queuedId, "completed");
                Check(starts == before, "Queue handoff did not reuse the retained worker");
                var waitingAgain = await Send(first.Thread, "wait");
                var blockedId = Guid.NewGuid().ToString();
                await service.StartAsync(Json(new { requestId = blockedId, applicationId, message = "complete" }), default);
                await Task.Delay(100);
                Check(starts == before, "Approval wait was evicted to start another session");
                await service.StopAsync(Json(new { operationId = blockedId }), default);
                await Wait(service, blockedId, "interrupted");
                await service.StopAsync(Json(new { operationId = waitingAgain.Job }), default);
                await Wait(service, waitingAgain.Job, "interrupted");
                await service.ArchiveAsync(Json(new { threadId = first.Thread, archived = true }), default);
                var logs = Directory.GetFiles(directory, "*.rpc").SelectMany(File.ReadAllLines).ToArray();
                Check(logs.Count(line => line == "thread/start " + first.Thread) == 1 &&
                    !logs.Contains("thread/resume " + first.Thread), "Retained rounds unnecessarily resumed/reloaded the thread");
            }
            // On a new service, a previously persisted thread must resume once.
            await using (var service = new CodeWorkshop(Path.Combine(directory, "reopened"), code, directory, Start, _ => CodexWriterState.Free))
            {
                var thread = Guid.NewGuid().ToString();
                var id = Guid.NewGuid().ToString();
                await service.StartAsync(Json(new { requestId = id, applicationId, threadId = thread, message = "complete" }), default);
                await Wait(service, id, "completed");
                Check(Directory.GetFiles(directory, "*.rpc").SelectMany(File.ReadAllLines).Contains("thread/resume " + thread), "Reclaimed thread was not restored");
            }
            await CheckPrewarmingAsync(Start, directory);
        }
        finally { Directory.Delete(directory, true); }
        Console.WriteLine("PASS: retained session processes, direct consecutive turns/queue handoff, idle writer ownership, expiry, LRU eviction, hard cap, cancellation, approval protection, crash replacement, archive and shutdown");
    }

    private static async Task CheckPrewarmingAsync(Func<CancellationToken, Task<CodexAppServer>> start, string directory)
    {
        var servers = new ConcurrentDictionary<int, CodexAppServer>();
        async Task<CodexAppServer> Start(CancellationToken token)
        {
            var server = await start(token);
            servers.TryAdd(await Pid(server), server);
            return server;
        }
        async Task Ready(WorkshopWorkers pool, int count)
        {
            using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(10));
            while (pool.WarmReadyCount != count) await Task.Delay(10, timeout.Token);
        }
        long now = 0;
        await using (var pool = new WorkshopWorkers(Start, 4, TimeSpan.FromMilliseconds(100), () => now,
            TimeSpan.FromHours(1), warmCount: 2))
        {
            await Ready(pool, 2);
            var initial = servers.Keys.ToHashSet();
            Check(initial.Count == 2 && initial.All(pid => File.ReadAllLines(Path.Combine(directory, pid + ".rpc"))
                .All(line => !line.StartsWith("thread/") && !line.StartsWith("turn/"))),
                "Prewarming loaded a conversation or sent model input");
            var first = await pool.AcquireAsync(null, "auto", default);
            var firstPid = await Pid(first.Server);
            Check(first.Prewarmed && !first.Reused && initial.Contains(firstPid), "Fresh work did not take an already initialized process");
            first.Bind("warm-first", Json(new { }));
            await Ready(pool, 2);
            var second = await pool.AcquireAsync("new-thread", "ask", default);
            Check(second.Prewarmed && !second.Reused && await Pid(second.Server) != firstPid,
                "Pristine warm process did not accept independent thread settings");
            second.Bind("warm-second", Json(new { }));
            await Ready(pool, 2);
            var third = await pool.AcquireAsync(null, "full", default);
            third.Bind("warm-third", Json(new { }));
            await Task.Delay(100);
            Check(pool.WarmReadyCount == 1 && servers.Count == 4, "Refill exceeded the total process limit");
            third.Retain = true; await third.DisposeAsync();
            first.Retain = true; await first.DisposeAsync();
            second.Retain = true; await second.DisposeAsync();
            var same = await pool.AcquireAsync("warm-first", "auto", default);
            Check(same.Reused && !same.Prewarmed && await Pid(same.Server) == firstPid,
                "A warm spare displaced the same conversation's retained process");
            same.Retain = true; await same.DisposeAsync();
            now = 1000;
            await pool.SweepAsync();
            await Ready(pool, 2);
            Check(!Alive(firstPid) && servers.Count(pair => pair.Value.IsConnected) == 2,
                "Idle expiry reclaimed resident spares or left expired conversations alive");
            var victim = servers.First(pair => pair.Value.IsConnected);
            try { await victim.Value.RequestAsync("exit", new { }, default); } catch (IOException) { }
            await Ready(pool, 2);
            Check(!Alive(victim.Key), "Dead resident spare was not replaced");
        }
        Check(servers.Keys.All(pid => !Alive(pid)), "Shutdown leaked prewarmed processes");

        var attempts = 0;
        var failure = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        async Task<CodexAppServer> FailOnce(CancellationToken token)
        {
            if (Interlocked.Increment(ref attempts) == 1)
            { failure.TrySetResult(); throw new IOException("fixture warmup failure"); }
            return await start(token);
        }
        await using (var recovering = new WorkshopWorkers(FailOnce, 1, warmCount: 1))
        {
            await failure.Task.WaitAsync(TimeSpan.FromSeconds(5));
            using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(5));
            await using var foreground = await recovering.AcquireAsync(null, "auto", timeout.Token);
            Check(foreground.Server.IsConnected, "Background warmup failure prevented foreground work");
        }
        var entering = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        async Task<CodexAppServer> Hold(CancellationToken token)
        {
            entering.TrySetResult();
            await Task.Delay(Timeout.Infinite, token);
            throw new InvalidOperationException("unreachable");
        }
        var closing = new WorkshopWorkers(Hold, 1, warmCount: 1);
        await entering.Task.WaitAsync(TimeSpan.FromSeconds(5));
        await closing.DisposeAsync().AsTask().WaitAsync(TimeSpan.FromSeconds(5));
        var code = Path.Combine(directory, "Code");
        var project = Path.Combine(code, "fixture");
        var applicationId = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(project.ToUpperInvariant())))[..16].ToLowerInvariant();
        var storage = Path.Combine(directory, "warm-service");
        var queryLog = Path.Combine(storage, "queries.jsonl");
        string[] ReadLog()
        {
            using var stream = new FileStream(queryLog, FileMode.Open, FileAccess.Read, FileShare.ReadWrite);
            using var reader = new StreamReader(stream);
            return reader.ReadToEnd().Split('\n');
        }
        await using (var service = new CodeWorkshop(storage, code, directory, start, workerWarmCount: 2))
        {
            using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(12));
            while (!File.Exists(queryLog) || ReadLog().Count(line => line.Contains("worker/prewarm") && line.Contains("completed")) < 2)
                await Task.Delay(10, timeout.Token);
            var id = Guid.NewGuid().ToString();
            await service.StartAsync(Json(new { requestId = id, applicationId, message = "complete" }), timeout.Token);
            while (true)
            {
                var operation = Json((await service.OperationAsync(Json(new { operationId = id }), timeout.Token))!).GetProperty("operation");
                if (CodexJson.Text(operation, "state") == "completed") break;
                if (CodexJson.Text(operation, "state") is "failed" or "unknown") throw new Exception("Warm service failed: " + operation);
                await Task.Delay(10, timeout.Token);
            }
            var entries = ReadLog();
            Check(entries.Any(line => line.Contains("worker/warm")) && !entries.Any(line => line.Contains("worker/start")),
                "Code Workshop did not use the initialized reserve for a real new round");
        }
        Console.WriteLine("PASS: two initialized resident spares, immediate claim, refill, shared hard limit, retained-session priority, no model input, spare crash replacement, startup failure and shutdown during warmup");
    }

    internal static async Task FixtureAsync()
    {
        var project = Environment.GetEnvironmentVariable("HAKO_WORKER_PROJECT")!;
        var log = Path.Combine(Environment.GetEnvironmentVariable("HAKO_WORKER_LOG")!, Environment.ProcessId + ".rpc");
        string? loaded = null;
        string? turn = null;
        var sequence = 0;
        void Write(object value) { Console.WriteLine(JsonSerializer.Serialize(value, WorkshopProtocol.Json)); Console.Out.Flush(); }
        void Complete(string status = "completed") => Write(new { method = "turn/completed", @params = new { threadId = loaded, turn = new { id = turn, status } } });
        while (await Console.In.ReadLineAsync() is { } line)
        {
            using var parsed = JsonDocument.Parse(line);
            var input = parsed.RootElement;
            var method = CodexJson.Text(input, "method");
            if (!input.TryGetProperty("id", out var id)) continue;
            if (method.Length == 0) { Complete(); continue; }
            var parameters = CodexJson.Field(input, "params");
            if (method == "exit") return;
            if (method is "thread/start" or "thread/resume")
            {
                Check(loaded is null, "A loaded thread was unnecessarily resumed");
                loaded = CodexJson.Text(parameters, "threadId");
                if (loaded.Length == 0) loaded = Guid.NewGuid().ToString();
            }
            var threadId = CodexJson.Text(parameters, "threadId");
            File.AppendAllText(log, method + " " + (method == "thread/start" ? loaded : threadId) + "\n");
            var thread = new { id = threadId.Length > 0 ? threadId : loaded, cwd = project, name = "Retained fixture", status = new { type = "idle" } };
            if (method == "turn/start")
            {
                Check(loaded == threadId, "Turn was started without loading the target thread");
                turn = Environment.ProcessId + "-" + ++sequence;
            }
            object result = method switch
            {
                "probe" => new { pid = Environment.ProcessId },
                "thread/start" or "thread/resume" => new { thread, model = "fixture", reasoningEffort = "medium" },
                "thread/read" => new { thread },
                "thread/sample" => new { sourceTurnId = CodexJson.Text(parameters, "expectedTurnId"), text = "查看修改" },
                "turn/start" => new { turn = new { id = turn, status = "inProgress" } },
                "thread/turns/list" => new { data = Array.Empty<object>(), nextCursor = (string?)null },
                _ => new { }
            };
            Write(new { id, result });
            if (method == "turn/start")
            {
                Write(new { method = "item/started", @params = new { threadId = loaded, turnId = turn, item = new { type = "userMessage", clientId = CodexJson.Text(parameters, "clientUserMessageId") } } });
                var wait = CodexJson.Items(CodexJson.Field(parameters, "input")).Any(item => CodexJson.Text(item, "text") == "wait");
                if (wait) Write(new { id = 900, method = "item/commandExecution/requestApproval", @params = new { threadId = loaded, turnId = turn, itemId = "approval", command = "test" } });
                else Complete();
            }
            if (method == "turn/interrupt") Complete("interrupted");
        }
    }
}
