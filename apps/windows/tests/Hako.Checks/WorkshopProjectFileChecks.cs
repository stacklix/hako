using System;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Hako.Platform;

internal static class WorkshopProjectFileChecks
{
    internal static async Task RunAsync()
    {
        var root = Path.Combine(Path.GetTempPath(), "hako-project-files-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        try
        {
            var api = new WorkshopProjectFiles();
            async Task<JsonElement> Call(string method, object p) => JsonSerializer.SerializeToElement(
                await api.CallAsync(method, root, JsonSerializer.SerializeToElement(p, WorkshopProtocol.Json), default), WorkshopProtocol.Json);
            async Task Reject(string method, object p, string code)
            {
                try { await Call(method, p); throw new Exception("Expected " + code); }
                catch (WorkshopException error) when (error.Code == code) { }
            }
            static string Hash(byte[] bytes) => Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant();
            static void Check(bool value, string message) { if (!value) throw new Exception(message); }
            async Task Git(params string[] args)
            {
                var info = new ProcessStartInfo("git") { WorkingDirectory = root, UseShellExecute = false, CreateNoWindow = true,
                    RedirectStandardOutput = true, RedirectStandardError = true };
                foreach (var arg in args) info.ArgumentList.Add(arg);
                using var process = Process.Start(info)!;
                var output = process.StandardOutput.ReadToEndAsync(); var error = process.StandardError.ReadToEndAsync();
                await process.WaitForExitAsync(); await output; await error;
                Check(process.ExitCode == 0, "Fixture git command failed");
            }
            await Git("init", "--initial-branch=master");
            Directory.CreateDirectory(Path.Combine(root, "folder"));
            File.WriteAllText(Path.Combine(root, "folder", "你好.swift"), "import SwiftUI\r\nlet value = 1\r\n", new UTF8Encoding(true));
            File.WriteAllText(Path.Combine(root, "deleted.txt"), "deleted");
            await Git("add", ".");
            File.Delete(Path.Combine(root, "deleted.txt"));
            for (var i = 0; i < 105; i++) File.WriteAllText(Path.Combine(root, $"file-{i:000}.txt"), "sample");
            var first = await Call("files.list", new { path = "" });
            Check(first.GetProperty("entries").GetArrayLength() == 100 && first.GetProperty("entries")[0].GetProperty("directory").GetBoolean(), "Directories were not sorted/paged first");
            Check(first.GetProperty("entries").EnumerateArray().All(e => e.GetProperty("name").GetString() != ".git"), "Git internals were exposed");
            var next = await Call("files.list", new { path = "", offset = first.GetProperty("nextOffset").GetInt32() });
            Check(next.GetProperty("entries").GetArrayLength() == 6, "Directory continuation lost files");
            Check(JsonSerializer.SerializeToUtf8Bytes(first, WorkshopProtocol.Json).Length < 64 * 1024, "Directory frame exceeded transport limit");
            var search = await Call("files.list", new { path = "", query = "你好" });
            Check(search.GetProperty("entries").GetArrayLength() == 1, "Recursive Unicode search failed");
            await Reject("files.list", new { path = "../" }, "invalid_params");
            await Reject("files.list", new { path = root }, "invalid_params");
            await Reject("files.list", new { path = ".git" }, "invalid_params");
            await Reject("files.read", new { path = "folder/你好.swift:stream" }, "invalid_params");
            File.WriteAllBytes(Path.Combine(root, "binary.bin"), new byte[] { 0, 1, 2 });
            var binary = await Call("files.read", new { path = "binary.bin" });
            Check(!binary.GetProperty("editable").GetBoolean() && binary.GetProperty("encoding").ValueKind == JsonValueKind.Null, "Binary file became editable");
            var large = Encoding.UTF8.GetBytes(new string('中', 7000) + "\r\n");
            File.WriteAllBytes(Path.Combine(root, "long.txt"), large);
            var read = await Call("files.read", new { path = "long.txt" });
            Check(Convert.FromBase64String(read.GetProperty("data").GetString()!).Length == 8192 && read.GetProperty("nextOffset").GetInt32() == 8192, "Large text was not chunked");
            File.AppendAllText(Path.Combine(root, "long.txt"), "changed");
            await Reject("files.read", new { path = "long.txt", offset = 8192, revision = read.GetProperty("revision").GetString() }, "file_conflict");
            var original = File.ReadAllBytes(Path.Combine(root, "folder", "你好.swift"));
            Check(WorkshopProjectFiles.TextEncoding(original) == "utf8-bom", "UTF-8 BOM was lost");
            var utf16 = new UnicodeEncoding(false, true, true).GetPreamble().Concat(Encoding.Unicode.GetBytes("你好\r\n")).ToArray();
            Check(WorkshopProjectFiles.TextEncoding(utf16) == "utf16-le", "UTF-16 text was rejected");
            var replacement = new byte[] { 0xef, 0xbb, 0xbf }.Concat(large).ToArray();
            async Task<string> Upload(byte[] bytes)
            {
                var id = Guid.NewGuid().ToString();
                await Call("files.write.begin", new { transferId = id, path = "folder/你好.swift", revision = Hash(original), sha256 = Hash(bytes), size = bytes.Length, encoding = "utf8-bom" });
                for (var offset = 0; offset < bytes.Length; offset += 8192)
                {
                    var chunk = Convert.ToBase64String(bytes.AsSpan(offset, Math.Min(8192, bytes.Length - offset)));
                    var reply = await Call("files.write.chunk", new { transferId = id, offset, data = chunk });
                    Check(reply.GetProperty("offset").GetInt32() == offset + Math.Min(8192, bytes.Length - offset), "Upload acknowledgement was wrong");
                    await Call("files.write.chunk", new { transferId = id, offset, data = chunk });
                }
                return id;
            }
            var transfer = await Upload(replacement);
            await Call("files.write.commit", new { transferId = transfer });
            await Call("files.write.commit", new { transferId = transfer });
            Check(File.ReadAllBytes(Path.Combine(root, "folder", "你好.swift")).SequenceEqual(replacement), "Atomic save changed bytes, BOM, or newlines");
            File.WriteAllBytes(Path.Combine(root, "folder", "你好.swift"), original);
            var conflict = await Upload(replacement);
            File.WriteAllText(Path.Combine(root, "folder", "你好.swift"), "external modification");
            await Reject("files.write.commit", new { transferId = conflict }, "file_conflict");
            Check(File.ReadAllText(Path.Combine(root, "folder", "你好.swift")) == "external modification", "Save overwrote a concurrent edit");
            var modified = await Call("files.modified", new { });
            var entries = modified.GetProperty("entries").EnumerateArray().ToArray();
            Check(entries.Any(e => e.GetProperty("path").GetString() == "folder/你好.swift") && entries.Any(e => e.GetProperty("path").GetString() == "deleted.txt"), "Git status lost Unicode/deleted paths");
            var readonlyPath = Path.Combine(root, "readonly.txt"); File.WriteAllText(readonlyPath, "read only"); File.SetAttributes(readonlyPath, FileAttributes.ReadOnly);
            Check(!(await Call("files.read", new { path = "readonly.txt" })).GetProperty("editable").GetBoolean(), "Read-only file became editable");
            File.SetAttributes(readonlyPath, FileAttributes.Normal);
            File.WriteAllBytes(Path.Combine(root, "oversize.txt"), new byte[WorkshopProjectFiles.TextLimit + 1]);
            Check(!(await Call("files.read", new { path = "oversize.txt" })).GetProperty("editable").GetBoolean(), "Oversize text became editable");
            var image = new byte[70_000];
            new byte[] { 137, 80, 78, 71, 13, 10, 26, 10 }.CopyTo(image, 0);
            File.WriteAllBytes(Path.Combine(root, "image.png"), image);
            var imageFirst = await Call("files.image.read", new { path = "image.png", offset = 0 });
            Check(imageFirst.GetProperty("total").GetInt32() == image.Length &&
                Convert.FromBase64String(imageFirst.GetProperty("content").GetString()!).Length == 24 * 1024 &&
                imageFirst.GetProperty("revision").GetString() == Hash(image), "Image read lost chunk bounds or hash");
            // A concurrent edit must not mix bytes into an in-flight snapshot.
            var imageRevision = imageFirst.GetProperty("revision").GetString();
            File.WriteAllBytes(Path.Combine(root, "image.png"), "GIF89a-new-version"u8.ToArray());
            var imageNext = await Call("files.image.read", new { path = "image.png", offset = 24 * 1024, revision = imageRevision });
            Check(imageNext.GetProperty("revision").GetString() == imageRevision &&
                Convert.FromBase64String(imageNext.GetProperty("content").GetString()!).All(b => b == 0), "Image snapshot mixed revisions");
            var refreshedImage = await Call("files.image.read", new { path = "image.png", offset = 0 });
            Check(refreshedImage.GetProperty("revision").GetString() != imageRevision, "Reopening an image retained stale bytes");
            await Reject("files.image.read", new { path = "image.png", offset = 0, revision = imageRevision }, "file_conflict");
            await Reject("files.image.read", new { path = "../image.png", offset = 0 }, "invalid_params");
            await Reject("files.image.read", new { path = ".git/config", offset = 0 }, "invalid_params");
            await Reject("files.image.read", new { path = "image.png", offset = 100_000 }, "invalid_params");
            File.WriteAllText(Path.Combine(root, "fake.png"), "<html>not an image</html>");
            await Reject("files.image.read", new { path = "fake.png", offset = 0 }, "file_not_image");
            File.WriteAllBytes(Path.Combine(root, "large.png"), new byte[CodeWorkshop.MaximumReadImageBytes + 1]);
            await Reject("files.image.read", new { path = "large.png", offset = 0 }, "file_too_large");
            Console.WriteLine("Workshop project file checks passed (paging, search, bounds, encoding, chunks, conflicts, Git status).");
        }
        finally
        {
            var prefix = Path.Combine(Path.GetTempPath(), "hako-project-files-");
            if (!Path.GetFullPath(root).StartsWith(prefix, StringComparison.OrdinalIgnoreCase)) throw new InvalidOperationException("Unexpected fixture path");
            foreach (var file in Directory.EnumerateFiles(root, "*", SearchOption.AllDirectories))
                File.SetAttributes(file, File.GetAttributes(file) & ~FileAttributes.ReadOnly);
            Directory.Delete(root, true);
        }
    }
}
