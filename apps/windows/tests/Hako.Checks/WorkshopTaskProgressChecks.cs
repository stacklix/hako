using System;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Threading;
using Hako.Platform;

internal static class WorkshopTaskProgressChecks
{
    internal static void Run()
    {
        var home = Path.Combine(Path.GetTempPath(), "hako-progress-" + Guid.NewGuid().ToString("N"));
        const string thread = "11111111-1111-4111-8111-111111111111";
        var folder = Path.Combine(home, "task-progress", thread);
        Directory.CreateDirectory(folder);
        void Check(bool value, string message) { if (!value) throw new Exception(message); }
        JsonElement Read() => JsonSerializer.SerializeToElement(WorkshopTaskProgress.Read(home, thread, CancellationToken.None), WorkshopProtocol.Json);
        void Save(WorkshopProgressTask task, string? scope = null) => File.WriteAllText(Path.Combine(folder, task.Id + ".json"),
            JsonSerializer.Serialize(new WorkshopProgressRecord(1, scope ?? thread, task), WorkshopProtocol.Json));
        var stamp = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
        WorkshopProgressTask Task(string id, string project) => new(id, project, project, "iOS", "running", stamp, stamp,
            [new("build", "编译", "running")]);
        try
        {
            Save(Task("one", "Project A")); Save(Task("two", "Project B"));
            Save(Task("one", "Project A") with { Summary = "改进会话内任务卡片布局" });
            Check(Read().GetProperty("tasks").EnumerateArray().Single(task => task.GetProperty("id").GetString() == "one")
                .GetProperty("summary").GetString() == "改进会话内任务卡片布局", "Build summary was dropped by the Agent");
            Check(Read().GetProperty("tasks").GetArrayLength() == 2, "Same-platform tasks were merged by project or platform");
            Save(Task("other-thread", "Hidden"), "22222222-2222-4222-8222-222222222222");
            File.WriteAllText(Path.Combine(folder, "broken.json"), "{unfinished");
            Check(Read().GetProperty("tasks").GetArrayLength() == 2 && Read().GetProperty("warning").ValueKind == JsonValueKind.String,
                "Invalid records leaked cross-thread data or hid valid tasks");
            Save(Task("bad-release", "A") with { Release = new("com.example.a", "1.0.0", "1", "http://insecure/latest.json") });
            Save(Task("duplicate-stage", "A") with { Stages = [new("x", "one", "running"), new("x", "two", "pending")] });
            Save(Task("bad-summary", "A") with { Summary = new string('x', 501) });
            Save(Task("control-summary", "A") with { Summary = "bad\nsummary" });
            Check(Read().GetProperty("tasks").GetArrayLength() == 2, "Unsafe release or duplicate stage IDs were exposed");
            var before = File.ReadAllText(Path.Combine(folder, "one.json"));
            _ = Read(); Check(before == File.ReadAllText(Path.Combine(folder, "one.json")), "Reading progress mutated producer records");
            var missing = JsonSerializer.SerializeToElement(WorkshopTaskProgress.Read(home, "33333333-3333-4333-8333-333333333333", CancellationToken.None), WorkshopProtocol.Json);
            Check(missing.GetProperty("tasks").GetArrayLength() == 0, "Unregistered session returned another session's tasks");
            try { WorkshopTaskProgress.Read(home, "../escape", CancellationToken.None); throw new Exception("Traversal accepted"); }
            catch (WorkshopException) { }
            for (var index = 0; index < 30; index++) Save(Task("task-" + index, "A"));
            var bounded = Read();
            Check(bounded.GetProperty("tasks").GetArrayLength() == 16 && bounded.GetRawText().Length < 48 * 1024, "Progress response was not bounded");
            Console.WriteLine("PASS: task progress is read-only, session-scoped, bounded and validates release/stage metadata");
        }
        finally { Directory.Delete(home, true); }
    }
}
