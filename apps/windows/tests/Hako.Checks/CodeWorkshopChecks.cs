using System;
using System.Diagnostics;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Hako.Core;
using Hako.Platform;

internal static class CodeWorkshopChecks
{
    private const string FixtureThread = "11111111-1111-4111-8111-111111111111";
    private static JsonElement Json(object value) => JsonSerializer.SerializeToElement(value, AgentConnection.Json);
    private static JsonElement Result(object? value) => Json(value!);
    private static void Check(bool condition, string message) { if (!condition) throw new Exception(message); }

    public static async Task RunAsync()
    {
        var summarized = CodeWorkshop.SummarizeTurn(Json(new { id = "latest-turn", status = "completed", items = new object[] {
            new { id = "first", type = "userMessage", content = new[] { new { type = "text", text = "First prompt" } } },
            new { id = "last", type = "agentMessage", text = "Latest\n  response" },
            new { id = "tool", type = "commandExecution", command = "Ignored tool", aggregatedOutput = "Ignored output" }
        } }));
        Check(summarized.Preview == "Latest response" && summarized.State == "completed" && summarized.CompletionId == "latest-turn",
            "Latest chat message/completion identity was not selected independently of trailing tools");
        var runningSummary = CodeWorkshop.SummarizeTurn(Json(new { id = "next-turn", status = "inProgress", items = new object[] {
            new { id = "new-user", type = "userMessage", content = new[] { new { type = "text", text = "Newest user message" } } }
        } }));
        Check(runningSummary.Preview == "Newest user message" && runningSummary.State == "running" && runningSummary.CompletionId is null,
            "Running turns must use their latest user message and cannot be marked completed");
        var userItem = Json(new { id = "canonical", type = "userMessage", content = new object[] {
            new { type = "text", text = "Same" }, new { type = "localImage", path = "image.jpg" } } });
        var userJobs = new[] {
            new WorkshopJob { Id = "request-one", TurnId = "turn-one", InputMessage = "Same", ImageIds = ["image"] },
            new WorkshopJob { Id = "request-two", TurnId = "turn-one", InputMessage = "Same", ImageIds = ["image"] }
        };
        var usedMessages = new HashSet<string>();
        var firstUser = CodeWorkshop.HistoryItem(userItem, "turn-one", userJobs, usedMessages)!;
        var secondUser = CodeWorkshop.HistoryItem(userItem, "turn-one", userJobs, usedMessages)!;
        Check(firstUser.Id == "request-one" && firstUser.ReplacesId == "canonical" && firstUser.Text == "Same\n[图片 × 1]",
            "Canonical user message did not reconcile with its durable receipt");
        Check(secondUser.Id == "request-two", "Identical messages in the same turn must remain distinct");
        Check(CodeWorkshop.HistoryItem(userItem, "different-turn", userJobs, new HashSet<string>())!.Id == "canonical",
            "Messages from different turns must not be deduplicated");
        var directory = Path.Combine(Path.GetTempPath(), "hako-workshop-" + Guid.NewGuid().ToString("N"));
        var launch = CodexAppServer.WithArguments(new ProcessStartInfo("codex.exe"));
        Check(launch.ArgumentList.Contains("--enable") && launch.ArgumentList.Contains("default_mode_request_user_input"),
            "Default-mode questions must be enabled for the phone's interactive answer UI");
        var code = Path.Combine(directory, "Code");
        var project = Path.Combine(code, "fixture");
        Directory.CreateDirectory(Path.Combine(project, ".git"));
        var preview = Path.Combine(project, "prototype.html");
        File.WriteAllText(preview, "<div>interactive prototype</div>");
        Task<CodexAppServer> Start(CancellationToken token, bool occupied = false)
        {
            var start = new ProcessStartInfo(Environment.ProcessPath!);
            if (Path.GetFileNameWithoutExtension(Environment.ProcessPath!).Equals("dotnet", StringComparison.OrdinalIgnoreCase))
                start.ArgumentList.Add(typeof(Program).Assembly.Location);
            start.ArgumentList.Add("--codex-workshop-fixture");
            start.Environment["CODEX_WINDOWS_REGISTERED_CORE"] = "1";
            start.Environment["HAKO_CODEX_TEST_PROJECT"] = project;
            if (occupied) start.Environment["HAKO_CODEX_TEST_OCCUPIED"] = "1";
            return CodexAppServer.StartAsync(token, start);
        }
        var storage = Path.Combine(directory, "state");
        try
        {
            string applicationId;
            string requestId;
            await using (var service = new CodeWorkshop(storage, code, Path.Combine(directory, ".codex"), token => Start(token)))
            {
                var catalog = Result(await service.CatalogAsync(Json(new { }), default));
                applicationId = catalog.GetProperty("applications")[0].GetProperty("id").GetString()!;
                Check(catalog.GetProperty("sessions")[0].GetProperty("applicationId").GetString() == applicationId, "Session/application association failed");
                Check(CodexJson.Text(catalog.GetProperty("sessions")[0], "state") == "completed",
                    "An active thread flag must not override its completed latest turn");
                Check(CodexJson.Text(catalog.GetProperty("sessions")[0], "preview") == "Latest fixture reply" &&
                    CodexJson.Text(catalog.GetProperty("sessions")[0], "completionId") == "fixture-turn", "Catalog still used the initial preview");
                var summaryStatus = Path.Combine(project, ".summary-status");
                foreach (var status in new[] { "inProgress", "failed", "interrupted" })
                {
                    File.WriteAllText(summaryStatus, status);
                    var session = Result(await service.CatalogAsync(Json(new { }), default)).GetProperty("sessions")[0];
                    Check(CodexJson.Text(session, "state") == (status == "inProgress" ? "running" : status),
                        "Catalog did not preserve the latest turn state: " + status);
                    Check(CodexJson.Field(session, "completionId").ValueKind == JsonValueKind.Null,
                        "An unfinished or unsuccessful turn acquired a completed unread marker");
                }
                File.Delete(summaryStatus);
                var archiveInFlight = service.ArchiveAsync(Json(new { threadId = FixtureThread, archived = true }), default);
                for (var attempt = 0; attempt < 100 && !File.Exists(Path.Combine(project, ".archive-entered")); attempt++) await Task.Delay(5);
                try { await service.StartAsync(Json(new { requestId = Guid.NewGuid().ToString(), applicationId, threadId = FixtureThread, message = "Blocked while archiving" }), default); throw new Exception("A turn started during archive"); }
                catch (AgentActionException e) when (e.Code == "codex_busy") { }
                Check(Result(await archiveInFlight).GetProperty("archived").GetBoolean(), "Archive response lost its state");
                Check(Result(await service.CatalogAsync(Json(new { }), default)).GetProperty("sessions").GetArrayLength() == 0, "Archived thread stayed in the active list");
                Check(Result(await service.CatalogAsync(Json(new { archived = true }), default)).GetProperty("sessions").GetArrayLength() == 1, "Archived filter did not reach Codex");
                Check(Result(await service.HistoryAsync(Json(new { threadId = FixtureThread }), default)).GetProperty("entries").GetArrayLength() > 0, "Archive destroyed readable history");
                Check(!Result(await service.ArchiveAsync(Json(new { threadId = FixtureThread, archived = false }), default)).GetProperty("archived").GetBoolean(), "Unarchive failed");
                Check(Result(await service.CatalogAsync(Json(new { archived = true }), default)).GetProperty("sessions").GetArrayLength() == 0, "Restored thread stayed in archives");
                Check(Result(await service.CatalogAsync(Json(new { }), default)).GetProperty("sessions").GetArrayLength() == 1, "Restored thread did not return to active list");
                try { await service.ArchiveAsync(Json(new { threadId = "22222222-2222-4222-8222-222222222222", archived = true }), default); throw new Exception("Thread outside Code root was archived"); }
                catch (AgentActionException e) when (e.Code == "codex_workspace_invalid") { }
                try { await service.CatalogAsync(Json(new { archived = "true" }), default); throw new Exception("Non-boolean archive filter accepted"); }
                catch (AgentActionException e) when (e.Code == "invalid_params") { }
                var models = Result(await service.ModelsAsync(Json(new { }), default));
                Check(models.GetProperty("models")[0].GetProperty("supportsImages").GetBoolean(), "Model image capability was lost");
                Check(models.GetProperty("models")[0].GetProperty("serviceTiers")[0].GetProperty("id").GetString() == "priority", "Fast service tier identity was lost");
                var imageId = Guid.NewGuid().ToString();
                var imageBytes = new byte[] { 0xff, 0xd8, 1, 2, 3, 4, 0xff, 0xd9 };
                var digest = Convert.ToHexString(SHA256.HashData(imageBytes));
                var firstChunk = Json(new { uploadId = imageId, offset = 0, total = imageBytes.Length, sha256 = digest, content = Convert.ToBase64String(imageBytes[..4]) });
                Check(!Result(await service.UploadImageAsync(firstChunk, default)).GetProperty("complete").GetBoolean(), "Incomplete image accepted");
                await service.UploadImageAsync(firstChunk, default);
                var lastChunk = Json(new { uploadId = imageId, offset = 4, total = imageBytes.Length, sha256 = digest, content = Convert.ToBase64String(imageBytes[4..]) });
                Check(Result(await service.UploadImageAsync(lastChunk, default)).GetProperty("complete").GetBoolean(), "Image upload did not finish");
                await service.UploadImageAsync(lastChunk, default);
                try { await service.UploadImageAsync(Json(new { uploadId = imageId, offset = 0, total = imageBytes.Length, sha256 = digest, content = Convert.ToBase64String(new byte[] { 1, 2, 3, 4 }) }), default); throw new Exception("Conflicting image bytes accepted"); }
                catch (AgentActionException e) when (e.Code == "codex_upload_conflict") { }
                Check((string)CodeWorkshop.ThreadOptions("auto")["approvalsReviewer"] == "auto_review" &&
                    (string)CodeWorkshop.ThreadOptions("full")["sandbox"] == "danger-full-access" &&
                    (string)CodeWorkshop.ThreadOptions("ask")["approvalsReviewer"] == "user" && CodeWorkshop.ThreadOptions("custom").Count == 0,
                    "Permission presets do not map to App Server policies");
                var history = Result(await service.HistoryAsync(Json(new { threadId = FixtureThread }), default));
                var artifactId = history.GetProperty("artifacts")[0].GetProperty("id").GetString();
                var artifact = Result(await service.ArtifactAsync(Json(new { threadId = FixtureThread, artifactId, offset = 0 }), default));
                Check(System.Text.Encoding.UTF8.GetString(Convert.FromBase64String(artifact.GetProperty("content").GetString()!)).Contains("interactive prototype"), "Artifact retrieval failed");
                try { await service.ArtifactAsync(Json(new { threadId = FixtureThread, artifactId, offset = 0, revision = "changed" }), default); throw new Exception("Changed artifact accepted"); }
                catch (AgentActionException e) when (e.Code == "codex_artifact_changed") { }
                requestId = Guid.NewGuid().ToString();
                var parameters = Json(new { requestId, applicationId, threadId = FixtureThread, name = "Fixture", message = "Run fixture" });
                using var requestLife = new CancellationTokenSource();
                var started = Result(await service.StartAsync(parameters, requestLife.Token));
                requestLife.Cancel();
                Check(Result(await service.StartAsync(parameters, default)).GetProperty("id").GetString() == started.GetProperty("id").GetString(), "Request deduplication failed");
                try { await service.StartAsync(Json(new { requestId, applicationId, threadId = FixtureThread, message = "different" }), default); throw new Exception("Request ID reused for different payload"); }
                catch (AgentActionException e) when (e.Code == "codex_request_conflict") { }
                var waiting = await WaitAsync(service, requestId, "waiting");
                Check(CodexJson.Text(Result(await service.CatalogAsync(Json(new { }), default)).GetProperty("sessions")[0], "state") == "waiting",
                    "An executing job awaiting approval must take precedence over older completed history");
                try { await service.ArchiveAsync(Json(new { threadId = FixtureThread, archived = true }), default); throw new Exception("Running turn was archived"); }
                catch (AgentActionException e) when (e.Code == "codex_busy") { }
                Check(!Result(await service.ArchiveAsync(Json(new { threadId = FixtureThread, archived = false }), default)).GetProperty("archived").GetBoolean(),
                    "Restoring a session must remain possible when pending work exists");
                var queuedId = Guid.NewGuid().ToString();
                using var watchLife = new CancellationTokenSource();
                var firstPush = new TaskCompletionSource<JsonElement>(TaskCreationOptions.RunContinuationsAsynchronously);
                var queuedPush = new TaskCompletionSource<JsonElement>(TaskCreationOptions.RunContinuationsAsynchronously);
                var watch = service.WatchOperationAsync(Json(new { operationId = requestId, cursor = 0L }), page =>
                {
                    firstPush.TrySetResult(page);
                    if (page.GetProperty("followups").EnumerateArray().Any(value => CodexJson.Text(value, "id") == queuedId))
                        queuedPush.TrySetResult(page);
                    return Task.CompletedTask;
                }, watchLife.Token);
                var initialPush = await firstPush.Task.WaitAsync(TimeSpan.FromSeconds(3));
                Check(initialPush.GetProperty("events").GetArrayLength() > 0, "Subscribe did not replay missed events");
                var queueRequest = Json(new { operationId = requestId, requestId = queuedId, message = "Follow-up fixture" });
                var queued = Result(await service.QueueAsync(queueRequest, default));
                var pushedQueue = await queuedPush.Task.WaitAsync(TimeSpan.FromSeconds(3));
                Check(pushedQueue.GetProperty("cursor").GetInt64() > initialPush.GetProperty("cursor").GetInt64(),
                    "A queue mutation did not push a new cursor without a phone query");
                watchLife.Cancel();
                try { await watch; throw new Exception("Cancelled subscription remained active"); }
                catch (OperationCanceledException) { }
                var resumePush = new TaskCompletionSource<JsonElement>(TaskCreationOptions.RunContinuationsAsynchronously);
                using var resumeLife = new CancellationTokenSource();
                var resumedStream = service.WatchOperationAsync(Json(new { operationId = requestId, cursor = pushedQueue.GetProperty("cursor").GetInt64() }),
                    page => { resumePush.TrySetResult(page); return Task.CompletedTask; }, resumeLife.Token);
                Check((await resumePush.Task.WaitAsync(TimeSpan.FromSeconds(3))).GetProperty("events").GetArrayLength() == 0,
                    "Reconnection replayed already consumed deltas");
                resumeLife.Cancel();
                try { await resumedStream; } catch (OperationCanceledException) { }
                Check(CodexJson.Text(queued, "state") == "queued", "Follow-up did not enter queue");
                await service.QueueAsync(queueRequest, default);
                var editId = Guid.NewGuid().ToString();
                var edit = Json(new { operationId = requestId, messageId = queuedId, requestId = editId, revision = 0, message = "Edited follow-up" });
                var edited = Result(await service.UpdateMessageAsync(edit, default));
                Check(CodexJson.Text(edited, "message") == "Edited follow-up" && edited.GetProperty("revision").GetInt32() == 1, "Queued edit was lost");
                await service.UpdateMessageAsync(edit, default);
                try { await service.CancelMessageAsync(Json(new { operationId = requestId, messageId = queuedId, requestId = Guid.NewGuid().ToString(), revision = 0 }), default); throw new Exception("Stale revision accepted"); }
                catch (AgentActionException e) when (e.Code == "codex_message_changed") { }
                var steerId = Guid.NewGuid().ToString();
                var steerRequest = Json(new { operationId = requestId, messageId = queuedId, requestId = steerId, revision = 1 });
                Check(CodexJson.Text(Result(await service.SteerMessageAsync(steerRequest, default)), "state") == "steered", "Queued message was not steered");
                await service.SteerMessageAsync(steerRequest, default);
                var cancelledId = Guid.NewGuid().ToString();
                await service.QueueAsync(Json(new { operationId = requestId, requestId = cancelledId, message = "Cancelled follow-up" }), default);
                await service.CancelMessageAsync(Json(new { operationId = requestId, messageId = cancelledId, requestId = Guid.NewGuid().ToString(), revision = 0 }), default);
                var automaticId = Guid.NewGuid().ToString();
                await service.QueueAsync(Json(new { operationId = requestId, requestId = automaticId, message = "Automatic follow-up" }), default);
                var approval = waiting.GetProperty("approvals")[0].GetProperty("id").GetString();
                try { await service.AnswerAsync(Json(new { operationId = requestId, approvalId = approval, decision = "invalid" }), default); throw new Exception("Invalid approval accepted"); }
                catch (AgentActionException e) when (e.Code == "invalid_params") { }
                Check(Result(await service.OperationAsync(Json(new { operationId = requestId }), default)).GetProperty("approvals").GetArrayLength() == 1, "Invalid response consumed approval");
                var liveCursor = Result(await service.OperationAsync(Json(new { operationId = requestId }), default)).GetProperty("cursor").GetInt64();
                using var liveLife = new CancellationTokenSource();
                var liveDelta = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
                var liveDone = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
                var liveStream = service.WatchOperationAsync(Json(new { operationId = requestId, cursor = liveCursor }), page =>
                {
                    if (page.GetProperty("events").EnumerateArray().Any(value => CodexJson.Text(value, "kind") == "delta"))
                        liveDelta.TrySetResult(true);
                    if (CodexJson.Text(page.GetProperty("operation"), "state") == "completed") liveDone.TrySetResult(true);
                    return Task.CompletedTask;
                }, liveLife.Token);
                await service.AnswerAsync(Json(new { operationId = requestId, approvalId = approval, decision = "accept" }), default);
                await liveDelta.Task.WaitAsync(TimeSpan.FromSeconds(3));
                JsonElement nextTurn = default;
                for (var attempt = 0; attempt < 100; attempt++)
                {
                    nextTurn = Result(await service.OperationAsync(Json(new { operationId = requestId }), default));
                    if (nextTurn.GetProperty("approvals").GetArrayLength() == 1 &&
                        nextTurn.GetProperty("followups").EnumerateArray().Any(value => CodexJson.Text(value, "id") == automaticId && CodexJson.Text(value, "state") is "running" or "waiting")) break;
                    await Task.Delay(30);
                }
                Check(nextTurn.GetProperty("operation").GetProperty("id").GetString() == requestId && nextTurn.GetProperty("approvals").GetArrayLength() == 1, "Queued turn did not keep root operation and approvals");
                await service.AnswerAsync(Json(new { operationId = requestId, approvalId = nextTurn.GetProperty("approvals")[0].GetProperty("id").GetString(), decision = "accept" }), default);
                var completed = await WaitAsync(service, requestId, "completed");
                await liveDone.Task.WaitAsync(TimeSpan.FromSeconds(3));
                liveLife.Cancel();
                try { await liveStream; } catch (OperationCanceledException) { }
                var completedSession = Result(await service.CatalogAsync(Json(new { }), default)).GetProperty("sessions")[0];
                Check(CodexJson.Text(completedSession, "state") == "completed" && CodexJson.Text(completedSession, "completionId").Length > 0,
                    "A finished worker stayed running in the catalog or lost its unread completion identity");
                await service.AnswerAsync(Json(new { operationId = requestId, approvalId = approval, decision = "accept" }), default);
                Check(completed.GetProperty("events").EnumerateArray().Any(value => CodexJson.Text(value, "text") == "Fixture completed"), "Streamed answer was lost");
                Check(completed.GetProperty("followups").GetArrayLength() == 3, "Follow-up ledger did not survive turn handoff");
                var cursor = completed.GetProperty("cursor").GetInt64();
                Check(Result(await service.OperationAsync(Json(new { operationId = requestId, cursor }), default)).GetProperty("events").GetArrayLength() == 0, "Cursor replay duplicated events");
                var stopId = Guid.NewGuid().ToString();
                await service.StartAsync(Json(new { requestId = stopId, applicationId, threadId = FixtureThread, message = "Stop fixture" }), default);
                await WaitAsync(service, stopId, "waiting");
                Check(CodexJson.Text(Result(await service.HistoryAsync(Json(new { threadId = FixtureThread }), default)), "operationId") == stopId,
                    "Latest thread history was associated with an older follow-up group");
                var pausedId = Guid.NewGuid().ToString();
                await service.QueueAsync(Json(new { operationId = stopId, requestId = pausedId, message = "Resume after stop" }), default);
                await service.StopAsync(Json(new { operationId = stopId }), default);
                var stopped = await WaitAsync(service, stopId, "interrupted");
                var paused = stopped.GetProperty("followups").EnumerateArray().Single(value => CodexJson.Text(value, "id") == pausedId);
                Check(CodexJson.Text(paused, "state") == "paused", "Stopping did not pause the queue");
                await service.SteerMessageAsync(Json(new { operationId = stopId, messageId = pausedId, requestId = Guid.NewGuid().ToString(), revision = paused.GetProperty("revision").GetInt32() }), default);
                var resumed = await WaitAsync(service, stopId, "waiting");
                await service.AnswerAsync(Json(new { operationId = stopId, approvalId = resumed.GetProperty("approvals")[0].GetProperty("id").GetString(), decision = "accept" }), default);
                await WaitAsync(service, stopId, "completed");
                var imageRequest = Guid.NewGuid().ToString();
                await service.StartAsync(Json(new { requestId = imageRequest, applicationId, threadId = FixtureThread,
                    message = "Image fixture", model = "fixture-vision", permission = "auto", imageIds = new[] { imageId }, serviceTier = "priority" }), default);
                var imageWaiting = await WaitAsync(service, imageRequest, "waiting");
                var downloaded = Result(await service.ImageAsync(Json(new { threadId = FixtureThread, messageId = imageRequest, index = 0, offset = 0 }), default));
                Check(Convert.FromBase64String(CodexJson.Text(downloaded, "content")).SequenceEqual(imageBytes), "Message image bytes did not round trip");
                Check(CodexJson.Text(downloaded, "revision") == digest.ToLowerInvariant(), "Message image integrity hash was lost");
                try { await service.ImageAsync(Json(new { threadId = FixtureThread, messageId = imageRequest, index = 0, offset = 0, revision = "changed" }), default); throw new Exception("Changed image revision accepted"); }
                catch (AgentActionException e) when (e.Code == "codex_image_changed") { }
                try { await service.ImageAsync(Json(new { threadId = Guid.NewGuid().ToString(), messageId = imageRequest, index = 0, offset = 0 }), default); throw new Exception("Image leaked across threads"); }
                catch (AgentActionException e) when (e.Code == "codex_image_missing") { }
                var imageApproval = imageWaiting.GetProperty("approvals")[0].GetProperty("id").GetString();
                await service.AnswerAsync(Json(new { operationId = imageRequest, approvalId = imageApproval, decision = "accept" }), default);
                await WaitAsync(service, imageRequest, "completed");
                try { await service.StartAsync(Json(new { requestId = imageRequest, applicationId, threadId = FixtureThread,
                    message = "Image fixture", model = "other-model", permission = "auto", imageIds = new[] { imageId } }), default); throw new Exception("Model change reused an existing request ID"); }
                catch (AgentActionException e) when (e.Code == "codex_request_conflict") { }
                try { await service.StartAsync(Json(new { requestId = imageRequest, applicationId, threadId = FixtureThread,
                    message = "Image fixture", model = "fixture-vision", permission = "auto", imageIds = new[] { imageId }, serviceTier = "default" }), default); throw new Exception("Speed change reused an existing request ID"); }
                catch (AgentActionException e) when (e.Code == "codex_request_conflict") { }
                var standardId = Guid.NewGuid().ToString();
                await service.StartAsync(Json(new { requestId = standardId, applicationId, message = "Standard fixture", serviceTier = "default" }), default);
                var standardWaiting = await WaitAsync(service, standardId, "waiting");
                await service.AnswerAsync(Json(new { operationId = standardId, approvalId = standardWaiting.GetProperty("approvals")[0].GetProperty("id").GetString(), decision = "accept" }), default);
                await WaitAsync(service, standardId, "completed");
                var questionId = Guid.NewGuid().ToString();
                await service.StartAsync(Json(new { requestId = questionId, applicationId, threadId = FixtureThread, message = "Question fixture" }), default);
                var questionWaiting = await WaitAsync(service, questionId, "waiting");
                var question = questionWaiting.GetProperty("approvals")[0];
                Check(CodexJson.Text(question, "kind") == "question" &&
                    question.GetProperty("questions")[0].GetProperty("options").GetArrayLength() == 2,
                    "Structured questions and selectable options did not reach the phone");
                var questionApproval = question.GetProperty("id").GetString();
                try { await service.AnswerAsync(Json(new { operationId = questionId, approvalId = questionApproval, answers = new { network = "" } }), default); throw new Exception("An unanswered question was accepted"); }
                catch (AgentActionException e) when (e.Code == "invalid_params") { }
                Check(Result(await service.OperationAsync(Json(new { operationId = questionId }), default)).GetProperty("approvals").GetArrayLength() == 1,
                    "Validation consumed the question before explicit confirmation");
                await service.AnswerAsync(Json(new { operationId = questionId, approvalId = questionApproval, answers = new { network = "服务器认证" } }), default);
                await WaitAsync(service, questionId, "completed");
                var failureId = Guid.NewGuid().ToString();
                await service.StartAsync(Json(new { requestId = failureId, applicationId, threadId = FixtureThread, message = "Failure fixture" }), default);
                var failureWaiting = await WaitAsync(service, failureId, "waiting");
                var steeredBeforeFailure = Guid.NewGuid().ToString();
                await service.QueueAsync(Json(new { operationId = failureId, requestId = steeredBeforeFailure, message = "Edited follow-up" }), default);
                await service.SteerMessageAsync(Json(new { operationId = failureId, messageId = steeredBeforeFailure, requestId = Guid.NewGuid().ToString(), revision = 0 }), default);
                var afterFailure = Guid.NewGuid().ToString();
                await service.QueueAsync(Json(new { operationId = failureId, requestId = afterFailure, message = "Must stay paused" }), default);
                await service.AnswerAsync(Json(new { operationId = failureId, approvalId = failureWaiting.GetProperty("approvals")[0].GetProperty("id").GetString(), decision = "decline" }), default);
                for (var attempt = 0; attempt < 100; attempt++)
                {
                    var failedPage = Result(await service.OperationAsync(Json(new { operationId = failureId }), default));
                    if (failedPage.GetProperty("followups").EnumerateArray().Any(value => CodexJson.Text(value, "id") == afterFailure && CodexJson.Text(value, "state") == "paused")) break;
                    if (attempt == 99) throw new Exception("Failed turn automatically continued through a steered predecessor");
                    await Task.Delay(30);
                }
            }
            await using (var recovered = new CodeWorkshop(storage, code, startServer: token => Start(token)))
            {
                Check(Result(await recovered.OperationAsync(Json(new { operationId = requestId }), default)).GetProperty("operation").GetProperty("state").GetString() == "completed", "Durable job recovery failed");
            }
            await using (var occupied = new CodeWorkshop(Path.Combine(directory, "occupied"), code, startServer: token => Start(token, true)))
            {
                var busyId = Guid.NewGuid().ToString();
                await occupied.StartAsync(Json(new { requestId = busyId, applicationId, threadId = FixtureThread, message = "Check lock" }), default);
                var failed = await WaitAsync(occupied, busyId, "failed");
                Check(CodexJson.Text(failed.GetProperty("operation"), "message").Contains("桌面版仍占用"), "Writer conflict was not translated");
            }
            Console.WriteLine("PASS: Codex stdio, durable queue/edit/cancel/Steer, stale revisions, automatic turn handoff, stop/resume, approval retries, images, models and artifacts");
        }
        finally
        {
            var resolved = Path.GetFullPath(directory);
            if (Path.GetDirectoryName(resolved) == Path.TrimEndingDirectorySeparator(Path.GetFullPath(Path.GetTempPath())) && Path.GetFileName(resolved).StartsWith("hako-workshop-", StringComparison.Ordinal))
                Directory.Delete(resolved, recursive: true);
        }
    }

    private static async Task<JsonElement> WaitAsync(CodeWorkshop service, string id, string state)
    {
        var deadline = DateTime.UtcNow.AddSeconds(15);
        while (DateTime.UtcNow < deadline)
        {
            var result = Result(await service.OperationAsync(Json(new { operationId = id }), default));
            var actual = result.GetProperty("operation").GetProperty("state").GetString();
            if (actual == state) return result;
            if (actual is "failed" or "unknown") throw new Exception("Workshop fixture ended: " + result.GetProperty("operation").GetProperty("message").GetString());
            await Task.Delay(50);
        }
        throw new TimeoutException("Workshop fixture did not reach " + state);
    }

    public static async Task RunFixtureAsync()
    {
        Check(Environment.GetEnvironmentVariable("CODEX_WINDOWS_REGISTERED_CORE") is null,
            "Codex CLI inherited the desktop app's registered Core identity");
        var project = Environment.GetEnvironmentVariable("HAKO_CODEX_TEST_PROJECT")!;
        var turnId = "fixture-turn";
        var archived = false;
        void Write(object message) { Console.WriteLine(JsonSerializer.Serialize(message, AgentConnection.Json)); Console.Out.Flush(); }
        while (await Console.In.ReadLineAsync() is { } line)
        {
            using var json = JsonDocument.Parse(line);
            var input = json.RootElement;
            var method = CodexJson.Text(input, "method");
            if (method.Length == 0 && input.TryGetProperty("id", out var approval))
            {
                if (approval.GetInt32() == 901)
                    Check(CodexJson.Field(CodexJson.Field(CodexJson.Field(input, "result"), "answers"), "network")
                        .GetProperty("answers")[0].GetString() == "服务器认证", "The user's confirmed selection was not returned to Codex");
                if (CodexJson.Text(CodexJson.Field(input, "result"), "decision") == "decline")
                {
                    Write(new { method = "turn/completed", @params = new { turn = new { id = turnId, status = "failed" } } });
                    continue;
                }
                Write(new { method = "item/agentMessage/delta", @params = new { threadId = FixtureThread, itemId = "answer", delta = "Fixture " } });
                Write(new { method = "item/completed", @params = new { item = new { id = "answer", type = "agentMessage", text = "Fixture completed" } } });
                Write(new { method = "turn/completed", @params = new { turn = new { id = turnId, status = "completed" } } });
                continue;
            }
            if (!input.TryGetProperty("id", out var id)) continue;
            if (method == "initialize")
                Check(CodexJson.Field(CodexJson.Field(CodexJson.Field(input, "params"), "capabilities"), "experimentalApi").ValueKind == JsonValueKind.True,
                    "The client did not opt into the structured input protocol");
            if (method == "thread/turns/list")
            {
                var options = CodexJson.Field(input, "params");
                Check(CodexJson.Text(options, "sortDirection") == "desc" && CodexJson.Text(options, "itemsView") == "summary" &&
                    CodexJson.Field(options, "limit").GetInt32() == 1, "Catalog hydrated the full transcript instead of one latest-turn summary");
            }
            if (method == "thread/archive")
            {
                File.WriteAllText(Path.Combine(project, ".archive-entered"), "entered");
                await Task.Delay(300);
                archived = true;
            }
            if (method == "thread/unarchive") archived = false;
            if (method is "thread/start" or "thread/resume")
            {
                var options = CodexJson.Field(input, "params");
                if (CodexJson.Text(options, "model") == "fixture-vision")
                    Check(CodexJson.Text(options, "serviceTier") == "priority", "Thread speed override was lost");
                if (method == "thread/start") Check(CodexJson.Text(options, "serviceTier") == "default", "Standard thread speed was lost");
            }
            if (method == "turn/start")
            {
                var parameters = CodexJson.Field(input, "params");
                var items = CodexJson.Items(CodexJson.Field(parameters, "input"));
                if (items.Any(value => CodexJson.Text(value, "text") == "Image fixture"))
                    Check(CodexJson.Text(parameters, "model") == "fixture-vision" && CodexJson.Text(parameters, "serviceTier") == "priority" &&
                        items.Any(value => CodexJson.Text(value, "type") == "localImage" && File.Exists(CodexJson.Text(value, "path"))),
                        "Selected model or local image was not sent to App Server");
                if (items.Any(value => CodexJson.Text(value, "text") == "Standard fixture"))
                    Check(CodexJson.Text(parameters, "serviceTier") == "default", "Standard turn speed was lost");
            }
            if (method == "turn/steer")
            {
                var parameters = CodexJson.Field(input, "params");
                Check(CodexJson.Text(parameters, "expectedTurnId") == turnId && CodexJson.Text(parameters, "threadId") == FixtureThread,
                    "Steer targeted the wrong turn");
                Check(CodexJson.Items(CodexJson.Field(parameters, "input")).Any(value => CodexJson.Text(value, "text") == "Edited follow-up"), "Steer did not use edited text");
            }
            if (method == "thread/resume" && Environment.GetEnvironmentVariable("HAKO_CODEX_TEST_OCCUPIED") == "1")
            { Write(new { id, error = new { code = -32600, message = "thread-store conflict: already has an active writer" } }); continue; }
            var thread = new
            {
                id = FixtureThread, cwd = CodexJson.Text(CodexJson.Field(input, "params"), "threadId") == "22222222-2222-4222-8222-222222222222" ? Path.GetDirectoryName(project)! : project,
                name = "Fixture", preview = "Fixture history", updatedAt = 1,
                status = new { type = method == "thread/list" ? "active" : "idle", activeFlags = Array.Empty<string>() },
                turns = new[] { new { id = turnId, status = "completed", items = new[] { new { id = "history", type = "agentMessage", text = "visualize" + JsonSerializer.Serialize(new { path = Path.Combine(project, "prototype.html") }) + "" } } } }
            };
            object result = method switch
            {
                "model/list" => new { data = new[] { new { model = "fixture-vision", displayName = "Fixture Vision", description = "Fixture", isDefault = true, inputModalities = new[] { "text", "image" }, serviceTiers = new[] { new { id = "priority", name = "Fast", description = "Faster fixture" } } } }, nextCursor = (string?)null },
                "thread/list" => new { data = archived == (CodexJson.Field(CodexJson.Field(input, "params"), "archived").ValueKind == JsonValueKind.True) ? new[] { thread } : [], nextCursor = (string?)null },
                "thread/turns/list" => new { data = new[] { new { id = turnId, status = File.Exists(Path.Combine(project, ".summary-status")) ? File.ReadAllText(Path.Combine(project, ".summary-status")) : "completed", items = new[] { new { id = "latest", type = "agentMessage", text = "Latest fixture reply" } } } }, nextCursor = (string?)null },
                "thread/read" or "thread/resume" or "thread/start" => new { thread },
                "turn/start" => new { turn = new { id = turnId, status = "inProgress" } },
                "turn/steer" => new { turnId },
                _ => new { }
            };
            Write(new { id, result });
            if (method == "turn/start")
            {
                if (CodexJson.Items(CodexJson.Field(CodexJson.Field(input, "params"), "input")).Any(value => CodexJson.Text(value, "text") == "Question fixture"))
                    Write(new { id = 901, method = "item/tool/requestUserInput", @params = new { threadId = FixtureThread, turnId, itemId = "question",
                        questions = new[] { new { id = "network", header = "认证方式", question = "是否需要离线直连？", options = new[] {
                            new { label = "离线直连", description = "配对后可离线使用" }, new { label = "服务器认证", description = "每次连接时认证" }
                        } } } } });
                else Write(new { id = 900, method = "item/commandExecution/requestApproval", @params = new { command = "fixture test", threadId = FixtureThread, turnId, itemId = "command" } });
            }
            if (method == "turn/interrupt")
                Write(new { method = "turn/completed", @params = new { turn = new { id = turnId, status = "interrupted" } } });
        }
    }
}
