using System;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Security.AccessControl;
using System.Text;
using System.Text.Json;
using System.Threading.Tasks;
using Hako.Core;
using Hako.Platform;

internal static class UserFileChecks
{
    internal static async Task ReadInstalledAsync(string profile)
    {
        using var timeout = new System.Threading.CancellationTokenSource(TimeSpan.FromSeconds(15));
        var result = await LocalRpc.CallAsync(LocalRpc.MainPipe(profile),
            new("agent", UserFiles.ListCommand, 1, JsonSerializer.SerializeToElement(new { path = "", showHidden = false })), timeout.Token);
        var expected = Path.GetFullPath(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile));
        if (!string.Equals(result.GetProperty("root").GetString(), expected, StringComparison.OrdinalIgnoreCase)
            || result.GetProperty("path").GetString() != ""
            || result.GetProperty("entries").GetArrayLength() > 100)
            throw new Exception("Installed file provider returned an invalid user-root page");
        Console.WriteLine($"PASS: installed Kage user-file command through main-process IPC; {result.GetProperty("entries").GetArrayLength()} visible entries, no file contents read or changed.");
    }
    internal static async Task RunAsync()
    {
        var fixture = Path.Combine(Path.GetTempPath(), "kage-user-files-" + Guid.NewGuid().ToString("N"));
        var root = Path.Combine(fixture, "home"); var state = Path.Combine(fixture, "state"); var outside = Path.Combine(fixture, "outside");
        Directory.CreateDirectory(root); Directory.CreateDirectory(outside);
        try
        {
            var api = new UserFiles(state, root);
            async Task<JsonElement> Call(string method, object p) => JsonSerializer.SerializeToElement(await api.CallAsync(method, JsonSerializer.SerializeToElement(p, AgentConnection.Json), default), AgentConnection.Json);
            async Task Reject(string method, object p, string code)
            {
                try { await Call(method, p); throw new Exception("Expected rejection: " + code); }
                catch (AgentActionException e) when (e.Code == code) { }
            }
            static void Check(bool ok, string message) { if (!ok) throw new Exception(message); }
            async Task<JsonElement> Entry(string name) => (await Call(UserFiles.ListCommand, new { path = "", showHidden = true })).GetProperty("entries").EnumerateArray().First(x => x.GetProperty("name").GetString() == name);
            string Id() => Guid.NewGuid().ToString("D");
            async Task<JsonElement> Mutation(string operation, string path, string? name = null, string? revision = null, string? id = null) =>
                await Call("action.files.mutate", new { requestId = id ?? Id(), operation, path, name = name ?? "", revision = revision ?? "" });
            Check((await Mutation("createFolder", "", "Documents")).GetProperty("state").GetString() == "completed", "Create folder failed");
            var createId = Id();
            Check((await Mutation("createFile", "", "notes.md", id: createId)).GetProperty("state").GetString() == "completed", "Create file failed");
            File.WriteAllText(Path.Combine(root, "notes.md"), "# 原始内容\r\n", new UTF8Encoding(true));
            Check((await Mutation("createFile", "", "notes.md", id: createId)).GetProperty("state").GetString() == "completed", "Duplicate request lost receipt");
            Check(File.ReadAllText(Path.Combine(root, "notes.md")).Contains("原始内容"), "Duplicate create overwrote file");
            await Reject("action.files.mutate", new { requestId = createId, operation = "createFile", path = "", name = "other.md", revision = "" }, "file_request_conflict");
            File.WriteAllText(Path.Combine(root, ".hidden"), "hidden");
            var list = await Call(UserFiles.ListCommand, new { path = "" });
            Check(list.GetProperty("entries")[0].GetProperty("directory").GetBoolean(), "Folders are not first");
            Check(list.GetProperty("entries").EnumerateArray().All(x => !x.GetProperty("name").GetString()!.StartsWith('.')), "Hidden file exposed by default");
            Check((await Call(UserFiles.ListCommand, new { path = "", query = "NOTES" })).GetProperty("entries").GetArrayLength() == 1, "Search is not case insensitive");
            foreach (var invalid in new[] { "../outside", "/Windows", "C:/Windows", "notes.md:stream", "Documents/../notes.md", "Documents//a", "notes.md.", "NUL.txt", "CONIN$", "COM¹.log", "Documents\\a" })
                await Reject(UserFiles.ListCommand, new { path = invalid }, "invalid_params");
            var read = await Call("query.files.read", new { path = "notes.md" });
            Check(read.GetProperty("encoding").GetString() == "utf8-bom", "BOM detection lost");
            var revision = read.GetProperty("revision").GetString()!;
            var originalFile = new FileInfo(Path.Combine(root, "notes.md"));
            File.SetAttributes(originalFile.FullName, FileAttributes.Hidden);
            var acl = originalFile.GetAccessControl(AccessControlSections.Access);
            acl.SetAccessRuleProtection(true, preserveInheritance: true); originalFile.SetAccessControl(acl);
            var originalAcl = originalFile.GetAccessControl(AccessControlSections.Access).GetSecurityDescriptorSddlForm(AccessControlSections.Access);
            var content = new UTF8Encoding(true).GetPreamble().Concat(Encoding.UTF8.GetBytes("# 更新内容\r\n" + new string('x', 20000))).ToArray();
            var hash = Convert.ToHexString(SHA256.HashData(content)).ToLowerInvariant(); var transfer = Id();
            await Call("action.files.write.begin", new { requestId = transfer, path = "notes.md", revision, sha256 = hash, size = content.Length, encoding = "utf8-bom" });
            for (var offset = 0; offset < content.Length; offset += UserFiles.ChunkSize)
            {
                var data = Convert.ToBase64String(content.AsSpan(offset, Math.Min(UserFiles.ChunkSize, content.Length - offset)));
                await Call("action.files.write.chunk", new { requestId = transfer, offset, data });
                await Call("action.files.write.chunk", new { requestId = transfer, offset, data });
            }
            var saved = await Call("action.files.write.commit", new { requestId = transfer });
            Check(saved.GetProperty("state").GetString() == "completed", "Commit failed: " + saved);
            var actual = File.ReadAllBytes(Path.Combine(root, "notes.md"));
            Check(actual.SequenceEqual(content), $"Atomic save content mismatch: expected {content.Length}/{hash}, actual {actual.Length}/{Convert.ToHexString(SHA256.HashData(actual))}; receipt={saved}; entries={string.Join(',', Directory.GetFiles(root).Select(x => Path.GetFileName(x) + ':' + new FileInfo(x).Length))}");
            Check((File.GetAttributes(originalFile.FullName) & FileAttributes.Hidden) != 0, "Atomic save dropped hidden attribute");
            Check(originalFile.GetAccessControl(AccessControlSections.Access).GetSecurityDescriptorSddlForm(AccessControlSections.Access) == originalAcl, "Atomic save broadened the original file ACL");
            Check(!Directory.EnumerateFiles(root, ".kage-save-*").Any(), "Save left temporary files");
            Check((await Call("action.files.write.commit", new { requestId = transfer })).GetProperty("revision").GetString() == hash, "Commit replay lost receipt");
            var recovered = new UserFiles(state, root);
            var receipt = JsonSerializer.SerializeToElement(await recovered.CallAsync("query.files.operation", JsonSerializer.SerializeToElement(new { requestId = transfer }), default), AgentConnection.Json);
            Check(receipt.GetProperty("state").GetString() == "completed", "Restart lost receipt");
            var conflictTransfer = Id();
            await Call("action.files.write.begin", new { requestId = conflictTransfer, path = "notes.md", revision = hash, sha256 = hash, size = content.Length, encoding = "utf8-bom" });
            for (var offset = 0; offset < content.Length; offset += UserFiles.ChunkSize)
                await Call("action.files.write.chunk", new { requestId = conflictTransfer, offset, data = Convert.ToBase64String(content.AsSpan(offset, Math.Min(UserFiles.ChunkSize, content.Length - offset))) });
            File.AppendAllText(originalFile.FullName, "external-save");
            Check((await Call("action.files.write.commit", new { requestId = conflictTransfer })).GetProperty("state").GetString() == "failed", "Concurrent change was overwritten by save");
            Check(File.ReadAllText(originalFile.FullName).EndsWith("external-save", StringComparison.Ordinal), "Save conflict lost external changes");
            var entry = await Entry("notes.md");
            File.AppendAllText(Path.Combine(root, "notes.md"), "external");
            var conflict = await Mutation("rename", "notes.md", "renamed.md", entry.GetProperty("revision").GetString());
            Check(conflict.GetProperty("state").GetString() == "failed" && File.Exists(Path.Combine(root, "notes.md")), "Stale rename was accepted");
            entry = await Entry("notes.md");
            Check((await Mutation("rename", "notes.md", "renamed.md", entry.GetProperty("revision").GetString())).GetProperty("state").GetString() == "completed", "Rename failed");
            File.WriteAllBytes(Path.Combine(root, "binary.bin"), [0, 1, 2, 3]);
            Check(!(await Call("query.files.read", new { path = "binary.bin" })).GetProperty("editable").GetBoolean(), "Binary became editable");
            File.WriteAllBytes(Path.Combine(root, "large.txt"), new byte[UserFiles.TextLimit + 1]);
            Check(!(await Call("query.files.read", new { path = "large.txt" })).GetProperty("editable").GetBoolean(), "Oversize became editable");
            var outsideFile = Path.Combine(outside, "keep.txt"); File.WriteAllText(outsideFile, "keep");
            var link = Path.Combine(root, "escape");
            var start = new ProcessStartInfo("cmd.exe") { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true };
            foreach (var arg in new[] { "/c", "mklink", "/J", link, outside }) start.ArgumentList.Add(arg);
            using (var process = Process.Start(start)!) { await process.WaitForExitAsync(); Check(process.ExitCode == 0, "Junction fixture failed"); }
            await Reject(UserFiles.ListCommand, new { path = "escape" }, "file_link");
            await Reject("query.files.read", new { path = "escape/keep.txt" }, "file_link");
            var linkEntry = await Entry("escape");
            Check((await Mutation("delete", "escape", revision: linkEntry.GetProperty("revision").GetString())).GetProperty("state").GetString() == "failed", "Junction deletion followed link");
            Directory.Delete(link);
            var hardlink = Path.Combine(root, "hard.txt"); Check(CreateHardLink(hardlink, outsideFile, IntPtr.Zero), "Hard-link fixture failed");
            await Reject("query.files.read", new { path = "hard.txt" }, "file_link");
            var hardEntry = await Entry("hard.txt");
            Check((await Mutation("delete", "hard.txt", revision: hardEntry.GetProperty("revision").GetString())).GetProperty("state").GetString() == "failed", "Hard link deletion accepted");
            File.Delete(hardlink); Check(File.ReadAllText(outsideFile) == "keep", "Outside file changed");
            Directory.CreateDirectory(Path.Combine(root, "Documents", "nested"));
            File.WriteAllText(Path.Combine(root, "Documents", "nested", "file.txt"), "child");
            using (var pin = new UserFileAccess(root, "Documents", directory: true))
            {
                try { Directory.Move(pin.Target, Path.Combine(root, "moved")); throw new Exception("Pinned ancestor was replaceable"); }
                catch (IOException) { }
            }
            entry = await Entry("Documents");
            var deleted = await Mutation("delete", "Documents", revision: entry.GetProperty("revision").GetString());
            Check(deleted.GetProperty("state").GetString() == "completed" && !Directory.Exists(Path.Combine(root, "Documents")), "Recursive deletion failed: " + deleted);
            var interrupted = Path.Combine(state, "user-file-operations", createId + ".json");
            File.WriteAllText(interrupted, File.ReadAllText(interrupted).Replace("\"completed\"", "\"running\""));
            Check((await Mutation("createFile", "", "notes.md", id: createId)).GetProperty("state").GetString() == "unknown", "Interrupted operation was replayed");
            Check((await Mutation("delete", "", revision: new string('0', 64))).GetProperty("state").GetString() == "failed", "Root deletion accepted");
            Console.WriteLine("PASS: user files CRUD, atomic chunked save, BOM, conflict detection, search, hidden files, durable deduplication, interruption, traversal, junction and hard-link boundaries.");
        }
        finally
        {
            var resolved = Path.GetFullPath(fixture);
            if (!resolved.StartsWith(Path.GetFullPath(Path.GetTempPath()) + "kage-user-files-", StringComparison.OrdinalIgnoreCase)) throw new Exception("Unsafe fixture cleanup path");
            Directory.Delete(resolved, true);
        }
    }
    [DllImport("kernel32.dll", EntryPoint = "CreateHardLinkW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CreateHardLink(string path, string existing, IntPtr security);
}
