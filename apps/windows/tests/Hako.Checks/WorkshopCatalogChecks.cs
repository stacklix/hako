using System;
using System.Linq;
using System.Text.Json;
using Hako.Platform;

internal static class WorkshopCatalogChecks
{
    private static JsonElement Json(object value) => JsonSerializer.SerializeToElement(value, WorkshopProtocol.Json);
    private static void Check(bool condition, string message) { if (!condition) throw new Exception(message); }

    public static void Run()
    {
        var thread = Json(new { recencyAt = 500, updatedAt = 9000 });
        Check(CodeWorkshop.CatalogSendTime(thread, null, []) == 500, "Execution activity became the send timestamp");
        var accepted = new WorkshopJob { Id = "request", TurnId = "turn", InputMessage = "Question",
            QueueOrder = DateTime.UnixEpoch.AddSeconds(100).Ticks, StartedAt = 500 };
        var summary = CodeWorkshop.SummarizeTurn(Json(new { id = "turn", status = "inProgress", items = new object[] {
            new { type = "userMessage", id = "canonical", clientUserMessageId = "request", content = new[] { new { type = "text", text = "Question" } } }
        } }));
        Check(CodeWorkshop.CatalogSendTime(thread, summary, [accepted]) == 100,
            "Starting an accepted queued message later changed its send time");
        accepted.StartedAt = 9999; accepted.State = "completed";
        Check(CodeWorkshop.CatalogSendTime(thread, summary, [accepted]) == 100,
            "Completion, restart or rereading changed a persisted acceptance time");
        var queued = new WorkshopJob { Id = "queued", RootId = "request", QueueOrder = DateTime.UnixEpoch.AddSeconds(600).Ticks, State = "queued" };
        Check(CodeWorkshop.CatalogSendTime(thread, summary, [accepted, queued]) == 600,
            "A newly accepted queued message did not promote its thread");
        var outside = CodeWorkshop.SummarizeTurn(Json(new { id = "turn", status = "inProgress", items = new object[] {
            new { type = "userMessage", id = "outside", content = new[] { new { type = "text", text = "Desktop follow-up" } } }
        } }));
        Check(CodeWorkshop.CatalogSendTime(thread, outside, [accepted]) == 500,
            "A later desktop message was hidden by a previous Agent request");
        var application = new WorkshopApplication("app", "App", "project");
        var rows = Enumerable.Range(0, 65).Select(index => new CodeWorkshop.CatalogRow(
            Json(new { id = new Guid(index + 1, 0, 0, new byte[8]).ToString("D") }), application, index / 3)).ToArray();
        var first = CodeWorkshop.CatalogPage(rows, "", false);
        var second = CodeWorkshop.CatalogPage(rows.Reverse(), first.NextCursor!, false);
        var third = CodeWorkshop.CatalogPage(rows, second.NextCursor!, false);
        var all = first.Rows.Concat(second.Rows).Concat(third.Rows).ToArray();
        Check(first.Rows.Length == 30 && second.Rows.Length == 30 && third.Rows.Length == 5 && third.NextCursor is null &&
            all.Select(row => row.Id).Distinct().Count() == 65 && all.SequenceEqual(rows.OrderByDescending(row => row.LastSentAt).ThenBy(row => row.Id, StringComparer.Ordinal)),
            "Keyset pagination lost, duplicated or reordered equal-time threads");
        try { CodeWorkshop.CatalogPage(rows, first.NextCursor!, true); throw new Exception("Cross-filter cursor accepted"); }
        catch (WorkshopException error) when (error.Code == "invalid_params") { }
        try { CodeWorkshop.CatalogPage(rows, "invalid", false); throw new Exception("Malformed cursor accepted"); }
        catch (WorkshopException error) when (error.Code == "invalid_params") { }
    }
}
