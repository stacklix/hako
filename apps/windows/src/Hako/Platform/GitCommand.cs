using System;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using Hako.Core;

namespace Hako.Platform;

internal static class GitCommand
{
    internal sealed record Result(int ExitCode, string Output);
    private static readonly UTF8Encoding Utf8 = new(false);

    public static async Task<Result> RunAsync(string directory, CancellationToken token, string[] arguments, string? input = null)
    {
        var start = new ProcessStartInfo(FindExecutable())
        {
            WorkingDirectory = directory, UseShellExecute = false, CreateNoWindow = true,
            RedirectStandardOutput = true, RedirectStandardError = true, RedirectStandardInput = true,
            StandardOutputEncoding = Utf8, StandardErrorEncoding = Utf8, StandardInputEncoding = Utf8
        };
        foreach (var key in new[] { "GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_COMMON_DIR", "GIT_CONFIG_COUNT", "GIT_CONFIG_PARAMETERS" })
            start.Environment.Remove(key);
        start.Environment["GIT_TERMINAL_PROMPT"] = "0";
        start.Environment["GCM_INTERACTIVE"] = "Never";
        start.Environment["GIT_OPTIONAL_LOCKS"] = "0";
        start.ArgumentList.Add("--literal-pathspecs");
        start.ArgumentList.Add("-c");
        start.ArgumentList.Add("protocol.ext.allow=never");
        foreach (var argument in arguments) start.ArgumentList.Add(argument);

        token.ThrowIfCancellationRequested();
        using var process = new Process { StartInfo = start };
        try { process.Start(); }
        catch (Win32Exception) { throw new AgentActionException("git_unavailable", "无法启动 Git，请检查 Windows 上的 Git 安装。"); }
        var stdout = ReadOutputAsync(process.StandardOutput, token);
        var stderr = process.StandardError.BaseStream.CopyToAsync(Stream.Null, token);
        try
        {
            if (input is not null) await process.StandardInput.WriteAsync(input.AsMemory(), token);
            process.StandardInput.Close();
            // If stdout exceeds the limit, stop the command even if Git is still writing.
            var exited = process.WaitForExitAsync(token);
            await await Task.WhenAny(stdout, exited);
            await exited;
            await stderr;
            return new(process.ExitCode, await stdout);
        }
        finally
        {
            if (!process.HasExited)
            {
                try { process.Kill(entireProcessTree: true); }
                catch (InvalidOperationException) { }
                catch (Win32Exception) { }
                await process.WaitForExitAsync(CancellationToken.None);
            }
        }
    }

    private static async Task<string> ReadOutputAsync(StreamReader reader, CancellationToken token)
    {
        var output = new StringBuilder();
        var buffer = new char[4096];
        int count;
        while ((count = await reader.ReadAsync(buffer.AsMemory(), token)) > 0)
        {
            if (output.Length + count > 4 * 1024 * 1024)
                throw new AgentActionException("git_result_too_large", "仓库的 Git 状态超出读取上限。");
            output.Append(buffer, 0, count);
        }
        return output.ToString();
    }

    private static string FindExecutable()
    {
        var name = OperatingSystem.IsWindows() ? "git.exe" : "git";
        foreach (var directory in (Environment.GetEnvironmentVariable("PATH") ?? "").Split(Path.PathSeparator))
        {
            var path = directory.Trim().Trim('"');
            if (!Path.IsPathFullyQualified(path)) continue;
            var candidate = Path.Combine(path, name);
            if (File.Exists(candidate)) return candidate;
        }
        foreach (var folder in new[] { Environment.SpecialFolder.ProgramFiles, Environment.SpecialFolder.ProgramFilesX86 })
        {
            var path = Environment.GetFolderPath(folder);
            if (path.Length == 0) continue;
            var candidate = Path.Combine(path, "Git", "cmd", name);
            if (File.Exists(candidate)) return candidate;
        }
        throw new AgentActionException("git_unavailable", "未找到 Git，请在 Windows 安装 Git 并重启 Agent。");
    }
}
