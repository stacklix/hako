using System;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Hako.Core;
using Hako.Platform;

internal static class WorkshopAccessChecks
{
    private static JsonElement Json(object value) => JsonSerializer.SerializeToElement(value, WorkshopProtocol.Json);
    private static void Check(bool value, string message) { if (!value) throw new Exception(message); }

    internal static async Task RunAsync(string directory, string code, string thread,
        Func<CancellationToken, Task<CodexAppServer>> start, Func<CancellationToken, Task<CodexAppServer>> slow)
    {
        var home = Path.Combine(directory, "lock-home");
        var path = Path.Combine(home, "thread-writer-locks", thread + ".lock");
        Check(CodexWriterLock.Read(home, thread) == CodexWriterState.Free && !Directory.Exists(home), "Missing locks must not be created");
        Check(CodexWriterLock.Read(home, "../escape") == CodexWriterState.Unknown, "Invalid thread escaped the lock directory");
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        File.WriteAllText(path, "stale lock contents");
        var original = File.ReadAllBytes(path);
        Check(CodexWriterLock.Read(home, thread) == CodexWriterState.Free, "A stale file was classified as occupied");
        using (var holder = new FileStream(path, FileMode.Open, FileAccess.ReadWrite, FileShare.ReadWrite | FileShare.Delete))
        {
            holder.Lock(0, 1);
            try { Check(CodexWriterLock.Read(home, thread) == CodexWriterState.Held, "A live byte lock was missed"); }
            finally { holder.Unlock(0, 1); }
        }
        Check(File.ReadAllBytes(path).SequenceEqual(original), "Probing modified the lock file contents");
        Check(File.ReadAllBytes(path).SequenceEqual(original), "Lock probing modified file contents");
        Check(CodexWriterLock.Read(home, thread) == CodexWriterState.Free && original.SequenceEqual(File.ReadAllBytes(path)), "Probing changed the file or retained its lock");
        File.Delete(path); Directory.CreateDirectory(path);
        Check(CodexWriterLock.Read(home, thread) == CodexWriterState.Unknown, "An unreadable lock was treated as available");
        Directory.Delete(path);

        var state = CodexWriterState.Held;
        var storage = Path.Combine(directory, "access-state");
        await using (var workshop = new CodeWorkshop(storage, code, home, start, _ => state))
        {
            var catalog = Json((await workshop.CatalogAsync(Json(new { }), default))!);
            var applicationId = catalog.GetProperty("applications")[0].GetProperty("id").GetString()!;
            Check(catalog.GetProperty("sessions")[0].GetProperty("access").GetProperty("state").GetString() == "occupied", "Catalog hid an idle external writer");
            var history = Json((await workshop.HistoryAsync(Json(new { threadId = thread }), default))!);
            Check(history.GetProperty("access").GetProperty("state").GetString() == "occupied", "Occupied history could not be read");
            foreach (var sample in new[] { (CodexWriterState.Held, "codex_thread_occupied"), (CodexWriterState.Unknown, "codex_thread_access_unknown") })
            {
                state = sample.Item1;
                try { await workshop.StartAsync(Json(new { requestId = Guid.NewGuid().ToString("D"), applicationId, threadId = thread, message = "Never submitted" }), default); throw new Exception("Unavailable thread accepted a message"); }
                catch (WorkshopException error) when (error.Code == sample.Item2) { }
            }
            Check(!Directory.Exists(storage) || !Directory.GetFiles(storage, "*.json").Any(), "Rejected preflight created a durable message");
            state = CodexWriterState.Free;
            var released = Json((await workshop.ThreadAccessAsync(Json(new { applicationId, threadId = thread }), default))!);
            Check(released.GetProperty("state").GetString() == "available", "Releasing the writer did not restore availability");
            try { await workshop.ThreadAccessAsync(Json(new { applicationId = "other", threadId = thread }), default); throw new Exception("Cross-project probe accepted"); }
            catch (WorkshopException error) when (error.Code == "codex_workspace_invalid") { }
        }

        state = CodexWriterState.Free;
        await using (var workshop = new CodeWorkshop(Path.Combine(directory, "owned-state"), code, home, slow, _ => state))
        {
            var catalog = Json((await workshop.CatalogAsync(Json(new { }), default))!);
            var applicationId = catalog.GetProperty("applications")[0].GetProperty("id").GetString()!;
            var id = Guid.NewGuid().ToString("D");
            await workshop.StartAsync(Json(new { requestId = id, applicationId, threadId = thread, message = "Own the fixture writer" }), default);
            var deadline = DateTime.UtcNow.AddSeconds(5);
            string actual;
            do
            {
                actual = Json((await workshop.ThreadAccessAsync(Json(new { applicationId, threadId = thread }), default))!).GetProperty("state").GetString()!;
                if (actual == "workshop") break;
                await Task.Delay(20);
            } while (DateTime.UtcNow < deadline);
            Check(actual == "workshop", "A successfully resumed worker did not identify its own writer");
            state = CodexWriterState.Held;
            Check(Json((await workshop.ThreadAccessAsync(Json(new { applicationId, threadId = thread }), default))!).GetProperty("state").GetString() == "workshop", "The workshop mistook its own writer for an external client");
            var queued = Json((await workshop.QueueAsync(Json(new { operationId = id, requestId = Guid.NewGuid().ToString("D"), message = "Allowed follow-up" }), default))!);
            Check(queued.GetProperty("state").GetString() == "queued", "The owned writer blocked follow-up messages");
        }
        Console.WriteLine("PASS: real writer locks, stale/missing/unreadable locks, occupied catalog/history, preflight without message persistence, release, scope and owned follow-ups");
    }
}
