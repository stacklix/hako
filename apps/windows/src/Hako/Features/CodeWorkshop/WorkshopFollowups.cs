using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Hako.Core;

namespace Hako.Platform;

internal sealed partial class CodeWorkshop
{
    private WorkshopJob RootJob(WorkshopJob job) => job.RootId is null ? job : GetJob(job.RootId);
    private IEnumerable<WorkshopJob> Group(WorkshopJob root) => jobs.Values.Where(value => value.Id == root.Id || value.RootId == root.Id);
    private WorkshopJob CurrentJob(WorkshopJob root) => Group(root).Where(value => value.Active)
        .OrderByDescending(value => value.QueueOrder).FirstOrDefault() ??
        Group(root).Where(value => value.State == "queued").OrderBy(value => value.QueueOrder).FirstOrDefault() ??
        Group(root).Where(value => value.State is not ("paused" or "cancelled" or "steered"))
            .OrderByDescending(value => value.QueueOrder).FirstOrDefault() ?? root;
    private object GroupSummary(WorkshopJob root)
    {
        var current = CurrentJob(root);
        return new { root.Id, root.ApplicationId, threadId = current.ThreadId ?? root.ThreadId,
            current.TurnId, state = current.State == "queued" ? "starting" : current.State,
            current.Message, root.StartedAt };
    }
    private object FollowupSummary(WorkshopJob job) => new { job.Id, message = job.InputMessage,
        job.ImageIds, state = job.State == "completed" ? "sent" : job.State, job.Revision, job.QueueOrder, detail = job.Message, job.QuestionId };
    private object[] FollowupSummaries(WorkshopJob root) => Group(root).Where(value => value.RootId is not null)
        .OrderBy(value => value.QueueOrder).Select(value => (object)new { value.Id, value.State, value.Revision, value.ImageIds }).ToArray();
    private void AppendFollowup(WorkshopJob job) => Append(job, new("followup", job.Id,
        job.InputMessage + (job.ImageIds.Length > 0 ? $"\n[图片 × {job.ImageIds.Length}]" : ""), "user", job.State, QuestionId: job.QuestionId));
    private static string Digest(string value) => Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(value)));

    public Task<object?> QueueAsync(JsonElement parameters, CancellationToken token)
    {
        CodexJson.Keys(parameters, "operationId", "requestId", "message", "imageIds", "questionId");
        var operationId = OperationId(parameters);
        var id = OperationId(parameters, "requestId");
        var message = CodexJson.Text(parameters, "message");
        var images = ImageIds(parameters);
        var questionId = CodexJson.Text(parameters, "questionId");
        if (questionId.Length > 200) throw CodexJson.Invalid();
        if (message.Length > 4000 || string.IsNullOrWhiteSpace(message) && images.Length == 0) throw CodexJson.Invalid();
        token.ThrowIfCancellationRequested();
        lock (gate)
        {
            RecoverJobs();
            var root = RootJob(GetJob(operationId));
            var fingerprint = Digest(root.Id + "\n" + message + "\n" + string.Join(",", images) + (questionId.Length > 0 ? "\n" + questionId : ""));
            if (jobs.ContainsKey(id) || File.Exists(JobPath(id)))
            {
                var existing = GetJob(id);
                if (existing.RootId != root.Id || existing.Fingerprint != fingerprint)
                    throw new WorkshopException("codex_request_conflict", "请求 ID 已用于其他消息。");
                return Task.FromResult<object?>(FollowupSummary(existing));
            }
            if (root.ThreadId is not null && changingArchive.Contains(root.ThreadId))
                throw new WorkshopException("codex_busy", "会话正在归档，请稍后再发送消息。");
            if (Group(root).Count(value => value.RootId is not null) >= 30)
                throw new WorkshopException("codex_queue_full", "本轮后续消息过多，请等待本轮完成后再发送。");
            if (images.Any(image => !File.Exists(UploadPath(image))))
                throw new WorkshopException("codex_image_missing", "图片尚未上传完成，请重试原消息。");
            var current = CurrentJob(root);
            var predecessor = Group(root).Where(value => value.Worker is not null && value.State is not ("paused" or "cancelled"))
                .OrderByDescending(value => value.QueueOrder).FirstOrDefault() ?? root;
            var paused = !current.Active && current.State is not ("queued" or "completed");
            var job = new WorkshopJob { Id = id, RootId = root.Id, Fingerprint = fingerprint,
                NotificationScope = notificationScope, QuestionId = questionId.Length > 0 ? questionId : null,
                ApplicationId = root.ApplicationId, Cwd = root.Cwd, ThreadId = current.ThreadId ?? root.ThreadId,
                SessionName = current.SessionName,
                InputMessage = message, ImageIds = images, Model = current.Model, Permission = current.Permission,
                ServiceTier = current.ServiceTier, State = paused ? "paused" : "queued",
                QueueOrder = Math.Max(DateTime.UtcNow.Ticks, Group(root).Max(value => value.QueueOrder) + 1) };
            Persist(job); jobs.Add(id, job); AppendFollowup(job);
            if (!paused) job.Worker = Task.Run(() => ExecuteQueuedAsync(job, predecessor));
            return Task.FromResult<object?>(FollowupSummary(job));
        }
    }

    private async Task ExecuteQueuedAsync(WorkshopJob job, WorkshopJob predecessor)
    {
        try
        {
            if (predecessor.Worker is not null) await predecessor.Worker.WaitAsync(stopping.Token);
            lock (gate)
            {
                if (job.State != "queued") { job.Outcome = predecessor.Outcome; return; }
                var root = RootJob(job);
                if (predecessor.State is not ("completed" or "cancelled" or "steered") || root.StopRequested ||
                    predecessor.Outcome != "completed" ||
                    jobs.Values.Any(value => value.Active && value.ThreadId == root.ThreadId))
                { job.State = "paused"; job.Revision++; Persist(job); AppendFollowup(job); return; }
                job.ThreadId = root.ThreadId;
                job.State = "starting"; job.Revision++; Persist(job); AppendFollowup(job);
            }
            await ExecuteAsync(job, "", job.InputMessage, job.Model, job.Permission, job.ImageIds, job.ServiceTier);
        }
        catch (OperationCanceledException)
        {
            lock (gate) { if (job.State == "queued") { job.State = "paused"; Persist(job); AppendFollowup(job); } }
        }
    }

    public Task<object?> UpdateMessageAsync(JsonElement parameters, CancellationToken token) => MutateMessageAsync(parameters, "update", token);
    public Task<object?> CancelMessageAsync(JsonElement parameters, CancellationToken token) => MutateMessageAsync(parameters, "cancel", token);
    public Task<object?> SteerMessageAsync(JsonElement parameters, CancellationToken token) => MutateMessageAsync(parameters, "steer", token);

    private async Task<object?> MutateMessageAsync(JsonElement parameters, string action, CancellationToken token)
    {
        if (action == "update") CodexJson.Keys(parameters, "operationId", "messageId", "requestId", "revision", "message");
        else CodexJson.Keys(parameters, "operationId", "messageId", "requestId", "revision");
        var rootId = OperationId(parameters);
        var messageId = OperationId(parameters, "messageId");
        var requestId = OperationId(parameters, "requestId");
        var revisionField = CodexJson.Field(parameters, "revision");
        if (revisionField.ValueKind != JsonValueKind.Number || !revisionField.TryGetInt32(out var revision) || revision < 0) throw CodexJson.Invalid();
        var text = CodexJson.Text(parameters, "message");
        if (action == "update" && text.Length > 4000) throw CodexJson.Invalid();
        var identity = Digest(action + "\n" + revision + "\n" + text);
        token.ThrowIfCancellationRequested();
        WorkshopJob job, root, current;
        lock (gate)
        {
            root = RootJob(GetJob(rootId)); job = GetJob(messageId);
            if (job.RootId != root.Id) throw CodexJson.Invalid();
            if (job.Commands.TryGetValue(requestId, out var previous))
            {
                if (previous != identity) throw new WorkshopException("codex_request_conflict", "操作请求 ID 已用于其他内容。");
                return FollowupSummary(job);
            }
            if (job.Revision != revision || job.State is not ("queued" or "paused"))
                throw new WorkshopException("codex_message_changed", "消息状态已经变化，请刷新后再操作。");
            if (action == "update" && string.IsNullOrWhiteSpace(text) && job.ImageIds.Length == 0) throw CodexJson.Invalid();
            current = CurrentJob(root);
            if (action == "steer" && !current.Active && current.State is "completed" or "interrupted" or "failed")
            {
                if (root.ThreadId is null || jobs.Values.Any(value => value.Active && value.ThreadId == root.ThreadId) ||
                    jobs.Values.Count(value => value.Active) >= 3 || Group(root).Any(value => value.State is "unknown" or "steering"))
                    throw new WorkshopException("codex_busy", "请先核对已有任务的状态。");
                var previousWorker = job.Worker;
                root.StopRequested = false; Persist(root);
                job.Commands[requestId] = identity; job.Revision++; job.State = "starting";
                job.ThreadId = root.ThreadId; job.StopRequested = false; job.Submitted = false;
                job.Outcome = "completed";
                job.Completed = new(TaskCreationOptions.RunContinuationsAsynchronously);
                Persist(job); AppendFollowup(job);
                job.Worker = Task.Run(async () =>
                {
                    if (previousWorker is not null) await previousWorker;
                    await ExecuteAsync(job, "", job.InputMessage, job.Model, job.Permission, job.ImageIds, job.ServiceTier);
                });
                return FollowupSummary(job);
            }
            if (action == "steer" && (!current.Active || current.State is "starting" or "finishing" || current.StopRequested || current.TurnId is null))
                throw new WorkshopException("codex_turn_finished", "当前任务已结束或正在收尾，消息仍保留在队列中。");
            job.Commands[requestId] = identity; job.Revision++;
            if (action == "update") job.InputMessage = text;
            if (action == "cancel") job.State = "cancelled";
            if (action == "steer") job.State = "steering";
            Persist(job); AppendFollowup(job);
            if (action != "steer") return FollowupSummary(job);
        }
        // The original command continues even if the phone disconnects.
        await current.Control.WaitAsync(stopping.Token);
        try
        {
            CodexAppServer server;
            string turnId;
            lock (gate)
            {
                if (current.State is not ("running" or "waiting") || current.StopRequested || current.Server is null || current.TurnId is null)
                {
                    job.State = "paused"; Persist(job); AppendFollowup(job); return FollowupSummary(job);
                }
                server = current.Server; turnId = current.TurnId;
            }
            var input = new List<object>();
            if (!string.IsNullOrWhiteSpace(job.InputMessage)) input.Add(new { type = "text", text = job.InputMessage });
            input.AddRange(job.ImageIds.Select(id => (object)new { type = "localImage", path = UploadPath(id) }));
            try
            {
                var result = await server.RequestAsync("turn/steer", new { threadId = current.ThreadId,
                    expectedTurnId = turnId, input, clientUserMessageId = job.Id }, stopping.Token);
                lock (gate)
                {
                    job.State = CodexJson.Text(result, "turnId") == turnId ? "steered" : "unknown";
                    if (job.State == "steered") job.TurnId = turnId;
                    Persist(job); AppendFollowup(job); return FollowupSummary(job);
                }
            }
            catch (Exception e)
            {
                lock (gate)
                {
                    job.State = e is CodexRpcException ? "paused" : "unknown";
                    job.Message = e is CodexRpcException ? "引导未被接收，消息已保留。" : "引导结果尚未确认，请核对原会话，不要重复发送。";
                    Persist(job); AppendFollowup(job); return FollowupSummary(job);
                }
            }
        }
        finally { current.Control.Release(); }
    }
}
