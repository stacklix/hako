using System;
using System.Collections.Concurrent;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Hako.Platform;

internal static class WorkshopNotificationChecks
{
    internal static async Task RunAsync()
    {
        var directory = Path.Combine(Path.GetTempPath(), "hako-workshop-notifications-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        string Save(string state, string? scope, bool acknowledged = false)
        {
            var id = Guid.NewGuid().ToString("D");
            File.WriteAllBytes(Path.Combine(directory,id+".json"),JsonSerializer.SerializeToUtf8Bytes(new WorkshopJob {
                Id=id,State=state,NotificationScope=scope,NotificationAcknowledged=acknowledged,
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
        Console.WriteLine("PASS: durable Workshop completion/failure/interruption outbox, restart unknown, scope isolation, LAN-only exclusion and persisted acknowledgements");
    }
}
