using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Hako.Core;
using Hako.Platform;

internal static class WorkshopSidechatChecks
{
    private const string Parent = "11111111-1111-4111-8111-111111111111";
    private const string Child = "33333333-3333-4333-8333-333333333333";
    private const string Agent = "44444444-4444-4444-8444-444444444444";
    private static JsonElement Json(object value) => JsonSerializer.SerializeToElement(value, WorkshopProtocol.Json);
    private static void Check(bool value, string message) { if (!value) throw new Exception(message); }

    internal static async Task RunAsync()
    {
        var directory = Path.Combine(Path.GetTempPath(), "hako-sidechat-" + Guid.NewGuid().ToString("N"));
        var code = Path.Combine(directory, "Code");
        var project = Path.Combine(code, "fixture");
        var storage = Path.Combine(directory, "state");
        Directory.CreateDirectory(Path.Combine(project, ".git"));
        var applicationId = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(project.ToUpperInvariant())))[..16].ToLowerInvariant();
        Task<CodexAppServer> Start(CancellationToken token)
        {
            var start = new ProcessStartInfo(Environment.ProcessPath!);
            if (Path.GetFileNameWithoutExtension(Environment.ProcessPath!).Equals("dotnet", StringComparison.OrdinalIgnoreCase))
                start.ArgumentList.Add(typeof(Program).Assembly.Location);
            start.ArgumentList.Add("--workshop-sidechat-fixture");
            start.Environment["HAKO_SIDECHAT_PROJECT"] = project;
            return CodexAppServer.StartAsync(token, start);
        }
        CodeWorkshop Service() => new(storage, code, directory, Start,
            id => id == Parent ? CodexWriterState.Held : CodexWriterState.Free);
        async Task Finish(CodeWorkshop service, string id)
        {
            var jobs = (Dictionary<string, WorkshopJob>)typeof(CodeWorkshop).GetField("jobs", BindingFlags.Instance | BindingFlags.NonPublic)!.GetValue(service)!;
            await jobs[id].Worker!.WaitAsync(TimeSpan.FromSeconds(10));
            Check(jobs[id].State == "completed", "Sidechat failed: " + jobs[id].Message);
        }
        try
        {
            var large = new string('测', 4000);
            var bounded = CodeWorkshop.Subagent(Json(new { id = Agent, agentNickname = large, agentRole = large,
                preview = large, model = large, reasoningEffort = large, updatedAt = 1L }), "completed");
            Check(JsonSerializer.SerializeToUtf8Bytes(new { agents = Enumerable.Repeat(bounded, 20).ToArray(), nextCursor = new string('x', 8192) }, WorkshopProtocol.Json).Length < 64 * 1024,
                "Subagent page exceeded its wire response budget");
            var id = Guid.NewGuid().ToString("D");
            var request = Json(new { requestId = id, applicationId, parentThreadId = Parent, message = "Explain the design", name = "Design" });
            await using (var service = Service())
            {
                var agents = Json((await service.SubagentsAsync(Json(new { threadId = Parent, applicationId }), default))!);
                Check(agents.GetProperty("agents").GetArrayLength() == 1, "Unrelated subagents leaked into collaboration");
                var agent = agents.GetProperty("agents")[0];
                Check(agent.GetProperty("name").GetString() == "Darwin" && agent.GetProperty("role").GetString() == "explorer"
                    && agent.GetProperty("model").GetString() == "fixture-model", "Subagent metadata was lost");
                var agentHistory = Json((await service.SubagentReadAsync(Json(new { threadId = Parent, applicationId, agentId = Agent }), default))!);
                Check(agentHistory.GetProperty("threadId").GetString() == Agent, "Subagent history was not read");
                try {
                    await service.SubagentReadAsync(Json(new { threadId = Parent, applicationId, agentId = Child }), default);
                    throw new Exception("An unrelated thread was read as a subagent");
                } catch (WorkshopException error) when (error.Code == "codex_subagent_invalid") { }
                await service.StartAsync(request, default);
                await Finish(service, id);
                await service.StartAsync(request, default);
                Check(File.ReadAllText(Path.Combine(project, "fork-count")) == "1", "Retry forked twice");
                try
                {
                    await service.StartAsync(Json(new { requestId = id, applicationId, parentThreadId = Guid.NewGuid().ToString("D"), message = "Explain the design", name = "Design" }), default);
                    throw new Exception("A reused request changed its parent");
                }
                catch (WorkshopException error) when (error.Code == "codex_request_conflict") { }
                var history = Json((await service.HistoryAsync(Json(new { threadId = Child }), default))!);
                Check(history.GetProperty("entries").GetArrayLength() == 2 && history.GetProperty("nextCursor").ValueKind == JsonValueKind.Null,
                    "Inherited parent transcript leaked into sidechat history");
                Check(!history.GetRawText().Contains("Parent-only response"), "Parent response shown in sidechat");
                var catalog = Json((await service.CatalogAsync(Json(new { }), default))!);
                Check(catalog.GetProperty("sessions").GetArrayLength() == 1 && catalog.GetProperty("sessions")[0].GetProperty("id").GetString() == Parent,
                    "Sidechat leaked into main session list");
                var jobs = (Dictionary<string, WorkshopJob>)typeof(CodeWorkshop).GetField("jobs", BindingFlags.Instance | BindingFlags.NonPublic)!.GetValue(service)!;
                var seeded = new List<string>();
                for (var index = 0; index < 31; index++)
                {
                    var key = Guid.NewGuid().ToString("D"); seeded.Add(key);
                    jobs.Add(key, new WorkshopJob { Id = key, ApplicationId = applicationId, ParentThreadId = Parent,
                        ThreadId = Guid.NewGuid().ToString("D"), Cwd = project, InheritedTurnId = "parent-turn", TurnId = id,
                        State = "completed", Submitted = true, QueueOrder = DateTime.UtcNow.Ticks + index, SessionName = "Sidechat" });
                }
                var firstPage = Json((await service.SidechatsAsync(Json(new { threadId = Parent, applicationId }), default))!);
                Check(firstPage.GetProperty("sessions").GetArrayLength() == 30 && firstPage.GetProperty("nextCursor").GetString() is { Length: > 0 },
                    "Sidechat list did not bound its first page");
                var secondPage = Json((await service.SidechatsAsync(Json(new { threadId = Parent, applicationId, cursor = firstPage.GetProperty("nextCursor").GetString() }), default))!);
                var ids = firstPage.GetProperty("sessions").EnumerateArray().Concat(secondPage.GetProperty("sessions").EnumerateArray())
                    .Select(row => row.GetProperty("id").GetString()).ToArray();
                Check(ids.Length == 32 && ids.Distinct().Count() == 32 && secondPage.GetProperty("nextCursor").ValueKind == JsonValueKind.Null,
                    "Sidechat pagination skipped or duplicated history");
                Check(JsonSerializer.SerializeToUtf8Bytes(firstPage, WorkshopProtocol.Json).Length <= 56 * 1024,
                    "Sidechat page exceeded the transport budget");
                foreach (var key in seeded) jobs.Remove(key);
            }
            await using (var restored = Service())
            {
                var list = Json((await restored.SidechatsAsync(Json(new { threadId = Parent, applicationId }), default))!);
                Check(list.GetProperty("sessions").GetArrayLength() == 1 && list.GetProperty("sessions")[0].GetProperty("parentThreadId").GetString() == Parent,
                    "Sidechat relationship was lost after restart");
                var next = Guid.NewGuid().ToString("D");
                await restored.StartAsync(Json(new { requestId = next, applicationId, threadId = Child, message = "Continue discussion", permission = "full" }), default);
                await Finish(restored, next);
                Check(File.Exists(Path.Combine(project, "readonly-resume")), "Resuming sidechat widened permissions");
            }
            Check(CodexAppServer.RequestTimeout("thread/fork") == TimeSpan.FromSeconds(60), "Fork used short query deadline");
            Console.WriteLine("PASS: active-parent fork, independent history, durable relationship, idempotency, catalog isolation and read-only resume");
        }
        finally { if (Directory.Exists(directory)) Directory.Delete(directory, true); }
    }

    internal static async Task FixtureAsync()
    {
        var project = Environment.GetEnvironmentVariable("HAKO_SIDECHAT_PROJECT")!;
        void Write(object value) { Console.WriteLine(Json(value).GetRawText()); Console.Out.Flush(); }
        while (await Console.In.ReadLineAsync() is { } line)
        {
            using var document = JsonDocument.Parse(line);
            var request = document.RootElement;
            if (!request.TryGetProperty("id", out var rpcId)) continue;
            var method = CodexJson.Text(request, "method");
            var p = CodexJson.Field(request, "params");
            var id = CodexJson.Text(p, "threadId");
            var own = File.Exists(Path.Combine(project, "turn")) ? JsonSerializer.Deserialize<JsonElement>(File.ReadAllText(Path.Combine(project, "turn"))) : default;
            var turnId = own.ValueKind == JsonValueKind.Undefined ? "parent-turn" : CodexJson.Text(own, "clientUserMessageId");
            object Thread(string threadId) => new { id = threadId, cwd = project, name = "Design", preview = "Discussion", updatedAt = 1000L, recencyAt = 1000L,
                parentThreadId = threadId == Agent ? Parent : (string?)null,
                agentNickname = threadId == Agent ? "Darwin" : null, agentRole = "explorer", model = "fixture-model", reasoningEffort = "high",
                source = new { subAgent = new { thread_spawn = new { parent_thread_id = Parent, depth = 1 } } },
                status = new { type = threadId == Parent ? "active" : "idle" } };
            if (method == "thread/list" && CodexJson.Text(p, "parentThreadId").Length > 0)
                Check(CodexJson.Text(p, "parentThreadId") == Parent && p.GetProperty("limit").GetInt32() == 20 &&
                    p.GetProperty("sourceKinds")[0].GetString() == "subAgentThreadSpawn", "Subagent query scanned unbounded or unrelated sessions");
            if (method is "thread/fork" or "thread/resume")
            {
                Check(CodexJson.Text(p, "sandbox") == "read-only" && CodexJson.Text(p, "approvalPolicy") == "never", "Sidechat permissions not constrained");
                if (method == "thread/fork")
                {
                    Check(id == Parent && p.GetProperty("deferGoalContinuation").GetBoolean(), "Parent/goal identity lost");
                    var countPath = Path.Combine(project, "fork-count");
                    File.WriteAllText(countPath, ((File.Exists(countPath) ? int.Parse(File.ReadAllText(countPath)) : 0) + 1).ToString());
                }
                else File.WriteAllText(Path.Combine(project, "readonly-resume"), "yes");
            }
            object result = method switch
            {
                "thread/fork" or "thread/resume" => new { thread = Thread(Child), model = "fixture" },
                "thread/read" => new { thread = Thread(id) },
                "thread/list" => new { data = CodexJson.Text(p, "parentThreadId").Length > 0 ? new[] { Thread(Agent), Thread(Child) } : new[] { Thread(Parent), Thread(Child) }, nextCursor = (string?)null },
                "thread/turns/list" => new { data = new[] { new { id = id == Parent ? "parent-turn" : turnId, status = id == Parent ? "inProgress" : "completed", items = Array.Empty<object>() } }, nextCursor = (string?)null },
                "thread/items/list" => new { data = id == Parent ? Array.Empty<object>() : own.ValueKind == JsonValueKind.Undefined ? new object[] {
                    new { turnId = "parent-turn", item = new { id = "parent-answer", type = "agentMessage", text = "Parent-only response" } }
                } : new object[] {
                    new { turnId, item = (object)new { id = "answer", type = "agentMessage", text = "Sidechat answer" } },
                    new { turnId, item = (object)new { id = "input", clientId = turnId, type = "userMessage", content = new[] { new { type = "text", text = "Explain the design" } } } },
                    new { turnId = "parent-turn", item = (object)new { id = "parent-answer", type = "agentMessage", text = "Parent-only response" } }
                }, nextCursor = (string?)null },
                "turn/start" => new { turn = new { id = CodexJson.Text(p, "clientUserMessageId"), status = "inProgress" } },
                _ => new { }
            };
            if (method == "turn/start") File.WriteAllText(Path.Combine(project, "turn"), p.GetRawText());
            if (method == "turn/start") Check(CodexJson.Text(CodexJson.Field(CodexJson.Field(p, "additionalContext"), "hako.sidechat"), "kind") == "application",
                "Sidechat did not receive independent discussion context");
            Write(new { id = rpcId.Clone(), result });
            if (method == "turn/start")
            {
                var tid = CodexJson.Text(p, "clientUserMessageId");
                Write(new { method = "item/completed", @params = new { threadId = Child, turnId = tid, item = new { id = "answer", type = "agentMessage", text = "Sidechat answer" } } });
                Write(new { method = "turn/completed", @params = new { threadId = Child, turn = new { id = tid, status = "completed" } } });
            }
        }
    }
}
