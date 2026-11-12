using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Threading;
using System.Threading.Tasks;
using Hako.Core;

namespace Hako.Platform;

internal sealed record WorkshopQuestion(string Id, string Question, string[] Options);
internal sealed record WorkshopApproval(string Id, string Kind, string Detail, WorkshopQuestion[] Questions);

internal sealed class WorkshopJob
{
    public string Id { get; set; } = "";
    public string Fingerprint { get; set; } = "";
    public string ApplicationId { get; set; } = "";
    public string Cwd { get; set; } = "";
    public string? ThreadId { get; set; }
    public string? TurnId { get; set; }
    public string State { get; set; } = "starting";
    public string? Message { get; set; }
    public long StartedAt { get; set; } = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
    public bool Submitted { get; set; }
    public string? RootId { get; set; }
    public string InputMessage { get; set; } = "";
    public string[] ImageIds { get; set; } = [];
    public string Model { get; set; } = "";
    public string Permission { get; set; } = "auto";
    public string ServiceTier { get; set; } = "";
    public int Revision { get; set; }
    public long QueueOrder { get; set; }
    public string? NotificationScope { get; set; }
    public long FinishedAt { get; set; }
    public bool NotificationAcknowledged { get; set; }
    public Dictionary<string, string> Commands { get; set; } = new();
    [JsonIgnore] public Task? Worker { get; set; }
    [JsonIgnore] public CodexAppServer? Server { get; set; }
    [JsonIgnore] public TaskCompletionSource<bool> Completed { get; set; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
    [JsonIgnore] public Dictionary<string, (JsonElement RpcId, WorkshopApproval Approval)> Approvals { get; } = new();
    [JsonIgnore] public HashSet<string> Answered { get; } = new();
    [JsonIgnore] public SemaphoreSlim Control { get; } = new(1, 1);
    [JsonIgnore] public bool StopRequested { get; set; }
    [JsonIgnore] public string Outcome { get; set; } = "completed";
    [JsonIgnore] public bool Active => State is "starting" or "running" or "waiting" or "stopping" or "finishing";
}

internal sealed partial class CodeWorkshop
{
    private string JobPath(string id) => Path.Combine(storage, id + ".json");
    private string EventPath(string id) => Path.Combine(storage, id + ".jsonl");
    private static string OperationId(JsonElement parameters, string key = "operationId") =>
        Guid.TryParse(CodexJson.Required(parameters, key, 36), out var id) ? id.ToString("D") : throw CodexJson.Invalid();

    private WorkshopJob GetJob(string id)
    {
        if (jobs.TryGetValue(id, out var existing)) return existing;
        if (!File.Exists(JobPath(id))) throw new WorkshopException("codex_operation_missing", "任务记录不存在，请查看会话历史确认发送结果。");
        var job = JsonSerializer.Deserialize<WorkshopJob>(File.ReadAllBytes(JobPath(id)), WorkshopProtocol.Json)
            ?? throw new InvalidDataException("代码工坊任务记录损坏。");
        if (job.Id != id) throw new InvalidDataException("代码工坊任务 ID 无效。");
        if (job.Active)
        {
            job.State = "unknown";
            job.Message = "Agent 已重新启动，请查看会话历史核对这一轮的执行结果。";
            Persist(job);
        }
        else if (job.State is "queued" or "paused")
        {
            job.State = "paused";
            job.Message = "Agent 已重新启动，排队消息已保留，等待手动发送。";
            Persist(job);
        }
        else if (job.State == "steering") { job.State = "unknown"; Persist(job); }
        jobs.Add(id, job);
        return job;
    }

    private void Persist(WorkshopJob job)
    {
        if (TerminalState(job.State) && job.FinishedAt == 0)
            job.FinishedAt = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
        Directory.CreateDirectory(storage);
        var temporary = JobPath(job.Id) + ".tmp";
        File.WriteAllBytes(temporary, JsonSerializer.SerializeToUtf8Bytes(job, WorkshopProtocol.Json));
        File.Move(temporary, JobPath(job.Id), true);
        SignalChange();
    }

    private void Append(WorkshopJob job, WorkshopEvent entry)
    {
        Directory.CreateDirectory(storage);
        File.AppendAllText(EventPath(job.RootId ?? job.Id), JsonSerializer.Serialize(entry, WorkshopProtocol.Json) + "\n", new UTF8Encoding(false));
        if (job.ThreadId is not null) DiscoverArtifacts(job.ThreadId, job.Cwd, [entry]);
        SignalChange();
    }

    public Task<object?> StartAsync(JsonElement parameters, CancellationToken token)
    {
        CodexJson.Keys(parameters, "requestId", "applicationId", "threadId", "name", "message", "model", "permission", "imageIds", "serviceTier");
        var id = OperationId(parameters, "requestId");
        var applicationId = CodexJson.Required(parameters, "applicationId", 16);
        var cwd = ResolveApplication(applicationId);
        var images = ImageIds(parameters);
        var message = CodexJson.Text(parameters, "message");
        if (message.Length > 4000 || string.IsNullOrWhiteSpace(message) && images.Length == 0) throw CodexJson.Invalid();
        var model = CodexJson.Text(parameters, "model");
        if (model.Length > 200) throw CodexJson.Invalid();
        var serviceTier = CodexJson.Text(parameters, "serviceTier");
        if (serviceTier.Length > 100) throw CodexJson.Invalid();
        var permission = CodexJson.Text(parameters, "permission");
        if (permission.Length == 0) permission = "auto";
        if (permission is not ("ask" or "auto" or "full" or "custom")) throw CodexJson.Invalid();
        var threadId = CodexJson.Text(parameters, "threadId");
        if (threadId.Length > 0 && !Guid.TryParse(threadId, out _)) throw CodexJson.Invalid();
        var name = CodexJson.Text(parameters, "name");
        if (name.Length > 120) throw CodexJson.Invalid();
        var identity = applicationId + "\n" + threadId + "\n" + name + "\n" + message;
        foreach (var key in new[] { "model", "permission", "imageIds", "serviceTier" })
            if (parameters.TryGetProperty(key, out var option)) identity += "\n" + key + ":" + option.GetRawText();
        var fingerprint = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(identity)));
        token.ThrowIfCancellationRequested();
        lock (gate)
        {
            RecoverJobs();
            if (jobs.ContainsKey(id) || File.Exists(JobPath(id)))
            {
                var old = GetJob(id);
                if (old.Fingerprint != fingerprint) throw new WorkshopException("codex_request_conflict", "请求 ID 已用于其他消息，请先确认原消息结果。");
                return Task.FromResult<object?>(Summary(old));
            }
            if (threadId.Length > 0 && changingArchive.Contains(threadId) || jobs.Values.Count(job => job.Active) >= 3 ||
                threadId.Length > 0 && jobs.Values.Any(job => (job.Active || job.State is "queued" or "paused" or "steering") && job.ThreadId == threadId))
                throw new WorkshopException("codex_busy", "此会话已有任务，或电脑的 Codex 并发任务已满。");
            if (images.Any(image => !File.Exists(UploadPath(image))))
                throw new WorkshopException("codex_image_missing", "图片尚未上传完成，请重新发送。");
            var job = new WorkshopJob { Id = id, Fingerprint = fingerprint, ApplicationId = applicationId, Cwd = cwd,
                NotificationScope = notificationScope,
                ThreadId = threadId.Length > 0 ? threadId : null, InputMessage = message, ImageIds = images,
                Model = model, Permission = permission, ServiceTier = serviceTier, QueueOrder = DateTime.UtcNow.Ticks };
            Persist(job);
            jobs.Add(id, job);
            try { Append(job, new("item", id, message + (images.Length > 0 ? $"\n[图片 × {images.Length}]" : ""), "user")); }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException)
            {
                job.State = "failed";
                job.Message = "电脑无法保存消息，任务尚未发送，请检查磁盘空间和目录权限。";
                try { Persist(job); } catch (IOException) { }
                throw new WorkshopException("codex_storage_failed", job.Message);
            }
            job.Worker = Task.Run(() => ExecuteAsync(job, name, message, model, permission, images, serviceTier));
            return Task.FromResult<object?>(Summary(job));
        }
    }

    private static object Summary(WorkshopJob job) => new { job.Id, job.ApplicationId, job.ThreadId, job.TurnId, job.State, job.Message, job.StartedAt };

    private async Task ExecuteAsync(WorkshopJob job, string name, string message, string model, string permission, string[] images, string serviceTier)
    {
        try
        {
            await using (var server = await startServer(stopping.Token))
            {
                job.Server = server;
                server.Event += value => Receive(job, value);
                var options = ThreadOptions(permission);
                if (model.Length > 0) options["model"] = model;
                if (serviceTier.Length > 0) options["serviceTier"] = serviceTier;
                if (job.ThreadId is null)
                {
                    options["cwd"] = job.Cwd;
                    var reply = await server.RequestAsync("thread/start", options, stopping.Token);
                    lock (gate)
                    {
                        job.ThreadId = CodexJson.Text(CodexJson.Field(reply, "thread"), "id");
                        if (!Guid.TryParse(job.ThreadId, out _)) throw new InvalidDataException("Codex 未返回会话 ID。");
                        Persist(job);
                    }
                    if (name.Length > 0) await server.RequestAsync("thread/name/set", new { threadId = job.ThreadId, name }, stopping.Token);
                }
                else
                {
                    var thread = await ThreadAsync(job.ThreadId, false, stopping.Token);
                    var cwd = CodexJson.Text(thread, "cwd");
                    if (ApplicationFor(cwd)?.Id != job.ApplicationId) throw new WorkshopException("codex_workspace_invalid", "会话与所选应用不一致，请刷新会话列表。");
                    job.Cwd = cwd;
                    options["threadId"] = job.ThreadId;
                    options["excludeTurns"] = true;
                    await server.RequestAsync("thread/resume", options, stopping.Token);
                }
                lock (gate)
                {
                    if (job.StopRequested) throw new OperationCanceledException();
                    job.Submitted = true;
                    job.State = "running";
                    Persist(job);
                }
                var input = new List<object>();
                if (!string.IsNullOrWhiteSpace(message)) input.Add(new { type = "text", text = message });
                input.AddRange(images.Select(image => (object)new { type = "localImage", path = UploadPath(image) }));
                var turnOptions = new Dictionary<string, object> { ["threadId"] = job.ThreadId!, ["clientUserMessageId"] = job.Id, ["input"] = input };
                if (model.Length > 0) turnOptions["model"] = model;
                if (serviceTier.Length > 0) turnOptions["serviceTier"] = serviceTier;
                var turn = await server.RequestAsync("turn/start", turnOptions, stopping.Token);
                lock (gate)
                {
                    job.TurnId = CodexJson.Text(CodexJson.Field(turn, "turn"), "id");
                    Persist(job);
                }
                if (job.StopRequested) await InterruptAsync(job, stopping.Token);
                await job.Completed.Task.WaitAsync(stopping.Token);
                // A steering RPC owns Control until its result has been recorded.
                await job.Control.WaitAsync(stopping.Token);
                job.Control.Release();
            }
            // Disposal closes the worker's thread writer before reporting handoff readiness.
            lock (gate)
            {
                if (job.State == "finishing") job.State = job.Outcome;
                job.Server = null;
                job.Approvals.Clear();
                Persist(job);
                if (job.RootId is not null) AppendFollowup(job);
            }
        }
        catch (Exception e)
        {
            lock (gate)
            {
                job.Server = null;
                job.Approvals.Clear();
                var writerConflict = e.Message.Contains("active writer", StringComparison.OrdinalIgnoreCase) || e.Message.Contains("thread-store conflict", StringComparison.OrdinalIgnoreCase);
                job.State = writerConflict || !job.Submitted ? "failed" : "unknown";
                job.Outcome = job.State;
                job.Message = writerConflict ? "桌面版仍占用此会话。释放会话后，再发送新消息。" :
                    e is WorkshopException action ? action.Message :
                    job.Submitted ? "任务结果尚未确认，请先刷新会话历史。此消息不会自动重发。" :
                    e is OperationCanceledException ? "任务已在发送前停止。" : "Codex 未能开始任务，请检查本机登录和配置后重试。";
                try
                {
                    Append(job, new("notice", "error-" + job.Id, job.Message));
                    Persist(job);
                    if (job.RootId is not null) AppendFollowup(job);
                }
                catch (Exception storageError) when (storageError is IOException or UnauthorizedAccessException)
                { job.Message += " 本机任务记录无法更新，请核对 Codex 原会话。"; }
            }
        }
    }

    private void Receive(WorkshopJob job, JsonElement message)
    {
        lock (gate)
        {
            if (!job.Active || job.State == "finishing") return;
            var method = CodexJson.Text(message, "method");
            var parameters = CodexJson.Field(message, "params");
            if (job.TurnId is null && CodexJson.Text(parameters, "turnId") is { Length: > 0 } notifiedTurn)
                job.TurnId = notifiedTurn;
            if (message.TryGetProperty("id", out var rpcId))
            {
                var kind = method switch
                {
                    "item/commandExecution/requestApproval" => "command",
                    "item/fileChange/requestApproval" => "files",
                    "item/tool/requestUserInput" => "question",
                    _ => "unsupported"
                };
                if (kind == "unsupported")
                {
                    Append(job, new("notice", Guid.NewGuid().ToString(), "Codex 请求了当前界面不支持的交互，已拒绝该请求。"));
                    _ = job.Server!.RejectAsync(rpcId.Clone(), stopping.Token);
                    return;
                }
                var questions = CodexJson.Items(CodexJson.Field(parameters, "questions")).Take(3).Select(question => new WorkshopQuestion(
                    CodexJson.Text(question, "id"), CodexJson.Clip(CodexJson.Text(question, "question"), 600),
                    CodexJson.Items(CodexJson.Field(question, "options")).Take(8).Select(option => CodexJson.Clip(CodexJson.Text(option, "label"), 120)).ToArray())).ToArray();
                var detail = CodexJson.Text(parameters, "command");
                if (detail.Length == 0) detail = CodexJson.Text(parameters, "reason");
                if (detail.Length == 0) detail = kind == "files" ? "允许本次文件修改？" : "Codex 需要你补充信息。";
                var approval = new WorkshopApproval(Guid.NewGuid().ToString("N"), kind, CodexJson.Clip(detail, 1000), questions);
                job.Approvals.Add(approval.Id, (rpcId.Clone(), approval));
                job.State = "waiting";
                Persist(job);
                return;
            }
            switch (method)
            {
                case "item/agentMessage/delta":
                    var delta = CodexJson.Text(parameters, "delta");
                    for (var offset = 0; offset < delta.Length;)
                    {
                        var chunk = CodexJson.Clip(delta[offset..], 3000);
                        Append(job, new("delta", CodexJson.Text(parameters, "itemId"), chunk, "assistant"));
                        offset += chunk.Length;
                    }
                    break;
                case "item/started":
                case "item/completed":
                    if (job.ThreadId is not null) DiscoverItemArtifacts(job.ThreadId, job.Cwd, CodexJson.Field(parameters, "item"));
                    if (Item(CodexJson.Field(parameters, "item")) is { } entry && entry.Role != "user") Append(job, entry);
                    break;
                case "turn/completed":
                    var turn = CodexJson.Field(parameters, "turn");
                    var status = CodexJson.Text(turn, "status");
                    job.Outcome = status == "completed" ? "completed" : status == "interrupted" ? "interrupted" : "failed";
                    job.State = "finishing";
                    if (status == "failed") job.Message = CodexJson.Clip(CodexJson.Text(CodexJson.Field(turn, "error"), "message"), 1000);
                    job.Completed.TrySetResult(true);
                    break;
                case "hako/connectionClosed":
                    job.Completed.TrySetException(new IOException("Codex 连接中断。"));
                    break;
            }
        }
    }

    public Task<object?> OperationAsync(JsonElement parameters, CancellationToken token)
    {
        CodexJson.Keys(parameters, "operationId", "cursor");
        var id = OperationId(parameters);
        var field = CodexJson.Field(parameters, "cursor");
        var cursor = field.ValueKind == JsonValueKind.Undefined ? 0 : field.ValueKind == JsonValueKind.Number && field.TryGetInt64(out var number) ? number : -1;
        token.ThrowIfCancellationRequested();
        lock (gate)
        {
            var root = RootJob(GetJob(id));
            var job = CurrentJob(root);
            var events = new List<WorkshopEvent>();
            var lineSizes = new List<int>();
            using var stream = new FileStream(EventPath(root.Id), FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.Read);
            if (cursor < 0 || cursor > stream.Length) throw CodexJson.Invalid();
            stream.Position = cursor;
            using var reader = new StreamReader(stream, Encoding.UTF8);
            var bytes = 0;
            while (events.Count < 32 && reader.ReadLine() is { } line)
            {
                var size = Encoding.UTF8.GetByteCount(line) + 1;
                if (bytes + size > 35 * 1024 && events.Count > 0) break;
                events.Add(JsonSerializer.Deserialize<WorkshopEvent>(line, WorkshopProtocol.Json) ?? throw new InvalidDataException());
                lineSizes.Add(size);
                cursor += size; bytes += size;
            }
            var approvals = job.Approvals.Values.Select(value => value.Approval).Take(1).ToArray();
            var files = artifacts.Values.Where(value => value.ThreadId == job.ThreadId).Take(20).ToArray();
            object Page() => new
            {
                operation = GroupSummary(root), events, cursor, hasMore = cursor < stream.Length,
                approvals, artifacts = files, followups = FollowupSummaries(root)
            };
            while (JsonSerializer.SerializeToUtf8Bytes(Page(), WorkshopProtocol.Json).Length > 56 * 1024)
            {
                if (files.Length > 0) { files = files[..^1]; continue; }
                if (events.Count == 0) throw new WorkshopException("codex_response_large", "Codex 的交互请求超出消息限制，请在电脑上处理该请求。");
                cursor -= lineSizes[^1];
                lineSizes.RemoveAt(lineSizes.Count - 1);
                events.RemoveAt(events.Count - 1);
            }
            return Task.FromResult<object?>(Page());
        }
    }

    public async Task<object?> AnswerAsync(JsonElement parameters, CancellationToken token)
    {
        CodexJson.Keys(parameters, "operationId", "approvalId", "decision", "answers");
        var id = OperationId(parameters);
        var approvalId = CodexJson.Required(parameters, "approvalId", 32);
        WorkshopJob job;
        lock (gate)
        {
            var root = RootJob(GetJob(id));
            job = Group(root).FirstOrDefault(value => value.Approvals.ContainsKey(approvalId) || value.Answered.Contains(approvalId)) ?? CurrentJob(root);
        }
        await job.Control.WaitAsync(token);
        try
        {
            (JsonElement RpcId, WorkshopApproval Approval) pending;
            lock (gate)
            {
                if (job.Answered.Contains(approvalId)) return Summary(job);
                if (!job.Approvals.TryGetValue(approvalId, out pending) || job.Server is null)
                    throw new WorkshopException("codex_approval_expired", "此请求已结束，请刷新任务状态。");
            }
            object response;
            if (pending.Approval.Kind == "question")
            {
                var answers = CodexJson.Field(parameters, "answers");
                if (answers.ValueKind != JsonValueKind.Object || pending.Approval.Questions.Any(question =>
                    string.IsNullOrWhiteSpace(CodexJson.Text(answers, question.Id)))) throw CodexJson.Invalid();
                response = new { answers = pending.Approval.Questions.ToDictionary(question => question.Id,
                    question => new { answers = new[] { CodexJson.Required(answers, question.Id, 2000) } }) };
            }
            else
            {
                var decision = CodexJson.Text(parameters, "decision");
                if (decision is not ("accept" or "decline")) throw CodexJson.Invalid();
                response = new { decision };
            }
            lock (gate)
            {
                job.Answered.Add(approvalId);
                job.Approvals.Remove(approvalId);
                job.State = job.Approvals.Count > 0 ? "waiting" : "running";
            }
            try { await job.Server!.ReplyAsync(pending.RpcId, response, stopping.Token); }
            catch (Exception)
            {
                lock (gate) job.Message = "审批回复的发送结果尚未确认，请查看任务进度。";
                throw new WorkshopException("codex_approval_unknown", "审批结果尚未确认，请查看任务进度。");
            }
            lock (gate) { Persist(job); return Summary(job); }
        }
        finally { job.Control.Release(); }
    }

    public async Task<object?> StopAsync(JsonElement parameters, CancellationToken token)
    {
        CodexJson.Keys(parameters, "operationId");
        WorkshopJob job;
        lock (gate)
        {
            var root = RootJob(GetJob(OperationId(parameters)));
            job = CurrentJob(root);
            foreach (var queued in Group(root).Where(value => value.State == "queued"))
            {
                queued.State = "paused"; queued.Revision++; Persist(queued); AppendFollowup(queued);
            }
            if (!job.Active || job.StopRequested) return Summary(job);
            job.StopRequested = true;
        }
        try { if (job.TurnId is not null) await InterruptAsync(job, stopping.Token); }
        catch (Exception)
        {
            lock (gate) { job.StopRequested = false; Persist(job); }
            throw new WorkshopException("codex_stop_unknown", "停止请求结果尚未确认，请检查任务进度后重试。");
        }
        lock (gate) { Persist(job); return Summary(job); }
    }

    private static async Task InterruptAsync(WorkshopJob job, CancellationToken token)
    {
        if (job.Server is not null) await job.Server.RequestAsync("turn/interrupt", new { threadId = job.ThreadId, turnId = job.TurnId }, token);
    }
}
