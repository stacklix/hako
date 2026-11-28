using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace Hako.Platform;

internal sealed record WorkshopProjectEntry(string Name, string Path, bool Directory, bool Link, long Size = 0, string? Status = null);

// File operations stay on the selected computer. The server only relays frames.
internal sealed class WorkshopProjectFiles
{
    internal const int TextLimit = 256 * 1024;
    private const int ChunkSize = 8192;
    private sealed record Upload(string Root, string Path, string Revision, string Hash, int Size, string Encoding, byte[] Bytes)
    {
        internal int Offset;
        internal bool Committed;
        internal long Created = Environment.TickCount64;
    }
    private readonly Dictionary<string, Upload> uploads = new();
    private readonly SemaphoreSlim gate = new(1, 1);
    private readonly WorkshopDownloadCache images = new();

    internal async Task<object?> CallAsync(string method, string root, JsonElement p, CancellationToken token)
    {
        try
        {
            if (method == "files.list")
            {
                CodexJson.Keys(p, "applicationId", "path", "offset", "query");
                return List(root, CodexJson.Text(p, "path"), Integer(p, "offset"), CodexJson.Text(p, "query"), token);
            }
            if (method == "files.modified")
            {
                CodexJson.Keys(p, "applicationId", "offset");
                return await ModifiedAsync(root, Integer(p, "offset"), token);
            }
            if (method == "files.read")
            {
                CodexJson.Keys(p, "applicationId", "path", "offset", "revision");
                return Read(root, CodexJson.Required(p, "path", 2048), Integer(p, "offset"), CodexJson.Text(p, "revision"));
            }
            if (method == "files.image.read")
            {
                CodexJson.Keys(p, "applicationId", "path", "offset", "revision");
                return await ReadImageAsync(root, CodexJson.Required(p, "path", 2048), Integer(p, "offset"), CodexJson.Text(p, "revision"), token);
            }
            await gate.WaitAsync(token);
            try { return Write(method, root, p, token); }
            finally { gate.Release(); }
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        { throw new WorkshopException("file_access_failed", "无法访问项目文件，文件可能已移动、被占用或没有读写权限。请刷新后重试。"); }
    }

    private static int Integer(JsonElement p, string key)
    {
        var value = CodexJson.Field(p, key);
        if (value.ValueKind == JsonValueKind.Undefined) return 0;
        if (!value.TryGetInt32(out var number) || number < 0) throw CodexJson.Invalid();
        return number;
    }
    private static string Hash(byte[] bytes) => Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant();
    private static string Digest(JsonElement p, string key)
    {
        var value = CodexJson.Required(p, key, 64);
        if (value.Length != 64 || value.Any(c => !char.IsAsciiHexDigit(c))) throw CodexJson.Invalid();
        return value.ToLowerInvariant();
    }
    internal static string Resolve(string root, string relative)
    {
        root = System.IO.Path.GetFullPath(root);
        var parts = relative.Replace('\\', '/').Split('/', StringSplitOptions.RemoveEmptyEntries);
        if (System.IO.Path.IsPathRooted(relative) || relative.Contains(':') || parts.Any(part =>
            part is "." or ".." || part.Equals(".git", StringComparison.OrdinalIgnoreCase) ||
            part.EndsWith('.') || part.EndsWith(' ') || part.IndexOfAny(System.IO.Path.GetInvalidFileNameChars()) >= 0))
            throw CodexJson.Invalid();
        var current = root;
        if ((File.GetAttributes(current) & FileAttributes.ReparsePoint) != 0) throw CodexJson.Invalid();
        foreach (var part in parts)
        {
            current = System.IO.Path.Combine(current, part);
            if ((File.GetAttributes(current) & FileAttributes.ReparsePoint) != 0)
                throw new WorkshopException("file_link", "链接文件或链接目录只读，不允许通过链接访问项目外文件。");
        }
        return current;
    }
    private static WorkshopProjectEntry Entry(string root, FileSystemInfo info, string? status = null) => new(info.Name,
        System.IO.Path.GetRelativePath(root, info.FullName).Replace('\\', '/'),
        (info.Attributes & FileAttributes.Directory) != 0, (info.Attributes & FileAttributes.ReparsePoint) != 0,
        info is FileInfo file ? file.Length : 0, status);

    private static object List(string root, string relative, int offset, string query, CancellationToken token)
    {
        if (query.Length > 200 || offset > 100_000) throw CodexJson.Invalid();
        var directory = Resolve(root, relative);
        var entries = new List<WorkshopProjectEntry>();
        var truncated = false;
        if (string.IsNullOrWhiteSpace(query))
        {
            foreach (var info in new DirectoryInfo(directory).EnumerateFileSystemInfos())
            {
                token.ThrowIfCancellationRequested();
                if (info.Name.Equals(".git", StringComparison.OrdinalIgnoreCase)) continue;
                if (entries.Count >= 100_000) { truncated = true; break; }
                entries.Add(Entry(root, info));
            }
            entries = entries.OrderByDescending(e => e.Directory).ThenBy(e => e.Name, StringComparer.OrdinalIgnoreCase).ToList();
        }
        else
        {
            var queue = new Queue<string>(); queue.Enqueue(directory);
            var scanned = 0;
            while (queue.Count > 0 && !truncated)
            {
                token.ThrowIfCancellationRequested();
                var next = queue.Dequeue();
                try
                {
                    foreach (var info in new DirectoryInfo(next).EnumerateFileSystemInfos())
                    {
                        token.ThrowIfCancellationRequested();
                        if (++scanned > 20_000 || entries.Count >= 200) { truncated = true; break; }
                        if (info.Name.Equals(".git", StringComparison.OrdinalIgnoreCase)) continue;
                        var entry = Entry(root, info);
                        if (entry.Path.Contains(query.Trim(), StringComparison.OrdinalIgnoreCase)) entries.Add(entry);
                        if (entry.Directory && !entry.Link) queue.Enqueue(info.FullName);
                    }
                }
                catch (Exception error) when (error is IOException or UnauthorizedAccessException) { truncated = true; }
            }
        }
        return Page(entries, offset, truncated);
    }

    private static object Page(List<WorkshopProjectEntry> entries, int offset, bool truncated)
    {
        var page = new List<WorkshopProjectEntry>(); var bytes = 0;
        foreach (var entry in entries.Skip(offset).Take(100))
        {
            var size = JsonSerializer.SerializeToUtf8Bytes(entry, WorkshopProtocol.Json).Length + 1;
            if (bytes + size > 45_000) break;
            page.Add(entry); bytes += size;
        }
        return new { entries = page, nextOffset = offset + page.Count < entries.Count ? (int?)(offset + page.Count) : null, truncated };
    }

    private static async Task<object> ModifiedAsync(string root, int offset, CancellationToken token)
    {
        var start = new ProcessStartInfo("git") { WorkingDirectory = root, UseShellExecute = false,
            CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true };
        foreach (var arg in new[] { "--no-optional-locks", "status", "--porcelain=v1", "-z", "--untracked-files=all", "--", "." }) start.ArgumentList.Add(arg);
        start.Environment["GIT_OPTIONAL_LOCKS"] = "0";
        using var process = Process.Start(start) ?? throw new WorkshopException("git_failed", "无法读取 Git 文件状态。");
        using var budget = CancellationTokenSource.CreateLinkedTokenSource(token); budget.CancelAfter(TimeSpan.FromSeconds(6));
        var errors = process.StandardError.ReadToEndAsync(budget.Token);
        try
        {
            using var output = new MemoryStream(); var buffer = new byte[8192]; int count;
            while ((count = await process.StandardOutput.BaseStream.ReadAsync(buffer, budget.Token)) > 0)
            {
                if (output.Length + count > 2 * 1024 * 1024) throw new WorkshopException("git_too_large", "修改的文件过多，请先在电脑整理 Git 状态后重试。");
                output.Write(buffer, 0, count);
            }
            await process.WaitForExitAsync(budget.Token); await errors;
            if (process.ExitCode != 0) throw new WorkshopException("git_failed", "无法读取 Git 状态，请确认项目的 Git 仓库可用。");
            var pieces = Encoding.UTF8.GetString(output.ToArray()).Split('\0');
            var values = new List<WorkshopProjectEntry>();
            for (var index = 0; index < pieces.Length; index++)
            {
                var row = pieces[index]; if (row.Length < 4) continue;
                var status = row[..2]; var path = row[3..];
                if (status.Contains('R') || status.Contains('C')) index++; // porcelain -z emits destination first, source second.
                var relative = System.IO.Path.GetRelativePath(root, System.IO.Path.Combine(root, path)).Replace('\\', '/');
                // Validate missing paths by their existing parent (deleted files remain visible).
                try
                {
                    var full = Resolve(root, relative);
                    values.Add(Entry(root, new FileInfo(full), status));
                }
                catch (FileNotFoundException) { values.Add(new(System.IO.Path.GetFileName(path), relative, false, false, 0, status)); }
                catch (DirectoryNotFoundException) { values.Add(new(System.IO.Path.GetFileName(path), relative, false, false, 0, status)); }
                catch (WorkshopException) { continue; }
                if (values.Count >= 200) break;
            }
            return Page(values, offset, pieces.Count(s => s.Length >= 4) > 200);
        }
        finally { if (!process.HasExited) { process.Kill(true); await process.WaitForExitAsync(CancellationToken.None); } }
    }

    private static byte[] Bytes(string path)
    {
        using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read);
        if (stream.Length > TextLimit) throw new WorkshopException("file_too_large", "文本文件超过 256 KB，暂不支持在手机中编辑。");
        var bytes = new byte[(int)stream.Length]; stream.ReadExactly(bytes); return bytes;
    }
    internal static string? TextEncoding(byte[] bytes)
    {
        var name = bytes.AsSpan().StartsWith(new byte[] { 0xef, 0xbb, 0xbf }) ? "utf8-bom" :
            bytes.AsSpan().StartsWith(new byte[] { 0xff, 0xfe }) ? "utf16-le" :
            bytes.AsSpan().StartsWith(new byte[] { 0xfe, 0xff }) ? "utf16-be" : "utf8";
        var encoding = name.StartsWith("utf16", StringComparison.Ordinal) ? new UnicodeEncoding(name == "utf16-be", false, true) : (Encoding)new UTF8Encoding(false, true);
        var skip = name == "utf8-bom" ? 3 : name.StartsWith("utf16", StringComparison.Ordinal) ? 2 : 0;
        try
        {
            var text = encoding.GetString(bytes, skip, bytes.Length - skip);
            return text.Any(c => char.IsControl(c) && c is not ('\r' or '\n' or '\t')) ? null : name;
        }
        catch (DecoderFallbackException) { return null; }
    }
    private static object Read(string root, string relative, int offset, string revision)
    {
        var path = Resolve(root, relative); var info = new FileInfo(path);
        if (info.Length > TextLimit) return new { size = info.Length, editable = false, reason = "文本文件超过 256 KB，暂不支持在手机中编辑。" };
        var bytes = Bytes(path); var hash = Hash(bytes); var encoding = TextEncoding(bytes);
        if (revision.Length > 0 && revision != hash) throw Conflict();
        if (offset > bytes.Length) throw CodexJson.Invalid();
        return new { size = bytes.Length, revision = hash, encoding, editable = encoding != null && !info.IsReadOnly,
            reason = encoding == null ? "此文件不是受支持的文本文件。" : info.IsReadOnly ? "此文件被设置为只读。" : null,
            data = encoding == null ? "" : Convert.ToBase64String(bytes.AsSpan(offset, Math.Min(ChunkSize, bytes.Length - offset))),
            nextOffset = encoding != null && offset + ChunkSize < bytes.Length ? (int?)(offset + ChunkSize) : null };
    }
    private async Task<object> ReadImageAsync(string root, string relative, int offset, string revision, CancellationToken token)
    {
        // Validate on every chunk, including cached snapshots, so links cannot escape the project.
        var path = Resolve(root, relative);
        var snapshot = await images.ReadAsync(path, revision, async () =>
        {
            await using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read, 8192, true);
            if (stream.Length is <= 0 or > CodeWorkshop.MaximumReadImageBytes)
                throw new WorkshopException("file_too_large", "图片为空或超过 8 MB，无法预览。");
            var bytes = new byte[(int)stream.Length];
            await stream.ReadExactlyAsync(bytes, token);
            // Raster images only; never deliver HTML/SVG or arbitrary project files as images.
            if (!ImageBytes(bytes)) throw new WorkshopException("file_not_image", "此文件不是受支持的图片。");
            return bytes;
        }, token);
        if (revision.Length > 0 && revision != snapshot.Revision)
            throw new WorkshopException("file_conflict", "图片已更新，请重新打开。");
        if (offset > snapshot.Data.Length) throw CodexJson.Invalid();
        var count = Math.Min(24 * 1024, snapshot.Data.Length - offset);
        return new { id = relative, name = Path.GetFileName(path), revision = snapshot.Revision, offset,
            total = snapshot.Data.Length, content = Convert.ToBase64String(snapshot.Data, offset, count), nextOffset = offset + count };
    }
    private static bool ImageBytes(byte[] bytes)
    {
        var data = bytes.AsSpan();
        return data.StartsWith(new byte[] { 137, 80, 78, 71, 13, 10, 26, 10 }) ||
            data.StartsWith(new byte[] { 255, 216, 255 }) || data.StartsWith("GIF87a"u8) || data.StartsWith("GIF89a"u8) ||
            (data.Length >= 12 && data.StartsWith("RIFF"u8) && data[8..].StartsWith("WEBP"u8));
    }
    private static WorkshopException Conflict() => new("file_conflict", "文件已被其他操作修改。草稿已保留，请重新读取电脑文件核对后再编辑。");

    private object Write(string method, string root, JsonElement p, CancellationToken token)
    {
        foreach (var expired in uploads.Where(e => Environment.TickCount64 - e.Value.Created > 30 * 60_000).Select(e => e.Key).ToArray()) uploads.Remove(expired);
        var id = CodexJson.Required(p, "transferId", 36); if (!Guid.TryParse(id, out _)) throw CodexJson.Invalid();
        if (method == "files.write.begin")
        {
            CodexJson.Keys(p, "applicationId", "transferId", "path", "revision", "sha256", "size", "encoding");
            var relative = CodexJson.Required(p, "path", 2048); var revision = Digest(p, "revision");
            var hash = Digest(p, "sha256"); var size = Integer(p, "size"); var encoding = CodexJson.Required(p, "encoding", 20);
            if (size > TextLimit) throw new WorkshopException("file_too_large", "文本文件超过 256 KB。");
            var path = Resolve(root, relative); var current = Bytes(path);
            if (Hash(current) != revision) throw Conflict();
            if (new FileInfo(path).IsReadOnly || TextEncoding(current) != encoding) throw new WorkshopException("file_read_only", "此文件不可编辑，或文本编码已变化，请重新读取。");
            if (uploads.TryGetValue(id, out var previous))
            {
                if (previous.Root != root || previous.Path != relative || previous.Revision != revision || previous.Hash != hash || previous.Size != size || previous.Encoding != encoding) throw CodexJson.Invalid();
                return new { offset = previous.Offset };
            }
            if (uploads.Count(e => !e.Value.Committed) >= 8) throw new WorkshopException("file_busy", "待保存文件较多，请稍后重试。");
            if (uploads.Count >= 16)
                foreach (var completed in uploads.Where(e => e.Value.Committed).OrderBy(e => e.Value.Created).Take(uploads.Count - 15).Select(e => e.Key).ToArray()) uploads.Remove(completed);
            uploads.Add(id, new(root, relative, revision, hash, size, encoding, new byte[size]));
            return new { offset = 0 };
        }
        if (!uploads.TryGetValue(id, out var upload) || upload.Root != root) throw new WorkshopException("file_transfer_missing", "保存传输已失效，请重新读取文件后再保存。");
        if (method == "files.write.chunk")
        {
            CodexJson.Keys(p, "applicationId", "transferId", "offset", "data");
            var offset = Integer(p, "offset"); byte[] bytes;
            try { bytes = Convert.FromBase64String(CodexJson.Required(p, "data", 12_000)); }
            catch (FormatException) { throw CodexJson.Invalid(); }
            if (bytes.Length is 0 or > ChunkSize || offset > upload.Offset || offset > upload.Size - bytes.Length || upload.Committed) throw CodexJson.Invalid();
            if (offset < upload.Offset)
            {
                if (offset + bytes.Length > upload.Offset || !upload.Bytes.AsSpan(offset, bytes.Length).SequenceEqual(bytes)) throw CodexJson.Invalid();
            }
            else { bytes.CopyTo(upload.Bytes, offset); upload.Offset += bytes.Length; }
            return new { offset = upload.Offset };
        }
        if (method != "files.write.commit") throw new WorkshopException("unsupported_method", "不支持此文件操作。");
        CodexJson.Keys(p, "applicationId", "transferId");
        if (upload.Offset != upload.Size || Hash(upload.Bytes) != upload.Hash || TextEncoding(upload.Bytes) != upload.Encoding) throw CodexJson.Invalid();
        var target = Resolve(root, upload.Path);
        var latest = Bytes(target);
        if (upload.Committed) return new { revision = upload.Hash, size = upload.Size };
        if (Hash(latest) != upload.Revision) throw Conflict();
        if (new FileInfo(target).IsReadOnly) throw new WorkshopException("file_read_only", "此文件被设置为只读。");
        token.ThrowIfCancellationRequested();
        var temporary = System.IO.Path.Combine(System.IO.Path.GetDirectoryName(target)!, ".hako-save-" + Guid.NewGuid().ToString("N") + ".tmp");
        try
        {
            using (var output = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None)) { output.Write(upload.Bytes); output.Flush(true); }
            // Keep writers out while checking the baseline and replacing the file.
            using var locked = new FileStream(target, FileMode.Open, FileAccess.Read, FileShare.Read | FileShare.Delete);
            var baseline = new byte[(int)Math.Min(locked.Length, TextLimit + 1)]; locked.ReadExactly(baseline);
            if (Hash(baseline) != upload.Revision || Resolve(root, upload.Path) != target) throw Conflict();
            File.Replace(temporary, target, null);
            upload.Committed = true;
            return new { revision = upload.Hash, size = upload.Size };
        }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }
}

internal sealed partial class CodeWorkshop
{
    private readonly WorkshopProjectFiles projectFiles = new();
    internal Task<object?> FilesAsync(string method, JsonElement parameters, CancellationToken token) =>
        projectFiles.CallAsync(method, ResolveApplication(CodexJson.Required(parameters, "applicationId", 100)), parameters, token);
}
