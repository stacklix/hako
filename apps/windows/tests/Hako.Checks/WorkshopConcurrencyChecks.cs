using System;
using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Hako.Platform;

internal static class WorkshopConcurrencyChecks
{
    private static JsonElement Json(object value) => JsonSerializer.SerializeToElement(value, WorkshopProtocol.Json);
    private static void Check(bool value, string message) { if (!value) throw new Exception(message); }

    internal static async Task RunAsync()
    {
        var directory = Path.Combine(Path.GetTempPath(), "hako-concurrency-" + Guid.NewGuid().ToString("N"));
        var code = Path.Combine(directory, "Code");
        var project = Path.Combine(code, "fixture");
        var storage = Path.Combine(directory, "state");
        Directory.CreateDirectory(Path.Combine(project, ".git"));
        Directory.CreateDirectory(storage);
        var applicationId = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(project.ToUpperInvariant())))[..16].ToLowerInvariant();
        var threadId = Guid.NewGuid().ToString("D");
        var root = new WorkshopJob { Id = Guid.NewGuid().ToString("D"), ApplicationId = applicationId,
            Cwd = project, ThreadId = threadId, State = "completed", QueueOrder = 1 };
        var paused = new WorkshopJob { Id = Guid.NewGuid().ToString("D"), RootId = root.Id,
            ApplicationId = applicationId, Cwd = project, ThreadId = threadId,
            State = "paused", InputMessage = "Resume independently of other sessions", QueueOrder = 2 };
        foreach (var job in new[] { root, paused })
            File.WriteAllBytes(Path.Combine(storage, job.Id + ".json"), JsonSerializer.SerializeToUtf8Bytes(job, WorkshopProtocol.Json));
        var started = 0;
        var allStarted = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        async Task<CodexAppServer> HoldStartup(CancellationToken token)
        {
            if (Interlocked.Increment(ref started) == 5) allStarted.TrySetResult();
            await Task.Delay(Timeout.Infinite, token);
            throw new InvalidOperationException("Unreachable fixture startup");
        }
        try
        {
            await using var service = new CodeWorkshop(storage, code, directory, HoldStartup);
            JsonElement lastRequest = default;
            for (var index = 0; index < 4; index++)
            {
                lastRequest = Json(new { requestId = Guid.NewGuid().ToString("D"), applicationId, message = "Independent session " + index });
                var accepted = Json((await service.StartAsync(lastRequest, default))!);
                Check(CodexJson.Text(accepted, "state") == "starting", "An unrelated session was blocked by the global task count");
            }
            var resumed = Json((await service.SteerMessageAsync(Json(new { operationId = root.Id, messageId = paused.Id,
                requestId = Guid.NewGuid().ToString("D"), revision = 0 }), default))!);
            Check(CodexJson.Text(resumed, "state") == "starting", "Other sessions prevented a paused message from resuming");
            await allStarted.Task.WaitAsync(TimeSpan.FromSeconds(15));
            var retry = Json((await service.StartAsync(lastRequest, default))!);
            Check(CodexJson.Text(retry, "id") == CodexJson.Text(lastRequest, "requestId") && started == 5,
                "Retrying an accepted request started a duplicate worker");
            try
            {
                await service.StartAsync(Json(new { requestId = Guid.NewGuid().ToString("D"), applicationId, threadId, message = "Conflicting same-session start" }), default);
                throw new Exception("The same session acquired a conflicting worker");
            }
            catch (WorkshopException error) when (error.Code == "codex_busy")
            {
                Check(!error.Message.Contains("并发"), "Same-session rejection still reports an unrelated global limit");
            }
        }
        finally { Directory.Delete(directory, true); }
        Console.WriteLine("PASS: independent sessions and paused-message resumption exceed three active workers without duplicate retries");
    }
}
