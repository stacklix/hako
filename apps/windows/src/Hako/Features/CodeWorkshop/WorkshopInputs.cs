using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Hako.Core;

namespace Hako.Platform;

internal sealed record WorkshopSpeed(string Id, string Name, string Description);
internal sealed record WorkshopModel(string Id, string Name, string Description, bool IsDefault, bool SupportsImages, WorkshopSpeed[] ServiceTiers);

internal sealed partial class CodeWorkshop
{
    internal const int MaximumReadImageBytes = 8 * 1024 * 1024;
    private readonly Dictionary<string, string> messageImageSources = new();
    public async Task<object?> ImageAsync(JsonElement parameters, CancellationToken token)
    {
        CodexJson.Keys(parameters, "threadId", "messageId", "index", "offset", "revision");
        var threadId = ThreadId(parameters);
        var messageId = CodexJson.Required(parameters, "messageId", 200);
        var index = CodexJson.Field(parameters, "index");
        var offsetValue = CodexJson.Field(parameters, "offset");
        if (index.ValueKind != JsonValueKind.Number || !index.TryGetInt32(out var imageIndex) || imageIndex < 0 || imageIndex >= 3 ||
            offsetValue.ValueKind != JsonValueKind.Number || !offsetValue.TryGetInt32(out var offset) || offset < 0) throw CodexJson.Invalid();
        var cacheKey = threadId + "\n" + messageId + "\n" + imageIndex;
        string? source = null;
        lock (gate)
        {
            RecoverJobs();
            messageImageSources.TryGetValue(cacheKey, out source);
            if (jobs.TryGetValue(messageId, out var job) && job.ThreadId == threadId && imageIndex < job.ImageIds.Length)
                source = UploadPath(job.ImageIds[imageIndex]);
        }
        if (source is null)
        {
            var thread = await ThreadAsync(threadId, true, token);
            var item = CodexJson.Items(CodexJson.Field(thread, "turns"))
                .SelectMany(turn => CodexJson.Items(CodexJson.Field(turn, "items")))
                .FirstOrDefault(item => CodexJson.Text(item, "type") is "userMessage" or "imageGeneration" && CodexJson.Text(item, "id") == messageId);
            if (CodexJson.Text(item, "type") == "imageGeneration")
            {
                if (imageIndex != 0 || CodexJson.Text(item, "status") != "completed")
                    throw new WorkshopException("codex_image_missing", "图片尚未生成完成。");
                source = CodexJson.Text(item, "savedPath");
            }
            else
            {
                var images = CodexJson.Items(CodexJson.Field(item, "content"))
                    .Where(value => CodexJson.Text(value, "type") is "localImage" or "image").ToArray();
                if (imageIndex >= images.Length) throw new WorkshopException("codex_image_missing", "找不到这条消息的图片。");
                source = CodexJson.Text(images[imageIndex], "type") == "localImage"
                    ? CodexJson.Text(images[imageIndex], "path") : CodexJson.Text(images[imageIndex], "url");
            }
        }
        lock (gate)
        {
            if (messageImageSources.Count >= 32) messageImageSources.Remove(messageImageSources.Keys.First());
            messageImageSources[cacheKey] = source;
        }
        byte[] data;
        if (source.StartsWith("data:image/", StringComparison.OrdinalIgnoreCase))
        {
            var comma = source.IndexOf(',');
            if (comma < 0 || !source[..comma].EndsWith(";base64", StringComparison.OrdinalIgnoreCase) || source.Length > (MaximumReadImageBytes + 2) / 3 * 4 + 256)
                throw CodexJson.Invalid();
            try { data = Convert.FromBase64String(source[(comma + 1)..]); }
            catch (FormatException) { throw CodexJson.Invalid(); }
        }
        else
        {
            // Only paths taken from the authorized thread or its saved upload are read.
            if (!Path.IsPathFullyQualified(source) || !File.Exists(source) || new FileInfo(source).Length > MaximumReadImageBytes)
                throw new WorkshopException("codex_image_missing", "图片不在电脑上，或超过 8 MB。");
            data = await File.ReadAllBytesAsync(source, token);
        }
        if (data.Length == 0 || data.Length > MaximumReadImageBytes || offset > data.Length) throw CodexJson.Invalid();
        var revision = Convert.ToHexString(SHA256.HashData(data)).ToLowerInvariant();
        var expected = CodexJson.Text(parameters, "revision");
        if (expected.Length > 0 && expected != revision)
            throw new WorkshopException("codex_image_changed", "图片已更新，请重新打开。");
        var count = Math.Min(24 * 1024, data.Length - offset);
        return new { id = messageId, name = "图片", revision, offset, total = data.Length,
            content = Convert.ToBase64String(data, offset, count), nextOffset = offset + count };
    }

    public async Task<object?> ModelsAsync(JsonElement parameters, CancellationToken token)
    {
        CodexJson.Keys(parameters);
        var models = new List<WorkshopModel>();
        string? cursor = null;
        do
        {
            var result = await ReadAsync("model/list", new { limit = 50, cursor, includeHidden = false }, token);
            foreach (var model in CodexJson.Items(CodexJson.Field(result, "data")))
            {
                var modalities = CodexJson.Field(model, "inputModalities");
                models.Add(new(CodexJson.Text(model, "model"), CodexJson.Text(model, "displayName"),
                    CodexJson.Clip(CodexJson.Text(model, "description"), 400),
                    CodexJson.Field(model, "isDefault").ValueKind == JsonValueKind.True,
                    modalities.ValueKind == JsonValueKind.Array && modalities.EnumerateArray().Any(value => value.GetString() == "image"),
                    CodexJson.Items(CodexJson.Field(model, "serviceTiers")).Select(tier => new WorkshopSpeed(
                        CodexJson.Text(tier, "id"), CodexJson.Text(tier, "name"), CodexJson.Clip(CodexJson.Text(tier, "description"), 400))).ToArray()));
            }
            cursor = CodexJson.Text(result, "nextCursor");
        } while (!string.IsNullOrEmpty(cursor) && models.Count < 100);
        return new { models };
    }

    private string UploadPath(string id) => Path.Combine(storage, "images", id + ".jpg");

    public Task<object?> UploadImageAsync(JsonElement parameters, CancellationToken token)
    {
        CodexJson.Keys(parameters, "uploadId", "offset", "total", "sha256", "content");
        var id = OperationId(parameters, "uploadId");
        var offsetField = CodexJson.Field(parameters, "offset");
        var totalField = CodexJson.Field(parameters, "total");
        if (offsetField.ValueKind != JsonValueKind.Number || !offsetField.TryGetInt32(out var offset) || offset < 0 ||
            totalField.ValueKind != JsonValueKind.Number || !totalField.TryGetInt32(out var total) || total < 4 || total > 2_000_000)
            throw CodexJson.Invalid();
        var digest = CodexJson.Required(parameters, "sha256", 64).ToLowerInvariant();
        if (digest.Length != 64 || !digest.All(Uri.IsHexDigit)) throw CodexJson.Invalid();
        byte[] bytes;
        try { bytes = Convert.FromBase64String(CodexJson.Required(parameters, "content", 12 * 1024)); }
        catch (FormatException) { throw CodexJson.Invalid(); }
        if (bytes.Length == 0 || offset + bytes.Length > total) throw CodexJson.Invalid();
        token.ThrowIfCancellationRequested();
        lock (gate)
        {
            var path = UploadPath(id);
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            var part = path + ".part";
            var metadata = path + ".json";
            var identity = total + "\n" + digest;
            if (File.Exists(metadata))
            {
                if (File.ReadAllText(metadata) != identity) throw new WorkshopException("codex_upload_conflict", "图片上传 ID 已用于其他内容。");
            }
            else
            {
                if (offset != 0) throw new WorkshopException("codex_upload_offset", "图片尚未开始上传，请重新发送。");
                if (Directory.EnumerateFiles(Path.GetDirectoryName(path)!, "*.part").Count() >= 20)
                    throw new WorkshopException("codex_upload_busy", "未完成的图片上传过多，请先完成已有上传。");
                File.WriteAllText(metadata, identity);
            }
            var complete = File.Exists(path);
            using (var stream = new FileStream(complete ? path : part, complete ? FileMode.Open : FileMode.OpenOrCreate,
                complete ? FileAccess.Read : FileAccess.ReadWrite, FileShare.Read))
            {
                if (offset > stream.Length) throw new WorkshopException("codex_upload_offset", "图片上传进度不一致，请重试原消息。");
                stream.Position = offset;
                if (offset < stream.Length)
                {
                    var previous = new byte[bytes.Length];
                    if (stream.Read(previous) != bytes.Length || !previous.AsSpan().SequenceEqual(bytes))
                        throw new WorkshopException("codex_upload_conflict", "重复图片分片与原内容不一致。");
                }
                else if (!complete) { stream.Write(bytes); stream.Flush(true); }
            }
            if (!complete && new FileInfo(part).Length == total)
            {
                var image = File.ReadAllBytes(part);
                if (image[0] != 0xff || image[1] != 0xd8 || image[^2] != 0xff || image[^1] != 0xd9 ||
                    !Convert.ToHexString(SHA256.HashData(image)).Equals(digest, StringComparison.OrdinalIgnoreCase))
                    throw new WorkshopException("codex_image_invalid", "图片格式或校验值不正确，请重新选择图片。");
                File.Move(part, path);
                complete = true;
            }
            return Task.FromResult<object?>(new { id, nextOffset = offset + bytes.Length, complete });
        }
    }

    private string[] ImageIds(JsonElement parameters)
    {
        var field = CodexJson.Field(parameters, "imageIds");
        if (field.ValueKind == JsonValueKind.Undefined) return [];
        if (field.ValueKind != JsonValueKind.Array || field.GetArrayLength() > 3) throw CodexJson.Invalid();
        return field.EnumerateArray().Select(value => value.ValueKind == JsonValueKind.String && Guid.TryParse(value.GetString(), out var id)
            ? id.ToString("D") : throw CodexJson.Invalid()).Distinct().ToArray();
    }

    internal static Dictionary<string, object> ThreadOptions(string permission)
    {
        var result = new Dictionary<string, object>();
        if (permission == "custom") return result;
        result["approvalPolicy"] = permission == "full" ? "never" : "on-request";
        result["approvalsReviewer"] = permission == "auto" ? "auto_review" : "user";
        result["sandbox"] = permission == "full" ? "danger-full-access" : "workspace-write";
        return result;
    }
}
