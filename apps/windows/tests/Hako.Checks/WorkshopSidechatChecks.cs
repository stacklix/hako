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
    private static readonly string TaskText = new string('测', 4095) + "😀" + new string('任', 6200);
    private static JsonElement Json(object value) => JsonSerializer.SerializeToElement(value, WorkshopProtocol.Json);
    private static void Check(bool value, string message) { if (!value) throw new Exception(message); }

    internal static async Task ReadLiveTasksAsync(string parent, string project)
    {
        var directory = Path.Combine(Path.GetTempPath(), "hako-subagent-read-" + Guid.NewGuid().ToString("N"));
        var applicationId = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(Path.GetFullPath(project).ToUpperInvariant())))[..16].ToLowerInvariant();
        try {
            await using var service = new CodeWorkshop(directory, Path.GetDirectoryName(Path.GetFullPath(project)), "C:/Users/xliqi/.codex");
            using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(90));
            JsonElement agents;
            do {
                var reply = Json((await service.SubagentsAsync(Json(new { threadId = parent, applicationId }), deadline.Token))!);
                agents = reply.GetProperty("agents");
                if (agents.EnumerateArray().All(a => a.GetProperty("taskState").GetString() != "loading")) break;
                await Task.Delay(500, deadline.Token);
            } while (true);
            Console.WriteLine(JsonSerializer.Serialize(agents.EnumerateArray().Select(a => new {
                name = a.GetProperty("name").GetString(), state = a.GetProperty("taskState").GetString(),
                taskLength = a.GetProperty("task").GetString()!.Length }), WorkshopProtocol.Json));
            if (agents.EnumerateArray().Any(a => a.GetProperty("taskState").GetString() == "error")) {
                var indexes = (System.Collections.IDictionary)typeof(CodeWorkshop).GetField("subagentTasks", BindingFlags.Instance | BindingFlags.NonPublic)!.GetValue(service)!;
                var index = indexes[parent]!;
                Console.WriteLine(index.GetType().GetField("Failure", BindingFlags.Instance | BindingFlags.NonPublic)!.GetValue(index));
            }
            Check(agents.EnumerateArray().All(a => a.GetProperty("taskState").GetString() == "ready"), "A live assignment was not recovered");
        } finally { if (Directory.Exists(directory)) Directory.Delete(directory, true); }
    }

    internal static async Task RunAsync()
    {
        var directory = Path.Combine(Path.GetTempPath(), "hako-sidechat-" + Guid.NewGuid().ToString("N"));
        var code = Path.Combine(directory, "Code");
        var project = Path.Combine(code, "fixture");
        var storage = Path.Combine(directory, "state");
        Directory.CreateDirectory(Path.Combine(project, ".git"));
        Directory.CreateDirectory(Path.Combine(directory, "sessions"));
        var taskFile = Path.Combine(directory, "sessions", "parent.jsonl");
        string RecordedCall(string id, string name, string message) => Json(new { type = "response_item", payload = new {
            type = "function_call", call_id = id, name, arguments = Json(new { message }).GetRawText() } }).GetRawText() + "\n";
        File.WriteAllText(taskFile, Json(new { type = "session_meta", payload = new { id = Parent } }).GetRawText() + "\n"
            + Json(new { type = "compacted", payload = new { text = new string('x', 150000) } }).GetRawText() + "\n"
            + RecordedCall("spawn-task", "spawn_agent", TaskText) + RecordedCall("message-task", "send_message", "补充要求"));
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
            var activity = CodeWorkshop.Item(Json(new { id = "dispatch", type = "collabAgentToolCall", tool = "spawnAgent", prompt = "Inspect", receiverThreadIds = new[] { Agent },
                agentsStates = new Dictionary<string, object> { [Agent] = new { status = "running", message = "Checking" } } }))!;
            Check(activity.Kind == "subagents" && activity.Agents is { Length: 1 } && activity.Agents[0].AgentId == Agent &&
                activity.Agents[0].Task == "Inspect" && activity.Agents[0].State == "running", "Native dispatch metadata was discarded");
            var finishedActivity = CodeWorkshop.Item(Json(new { id = "finish", type = "subAgentActivity", kind = "completed", agentThreadId = Agent }))!;
            Check(finishedActivity.Agents![0].State == "completed", "Native child completion must reach the main transcript");
            Check(CodeWorkshop.Item(Json(new { id = "bad", type = "subAgentActivity", kind = "started", agentThreadId = "invalid" })) is null,
                "Malformed child identities must not create task cards");
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
                Check(agent.GetProperty("turn").GetProperty("durationMs").GetInt64() == 128000, "Subagent list lost native turn duration");
                Check(agent.GetProperty("name").GetString() == "Darwin" && agent.GetProperty("role").GetString() == "explorer"
                    && agent.GetProperty("model").GetString() == "fixture-model", "Subagent metadata was lost");
                for (var attempt = 0; attempt < 100 && agent.GetProperty("taskState").GetString() == "loading"; attempt++) {
                    await Task.Delay(10);
                    agents = Json((await service.SubagentsAsync(Json(new { threadId = Parent, applicationId }), default))!);
                    agent = agents.GetProperty("agents")[0];
                }
                Check(agent.GetProperty("taskState").GetString() == "ready" && agent.GetProperty("task").GetString() == CodexJson.Clip(TaskText, 160),
                    "Empty preview hid the real spawn assignment");
                async Task<Dictionary<string, string>> Tasks() {
                    var text = new Dictionary<string, string>(); string? cursor = null;
                    do {
                        var page = Json((await service.SubagentTaskReadAsync(Json(new { threadId = Parent, applicationId, agentId = Agent, cursor }), default))!);
                        Check(JsonSerializer.SerializeToUtf8Bytes(page, WorkshopProtocol.Json).Length < 56 * 1024, "Task page exceeds transport budget");
                        foreach (var chunk in page.GetProperty("entries").EnumerateArray()) {
                            var message = chunk.GetProperty("messageId").GetString()!;
                            var part = chunk.GetProperty("text").GetString()!;
                            text.TryGetValue(message, out var previous); previous ??= "";
                            Check(chunk.GetProperty("offset").GetInt32() == previous.Length, "Task chunks skipped or repeated text");
                            Check(part.Length == 0 || (!char.IsLowSurrogate(part[0]) && !char.IsHighSurrogate(part[^1])), "Task chunk split a Unicode scalar");
                            text[message] = previous + part;
                        }
                        cursor = page.GetProperty("nextCursor").GetString();
                    } while (cursor is not null);
                    return text;
                }
                var assignments = await Tasks();
                Check(assignments.Count == 3 && assignments["spawn-task"] == TaskText && assignments["followup-task"] == "追加检查" && assignments["message-task"] == "补充要求",
                    "Assignments lost full text/followups or included inherited/failed calls");
                var filtered = Json((await service.SubagentTaskReadAsync(Json(new { threadId = Parent, applicationId, agentId = Agent,
                    messageIds = new[] { "followup-task" } }), default))!);
                Check(filtered.GetProperty("entries").GetArrayLength() == 1 &&
                    filtered.GetProperty("entries")[0].GetProperty("text").GetString() == "追加检查",
                    "Inline task details included instructions from a different assignment");
                var absent = Json((await service.SubagentTaskReadAsync(Json(new { threadId = Parent, applicationId, agentId = Agent,
                    messageIds = new[] { "another-round" } }), default))!);
                Check(absent.GetProperty("entries").GetArrayLength() == 0, "Unmatched round filters leaked older instructions");
                var scans = File.ReadAllText(Path.Combine(project, "assignment-reads"));
                await Tasks();
                Check(scans == File.ReadAllText(Path.Combine(project, "assignment-reads")), "Unchanged task descriptions were rescanned");
                var partial = RecordedCall("second-followup", "followup_task", "继续执行同一个子代理");
                File.AppendAllText(taskFile, partial[..(partial.Length / 2)]);
                File.WriteAllText(Path.Combine(project, "assignment-updated"), "yes");
                await service.SubagentsAsync(Json(new { threadId = Parent, applicationId }), default);
                await Task.Delay(50);
                Check(!(await Tasks()).ContainsKey("second-followup"), "An incomplete history line became an instruction");
                File.AppendAllText(taskFile, partial[(partial.Length / 2)..]);
                for (var attempt = 0; attempt < 100; attempt++) {
                    await service.SubagentsAsync(Json(new { threadId = Parent, applicationId }), default);
                    await Task.Delay(10);
                    assignments = await Tasks();
                    if (assignments.ContainsKey("second-followup")) break;
                }
                Check(assignments.Count == 4 && assignments["spawn-task"] == TaskText && assignments["second-followup"] == "继续执行同一个子代理",
                    "Reusing a child overwrote its original task or lost the next instruction");
                Check(!File.Exists(Path.Combine(project, "fork-count")), "Reading tasks resumed or forked an agent");
                try {
                    await service.SubagentTaskReadAsync(Json(new { threadId = Parent, applicationId, agentId = Child }), default);
                    throw new Exception("An unrelated child's assignments were read");
                } catch (WorkshopException error) when (error.Code == "codex_subagent_invalid") { }
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
            object Thread(string threadId) => new { id = threadId, cwd = project, name = "Design", preview = threadId == Agent ? "" : "Discussion",
                path = @"\\?\" + Path.Combine(Path.GetDirectoryName(Path.GetDirectoryName(project))!, "sessions", "parent.jsonl"),
                updatedAt = threadId == Agent && File.Exists(Path.Combine(project, "assignment-updated")) ? 1001L : 1000L, recencyAt = 1000L,
                parentThreadId = threadId == Agent ? Parent : (string?)null,
                agentNickname = threadId == Agent ? "Darwin" : null, agentRole = "explorer", model = "fixture-model", reasoningEffort = "high",
                source = new { subAgent = new { thread_spawn = new { parent_thread_id = Parent, depth = 1 } } },
                status = new { type = threadId == Parent ? "active" : "idle" } };
            object AssignmentItems() {
                var counter = Path.Combine(project, "assignment-reads");
                File.WriteAllText(counter, (File.Exists(counter) ? int.Parse(File.ReadAllText(counter)) + 1 : 1).ToString());
                object Item(string key, string tool, string prompt, string sender = Parent, string status = "completed") => new {
                    turnId = "parent-turn", item = new { id = key, type = "collabAgentToolCall", tool, prompt, senderThreadId = sender,
                        receiverThreadIds = new[] { Agent }, status } };
                object Activity(string key, string kind) => new { turnId = "parent-turn", item = new {
                    id = key, type = "subAgentActivity", kind, agentThreadId = Agent, agentPath = "/root/fixture" } };
                var items = new List<object> { Item("inherited-task", "spawnAgent", "其他会话的任务", Child),
                    Item("failed-task", "spawnAgent", "未成功分派", status: "failed"), Activity("spawn-task", "started"),
                    Item("followup-task", "followupTask", "追加检查"), Activity("message-task", "interacted") };
                if (File.Exists(Path.Combine(project, "assignment-updated"))) items.Add(Activity("second-followup", "interacted"));
                if (CodexJson.Text(p, "sortDirection") == "desc") items.Reverse();
                return items.ToArray();
            }
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
                "thread/turns/list" => new { data = new[] { new { id = id == Parent ? "parent-turn" : turnId, status = id == Parent ? "inProgress" : "completed",
                    startedAt = 1000L, completedAt = 1128L, durationMs = 128000L, items = Array.Empty<object>() } }, nextCursor = (string?)null },
                "thread/items/list" => new { data = id == Parent ? (object[])AssignmentItems() : own.ValueKind == JsonValueKind.Undefined ? new object[] {
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
