using System;
using System.Buffers.Binary;
using System.Collections.Generic;
using System.IO;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Threading;
using System.Threading.Tasks;

namespace Hako.Core;

public sealed record AgentCommand(string Command, Dictionary<string, string> Options);
public sealed record CommandReply(int ExitCode, string Text, JsonElement? Data = null, string? ErrorCode = null, string? ErrorMessage = null)
{
    public static CommandReply Success(object data, string text = "完成。") => new(0, text, JsonSerializer.SerializeToElement(data, CliWire.Json));
    public static CommandReply Failure(int exitCode, string code, string message) => new(exitCode, message, null, code, message);
    public string ToJson() => JsonSerializer.Serialize(new { ok = ExitCode == 0, exitCode = ExitCode, data = Data,
        error = ErrorCode is null ? null : new { code = ErrorCode, message = ErrorMessage } }, CliWire.Json);
}

public sealed class AgentProfile
{
    public AgentSettingsStore Store { get; }
    public string PipeName { get; }
    public string MutexName { get; }
    public AgentProfile(string? directory = null)
    {
        Store = new AgentSettingsStore(directory);
        var sid = WindowsIdentity.GetCurrent().User?.Value ?? throw new InvalidOperationException("无法确认当前 Windows 用户。");
        var hash = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(sid + "\n" + Store.DirectoryPath.ToUpperInvariant())))[..32];
        PipeName = "Hako.Agent." + hash;
        // Preserve the existing GUI lock for the default profile, including older running versions.
        MutexName = "Local\\Hako.Agent." + sid;
        if (!string.Equals(Store.DirectoryPath, AgentSettingsStore.DefaultDirectory, StringComparison.OrdinalIgnoreCase)) MutexName += "." + hash;
    }
}

public static class CliWire
{
    public const int MaximumFrameBytes = 65536;
    public static readonly JsonSerializerOptions Json = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
        UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow
    };
    public static async Task WriteAsync<T>(Stream stream, T value, CancellationToken token)
    {
        var bytes = JsonSerializer.SerializeToUtf8Bytes(value, Json);
        if (bytes.Length > MaximumFrameBytes) throw new InvalidDataException("本机通信消息过长。");
        var header = new byte[4]; BinaryPrimitives.WriteInt32LittleEndian(header, bytes.Length);
        await stream.WriteAsync(header, token);
        await stream.WriteAsync(bytes, token);
        await stream.FlushAsync(token);
    }
    public static async Task<T> ReadAsync<T>(Stream stream, CancellationToken token)
    {
        var header = new byte[4]; await stream.ReadExactlyAsync(header, token);
        var length = BinaryPrimitives.ReadInt32LittleEndian(header);
        if (length <= 0 || length > MaximumFrameBytes) throw new InvalidDataException("本机通信消息长度无效。");
        var bytes = new byte[length]; await stream.ReadExactlyAsync(bytes, token);
        return JsonSerializer.Deserialize<T>(bytes, Json) ?? throw new InvalidDataException("本机通信消息无效。");
    }
}
