using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Hako.Core;

namespace Hako.Platform;

internal sealed record UserFileEntry(string Name, string Path, bool Directory, bool Link, bool Hidden, bool ReadOnly, long Size, long ModifiedAt, string Revision);
internal sealed record UserFilePage(string Root, string Path, IReadOnlyList<UserFileEntry> Entries, int? NextOffset, bool Truncated);
internal sealed record UserFileOperation(string RequestId, string State, string Path, string? Revision = null, string? Error = null);
internal sealed class UserFiles
{
    internal const string ListCommand = "query.files.list";
    internal static readonly string[] QueryCommands = [ListCommand, "query.files.read", "query.files.operation"];
    internal static readonly string[] ActionCommands = ["action.files.mutate", "action.files.write.begin", "action.files.write.chunk", "action.files.write.commit"];
    internal const int TextLimit = 256 * 1024, ChunkSize = 8192;
    private readonly string root, receipts;
    private readonly SemaphoreSlim gate = new(1, 1);
    private readonly Dictionary<string, Upload> uploads = new();
    private sealed record Receipt(string Fingerprint, UserFileOperation Operation);
    private sealed record Upload(string Path, string Revision, string Hash, string Encoding, byte[] Bytes)
    { internal int Offset; internal long Created = Environment.TickCount64; }
    internal UserFiles(string dataDirectory, string? userRoot = null)
    {
        root = Path.GetFullPath(userRoot ?? Environment.GetFolderPath(Environment.SpecialFolder.UserProfile));
        receipts = Path.Combine(dataDirectory, "user-file-operations");
    }
    internal async Task<object?> CallAsync(string method, JsonElement p, CancellationToken token)
    {
        await gate.WaitAsync(token);
        try
        {
            return await Task.Run<object?>(() =>
            {
                token.ThrowIfCancellationRequested();
                try
                {
                    return method switch
                    {
                        ListCommand => List(p, token),
                        "query.files.read" => Read(p),
                        "query.files.operation" => Operation(p),
                        "action.files.mutate" => Mutate(p, token),
                        "action.files.write.begin" => Begin(p),
                        "action.files.write.chunk" => Chunk(p),
                        "action.files.write.commit" => Commit(p, token),
                        _ => throw new AgentActionException("unsupported_method", "设备不支持此文件操作。")
                    };
                }
                catch (Exception e) when (e is IOException or UnauthorizedAccessException or Win32Exception)
                { throw AccessError(); }
            }, token);
        }
        finally { gate.Release(); }
    }
    private static AgentActionException AccessError() => new("file_access_failed", "无法完成文件操作，文件可能被占用、已移动或没有权限。请刷新目录核对，部分操作可能已完成。");
    private static AgentActionException Conflict() => new("file_conflict", "文件已发生变化。当前草稿已保留，请重新读取电脑文件核对后再操作。");
    private static string Hash(byte[] bytes) => Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant();
    private static string Text(JsonElement p, string key, int max = 2048)
    {
        if (!p.TryGetProperty(key, out var v)) return "";
        if (v.ValueKind != JsonValueKind.String || v.GetString()!.Length > max) throw UserFileAccess.Invalid();
        return v.GetString()!;
    }
    private static int Number(JsonElement p, string key)
    {
        if (!p.TryGetProperty(key, out var v)) return 0;
        if (!v.TryGetInt32(out var n) || n < 0) throw UserFileAccess.Invalid();
        return n;
    }
    private static bool Flag(JsonElement p, string key)
    {
        if (!p.TryGetProperty(key, out var v)) return false;
        if (v.ValueKind is not (JsonValueKind.True or JsonValueKind.False)) throw UserFileAccess.Invalid();
        return v.GetBoolean();
    }
    private static void Keys(JsonElement p, params string[] keys)
    { if (p.ValueKind != JsonValueKind.Object || p.EnumerateObject().Any(v => !keys.Contains(v.Name, StringComparer.Ordinal))) throw UserFileAccess.Invalid(); }
    private static string Id(JsonElement p)
    { var id = Text(p, "requestId", 36); if (!Guid.TryParseExact(id, "D", out var value)) throw UserFileAccess.Invalid(); return value.ToString("D"); }
    private static string Digest(JsonElement p, string key)
    { var text = Text(p, key, 64); if (text.Length != 64 || !text.All(char.IsAsciiHexDigit)) throw UserFileAccess.Invalid(); return text.ToLowerInvariant(); }
    private static long Time(System.Runtime.InteropServices.ComTypes.FILETIME t) => ((long)(uint)t.dwHighDateTime << 32) | (uint)t.dwLowDateTime;
    private static string Stamp(long size, long created, long written, uint attrs) => Hash(Encoding.UTF8.GetBytes($"{size}:{created}:{written}:{attrs}"));
    private static string Stamp(UserFileAccess.Info info) => Stamp(info.Directory ? 0 : info.Size, Time(info.Created), Time(info.Written), info.Attributes);
    private static UserFileEntry Entry(string root, FileSystemInfo info)
    {
        var attr = info.Attributes;
        var directory = (attr & FileAttributes.Directory) != 0;
        var link = (attr & FileAttributes.ReparsePoint) != 0;
        var size = !directory && !link && info is FileInfo file ? file.Length : 0;
        var revision = Stamp(size, info.CreationTimeUtc.ToFileTimeUtc(), info.LastWriteTimeUtc.ToFileTimeUtc(), (uint)attr);
        var modified = new DateTimeOffset(info.LastWriteTimeUtc).ToUnixTimeMilliseconds();
        if (!link)
        {
            try
            {
                using var handle = UserFileAccess.Open(info.FullName, 0x80, out var current);
                // NTFS enumeration metadata can lag behind handle metadata.
                // Use the same handle snapshot for listings and mutations.
                revision = Stamp(current); attr = (FileAttributes)current.Attributes;
                directory = current.Directory; size = directory ? 0 : current.Size;
                modified = new DateTimeOffset(DateTime.FromFileTimeUtc(Time(current.Written))).ToUnixTimeMilliseconds();
            }
            catch (AgentActionException error) when (error.Code == "file_link") { link = true; }
        }
        return new(info.Name, Path.GetRelativePath(root, info.FullName).Replace('\\', '/'), directory, link,
            info.Name.StartsWith('.') || (attr & FileAttributes.Hidden) != 0, (attr & FileAttributes.ReadOnly) != 0,
            size, modified, revision);
    }
    private UserFilePage List(JsonElement p, CancellationToken token)
    {
        Keys(p, "path", "query", "offset", "showHidden");
        var relative = Text(p, "path"); var query = Text(p, "query", 200).Trim();
        var offset = Number(p, "offset"); var hidden = Flag(p, "showHidden");
        if (offset > 10_000) throw UserFileAccess.Invalid();
        using var access = new UserFileAccess(root, relative, directory: true);
        var entries = new List<UserFileEntry>(); var truncated = false; var scanned = 0;
        foreach (var info in new DirectoryInfo(access.Target).EnumerateFileSystemInfos())
        {
            token.ThrowIfCancellationRequested();
            if (++scanned > 10_000) { truncated = true; break; }
            try
            {
                var entry = Entry(root, info);
                if ((hidden || !entry.Hidden) && entry.Name.Contains(query, StringComparison.OrdinalIgnoreCase)) entries.Add(entry);
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException) { truncated = true; }
        }
        entries = entries.OrderByDescending(f => f.Directory).ThenBy(f => f.Name, StringComparer.OrdinalIgnoreCase).ToList();
        var page = new List<UserFileEntry>(); var bytes = 0;
        foreach (var entry in entries.Skip(offset).Take(100))
        {
            var length = JsonSerializer.SerializeToUtf8Bytes(entry, AgentConnection.Json).Length;
            if (bytes + length > 40_000) break;
            page.Add(entry); bytes += length;
        }
        return new(root, relative, page, offset + page.Count < entries.Count ? offset + page.Count : null, truncated);
    }
    private static byte[] Bytes(Microsoft.Win32.SafeHandles.SafeFileHandle handle)
    {
        using var stream = new FileStream(new Microsoft.Win32.SafeHandles.SafeFileHandle(handle.DangerousGetHandle(), ownsHandle: false), FileAccess.Read);
        if (stream.Length > TextLimit) throw new AgentActionException("file_too_large", "文件超过 256 KB，暂不支持文本编辑。");
        var bytes = new byte[(int)stream.Length]; stream.ReadExactly(bytes); return bytes;
    }
    private object Read(JsonElement p)
    {
        Keys(p, "path", "offset", "revision");
        using var access = new UserFileAccess(root, Text(p, "path"));
        if (access.IsRoot) throw UserFileAccess.Invalid();
        using var handle = UserFileAccess.Open(access.Target, 0x80000000, out var info);
        if (info.Directory) throw UserFileAccess.Invalid();
        if (info.Size > TextLimit) return new { size = info.Size, editable = false, reason = "文件超过 256 KB，暂不支持文本预览和编辑。" };
        var bytes = Bytes(handle); var revision = Hash(bytes); var encoding = WorkshopProjectFiles.TextEncoding(bytes);
        var expected = Text(p, "revision", 64); var offset = Number(p, "offset");
        if (expected.Length > 0 && expected != revision) throw Conflict();
        if (offset > bytes.Length) throw UserFileAccess.Invalid();
        return new { size = bytes.Length, revision, encoding, editable = encoding != null && (info.Attributes & (uint)FileAttributes.ReadOnly) == 0,
            reason = encoding == null ? "此文件不支持文本预览。" : (info.Attributes & (uint)FileAttributes.ReadOnly) != 0 ? "此文件为只读。" : null,
            data = encoding == null ? "" : Convert.ToBase64String(bytes.AsSpan(offset, Math.Min(ChunkSize, bytes.Length - offset))),
            nextOffset = encoding != null && offset + ChunkSize < bytes.Length ? (int?)(offset + ChunkSize) : null };
    }
    private string ReceiptPath(string id) => Path.Combine(receipts, id + ".json");
    private UserFileOperation Operation(JsonElement p)
    {
        Keys(p, "requestId");
        var file = ReceiptPath(Id(p));
        if (!File.Exists(file)) return new(Id(p), "unknown", "", Error: "未找到完成记录，请刷新目录核对；不要自动重复操作。");
        var receipt = JsonSerializer.Deserialize<Receipt>(File.ReadAllBytes(file), AgentConnection.Json)!;
        return receipt.Operation.State == "running" ? receipt.Operation with { State = "unknown", Error = "上次操作曾中断，结果需要核对。" } : receipt.Operation;
    }
    private UserFileOperation Once(JsonElement p, string relative, Func<string?> action)
    {
        var id = Id(p);
        var fingerprint = Hash(JsonSerializer.SerializeToUtf8Bytes(p.EnumerateObject().OrderBy(x => x.Name, StringComparer.Ordinal).ToDictionary(x => x.Name, x => x.Value)));
        var file = ReceiptPath(id);
        Directory.CreateDirectory(receipts);
        if (File.Exists(file))
        {
            var prior = JsonSerializer.Deserialize<Receipt>(File.ReadAllBytes(file), AgentConnection.Json)!;
            if (prior.Fingerprint != fingerprint) throw new AgentActionException("file_request_conflict", "此操作编号已经用于另一项操作。");
            return prior.Operation.State == "running" ? prior.Operation with { State = "unknown", Error = "上次操作曾中断，请刷新目录核对。" } : prior.Operation;
        }
        if (Directory.EnumerateFiles(receipts, "*.json").Take(4096).Count() >= 4096)
            throw new AgentActionException("file_history_full", "文件操作记录已满，请在电脑上整理 Kage 的文件操作记录后重试。");
        var running = new Receipt(fingerprint, new(id, "running", relative));
        using (var output = new FileStream(file, FileMode.CreateNew, FileAccess.Write, FileShare.None))
        { output.Write(JsonSerializer.SerializeToUtf8Bytes(running, AgentConnection.Json)); output.Flush(true); }
        UserFileOperation result;
        try { result = new(id, "completed", relative, action()); }
        catch (Exception error) when (error is AgentActionException or IOException or UnauthorizedAccessException or Win32Exception or OperationCanceledException)
        { result = new(id, "failed", relative, Error: error is AgentActionException ? error.Message : AccessError().Message); }
        CommandHost.Save(file, JsonSerializer.SerializeToUtf8Bytes(new Receipt(fingerprint, result), AgentConnection.Json));
        return result;
    }
    private void Mutable(UserFileAccess access)
        => MutablePath(access.Target, access.IsRoot);
    private void MutablePath(string target, bool isRoot = false)
    {
        // Keep the active journal available even when its directory is in the user profile.
        if (isRoot || Path.GetFullPath(receipts).StartsWith(Path.TrimEndingDirectorySeparator(target) + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase)
            || target.StartsWith(Path.TrimEndingDirectorySeparator(Path.GetFullPath(receipts)) + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase)
            || string.Equals(target, receipts, StringComparison.OrdinalIgnoreCase))
            throw new AgentActionException("file_protected", "不能修改用户根目录或正在使用的文件操作记录目录。");
    }
    private object Mutate(JsonElement p, CancellationToken token)
    {
        Keys(p, "requestId", "operation", "path", "name", "revision");
        var relative = Text(p, "path"); var operation = Text(p, "operation", 24); var name = Text(p, "name", 255);
        if (operation is not ("createFile" or "createFolder" or "rename" or "delete")) throw UserFileAccess.Invalid();
        if (operation != "delete") UserFileAccess.ValidateName(name);
        return Once(p, relative, () =>
        {
            token.ThrowIfCancellationRequested();
            var creating = operation is "createFile" or "createFolder";
            using var access = new UserFileAccess(root, relative, directory: creating);
            if (creating)
            {
                var target = Path.Combine(access.Target, name);
                if (operation == "createFile") { using var empty = UserFileAccess.Open(target, 0x40000000, out _, 1); }
                else
                {
                    if (!CreateDirectory(target, IntPtr.Zero)) throw new Win32Exception(System.Runtime.InteropServices.Marshal.GetLastWin32Error());
                }
                return null;
            }
            Mutable(access);
            using (var inspect = UserFileAccess.Open(access.Target, 0x80, out var before))
            {
                if (Stamp(before) != Digest(p, "revision")) throw Conflict();
                if (operation == "delete" && before.Directory) { var count = 0; InspectTree(relative, ref count, token); }
            }
            using var handle = UserFileAccess.Open(access.Target, 0x10080, out var info);
            if (Stamp(info) != Digest(p, "revision")) throw Conflict();
            if (operation == "rename") UserFileAccess.Rename(handle, Path.Combine(Path.GetDirectoryName(access.Target)!, name));
            else
            {
                if (info.Directory)
                {
                    DeleteChildren(access.Target, token);
                }
                UserFileAccess.Delete(handle);
            }
            return null;
        });
    }
    private void InspectTree(string relative, ref int count, CancellationToken token)
    {
        using var access = new UserFileAccess(root, relative, directory: true);
        foreach (var entry in new DirectoryInfo(access.Target).EnumerateFileSystemInfos())
        {
            token.ThrowIfCancellationRequested();
            if (++count > 10_000 || relative.Count(c => c == '/') > 64) throw new AgentActionException("file_tree_large", "此文件夹内容过多或层级过深，请在电脑上删除。");
            var child = relative + "/" + entry.Name;
            using var pin = new UserFileAccess(root, child); Mutable(pin);
            using var handle = UserFileAccess.Open(pin.Target, 0x80, out var info);
            if (info.Directory) InspectTree(child, ref count, token);
        }
    }
    private void DeleteChildren(string target, CancellationToken token, int depth = 0)
    {
        if (depth > 64) throw new AgentActionException("file_tree_large", "文件夹层级过深，请在电脑上删除。");
        // The caller retains the verified DELETE handle for this directory;
        // reopening ancestors here would weaken or conflict with that pin.
        var names = new DirectoryInfo(target).EnumerateFileSystemInfos().Take(10_001).Select(x => x.Name).ToArray();
        if (names.Length > 10_000) throw new AgentActionException("file_tree_large", "文件夹内容过多，请在电脑上删除。");
        foreach (var name in names)
        {
            token.ThrowIfCancellationRequested();
            UserFileAccess.ValidateName(name);
            var child = Path.Combine(target, name); MutablePath(child);
            using var handle = UserFileAccess.Open(child, 0x10080, out var info);
            if (info.Directory) DeleteChildren(child, token, depth + 1);
            UserFileAccess.Delete(handle);
        }
    }
    private object Begin(JsonElement p)
    {
        Keys(p, "requestId", "path", "revision", "sha256", "size", "encoding");
        var id = Id(p); var relative = Text(p, "path"); var revision = Digest(p, "revision"); var hash = Digest(p, "sha256");
        var size = Number(p, "size"); var encoding = Text(p, "encoding", 20);
        if (size > TextLimit || encoding is not ("utf8" or "utf8-bom" or "utf16-le" or "utf16-be")) throw UserFileAccess.Invalid();
        using var access = new UserFileAccess(root, relative); Mutable(access);
        using var handle = UserFileAccess.Open(access.Target, 0x80000000, out var info);
        if (info.Directory || (info.Attributes & (uint)FileAttributes.ReadOnly) != 0) throw UserFileAccess.Invalid();
        var bytes = Bytes(handle);
        if (Hash(bytes) != revision || WorkshopProjectFiles.TextEncoding(bytes) != encoding) throw Conflict();
        foreach (var expired in uploads.Where(x => Environment.TickCount64 - x.Value.Created > 30 * 60_000).Select(x => x.Key).ToArray()) uploads.Remove(expired);
        if (uploads.TryGetValue(id, out var previous))
        {
            if (previous.Path != relative || previous.Revision != revision || previous.Hash != hash || previous.Encoding != encoding || previous.Bytes.Length != size) throw UserFileAccess.Invalid();
            return new { offset = previous.Offset };
        }
        if (uploads.Count >= 8) throw new AgentActionException("file_busy", "待保存文件较多，请稍后重试。");
        uploads.Add(id, new(relative, revision, hash, encoding, new byte[size]));
        return new { offset = 0 };
    }
    private object Chunk(JsonElement p)
    {
        Keys(p, "requestId", "offset", "data");
        if (!uploads.TryGetValue(Id(p), out var upload)) throw new AgentActionException("file_transfer_missing", "保存传输已失效，请重新读取后保存。");
        var offset = Number(p, "offset"); byte[] bytes;
        try { bytes = Convert.FromBase64String(Text(p, "data", 12_000)); } catch (FormatException) { throw UserFileAccess.Invalid(); }
        if (bytes.Length is 0 or > ChunkSize || offset > upload.Offset || offset > upload.Bytes.Length - bytes.Length) throw UserFileAccess.Invalid();
        if (offset < upload.Offset)
        { if (offset + bytes.Length > upload.Offset || !upload.Bytes.AsSpan(offset, bytes.Length).SequenceEqual(bytes)) throw UserFileAccess.Invalid(); }
        else { bytes.CopyTo(upload.Bytes, offset); upload.Offset += bytes.Length; }
        return new { offset = upload.Offset };
    }
    private object Commit(JsonElement p, CancellationToken token)
    {
        Keys(p, "requestId"); var id = Id(p);
        if (File.Exists(ReceiptPath(id))) return Operation(p);
        if (!uploads.TryGetValue(id, out var upload)) throw new AgentActionException("file_transfer_missing", "保存传输已失效，请刷新文件核对后再保存。");
        if (upload.Offset != upload.Bytes.Length || Hash(upload.Bytes) != upload.Hash || WorkshopProjectFiles.TextEncoding(upload.Bytes) != upload.Encoding) throw UserFileAccess.Invalid();
        var result = Once(p, upload.Path, () =>
        {
            using var access = new UserFileAccess(root, upload.Path); Mutable(access);
            // Deny writers while comparing the baseline. The replacement is a
            // verified temporary handle renamed into the pinned parent.
            using var existing = UserFileAccess.Open(access.Target, 0x80000000, out var info, share: 5);
            if (info.Directory || (info.Attributes & (uint)FileAttributes.ReadOnly) != 0 || Hash(Bytes(existing)) != upload.Revision) throw Conflict();
            token.ThrowIfCancellationRequested();
            var temp = Path.Combine(Path.GetDirectoryName(access.Target)!, ".kage-save-" + Guid.NewGuid().ToString("N"));
            using var handle = UserFileAccess.Open(temp, 0x40050000, out _, 1);
            try
            {
                using (var output = new FileStream(new Microsoft.Win32.SafeHandles.SafeFileHandle(handle.DangerousGetHandle(), ownsHandle: false), FileAccess.Write))
                { output.Write(upload.Bytes); output.Flush(true); }
                UserFileAccess.PreserveMetadata(existing, handle, info);
                UserFileAccess.Rename(handle, access.Target, replace: true);
            }
            catch { UserFileAccess.Delete(handle); throw; }
            return upload.Hash;
        });
        uploads.Remove(id); return result;
    }
    [System.Runtime.InteropServices.DllImport("kernel32.dll", EntryPoint = "CreateDirectoryW", CharSet = System.Runtime.InteropServices.CharSet.Unicode, SetLastError = true)]
    private static extern bool CreateDirectory(string path, IntPtr security);
}
