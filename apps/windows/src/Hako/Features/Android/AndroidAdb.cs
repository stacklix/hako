using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using Hako.Core;

namespace Hako.Platform;

internal interface IAndroidAdb
{
    string? Executable { get; }
    Task<byte[]> RunAsync(string[] arguments, CancellationToken token, string? input = null, int limit = 2 * 1024 * 1024);
}

internal sealed class AndroidAdb(string directory) : IAndroidAdb
{
    public string? Executable => Candidates().FirstOrDefault(File.Exists);
    private IEnumerable<string> Candidates()
    {
        yield return Path.Combine(directory, "platform-tools", "adb.exe");
        foreach (var key in new[] { "ANDROID_HOME", "ANDROID_SDK_ROOT" })
            if (Environment.GetEnvironmentVariable(key) is { Length: > 0 } sdk) yield return Path.Combine(sdk, "platform-tools", "adb.exe");
        foreach (var path in (Environment.GetEnvironmentVariable("PATH") ?? "").Split(Path.PathSeparator))
            if (path.Length > 0) yield return Path.Combine(path.Trim('"'), "adb.exe");
    }
    public async Task<byte[]> RunAsync(string[] arguments, CancellationToken token, string? input = null, int limit = 2 * 1024 * 1024)
    {
        var executable = Executable ?? throw new AgentActionException("adb_unavailable", "未找到 ADB，请在 Android 管理中下载官方平台工具。");
        using var budget = CancellationTokenSource.CreateLinkedTokenSource(token);
        budget.CancelAfter(TimeSpan.FromSeconds(arguments.Contains("install") ? 180 : 20));
        var start = new ProcessStartInfo(executable) { UseShellExecute = false, CreateNoWindow = true,
            RedirectStandardOutput = true, RedirectStandardError = true, RedirectStandardInput = true,
            StandardErrorEncoding = Encoding.UTF8, StandardInputEncoding = new UTF8Encoding(false) };
        foreach (var argument in arguments) start.ArgumentList.Add(argument);
        using var process = Process.Start(start) ?? throw new IOException("无法启动 ADB。");
        using var output = new MemoryStream();
        var read = ReadAsync(process.StandardOutput.BaseStream, output, limit, budget.Token);
        var errors = ReadAsync(process.StandardError.BaseStream, Stream.Null, 256 * 1024, budget.Token);
        try
        {
            if (input is not null) await process.StandardInput.WriteAsync(input.AsMemory(), budget.Token);
            process.StandardInput.Close();
            var exit = process.WaitForExitAsync(budget.Token);
            await Task.WhenAll(read, errors, exit).WaitAsync(budget.Token);
            if (process.ExitCode != 0) throw new AgentActionException("adb_failed", "ADB 执行失败，请检查设备连接、授权和系统限制。安装失败时请核对 APK 签名及版本。");
            return output.ToArray();
        }
        catch { try { if (!process.HasExited) process.Kill(entireProcessTree: true); } catch (InvalidOperationException) { } throw; }
    }
    private static async Task ReadAsync(Stream input, Stream output, int limit, CancellationToken token)
    {
        var buffer = new byte[8192]; var total = 0;
        while (true) { var count = await input.ReadAsync(buffer, token); if (count == 0) return;
            total += count; if (total > limit) throw new IOException("ADB 输出超过大小限制。");
            await output.WriteAsync(buffer.AsMemory(0, count), token); }
    }
}

internal sealed record AndroidEndpoint(string Serial, string TransportId, string Kind, string State);
internal sealed record AndroidManagedDevice(string Id, string Name, string? Model, string? AndroidVersion,
    AndroidEndpoint[] Connections, string? AgentId = null);
internal sealed record AndroidInventory(bool AdbAvailable, AndroidManagedDevice[] Devices, string SampledAt);
internal sealed record AndroidDetail(string Id, string Screen, int? BatteryPercent, bool? Charging,
    long? MemoryAvailableBytes, long? MemoryTotalBytes, long? StorageAvailableBytes, long? StorageTotalBytes,
    double? UptimeSeconds, string? NamiVersion, long? NamiVersionCode, bool ProcessRunning, bool AgentProcessRunning, string SampledAt);

internal static class AndroidParsing
{
    // Some ADB transports emit CRCRLF. Normalize text only; screenshots/video stay byte-exact.
    private static string NormalizeLines(string text) => Regex.Replace(text, @"\r+\n?", "\n");
    internal static AndroidEndpoint[] Devices(string text) => text.Split('\n').Select(line => line.Trim())
        .Where(line => line.Length > 0 && !line.StartsWith("List ", StringComparison.Ordinal) && !line.StartsWith('*'))
        .Select(line => line.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries))
        .Where(parts => parts.Length >= 2 && new[] { "device", "offline", "unauthorized" }.Contains(parts[1]))
        .Select(parts => new AndroidEndpoint(parts[0], parts.FirstOrDefault(value => value.StartsWith("transport_id:", StringComparison.Ordinal))?[13..] ?? "",
            parts[0].Contains(':') || parts[0].Contains("_adb-tls-", StringComparison.Ordinal) ? "wifi" : "usb", parts[1]))
        .Where(value => Regex.IsMatch(value.TransportId, @"\A[0-9]{1,12}\z")).Take(16).ToArray();
    internal static Dictionary<string, string> Properties(string text) => Regex.Matches(NormalizeLines(text), @"(?m)^\[([^\]]+)\]: \[(.*)\]$")
        .ToDictionary(match => match.Groups[1].Value, match => match.Groups[2].Value, StringComparer.Ordinal);
    internal static long? Number(string text, string pattern) => long.TryParse(Regex.Match(text, pattern, RegexOptions.Multiline).Groups[1].Value, out var n) ? n : null;
    internal static AndroidDetail Detail(string id, string text)
    {
        text = NormalizeLines(text);
        string Section(string name) { var match = Regex.Match(text, "@@" + name + "\\r?\\n([\\s\\S]*?)(?=@@|$)"); return match.Groups[1].Value; }
        var mem = Section("memory"); var diskSection = Section("disk");
        var disk = diskSection.Split('\n').LastOrDefault(line => Regex.IsMatch(line, @"^\S+\s+\d")) ?? "";
        var columns = disk.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);
        var legacyDisk = Regex.IsMatch(diskSection, @"(?m)^Filesystem\s+Size\s+Used\s+Free\s+Blksize\s*$");
        long? BytesAt(int index)
        {
            if (columns.Length <= index) return null;
            if (legacyDisk)
            {
                var match = Regex.Match(columns[index], @"\A(\d+(?:\.\d+)?)([KMGT]?)\z");
                if (!match.Success || !decimal.TryParse(match.Groups[1].Value, System.Globalization.NumberStyles.AllowDecimalPoint,
                    System.Globalization.CultureInfo.InvariantCulture, out var size)) return null;
                var factor = match.Groups[2].Value switch { "K" => 1024m, "M" => 1024m * 1024, "G" => 1024m * 1024 * 1024, "T" => 1024m * 1024 * 1024 * 1024, _ => 1m };
                return size <= long.MaxValue / factor ? (long?)(size * factor) : null;
            }
            return long.TryParse(columns[index], out var n) && n is >= 0 and < long.MaxValue / 1024 ? n * 1024 : null;
        }
        var display = Section("display");
        var raw = Regex.Match(display, @"mScreenState=(OFF|ON|DOZE_SUSPEND|DOZE|ON_SUSPEND|VR)\b").Groups[1].Value;
        var screen = raw switch { "OFF" => "off", "ON" => "on", "DOZE" or "DOZE_SUSPEND" => "doze", "ON_SUSPEND" => "on", "VR" => "on", _ => "unknown" };
        if (screen == "unknown")
        {
            var screenOn = Regex.Match(Section("power"), @"(?m)^\s*mScreenOn=(true|false)\b").Groups[1].Value;
            screen = screenOn switch { "true" => "on", "false" => "off", _ => "unknown" };
        }
        var battery = Section("battery"); var level = Number(battery, @"^\s*level:\s*(\d+)"); var scale = Number(battery, @"^\s*scale:\s*(\d+)");
        var percent = level is >= 0 && scale is > 0 && level <= scale ? (int?)(level * 100 / scale) : null;
        var charge = Number(battery, @"^\s*status:\s*(\d+)");
        var uptimeRaw = Section("uptime").Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries).FirstOrDefault();
        double? uptime = double.TryParse(uptimeRaw, System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out var seconds) && double.IsFinite(seconds) && seconds >= 0 ? seconds : null;
        var package = Section("package"); var version = Regex.Match(package, @"(?m)^\s*versionName=(\S+)").Groups[1].Value;
        var available = Number(mem, @"^MemAvailable:\s*(\d+) kB")
            ?? Number(Section("memorysummary"), @"^\s*Free RAM:\s*(\d+) kB\b");
        var total = Number(mem, @"^MemTotal:\s*(\d+) kB");
        return new(id, screen, percent, charge is null ? null : charge is 2 or 5, available * 1024, total * 1024,
            BytesAt(3), BytesAt(1), uptime, version.Length == 0 ? null : version, Number(package, @"versionCode=(\d+)"),
            Regex.IsMatch(Section("process"), @"\d+"), Regex.IsMatch(Section("agent"), @"\d+"), DateTimeOffset.UtcNow.ToString("O"));
    }
    internal const string DetailScript = """
        echo @@memory
        cat /proc/meminfo
        echo @@memorysummary
        memory_available=0
        while read -r key rest; do
            if [ "$key" = MemAvailable: ]; then memory_available=1; fi
        done < /proc/meminfo
        if [ "$memory_available" = 0 ]; then dumpsys meminfo; fi
        echo @@disk
        df -k /data
        echo @@uptime
        cat /proc/uptime
        echo @@battery
        dumpsys battery
        echo @@display
        dumpsys display
        echo @@power
        dumpsys power
        echo @@package
        dumpsys package me.stackli.doppel
        echo @@process
        pidof me.stackli.doppel
        echo @@agent
        pidof me.stackli.doppel:agent
        echo @@end
        """;
}
