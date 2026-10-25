using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;

namespace Hako.Core;

public sealed class CliUsageException : Exception { public CliUsageException(string message) : base(message) { } }
public sealed record CliInvocation(AgentProfile Profile, AgentCommand? Request, bool Json, bool Background);

public static class CliParser
{
    private static readonly Dictionary<string, string[]> Allowed = new(StringComparer.Ordinal)
    {
        ["status"] = [], ["config show"] = [], ["config set"] = ["url", "account"],
        ["key generate"] = ["force"], ["key import"] = ["input", "force"],
        ["key export-public"] = ["output", "force"], ["connect"] = [], ["disconnect"] = [],
        ["metrics"] = [], ["exit"] = [], ["show"] = []
    };
    public static CliInvocation Parse(string[] args)
    {
        string? directory = null;
        bool json = false;
        var tokens = new List<string>();
        for (int i = 0; i < args.Length; i++)
        {
            if (args[i] == "--json") { if (json) throw new CliUsageException("--json 不能重复。"); json = true; }
            else if (args[i] == "--data-dir")
            {
                if (directory is not null || i + 1 == args.Length || args[i + 1].StartsWith('-')) throw new CliUsageException("--data-dir 需要一个目录且不能重复。");
                directory = Path.GetFullPath(args[++i]);
            }
            else tokens.Add(args[i]);
        }
        var profile = new AgentProfile(directory);
        if (tokens.Count == 0) return new CliInvocation(profile, json ? new AgentCommand("help", new()) : null, json, false);
        if (tokens[0] == "--background")
        {
            if (tokens.Count != 1 || json) throw new CliUsageException("后台启动参数无效。");
            return new CliInvocation(profile, null, false, true);
        }
        if (tokens[0] == "help" || tokens.Any(t => t is "--help" or "-h"))
        {
            var words = tokens.Where(t => t is not "--help" and not "-h").ToList();
            if (words.Count > 0 && words[0] == "help") words.RemoveAt(0);
            var topic = string.Join(" ", words.TakeWhile(t => !t.StartsWith('-')));
            CliHelp.Get(topic);
            return new CliInvocation(profile, new AgentCommand("help", new() { ["topic"] = topic }), json, false);
        }
        int wordCount = tokens[0] is "key" or "config" ? 2 : 1;
        if (tokens.Count < wordCount) throw new CliUsageException("子命令不完整，请运行 Hako.exe help。");
        var command = string.Join(" ", tokens.Take(wordCount));
        var options = new Dictionary<string, string>(StringComparer.Ordinal);
        for (int i = wordCount; i < tokens.Count; i++)
        {
            var option = tokens[i];
            if (!option.StartsWith("--", StringComparison.Ordinal)) throw new CliUsageException("存在多余参数，请查看该命令的 --help。");
            var name = option[2..];
            if (options.ContainsKey(name)) throw new CliUsageException("选项不能重复。");
            if (name == "force") options[name] = "true";
            else
            {
                if (i + 1 == tokens.Count || tokens[i + 1].StartsWith("--", StringComparison.Ordinal)) throw new CliUsageException("选项缺少值，请查看该命令的 --help。");
                options[name] = tokens[++i];
            }
        }
        var request = new AgentCommand(command, options);
        Validate(request);
        foreach (var path in new[] { "input", "output" }) if (options.TryGetValue(path, out var value)) options[path] = Path.GetFullPath(value);
        return new CliInvocation(profile, request, json, false);
    }
    public static void Validate(AgentCommand request)
    {
        if (request.Command == "help") { CliHelp.Get(request.Options.GetValueOrDefault("topic", "")); return; }
        if (!Allowed.TryGetValue(request.Command, out var allowed) || request.Options.Keys.Any(k => !allowed.Contains(k)))
            throw new CliUsageException("未知命令或选项，请运行 Hako.exe help。");
        if (request.Command == "config set" && request.Options.Count == 0) throw new CliUsageException("config set 至少需要 --url 或 --account。");
        if (request.Command == "key import" && !request.Options.ContainsKey("input")) throw new CliUsageException("key import 需要 --input 私钥文件。");
        if (request.Options.Any(p => string.IsNullOrWhiteSpace(p.Value))) throw new CliUsageException("选项值不能为空。");
        if (request.Options.TryGetValue("force", out var force) && force != "true") throw new CliUsageException("--force 不接受参数值。");
    }
}
