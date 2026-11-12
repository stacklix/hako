using System;
using System.Collections.Concurrent;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Hako.Platform;

internal static class WorkshopNotificationChecks
{
    internal static async Task RunAsync()
    {
        var excerpt = CodeWorkshop.NotificationText("  最后回复\n\t完成。 visualize{\"path\":\"C:/private.html\"} \0", 240);
        if (excerpt != "最后回复 完成。") throw new Exception("Notification excerpt did not normalize whitespace/control characters or remove internal preview references");
        excerpt = CodeWorkshop.NotificationText(string.Concat(Enumerable.Repeat("🛠", 250)), 240);
        if (excerpt.EnumerateRunes().Count() != 240 || !excerpt.EndsWith("…", StringComparison.Ordinal) || excerpt.Contains('\uFFFD'))
            throw new Exception("Notification excerpt split Unicode or exceeded its length limit");
        var directory = Path.Combine(Path.GetTempPath(), "hako-workshop-notifications-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        string Save(string state, string? scope, bool acknowledged = false)
        {
            var id = Guid.NewGuid().ToString("D");
            File.WriteAllBytes(Path.Combine(directory,id+".json"),JsonSerializer.SerializeToUtf8Bytes(new WorkshopJob {
                Id=id,State=state,NotificationScope=scope,NotificationAcknowledged=acknowledged,
                Cwd=Path.Combine(directory,"Project"),SessionName="我的会话",ReplySummary="本轮最后回复",InputMessage="secret-prompt",
                FinishedAt=CodeWorkshop.TerminalState(state)?DateTimeOffset.UtcNow.ToUnixTimeMilliseconds():0
            },WorkshopProtocol.Json));
            return id;
        }
        var completed=Save("completed","cloud");
        var failed=Save("failed","cloud");
        var interrupted=Save("interrupted","cloud");
        var recovered=Save("running","cloud");
        var ignored=new[] {Save("completed",null),Save("completed","other-server"),Save("completed","cloud",true),Save("paused","cloud"),Save("queued","cloud"),Save("steered","cloud"),Save("cancelled","cloud")};
        using var lifetime=new CancellationTokenSource(TimeSpan.FromSeconds(15));
        try
        {
            await using (var workshop=new CodeWorkshop(directory))
            {
                var received=new ConcurrentDictionary<string,WorkshopTerminal>();
                var watcher=workshop.WatchTerminalsAsync("cloud", item => { received[item.OperationId]=item; return Task.CompletedTask; },lifetime.Token);
                var deadline=DateTime.UtcNow.AddSeconds(5);
                while (received.Count<4 && DateTime.UtcNow<deadline) await Task.Delay(10);
                if (received.Count!=4 || ignored.Any(received.ContainsKey) || received[recovered].State!="unknown") throw new Exception("Incorrect scope, terminal classification or restart recovery");
                if (received.Values.Any(item => item.ProjectName != "Project" || item.SessionName != "我的会话" || item.Summary != "本轮最后回复"))
                    throw new Exception("Restart lost project/session/reply metadata");
                if (JsonSerializer.Serialize(received[completed], WorkshopProtocol.Json).Contains("secret-prompt", StringComparison.Ordinal))
                    throw new Exception("Terminal event leaked the user's input");
                // An ACK from another server cannot remove the durable outbox entry.
                workshop.AcknowledgeTerminal("other-server",completed);
                if (JsonDocument.Parse(File.ReadAllBytes(Path.Combine(directory,completed+".json"))).RootElement.GetProperty("notificationAcknowledged").GetBoolean()) throw new Exception("Cross-server ACK accepted");
                foreach(var id in received.Keys) workshop.AcknowledgeTerminal("cloud",id);
                lifetime.Cancel();
                try { await watcher; } catch(OperationCanceledException) { }
            }
            await using(var reopened=new CodeWorkshop(directory))
            {
                using var timeout=new CancellationTokenSource(150);
                var resent=0;
                try { await reopened.WatchTerminalsAsync("cloud", _=>{resent++;return Task.CompletedTask;},timeout.Token); } catch(OperationCanceledException) { }
                if(resent!=0) throw new Exception("Restart forgot persisted ACKs");
            }
        }
        finally { Directory.Delete(directory,true); }
        var questionDirectory = Path.Combine(Path.GetTempPath(), "hako-question-outbox-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(questionDirectory);
        var questionJob = new WorkshopJob { Id = Guid.NewGuid().ToString("D"), State = "completed", NotificationScope = "cloud",
            NotificationAcknowledged = true, ThreadId = Guid.NewGuid().ToString("D"), Cwd = "C:/Code/hako", SessionName = "Question session",
            QuestionNotifications = new() { ["async-question"] = new() { CreatedAt = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds(), Summary = "如何升级？" } } };
        File.WriteAllBytes(Path.Combine(questionDirectory, questionJob.Id + ".json"), JsonSerializer.SerializeToUtf8Bytes(questionJob, WorkshopProtocol.Json));
        try {
            await using (var questions = new CodeWorkshop(questionDirectory)) {
                using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(3));
                await questions.WatchTerminalsAsync("cloud", notice => {
                    if (notice.State != "input_required" || notice.QuestionId != "async-question" || notice.ThreadId != questionJob.ThreadId)
                        throw new Exception("Question notification lost routing or question identity");
                    questions.AcknowledgeTerminal("wrong-scope", notice.OperationId, notice.QuestionId);
                    var unchanged = JsonSerializer.Deserialize<WorkshopJob>(File.ReadAllBytes(Path.Combine(questionDirectory, questionJob.Id + ".json")), WorkshopProtocol.Json)!;
                    if (unchanged.QuestionNotifications[notice.QuestionId].Acknowledged) throw new Exception("Cross-scope question ACK accepted");
                    questions.AcknowledgeTerminal("cloud", notice.OperationId, notice.QuestionId);
                    timeout.Cancel(); return Task.CompletedTask;
                }, timeout.Token).ContinueWith(task => { if (task.IsFaulted) throw task.Exception!; });
            }
            await using (var questions = new CodeWorkshop(questionDirectory)) {
                using var timeout = new CancellationTokenSource(150);
                var count = 0;
                try { await questions.WatchTerminalsAsync("cloud", _ => { count++; return Task.CompletedTask; }, timeout.Token); } catch (OperationCanceledException) { }
                if (count != 0) throw new Exception("Restart resent an acknowledged question");
            }
        } finally { Directory.Delete(questionDirectory, true); }
        Console.WriteLine("PASS: durable Workshop completion/failure/interruption outbox, restart unknown, scope isolation, LAN-only exclusion and persisted acknowledgements");
    }
}
