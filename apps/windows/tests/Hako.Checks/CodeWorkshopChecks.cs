using System;
using System.Diagnostics;
using System.Collections.Generic;
using System.Collections.Concurrent;
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
    private const string FixtureSystemPrompt = "每次原型修改都使用新路径，并在本次回复中发送新的原型卡片。";
    private static JsonElement Json(object value) => JsonSerializer.SerializeToElement(value, WorkshopProtocol.Json);
    private static JsonElement Result(object? value) => Json(value!);
    private static void Check(bool condition, string message) { if (!condition) throw new Exception(message); }

    public static async Task RunAsync()
    {
        await WorkshopReadChecks.RunAsync();
        await WorkshopConcurrencyChecks.RunAsync();
        WorkshopCatalogChecks.Run();
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
        foreach (var state in new[] { "completed", "failed", "interrupted" })
        {
            var finishedJob = new WorkshopJob { TurnId = "next-turn", State = state };
            var reconciled = CodeWorkshop.ReconcileSummary(runningSummary, finishedJob);
            Check(reconciled.State == state && reconciled.CompletionId == (state == "completed" ? "next-turn" : null),
                "A stale metadata summary overrode a matching finished worker: " + state);
            Check(CodeWorkshop.ReconcileSummary(runningSummary, new WorkshopJob { TurnId = "older-turn", State = state }) == runningSummary,
                "A previous local worker hid a newer external turn");
        }
        foreach (var state in new[] { "running", "waiting", "finishing", "queued", "paused" })
        {
            var active = CodeWorkshop.ReconcileSummary(summarized, new WorkshopJob { TurnId = "latest-turn", State = state });
            Check(active.State == state && active.CompletionId is null,
                "Catalog must not report completion while a local worker or queued request remains: " + state);
        }
        Check(CodeWorkshop.ReconcileSummary(runningSummary, null) == runningSummary,
            "An external turn without a local worker must keep its reported state");
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
        foreach (var state in new[] { "completed", "interrupted", "failed" })
        {
            var unknown = new WorkshopJob { State = "unknown", TurnId = "uncertain-turn", Message = "Old uncertainty" };
            Check(CodeWorkshop.ReconcileTurn(unknown, [Json(new { id = "uncertain-turn", status = state, error = new { message = "Actual failure" }, items = Array.Empty<object>() })]) && unknown.State == state,
                "Matching canonical terminal turn did not reconcile the unknown job");
            Check(unknown.Message == (state == "failed" ? "Actual failure" : null), "Reconciliation retained a stale uncertainty message");
        }
        var unresolved = new WorkshopJob { State = "unknown", TurnId = "uncertain-turn" };
        Check(!CodeWorkshop.ReconcileTurn(unresolved, [Json(new { id = "other-turn", status = "completed" })]) && unresolved.State == "unknown",
            "Another turn incorrectly resolved this job");
        Check(!CodeWorkshop.ReconcileTurn(unresolved, [Json(new { id = "uncertain-turn", status = "inProgress" })]),
            "An unfinished turn must remain unconfirmed");
        var activeJob = new WorkshopJob { State = "running", TurnId = "uncertain-turn" };
        Check(!CodeWorkshop.ReconcileTurn(activeJob, [Json(new { id = "uncertain-turn", status = "completed" })]),
            "History reconciliation must not overwrite an owned active worker");
        var generatedItem = CodeWorkshop.Item(Json(new { id = "generated-output", type = "imageGeneration", status = "completed", savedPath = "C:/Code/fixture/cat.png" }))!;
        Check(generatedItem.Kind == "imageGeneration" && generatedItem.Role == "assistant" && generatedItem.Text == "[图片 × 1]",
            "Generated image items were omitted from the phone transcript");
        var generatingItem = CodeWorkshop.Item(Json(new { id = "generating", type = "imageGeneration", status = "inProgress" }))!;
        Check(generatingItem.Text == "正在生成图片…", "Pending generations should not request a nonexistent image");
        var asyncItem = Json(new { id = "async-question", type = "agentMessage", text = "选择升级方式", delivery = "async",
            questions = new[] { new { title = "如何升级？", options = new[] { "同步升级", "保留兼容" } } } });
        var parsedQuestion = CodeWorkshop.Item(asyncItem)!;
        Check(parsedQuestion.Questions is { Length: 1 } && parsedQuestion.Questions[0].Options[1] == "保留兼容",
            "Async question metadata was discarded while converting assistant messages");
        Check(CodeWorkshop.Item(Json(new { id = "normal", type = "agentMessage", text = "Text without a question" }))!.Questions is null,
            "Ordinary prose was incorrectly interpreted as an interactive question");
        userJobs[0].QuestionId = "async-question";
        Check(CodeWorkshop.HistoryItem(userItem, "turn-one", userJobs, new HashSet<string>())!.QuestionId == "async-question",
            "Canonical history lost the durable answer association");
        var directory = Path.Combine(Path.GetTempPath(), "hako-workshop-" + Guid.NewGuid().ToString("N"));
        var launch = CodexAppServer.WithArguments(new ProcessStartInfo("codex.exe"));
        Check(launch.ArgumentList.Contains("--enable") && launch.ArgumentList.Contains("default_mode_request_user_input"),
            "Default-mode questions must be enabled for the phone's interactive answer UI");
        var code = Path.Combine(directory, "Code");
        var project = Path.Combine(code, "fixture");
        Directory.CreateDirectory(Path.Combine(project, ".git"));
        var preview = Path.Combine(project, "prototype.html");
        File.WriteAllText(preview, "<div>interactive prototype</div>");
        var generatedBytes = new byte[3_133_248];
        new byte[] { 137, 80, 78, 71, 13, 10, 26, 10 }.CopyTo(generatedBytes, 0);
        File.WriteAllBytes(Path.Combine(project, "generated-fixture.png"), generatedBytes);
        Task<CodexAppServer> Start(CancellationToken token, bool occupied = false, string? scenario = null)
        {
            var start = new ProcessStartInfo(Environment.ProcessPath!);
            if (Path.GetFileNameWithoutExtension(Environment.ProcessPath!).Equals("dotnet", StringComparison.OrdinalIgnoreCase))
                start.ArgumentList.Add(typeof(Program).Assembly.Location);
            start.ArgumentList.Add("--codex-workshop-fixture");
            start.Environment["CODEX_WINDOWS_REGISTERED_CORE"] = "1";
            start.Environment["HAKO_CODEX_TEST_PROJECT"] = project;
            if (occupied) start.Environment["HAKO_CODEX_TEST_OCCUPIED"] = "1";
            if (scenario is not null) start.Environment["HAKO_CODEX_TEST_SCENARIO"] = scenario;
            return CodexAppServer.StartAsync(token, start);
        }
        var storage = Path.Combine(directory, "state");
        try
        {
            await using (var parallel = new CodeWorkshop(Path.Combine(directory, "parallel-state"), code, directory,
                token => Start(token, scenario: "concurrent-reads")))
            {
                var models = parallel.ModelsAsync(Json(new { }), default);
                var deadline = DateTime.UtcNow.AddSeconds(5);
                while (!File.Exists(Path.Combine(project, ".model-waiting")) && DateTime.UtcNow < deadline)
                    await Task.Delay(10);
                Check(File.Exists(Path.Combine(project, ".model-waiting")), "Fixture did not receive the held model query");
                await Task.WhenAll(models,
                    parallel.HistoryAsync(Json(new { threadId = FixtureThread }), default)).WaitAsync(TimeSpan.FromSeconds(7));
                var marker = Path.Combine(project, ".history-reads");
                var before = File.ReadAllLines(marker).Length;
                try { await parallel.HistoryAsync(Json(new { threadId = FixtureThread, cursor = "invalid" }), default); throw new Exception("Malformed history cursor accepted"); }
                catch (WorkshopException error) when (error.Code == "invalid_params") { }
                Check(File.ReadAllLines(marker).Length == before, "History pagination reread the entire Codex thread");
                await parallel.HistoryAsync(Json(new { threadId = FixtureThread }), default);
                Check(File.ReadAllLines(marker).Length == before + 1, "A fresh history head reused stale page data");
            }
            await using (var paged = new CodeWorkshop(Path.Combine(directory, "paged-state"), code, directory,
                token => Start(token, scenario: "paged-history")))
            {
                var previousReads = File.ReadAllLines(Path.Combine(project, ".history-item-reads")).Length;
                string? cursor = null;
                var entries = new List<string>();
                string? restartCursor = null;
                do
                {
                    var page = Result(await paged.HistoryAsync(Json(new { threadId = FixtureThread, cursor }), default));
                    entries.InsertRange(0, page.GetProperty("entries").EnumerateArray().Select(entry => CodexJson.Text(entry, "id")));
                    cursor = CodexJson.Text(page, "nextCursor");
                    restartCursor ??= cursor;
                } while (cursor.Length > 0);
                Check(entries.SequenceEqual(Enumerable.Range(0, 75).Select(index => "history-" + index)),
                    "Upstream turn/item pagination lost, duplicated or reordered history");
                Check(File.ReadAllLines(Path.Combine(project, ".history-item-reads")).Length == previousReads + 2,
                    "History pages reread upstream items or hydrated complete turns");
                File.WriteAllText(Path.Combine(project, ".history-new-item"), "append");
                await paged.HistoryAsync(Json(new { threadId = FixtureThread }), default);
                var afterAppend = Result(await paged.HistoryAsync(Json(new { threadId = FixtureThread, cursor = restartCursor }), default));
                Check(afterAppend.GetProperty("entries").EnumerateArray().Select(entry => CodexJson.Text(entry, "id"))
                    .SequenceEqual(Enumerable.Range(51, 12).Select(index => "history-" + index)),
                    "Refreshing the head shifted an existing item-page cursor");
                await using var restarted = new CodeWorkshop(Path.Combine(directory, "paged-restart"), code, directory,
                    token => Start(token, scenario: "paged-history"));
                Check(Result(await restarted.HistoryAsync(Json(new { threadId = FixtureThread, cursor = restartCursor }), default))
                    .GetProperty("entries").GetArrayLength() == 12, "An opaque history cursor did not survive restart");
                try { await restarted.HistoryAsync(Json(new { threadId = "22222222-2222-4222-8222-222222222222", cursor = restartCursor }), default); throw new Exception("Cross-thread history cursor accepted"); }
                catch (WorkshopException error) when (error.Code == "invalid_params") { }
                File.Delete(Path.Combine(project, ".history-new-item"));
            }
            var catalogStorage = Path.Combine(directory, "catalog-state");
            Directory.CreateDirectory(catalogStorage);
            var accepted = new WorkshopJob { Id = Guid.NewGuid().ToString("D"), ThreadId = FixtureThread, TurnId = "fixture-turn",
                State = "completed", Cwd = project, ApplicationId = Convert.ToHexString(SHA256.HashData(System.Text.Encoding.UTF8.GetBytes(project.ToUpperInvariant())))[..16].ToLowerInvariant(),
                QueueOrder = DateTime.UnixEpoch.AddSeconds(2000).Ticks };
            File.WriteAllBytes(Path.Combine(catalogStorage, accepted.Id + ".json"), JsonSerializer.SerializeToUtf8Bytes(accepted, WorkshopProtocol.Json));
            var catalogPages = Path.Combine(project, ".catalog-pages");
            File.WriteAllText(catalogPages, "enabled");
            File.WriteAllText(Path.Combine(project, ".catalog-owner"), accepted.Id);
            try
            {
                await using var listing = new CodeWorkshop(catalogStorage, code, Path.Combine(directory, ".codex"), token => Start(token));
                var firstPage = Result(await listing.CatalogAsync(Json(new { }), default));
                File.WriteAllText(Path.Combine(project, ".catalog-hidden"), "hide");
                await listing.CatalogAsync(Json(new { }), default);
                var scans = File.ReadAllLines(Path.Combine(project, ".catalog-scans")).Length;
                Check(CodexJson.Text(firstPage.GetProperty("sessions")[0], "id") == FixtureThread &&
                    firstPage.GetProperty("sessions")[0].GetProperty("lastSentAt").GetInt64() == 2000,
                    "An accepted send from the fourth upstream page did not reach the first client page");
                var all = new List<string>();
                var currentPage = firstPage;
                do
                {
                    all.AddRange(currentPage.GetProperty("sessions").EnumerateArray().Select(row => CodexJson.Text(row, "id")));
                    var cursor = CodexJson.Text(currentPage, "nextCursor");
                    if (cursor.Length == 0) break;
                    currentPage = Result(await listing.CatalogAsync(Json(new { cursor }), default));
                } while (true);
                Check(all.Count == 65 && all.Distinct().Count() == 65, "Global send-order pagination lost or duplicated a thread");
                File.Delete(Path.Combine(project, ".catalog-hidden"));
                Check(File.ReadAllLines(Path.Combine(project, ".catalog-scans")).Length == scans,
                    "Client pagination rescanned the complete upstream catalog");
                var summaryReads = File.ReadAllLines(Path.Combine(project, ".catalog-summary-count")).Length;
                await listing.CatalogAsync(Json(new { }), default);
                Check(File.ReadAllLines(Path.Combine(project, ".catalog-summary-count")).Length == summaryReads,
                    "Unchanged settled threads repeated their summary queries on the next head refresh");
                await listing.HistoryAsync(Json(new { threadId = FixtureThread }), default);
                File.WriteAllText(Path.Combine(project, ".catalog-delayed"), "enabled");
                var afterOpen = Result(await listing.CatalogAsync(Json(new { }), default));
                Check(firstPage.GetProperty("sessions").EnumerateArray().Select(row => CodexJson.Text(row, "id"))
                    .SequenceEqual(afterOpen.GetProperty("sessions").EnumerateArray().Select(row => CodexJson.Text(row, "id"))),
                    "Reading a running/completed thread changed the send-order page");
                Check(afterOpen.GetProperty("sessions")[0].GetProperty("lastSentAt").GetInt64() == 2000,
                    "A queued send starting later acquired its execution time as its send time");
                File.WriteAllText(Path.Combine(project, ".catalog-outside"), "enabled");
                var outside = Result(await listing.CatalogAsync(Json(new { }), default));
                Check(outside.GetProperty("sessions")[0].GetProperty("lastSentAt").GetInt64() == 10000,
                    "The last actual desktop user input was hidden by the first user message in a turn summary");
            }
            finally
            {
                foreach (var marker in new[] { ".catalog-pages", ".catalog-owner", ".catalog-delayed", ".catalog-outside", ".catalog-hidden" })
                    File.Delete(Path.Combine(project, marker));
            }
            string applicationId;
            string requestId;
            long completedStart;
            long completedEnd;
            await using (var service = new CodeWorkshop(storage, code, Path.Combine(directory, ".codex"), token => Start(token)))
            {
                // The worker is shared by LAN and cloud; a configured cloud identity
                // scopes notifications even when no phone/cloud request socket exists.
                service.SetNotificationScope("fixture-cloud");
                using var notificationLife = new CancellationTokenSource();
                var notifications = new ConcurrentDictionary<string, WorkshopTerminal>();
                var asyncNotices = new ConcurrentQueue<WorkshopTerminal>();
                var notificationWatch = service.WatchTerminalsAsync("fixture-cloud", terminal =>
                {
                    if (terminal.QuestionId.Length > 0) asyncNotices.Enqueue(terminal);
                    notifications[terminal.OperationId] = terminal;
                    service.AcknowledgeTerminal("fixture-cloud", terminal.OperationId, terminal.QuestionId);
                    return Task.CompletedTask;
                }, notificationLife.Token);
                var catalog = Result(await service.CatalogAsync(Json(new { }), default));
                applicationId = catalog.GetProperty("applications")[0].GetProperty("id").GetString()!;
                Check(catalog.GetProperty("sessions")[0].GetProperty("applicationId").GetString() == applicationId, "Session/application association failed");
                Check(catalog.GetProperty("sessions")[0].GetProperty("lastSentAt").GetInt64() == 1 &&
                    catalog.GetProperty("sessions")[0].GetProperty("updatedAt").GetInt64() == 1000,
                    "Send order and execution freshness must remain separate in the client response");
                Check(CodexJson.Text(catalog.GetProperty("sessions")[0], "state") == "completed",
                    "An active thread flag must not override its completed latest turn");
                Check(CodexJson.Text(catalog.GetProperty("sessions")[0], "preview") == "Latest fixture reply" &&
                    CodexJson.Text(catalog.GetProperty("sessions")[0], "completionId") == "fixture-turn", "Catalog still used the initial preview");
                var previewFile = Path.Combine(project, ".catalog-preview");
                try
                {
                    foreach (var text in new[] { "Latest same-turn Steer", "Newest assistant commentary" })
                    {
                        File.WriteAllText(previewFile, text);
                        var refreshed = Result(await service.CatalogAsync(Json(new { }), default)).GetProperty("sessions")[0];
                        Check(CodexJson.Text(refreshed, "preview") == text && refreshed.GetProperty("lastSentAt").GetInt64() == 1 &&
                            CodexJson.Text(refreshed, "completionId") == "fixture-turn",
                            "Same-turn messages must refresh the preview without changing send order or turn state");
                    }
                }
                finally { File.Delete(previewFile); }
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
                catch (WorkshopException e) when (e.Code == "codex_busy") { }
                Check(Result(await archiveInFlight).GetProperty("archived").GetBoolean(), "Archive response lost its state");
                Check(Result(await service.CatalogAsync(Json(new { }), default)).GetProperty("sessions").GetArrayLength() == 0, "Archived thread stayed in the active list");
                Check(Result(await service.CatalogAsync(Json(new { archived = true }), default)).GetProperty("sessions").GetArrayLength() == 1, "Archived filter did not reach Codex");
                Check(Result(await service.HistoryAsync(Json(new { threadId = FixtureThread }), default)).GetProperty("entries").GetArrayLength() > 0, "Archive destroyed readable history");
                Check(!Result(await service.ArchiveAsync(Json(new { threadId = FixtureThread, archived = false }), default)).GetProperty("archived").GetBoolean(), "Unarchive failed");
                Check(Result(await service.CatalogAsync(Json(new { archived = true }), default)).GetProperty("sessions").GetArrayLength() == 0, "Restored thread stayed in archives");
                Check(Result(await service.CatalogAsync(Json(new { }), default)).GetProperty("sessions").GetArrayLength() == 1, "Restored thread did not return to active list");
                try { await service.ArchiveAsync(Json(new { threadId = "22222222-2222-4222-8222-222222222222", archived = true }), default); throw new Exception("Thread outside Code root was archived"); }
                catch (WorkshopException e) when (e.Code == "codex_workspace_invalid") { }
                try { await service.CatalogAsync(Json(new { archived = "true" }), default); throw new Exception("Non-boolean archive filter accepted"); }
                catch (WorkshopException e) when (e.Code == "invalid_params") { }
                var models = Result(await service.ModelsAsync(Json(new { }), default));
                Check(models.GetProperty("models")[0].GetProperty("supportsImages").GetBoolean(), "Model image capability was lost");
                Check(models.GetProperty("models")[0].GetProperty("serviceTiers")[0].GetProperty("id").GetString() == "priority", "Fast service tier identity was lost");
                Check(models.GetProperty("models")[0].GetProperty("reasoningEfforts").EnumerateArray().Select(value => CodexJson.Text(value, "id")).SequenceEqual(new[] { "high", "low", "future-effort" }), "Advertised reasoning efforts were reordered or hard-coded");
                Check(CodexJson.Text(models.GetProperty("models")[0], "defaultReasoningEffort") == "low", "Default reasoning effort was lost");
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
                catch (WorkshopException e) when (e.Code == "codex_upload_conflict") { }
                Check((string)CodeWorkshop.ThreadOptions("auto")["approvalsReviewer"] == "auto_review" &&
                    (string)CodeWorkshop.ThreadOptions("full")["sandbox"] == "danger-full-access" &&
                    (string)CodeWorkshop.ThreadOptions("ask")["approvalsReviewer"] == "user" && CodeWorkshop.ThreadOptions("custom").Count == 0,
                    "Permission presets do not map to App Server policies");
                var history = Result(await service.HistoryAsync(Json(new { threadId = FixtureThread }), default));
                Check(CodexJson.Text(history, "model") == "fixture-session" && CodexJson.Text(history, "reasoningEffort") == "max",
                    "History did not expose the session's actual model and reasoning effort");
                Check(history.GetProperty("entries").EnumerateArray().Any(entry => CodexJson.Text(entry, "kind") == "imageGeneration" && CodexJson.Text(entry, "id") == "generated-fixture"),
                    "Completed image generation disappeared when reopening the thread history");
                using (var imageData = new MemoryStream())
                {
                    string? imageRevision = null;
                    do {
                        var chunk = Result(await service.ImageAsync(Json(new { threadId = FixtureThread, messageId = "generated-fixture", index = 0, offset = (int)imageData.Length, revision = imageRevision }), default));
                        imageRevision = CodexJson.Text(chunk, "revision");
                        Check(chunk.GetProperty("total").GetInt32() == generatedBytes.Length, "Generated images larger than 2 MB were rejected or truncated");
                        imageData.Write(Convert.FromBase64String(CodexJson.Text(chunk, "content")));
                    } while (imageData.Length < generatedBytes.Length);
                    Check(imageData.ToArray().SequenceEqual(generatedBytes), "Generated image bytes were not preserved across chunked reads");
                }
                try { await service.ImageAsync(Json(new { threadId = FixtureThread, messageId = "generated-fixture", index = 1, offset = 0 }), default); throw new Exception("Invalid generated image index accepted"); }
                catch (WorkshopException error) when (error.Code == "codex_image_missing") { }
                File.WriteAllBytes(Path.Combine(project, "generated-fixture.png"), new byte[CodeWorkshop.MaximumReadImageBytes + 1]);
                try { await service.ImageAsync(Json(new { threadId = FixtureThread, messageId = "generated-fixture", index = 0, offset = 0 }), default); throw new Exception("Oversized generated image accepted"); }
                catch (WorkshopException error) when (error.Code == "codex_image_missing") { }
                File.WriteAllBytes(Path.Combine(project, "generated-fixture.png"), generatedBytes);
                var artifactId = history.GetProperty("artifacts")[0].GetProperty("id").GetString();
                var artifact = Result(await service.ArtifactAsync(Json(new { threadId = FixtureThread, artifactId, offset = 0 }), default));
                Check(System.Text.Encoding.UTF8.GetString(Convert.FromBase64String(artifact.GetProperty("content").GetString()!)).Contains("interactive prototype"), "Artifact retrieval failed");
                try { await service.ArtifactAsync(Json(new { threadId = FixtureThread, artifactId, offset = 0, revision = "changed" }), default); throw new Exception("Changed artifact accepted"); }
                catch (WorkshopException e) when (e.Code == "codex_artifact_changed") { }
                requestId = Guid.NewGuid().ToString();
                var parameters = Json(new { requestId, applicationId, threadId = FixtureThread, name = "Fixture", message = "Run fixture", reasoningEffort = "high" });
                using var requestLife = new CancellationTokenSource();
                var started = Result(await service.StartAsync(parameters, requestLife.Token));
                Check(started.GetProperty("startedAt").GetInt64() > 0 && started.GetProperty("finishedAt").ValueKind == JsonValueKind.Null,
                    "A new operation must expose its start without inventing a terminal time");
                Check(JsonDocument.Parse(File.ReadAllBytes(Path.Combine(storage, requestId + ".json"))).RootElement.GetProperty("notificationScope").GetString() == "fixture-cloud",
                    "LAN/shared worker did not persist its configured cloud notification scope");
                requestLife.Cancel();
                Check(Result(await service.StartAsync(parameters, default)).GetProperty("id").GetString() == started.GetProperty("id").GetString(), "Request deduplication failed");
                try { await service.StartAsync(Json(new { requestId, applicationId, threadId = FixtureThread, message = "different" }), default); throw new Exception("Request ID reused for different payload"); }
                catch (WorkshopException e) when (e.Code == "codex_request_conflict") { }
                var waiting = await WaitAsync(service, requestId, "waiting");
                Check(CodexJson.Text(waiting.GetProperty("operation"), "model") == "fixture-resolved" &&
                    CodexJson.Text(waiting.GetProperty("operation"), "reasoningEffort") == "high",
                    "Running task lost its resolved model or explicit turn reasoning effort");
                Check(!notifications.ContainsKey(requestId), "Waiting for user input was reported as task completion");
                Check(CodexJson.Text(Result(await service.CatalogAsync(Json(new { }), default)).GetProperty("sessions")[0], "state") == "waiting",
                    "An executing job awaiting approval must take precedence over older completed history");
                try { await service.ArchiveAsync(Json(new { threadId = FixtureThread, archived = true }), default); throw new Exception("Running turn was archived"); }
                catch (WorkshopException e) when (e.Code == "codex_busy") { }
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
                Check(CodexJson.Text(JsonDocument.Parse(File.ReadAllBytes(Path.Combine(storage, queuedId + ".json"))).RootElement, "reasoningEffort") == "high", "A queued message lost its inherited reasoning effort");
                try { await service.QueueAsync(Json(new { operationId = requestId, requestId = queuedId, message = "Follow-up fixture", reasoningEffort = "low" }), default); throw new Exception("Reasoning change reused a queued request ID"); }
                catch (WorkshopException e) when (e.Code == "codex_request_conflict") { }
                var editId = Guid.NewGuid().ToString();
                var edit = Json(new { operationId = requestId, messageId = queuedId, requestId = editId, revision = 0, message = "Edited follow-up" });
                var edited = Result(await service.UpdateMessageAsync(edit, default));
                Check(CodexJson.Text(edited, "message") == "Edited follow-up" && edited.GetProperty("revision").GetInt32() == 1, "Queued edit was lost");
                await service.UpdateMessageAsync(edit, default);
                try { await service.CancelMessageAsync(Json(new { operationId = requestId, messageId = queuedId, requestId = Guid.NewGuid().ToString(), revision = 0 }), default); throw new Exception("Stale revision accepted"); }
                catch (WorkshopException e) when (e.Code == "codex_message_changed") { }
                var steerId = Guid.NewGuid().ToString();
                var steerRequest = Json(new { operationId = requestId, messageId = queuedId, requestId = steerId, revision = 1 });
                Check(CodexJson.Text(Result(await service.SteerMessageAsync(steerRequest, default)), "state") == "steered", "Queued message was not steered");
                await service.SteerMessageAsync(steerRequest, default);
                var steeredHistory = Result(await service.HistoryAsync(Json(new { threadId = FixtureThread }), default)).GetProperty("entries");
                Check(steeredHistory.EnumerateArray().Count(value => CodexJson.Text(value, "id") == queuedId &&
                    CodexJson.Text(value, "text") == "Edited follow-up") == 1,
                    "Accepted Steer history did not use the durable request ID; the phone will retain two bubbles");
                Check(!steeredHistory.EnumerateArray().Any(value => CodexJson.Text(value, "id") == "canonical-" + queuedId),
                    "History kept a second canonical identity for the steered request");
                var cancelledId = Guid.NewGuid().ToString();
                await service.QueueAsync(Json(new { operationId = requestId, requestId = cancelledId, message = "Cancelled follow-up" }), default);
                await service.CancelMessageAsync(Json(new { operationId = requestId, messageId = cancelledId, requestId = Guid.NewGuid().ToString(), revision = 0 }), default);
                var automaticId = Guid.NewGuid().ToString();
                await service.QueueAsync(Json(new { operationId = requestId, requestId = automaticId, message = "Automatic follow-up", reasoningEffort = "future-effort" }), default);
                var approval = waiting.GetProperty("approvals")[0].GetProperty("id").GetString();
                try { await service.AnswerAsync(Json(new { operationId = requestId, approvalId = approval, decision = "invalid" }), default); throw new Exception("Invalid approval accepted"); }
                catch (WorkshopException e) when (e.Code == "invalid_params") { }
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
                var firstTiming = JsonSerializer.Deserialize<WorkshopJob>(File.ReadAllBytes(Path.Combine(storage, requestId + ".json")), WorkshopProtocol.Json)!;
                Check(nextTurn.GetProperty("operation").GetProperty("startedAt").GetInt64() >= firstTiming.FinishedAt / 1000 &&
                    nextTurn.GetProperty("operation").GetProperty("finishedAt").ValueKind == JsonValueKind.Null,
                    "The next round's clock must start after the preceding round finishes, excluding queue wait");
                await service.AnswerAsync(Json(new { operationId = requestId, approvalId = nextTurn.GetProperty("approvals")[0].GetProperty("id").GetString(), decision = "accept" }), default);
                var completed = await WaitAsync(service, requestId, "completed");
                Check(CodexJson.Text(completed.GetProperty("operation"), "model") == "fixture-resolved" &&
                    CodexJson.Text(completed.GetProperty("operation"), "reasoningEffort") == "future-effort",
                    "Grouped operation settings must belong to the latest round, not the original request");
                var latestTiming = JsonSerializer.Deserialize<WorkshopJob>(File.ReadAllBytes(Path.Combine(storage, automaticId + ".json")), WorkshopProtocol.Json)!;
                completedStart = completed.GetProperty("operation").GetProperty("startedAt").GetInt64();
                completedEnd = completed.GetProperty("operation").GetProperty("finishedAt").GetInt64();
                Check(completedStart == latestTiming.StartedAt && completedEnd == latestTiming.FinishedAt && completedEnd >= completedStart * 1000,
                    "Grouped operation timing must belong to the displayed round and use its durable completion timestamp");
                await liveDone.Task.WaitAsync(TimeSpan.FromSeconds(3));
                liveLife.Cancel();
                try { await liveStream; } catch (OperationCanceledException) { }
                var completedSession = Result(await service.CatalogAsync(Json(new { }), default)).GetProperty("sessions")[0];
                Check(CodexJson.Text(completedSession, "state") == "completed" && CodexJson.Text(completedSession, "completionId").Length > 0,
                    "A finished worker stayed running in the catalog or lost its unread completion identity");
                File.WriteAllText(summaryStatus, "inProgress");
                var staleCompleted = Result(await service.CatalogAsync(Json(new { }), default)).GetProperty("sessions")[0];
                Check(CodexJson.Text(staleCompleted, "state") == "completed" && CodexJson.Text(staleCompleted, "completionId").Length > 0,
                    "A later catalog poll restored running from a stale metadata connection after the worker completed");
                File.Delete(summaryStatus);
                await service.AnswerAsync(Json(new { operationId = requestId, approvalId = approval, decision = "accept" }), default);
                Check(completed.GetProperty("events").EnumerateArray().Any(value => CodexJson.Text(value, "text") == "Fixture completed"), "Streamed answer was lost");
                Check(completed.GetProperty("followups").GetArrayLength() == 3, "Follow-up ledger did not survive turn handoff");
                var cursor = completed.GetProperty("cursor").GetInt64();
                Check(Result(await service.OperationAsync(Json(new { operationId = requestId, cursor }), default)).GetProperty("events").GetArrayLength() == 0, "Cursor replay duplicated events");
                var stopId = Guid.NewGuid().ToString();
                await service.StartAsync(Json(new { requestId = stopId, applicationId, threadId = FixtureThread, message = "Stop fixture" }), default);
                var inherited = await WaitAsync(service, stopId, "waiting");
                Check(CodexJson.Text(inherited.GetProperty("operation"), "reasoningEffort") == "medium",
                    "Following the session substituted the model catalog's default reasoning effort");
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
                    message = "Image fixture", model = "fixture-vision", permission = "auto", imageIds = new[] { imageId }, serviceTier = "priority", reasoningEffort = "high" }), default);
                var imageWaiting = await WaitAsync(service, imageRequest, "waiting");
                var downloaded = Result(await service.ImageAsync(Json(new { threadId = FixtureThread, messageId = imageRequest, index = 0, offset = 0 }), default));
                Check(Convert.FromBase64String(CodexJson.Text(downloaded, "content")).SequenceEqual(imageBytes), "Message image bytes did not round trip");
                Check(CodexJson.Text(downloaded, "revision") == digest.ToLowerInvariant(), "Message image integrity hash was lost");
                try { await service.ImageAsync(Json(new { threadId = FixtureThread, messageId = imageRequest, index = 0, offset = 0, revision = "changed" }), default); throw new Exception("Changed image revision accepted"); }
                catch (WorkshopException e) when (e.Code == "codex_image_changed") { }
                try { await service.ImageAsync(Json(new { threadId = Guid.NewGuid().ToString(), messageId = imageRequest, index = 0, offset = 0 }), default); throw new Exception("Image leaked across threads"); }
                catch (WorkshopException e) when (e.Code == "codex_image_missing") { }
                var imageApproval = imageWaiting.GetProperty("approvals")[0].GetProperty("id").GetString();
                await service.AnswerAsync(Json(new { operationId = imageRequest, approvalId = imageApproval, decision = "accept" }), default);
                await WaitAsync(service, imageRequest, "completed");
                try { await service.StartAsync(Json(new { requestId = imageRequest, applicationId, threadId = FixtureThread,
                    message = "Image fixture", model = "other-model", permission = "auto", imageIds = new[] { imageId } }), default); throw new Exception("Model change reused an existing request ID"); }
                catch (WorkshopException e) when (e.Code == "codex_request_conflict") { }
                try { await service.StartAsync(Json(new { requestId = imageRequest, applicationId, threadId = FixtureThread,
                    message = "Image fixture", model = "fixture-vision", permission = "auto", imageIds = new[] { imageId }, serviceTier = "default" }), default); throw new Exception("Speed change reused an existing request ID"); }
                catch (WorkshopException e) when (e.Code == "codex_request_conflict") { }
                var standardId = Guid.NewGuid().ToString();
                foreach (var invalidEffort in new object[] { 123, "", " ", "high\0bad", new string('x', 101) })
                {
                    try { await service.StartAsync(Json(new { requestId = Guid.NewGuid().ToString(), applicationId, message = "Invalid effort", reasoningEffort = invalidEffort }), default); throw new Exception("Invalid reasoning effort accepted"); }
                    catch (WorkshopException e) when (e.Code == "invalid_params") { }
                }
                await service.StartAsync(Json(new { requestId = standardId, applicationId, message = "Standard fixture", serviceTier = "default", systemPrompt = FixtureSystemPrompt, reasoningEffort = "low" }), default);
                try { await service.StartAsync(Json(new { requestId = standardId, applicationId, message = "Standard fixture", serviceTier = "default", systemPrompt = FixtureSystemPrompt, reasoningEffort = "high" }), default); throw new Exception("Reasoning change reused request ID"); }
                catch (WorkshopException e) when (e.Code == "codex_request_conflict") { }
                var savedPrompt = JsonDocument.Parse(File.ReadAllBytes(Path.Combine(storage, standardId + ".json")));
                Check(CodexJson.Text(savedPrompt.RootElement, "systemPrompt") == FixtureSystemPrompt, "Initial prompt was not durably captured with the first request");
                try { await service.StartAsync(Json(new { requestId = standardId, applicationId, message = "Standard fixture", serviceTier = "default", systemPrompt = "Changed" }), default); throw new Exception("Prompt change reused the original request ID"); }
                catch (WorkshopException e) when (e.Code == "codex_request_conflict") { }
                foreach (var invalidPrompt in new object[] { 123, new string('x', 4001), "invalid\0prompt" })
                {
                    try { await service.StartAsync(Json(new { requestId = Guid.NewGuid().ToString(), applicationId, message = "Invalid", systemPrompt = invalidPrompt }), default); throw new Exception("Invalid prompt accepted"); }
                    catch (WorkshopException e) when (e.Code == "invalid_params") { }
                }
                try { await service.StartAsync(Json(new { requestId = Guid.NewGuid().ToString(), applicationId, threadId = FixtureThread, message = "Existing", systemPrompt = FixtureSystemPrompt }), default); throw new Exception("Existing conversation accepted a replacement system prompt"); }
                catch (WorkshopException e) when (e.Code == "invalid_params") { }
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
                catch (WorkshopException e) when (e.Code == "invalid_params") { }
                Check(Result(await service.OperationAsync(Json(new { operationId = questionId }), default)).GetProperty("approvals").GetArrayLength() == 1,
                    "Validation consumed the question before explicit confirmation");
                await service.AnswerAsync(Json(new { operationId = questionId, approvalId = questionApproval, answers = new { network = "服务器认证" } }), default);
                await WaitAsync(service, questionId, "completed");
                var asyncRequest = Guid.NewGuid().ToString();
                await service.StartAsync(Json(new { requestId = asyncRequest, applicationId, threadId = FixtureThread, message = "Async question fixture" }), default);
                var asyncPage = await WaitAsync(service, asyncRequest, "completed");
                Check(asyncPage.GetProperty("events").EnumerateArray().Any(entry => CodexJson.Text(entry, "id") == "async-fixture" &&
                    entry.GetProperty("questions")[0].GetProperty("options")[1].GetString() == "同步升级"), "Async options did not reach the operation stream");
                var noticeDeadline = DateTime.UtcNow.AddSeconds(3);
                while (asyncNotices.IsEmpty && DateTime.UtcNow < noticeDeadline) await Task.Delay(10);
                Check(asyncNotices.TryPeek(out var asyncNotice) && asyncNotice.QuestionId == "async-fixture" &&
                    asyncNotice.State == "input_required" && asyncNotice.ThreadId == FixtureThread, "Async question did not produce its own durable push receipt");
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
                var notificationDeadline = DateTime.UtcNow.AddSeconds(3);
                while ((!notifications.ContainsKey(failureId) || !notifications.ContainsKey(automaticId) || !notifications.ContainsKey(stopId)) && DateTime.UtcNow < notificationDeadline)
                    await Task.Delay(10);
                Check(notifications[requestId].State == "completed" && notifications[automaticId].State == "completed" &&
                    notifications[stopId].State == "interrupted" && notifications[failureId].State == "failed",
                    "Actual worker outcomes did not reach the background notification outbox");
                Check(notifications[requestId].ProjectName == "fixture" && notifications[requestId].SessionName == "Fixture" &&
                    notifications[requestId].Summary == "Fixture completed" && notifications[automaticId].Summary == "Fixture completed",
                    "Completed rounds lost the project, canonical session name or final assistant reply");
                Check(notifications[failureId].Summary == "" && notifications[stopId].Summary == "",
                    "A failed or interrupted round reused a reply from the previous round");
                Check(!notifications.ContainsKey(cancelledId) && !notifications.ContainsKey(queuedId) && !notifications.ContainsKey(afterFailure),
                    "Cancelled, steered or paused messages incorrectly generated terminal notifications");
                notificationLife.Cancel();
                try { await notificationWatch; } catch (OperationCanceledException) { }
            }
            await using (var recovered = new CodeWorkshop(storage, code, startServer: token => Start(token)))
            {
                var reopened = Result(await recovered.OperationAsync(Json(new { operationId = requestId }), default)).GetProperty("operation");
                Check(reopened.GetProperty("state").GetString() == "completed", "Durable job recovery failed");
                Check(reopened.GetProperty("startedAt").GetInt64() == completedStart && reopened.GetProperty("finishedAt").GetInt64() == completedEnd,
                    "Reopening a completed operation must preserve its duration instead of counting time since completion");
            }
            await using (var occupied = new CodeWorkshop(Path.Combine(directory, "occupied"), code, startServer: token => Start(token, true)))
            {
                var busyId = Guid.NewGuid().ToString();
                await occupied.StartAsync(Json(new { requestId = busyId, applicationId, threadId = FixtureThread, message = "Check lock" }), default);
                var failed = await WaitAsync(occupied, busyId, "failed");
                Check(CodexJson.Text(failed.GetProperty("operation"), "message").Contains("桌面版仍占用"), "Writer conflict was not translated");
            }
            await using (var slow = new CodeWorkshop(Path.Combine(directory, "slow"), code, startServer: token => Start(token, scenario: "slow-resume")))
            {
                var slowId = Guid.NewGuid().ToString();
                await slow.StartAsync(Json(new { requestId = slowId, applicationId, threadId = FixtureThread, message = "Slow resume" }), default);
                await WaitAsync(slow, slowId, "waiting");
                await slow.StopAsync(Json(new { operationId = slowId }), default);
                await WaitAsync(slow, slowId, "interrupted");
            }
            foreach (var scenario in new[] { "reject-resume", "lost-start-reply" })
            {
                await using var failing = new CodeWorkshop(Path.Combine(directory, scenario), code, startServer: token => Start(token, scenario: scenario));
                var failedId = Guid.NewGuid().ToString();
                var request = Json(new { requestId = failedId, applicationId, threadId = FixtureThread, message = "Fail safely" });
                await failing.StartAsync(request, default);
                var page = await WaitAsync(failing, failedId, scenario == "reject-resume" ? "failed" : "unknown");
                var detail = CodexJson.Text(page.GetProperty("operation"), "message");
                Check(scenario == "reject-resume" ? detail.Contains("恢复会话") && detail.Contains("尚未发送") : detail.Contains("结果尚未确认") && !detail.Contains("尚未发送"),
                    "Startup rejection and an uncertain turn submission must have different recovery instructions: " + detail);
                Check(!detail.Contains("登录"), "A startup error incorrectly diagnosed a login problem");
                var duplicate = Result(await failing.StartAsync(request, default));
                Check(CodexJson.Text(duplicate, "state") == CodexJson.Text(page.GetProperty("operation"), "state"),
                    "Retrying the same request must not automatically submit a failed or uncertain turn");
            }
            var startupAttempts = 0;
            await using (var timeout = new CodeWorkshop(Path.Combine(directory, "timeout"), code, startServer: _ =>
            {
                startupAttempts++;
                return Task.FromException<CodexAppServer>(new TimeoutException());
            }))
            {
                var timeoutId = Guid.NewGuid().ToString();
                var request = Json(new { requestId = timeoutId, applicationId, threadId = FixtureThread, message = "Startup timeout" });
                await timeout.StartAsync(request, default);
                var page = await WaitAsync(timeout, timeoutId, "failed");
                var detail = CodexJson.Text(page.GetProperty("operation"), "message");
                Check(detail.Contains("启动 Codex") && detail.Contains("响应超时") && detail.Contains("尚未发送") && !detail.Contains("登录"),
                    "Startup timeout was hidden behind an unrelated login error: " + detail);
                await timeout.StartAsync(request, default);
                Check(startupAttempts == 1, "A failed startup was retried without a new explicit send");
            }
            var recoveryStorage = Path.Combine(directory, "recovery");
            Directory.CreateDirectory(recoveryStorage);
            var recoveredJob = new WorkshopJob { Id = Guid.NewGuid().ToString("D"), ThreadId = FixtureThread,
                TurnId = "fixture-turn", State = "unknown", Cwd = project, ApplicationId = applicationId,
                Submitted = true, Message = "Old uncertainty" };
            File.WriteAllBytes(Path.Combine(recoveryStorage, recoveredJob.Id + ".json"), JsonSerializer.SerializeToUtf8Bytes(recoveredJob, WorkshopProtocol.Json));
            await using (var recovery = new CodeWorkshop(recoveryStorage, code, Path.Combine(directory, ".codex"), token => Start(token)))
            {
                await recovery.HistoryAsync(Json(new { threadId = FixtureThread }), default);
                var reconciled = Result(await recovery.OperationAsync(Json(new { operationId = recoveredJob.Id }), default)).GetProperty("operation");
                Check(CodexJson.Text(reconciled, "state") == "completed" && CodexJson.Text(reconciled, "message") == "",
                    "History refresh did not persist a verified outcome for the operation API");
                var saved = JsonSerializer.Deserialize<WorkshopJob>(File.ReadAllBytes(Path.Combine(recoveryStorage, recoveredJob.Id + ".json")), WorkshopProtocol.Json)!;
                Check(saved.State == "completed" && saved.Message is null, "Reconciled outcome did not survive a restart");
                Check(saved.ReplySummary.Length == 0, "Recovery used an earlier display summary instead of the actual final reply containing only a prototype reference");
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
        var scenario = Environment.GetEnvironmentVariable("HAKO_CODEX_TEST_SCENARIO");
        Check(Environment.GetEnvironmentVariable("CODEX_WINDOWS_REGISTERED_CORE") is null,
            "Codex CLI inherited the desktop app's registered Core identity");
        var project = Environment.GetEnvironmentVariable("HAKO_CODEX_TEST_PROJECT")!;
        var turnId = "fixture-turn";
        var archived = false;
        JsonElement? waitingModel = null;
        void Write(object message) { Console.WriteLine(JsonSerializer.Serialize(message, WorkshopProtocol.Json)); Console.Out.Flush(); }
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
                Write(new { method = "item/completed", @params = new { item = new { id = "commentary", type = "agentMessage", text = "Earlier progress update" } } });
                Write(new { method = "item/agentMessage/delta", @params = new { threadId = FixtureThread, itemId = "answer", delta = "Fixture " } });
                Write(new { method = "item/completed", @params = new { item = new { id = "answer", type = "agentMessage", text = "Fixture completed" } } });
                Write(new { method = "item/completed", @params = new { item = new { id = "tool-log", type = "commandExecution", command = "fixture", aggregatedOutput = "Tool output must not replace the reply" } } });
                Write(new { method = "turn/completed", @params = new { turn = new { id = turnId, status = "completed" } } });
                continue;
            }
            if (!input.TryGetProperty("id", out var id)) continue;
            if (method == "initialize")
                Check(CodexJson.Field(CodexJson.Field(CodexJson.Field(input, "params"), "capabilities"), "experimentalApi").ValueKind == JsonValueKind.True,
                    "The client did not opt into the structured input protocol");
            if (method == "thread/turns/list")
            {
                if (File.Exists(Path.Combine(project, ".catalog-pages"))) File.AppendAllText(Path.Combine(project, ".catalog-summary-count"), "read\n");
                var options = CodexJson.Field(input, "params");
                Check(CodexJson.Text(options, "sortDirection") == "desc" && CodexJson.Field(options, "limit").GetInt32() == 1,
                    "Catalog/history must request only one upstream turn");
                Check(CodexJson.Text(options, "itemsView") == "summary", "History hydrated a complete upstream turn");
            }
            if (method == "thread/list")
                Check(CodexJson.Field(CodexJson.Field(input, "params"), "useStateDbOnly").ValueKind == JsonValueKind.True &&
                    CodexJson.Text(CodexJson.Field(input, "params"), "sortKey") == "recency_at" &&
                    CodexJson.Text(CodexJson.Field(input, "params"), "sortDirection") == "desc",
                    "Catalog must read lightweight metadata in user-send order, independently of execution updates");
            if (method == "thread/list" && File.Exists(Path.Combine(project, ".catalog-pages")))
            {
                File.AppendAllText(Path.Combine(project, ".catalog-scans"), "scan\n");
                var cursor = CodexJson.Text(CodexJson.Field(input, "params"), "cursor");
                var offset = cursor.Length == 0 ? 0 : int.Parse(cursor.Replace("native-", ""));
                var data = Enumerable.Range(offset, Math.Min(20, 65 - offset))
                    .Where(index => index != 35 || !File.Exists(Path.Combine(project, ".catalog-hidden"))).Select(index => new {
                    id = index == 64 ? FixtureThread : new Guid(index + 1, 0, 0, new byte[8]).ToString("D"),
                    cwd = project, name = "Catalog fixture", preview = "Preview", updatedAt = 999999 - index,
                    recencyAt = index == 64 && File.Exists(Path.Combine(project, ".catalog-outside")) ? 10000 :
                        index == 64 && File.Exists(Path.Combine(project, ".catalog-delayed")) ? 9000 : 1000 - index
                }).ToArray();
                Write(new { id, result = new { data, nextCursor = offset + 20 < 65 ? "native-" + (offset + 20) : null } });
                continue;
            }
            if (method == "thread/items/list" && CodexJson.Field(CodexJson.Field(input, "params"), "limit").GetInt32() != 64)
            {
                Check(CodexJson.Text(CodexJson.Field(input, "params"), "sortDirection") == "desc", "Latest user reads must scan backwards");
                var cursor = CodexJson.Text(CodexJson.Field(input, "params"), "cursor");
                var previewFile = Path.Combine(project, ".catalog-preview");
                if (!File.Exists(Path.Combine(project, ".catalog-owner")))
                {
                    var text = File.Exists(previewFile) ? File.ReadAllText(previewFile) : "Latest fixture reply";
                    object[] messages = cursor.Length == 0 ? new object[] {
                        new { turnId, item = new { type = "commandExecution", id = "last-tool", command = "ignored" } },
                        new { turnId, item = new { type = "agentMessage", id = "empty-message", text = "  " } }
                    } : new object[] {
                        new { turnId, item = new { type = text.Contains("Steer") ? "userMessage" : "agentMessage", id = "actual-latest",
                            text, content = new[] { new { type = "text", text } } } }
                    };
                    Write(new { id, result = new { data = messages, nextCursor = cursor.Length == 0 ? "older-message" : null } });
                    continue;
                }
                var outside = File.Exists(Path.Combine(project, ".catalog-outside"));
                object[] data = cursor.Length == 0 ? new object[] { new { turnId, item = new { type = "commandExecution", id = "tool", command = "ignored" } } } :
                    new object[] { new { turnId, item = new { type = "userMessage", id = "canonical-user", clientId = outside ? "external" : File.ReadAllText(Path.Combine(project, ".catalog-owner")),
                        content = new[] { new { type = "text", text = outside ? "Desktop follow-up" : "Accepted queued input" } } } } };
                Write(new { id, result = new { data, nextCursor = cursor.Length == 0 ? "older-user" : null } });
                continue;
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
                if (method == "thread/start")
                {
                    Check(CodexJson.Text(options, "serviceTier") == "default", "Standard thread speed was lost");
                    Check(CodexJson.Text(options, "developerInstructions") == FixtureSystemPrompt,
                        "New thread did not receive its system prompt as developer instructions");
                }
                else Check(CodexJson.Field(options, "developerInstructions").ValueKind == JsonValueKind.Undefined,
                    "Resuming an existing or queued conversation resent/replaced its system prompt");
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
                foreach (var (message, effort) in new[] { ("Run fixture", "high"), ("Image fixture", "high"), ("Standard fixture", "low"), ("Automatic follow-up", "future-effort") })
                    if (items.Any(value => CodexJson.Text(value, "text") == message))
                        Check(CodexJson.Text(parameters, "effort") == effort, "Reasoning effort was not sent to the actual Codex turn: " + message);
            }
            if (method == "turn/steer")
            {
                var parameters = CodexJson.Field(input, "params");
                Check(CodexJson.Text(parameters, "expectedTurnId") == turnId && CodexJson.Text(parameters, "threadId") == FixtureThread,
                    "Steer targeted the wrong turn");
                Check(CodexJson.Items(CodexJson.Field(parameters, "input")).Any(value => CodexJson.Text(value, "text") == "Edited follow-up"), "Steer did not use edited text");
                File.AppendAllText(Path.Combine(project, ".steered-inputs.jsonl"), JsonSerializer.Serialize(new {
                    id = "canonical-" + CodexJson.Text(parameters, "clientUserMessageId"), type = "userMessage",
                    clientUserMessageId = CodexJson.Text(parameters, "clientUserMessageId"), content = CodexJson.Field(parameters, "input")
                }, WorkshopProtocol.Json) + "\n");
            }
            if (method == "thread/resume" && Environment.GetEnvironmentVariable("HAKO_CODEX_TEST_OCCUPIED") == "1")
            { Write(new { id, error = new { code = -32600, message = "thread-store conflict: already has an active writer" } }); continue; }
            if (scenario == "concurrent-reads" && method == "model/list" && waitingModel is null)
            { waitingModel = id.Clone(); File.WriteAllText(Path.Combine(project, ".model-waiting"), "waiting"); continue; }
            if (scenario == "concurrent-reads" && method == "thread/read")
            {
                File.AppendAllText(Path.Combine(project, ".history-reads"), "read\n");
                if (waitingModel is { } modelId)
                {
                    Write(new { id = modelId, result = new { data = Array.Empty<object>(), nextCursor = (string?)null } });
                    waitingModel = null;
                }
            }
            if (method == "thread/resume" && scenario == "slow-resume") await Task.Delay(8500);
            if (method == "thread/resume" && scenario == "reject-resume")
            { Write(new { id, error = new { code = -32600, message = "Unable to resume this thread" } }); continue; }
            if (method == "turn/start" && scenario == "lost-start-reply") return;
            var historyItems = new List<object>();
            var steeredInputs = Path.Combine(project, ".steered-inputs.jsonl");
            if (File.Exists(steeredInputs))
                foreach (var historyLine in File.ReadAllLines(steeredInputs))
                {
                    using var stored = JsonDocument.Parse(historyLine);
                    historyItems.Add(stored.RootElement.Clone());
                }
            historyItems.Add(new { id = "generated-fixture", type = "imageGeneration", status = "completed", savedPath = Path.Combine(project, "generated-fixture.png") });
            historyItems.Add(new { id = "history", type = "agentMessage", text = "visualize" + JsonSerializer.Serialize(new { path = Path.Combine(project, "prototype.html") }) + "" });
            if (scenario == "paged-history")
            {
                historyItems = Enumerable.Range(0, File.Exists(Path.Combine(project, ".history-new-item")) ? 76 : 75)
                    .Select(index => (object)new { id = "history-" + index, type = "agentMessage", text = "History " + index }).ToList();
            }
            var itemOptions = CodexJson.Field(input, "params");
            var itemCursor = CodexJson.Text(itemOptions, "cursor");
            var itemOffset = method == "thread/items/list" && itemCursor.Length > 0 ? int.Parse(itemCursor) : 0;
            if (method == "thread/items/list") File.AppendAllText(Path.Combine(project, ".history-item-reads"), "read\n");
            if (method == "thread/read") Check(CodexJson.Field(itemOptions, "includeTurns").ValueKind == JsonValueKind.False,
                "A history/image request hydrated the full thread");
            var thread = new
            {
                id = FixtureThread, cwd = CodexJson.Text(CodexJson.Field(input, "params"), "threadId") == "22222222-2222-4222-8222-222222222222" ? Path.GetDirectoryName(project)! : project,
                name = "Fixture", preview = "Fixture history", updatedAt = 1000, recencyAt = 1,
                model = "fixture-session", reasoningEffort = "max",
                fixtureRevision = string.Join("|", new[] { ".catalog-preview", ".summary-status" }.Select(name =>
                    File.Exists(Path.Combine(project, name)) ? File.ReadAllText(Path.Combine(project, name)) : "")),
                status = new { type = method == "thread/list" ? "active" : "idle", activeFlags = Array.Empty<string>() },
                turns = new[] { new { id = turnId, status = "completed", items = historyItems.ToArray() } }
            };
            object result = method switch
            {
                "model/list" => new { data = new[] { new { model = "fixture-vision", displayName = "Fixture Vision", description = "Fixture", isDefault = true, defaultReasoningEffort = "low", supportedReasoningEfforts = new[] { new { reasoningEffort = "high", description = "Deep reasoning" }, new { reasoningEffort = "low", description = "Quick reasoning" }, new { reasoningEffort = "future-effort", description = "Future model level" } }, inputModalities = new[] { "text", "image" }, serviceTiers = new[] { new { id = "priority", name = "Fast", description = "Faster fixture" } } } }, nextCursor = (string?)null },
                "thread/list" => new { data = archived == (CodexJson.Field(CodexJson.Field(input, "params"), "archived").ValueKind == JsonValueKind.True) ? new[] { thread } : [], nextCursor = (string?)null },
                "thread/turns/list" => new { data = new[] { new { id = turnId, status = File.Exists(Path.Combine(project, ".summary-status")) ? File.ReadAllText(Path.Combine(project, ".summary-status")) : "completed", items = CodexJson.Text(CodexJson.Field(input, "params"), "itemsView") == "full" ? historyItems.ToArray() : new object[] { new { id = "latest", type = "agentMessage", text = "Earlier summarized reply" } } } }, nextCursor = (string?)null },
                "thread/read" => new { thread },
                "thread/items/list" => new { data = historyItems.AsEnumerable().Reverse().Skip(itemOffset).Take(64)
                    .Select(item => new { turnId, item }).ToArray(), nextCursor = itemOffset + 64 < historyItems.Count ? (itemOffset + 64).ToString() : null },
                "thread/resume" or "thread/start" => new { thread, model = "fixture-resolved", reasoningEffort = "medium" },
                "turn/start" => new { turn = new { id = turnId, status = "inProgress" } },
                "turn/steer" => new { turnId },
                _ => new { }
            };
            Write(new { id, result });
            if (method == "turn/start")
            {
                if (CodexJson.Items(CodexJson.Field(CodexJson.Field(input, "params"), "input")).Any(value => CodexJson.Text(value, "text") == "Async question fixture"))
                {
                    Write(new { method = "item/completed", @params = new { threadId = FixtureThread, turnId, item = new {
                        id = "async-fixture", type = "agentMessage", text = "需要你选择升级方式", delivery = "async",
                        questions = new[] { new { title = "如何升级？", options = new[] { "保持现状", "同步升级" } } } } } });
                    Write(new { method = "turn/completed", @params = new { turn = new { id = turnId, status = "completed" } } });
                    continue;
                }
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
