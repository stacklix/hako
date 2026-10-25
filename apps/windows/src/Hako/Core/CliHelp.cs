using System;
using System.Linq;

namespace Hako.Core;

public static class CliHelp
{
    public sealed record Entry(string Command, string Description, string Usage);
    public static readonly Entry[] Entries =
    [
        new("help", "查看全部命令或指定命令帮助；支持 --help、-h。", "Hako.exe help [命令]"),
        new("status", "查看进程、连接状态与公开配置信息，不启动后台实例。", "Hako.exe status [--json]"),
        new("config show", "查看 URL、账号、密钥指纹，不返回私钥。", "Hako.exe config show [--json]"),
        new("config set", "更新配置并断开旧连接；可在尚未生成密钥时配置。", "Hako.exe config set [--url https://monitor.example.com] [--account owner] [--json]"),
        new("key generate", "生成并加密保存 RSA 3072 位密钥；替换现有密钥必须使用 --force。", "Hako.exe key generate [--force] [--json]"),
        new("key import", "从 PEM 文件导入私钥并加密保存；替换需要 --force。", "Hako.exe key import --input private.pem [--force] [--json]"),
        new("key export-public", "导出 SPKI PEM 公钥；省略 --output 则输出到终端；覆盖文件需要 --force。", "Hako.exe key export-public [--output desktop.public.pem] [--force] [--json]"),
        new("connect", "启动或复用后台实例并发起连接；使用 status 检查是否已通过身份验证。", "Hako.exe connect [--json]"),
        new("disconnect", "断开连接并停止重试，保留后台进程和配置。", "Hako.exe disconnect [--json]"),
        new("metrics", "按需采样本机 CPU、物理内存（约 1 秒），无需连接服务器。", "Hako.exe metrics [--json]"),
        new("exit", "退出当前配置对应的 Hako 实例，保留已保存的配置和密钥。", "Hako.exe exit [--json]")
    ];
    public static Entry[] Get(string topic)
    {
        var entries = Entries.Where(e => topic.Length == 0 || e.Command == topic || e.Command.StartsWith(topic + " ", StringComparison.Ordinal)).ToArray();
        if (entries.Length == 0) throw new CliUsageException("未知帮助主题，请运行 Hako.exe help。");
        return entries;
    }
    public static CommandReply Reply(string topic)
    {
        var commands = Get(topic);
        var globals = "全局选项：--json 输出 JSON；--data-dir <目录> 使用独立的加密配置和后台实例。";
        var exits = "退出码：0 成功；1 操作失败；2 参数错误；3 实例不可用；4 超时。";
        var examples = "示例：Hako.exe help key\n      Hako.exe key generate --json\n      Hako.exe key export-public --output desktop.public.pem\n      Hako.exe status --json | ConvertFrom-Json\nPowerShell 脚本可使用管道或 Start-Process -Wait 等待这个 GUI/CLI 共用 EXE 并读取退出码。";
        return CommandReply.Success(new { commands, globalOptions = new[] { "--json", "--data-dir <directory>" },
            exitCodes = new { success = 0, operationFailed = 1, invalidArguments = 2, instanceUnavailable = 3, timeout = 4 } },
            "Hako Windows Agent\n\n" + string.Join("\n\n", commands.Select(e => e.Usage + "\n  " + e.Description)) + "\n\n" + globals + "\n" + exits + "\n\n" + examples);
    }
}
