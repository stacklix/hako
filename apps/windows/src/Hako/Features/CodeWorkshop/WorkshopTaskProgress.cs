using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;

namespace Hako.Platform;

internal sealed record WorkshopTaskStage(string Id, string Name, string Status);
internal sealed record WorkshopTaskRelease(string BundleId, string Version, string Build, string MetadataUrl);
internal sealed record WorkshopProgressTask(string Id, string Name, string Project, string Platform, string Status,
    long CreatedAt, long UpdatedAt, WorkshopTaskStage[] Stages, string? Message = null, WorkshopTaskRelease? Release = null,
    string? Summary = null);
internal sealed record WorkshopProgressRecord(int Schema, string ThreadId, WorkshopProgressTask Task);

// Local skills publish progress; the Agent only reads bounded, session-scoped
// records. There is no build-tool, repository or shell execution in this API.
internal static class WorkshopTaskProgress
{
    private static readonly string[] States = ["queued", "pending", "running", "succeeded", "failed", "cancelled", "unknown", "skipped"];
    private static bool Label(string? value, int maximum, bool empty = false) => value is not null &&
        (empty || value.Length > 0) && value.Length <= maximum && !value.Any(char.IsControl);
    private static bool Id(string? value) => value is not null && Regex.IsMatch(value, "\\A[a-zA-Z0-9_-]{1,80}\\z");
    private static bool Valid(WorkshopProgressTask task)
    {
        if (!Id(task.Id) || !Label(task.Name, 120) || !Label(task.Project, 160) || !Label(task.Platform, 40) ||
            !States.Contains(task.Status) || task.CreatedAt <= 0 || task.UpdatedAt < task.CreatedAt ||
            task.Stages is null || task.Stages.Length > 16 || task.Stages.Any(stage => stage is null ||
                !Id(stage.Id) || !Label(stage.Name, 100) || !States.Contains(stage.Status)) ||
            task.Stages.Select(stage => stage.Id).Distinct().Count() != task.Stages.Length ||
            task.Message is not null && !Label(task.Message, 500, true) ||
            task.Summary is not null && !Label(task.Summary, 500, true)) return false;
        if (task.Release is not { } release) return true;
        return Label(release.BundleId, 200) && Label(release.Version, 40) && Label(release.Build, 40) &&
            release.MetadataUrl?.Length <= 1500 && Uri.TryCreate(release.MetadataUrl, UriKind.Absolute, out var url) &&
            url.Scheme == Uri.UriSchemeHttps && url.UserInfo.Length == 0 && url.Fragment.Length == 0;
    }

    internal static object Read(string home, string thread, CancellationToken token)
    {
        if (!Guid.TryParseExact(thread, "D", out var id)) throw CodexJson.Invalid();
        thread = id.ToString("D");
        var directory = Path.Combine(home, "task-progress", id.ToString("D"));
        var records = new List<WorkshopProgressTask>();
        var invalid = false;
        if (Directory.Exists(directory))
        {
            if ((File.GetAttributes(directory) & FileAttributes.ReparsePoint) != 0) throw CodexJson.Invalid();
            foreach (var file in Directory.EnumerateFiles(directory, "*.json").Take(256))
            {
                token.ThrowIfCancellationRequested();
                try
                {
                    var info = new FileInfo(file);
                    if (info.Length > 24 * 1024 || (info.Attributes & FileAttributes.ReparsePoint) != 0) { invalid = true; continue; }
                    var bytes = File.ReadAllBytes(file);
                    if (bytes.Length > 24 * 1024) { invalid = true; continue; }
                    var record = JsonSerializer.Deserialize<WorkshopProgressRecord>(bytes, WorkshopProtocol.Json);
                    if (record is null || record.Schema != 1 || record.ThreadId != thread || record.Task is null ||
                        record.Task.Id != Path.GetFileNameWithoutExtension(file) || !Valid(record.Task)) { invalid = true; continue; }
                    records.Add(record.Task);
                }
                catch (Exception error) when (error is IOException or JsonException or UnauthorizedAccessException) { invalid = true; }
            }
        }
        var selected = new List<WorkshopProgressTask>();
        var size = 0;
        foreach (var task in records.OrderByDescending(task => task.CreatedAt).ThenBy(task => task.Id))
        {
            var bytes = JsonSerializer.SerializeToUtf8Bytes(task, WorkshopProtocol.Json).Length;
            if (selected.Count >= 16 || size + bytes > 44 * 1024) break;
            selected.Add(task); size += bytes;
        }
        return new { tasks = selected, warning = invalid ? "部分任务进度暂时无法读取，请稍后刷新。" : null };
    }
}

internal sealed partial class CodeWorkshop
{
    public Task<object?> TaskProgressAsync(JsonElement parameters, CancellationToken token)
    {
        CodexJson.Keys(parameters, "threadId");
        return Task.FromResult<object?>(WorkshopTaskProgress.Read(home, ThreadId(parameters), token));
    }
}
