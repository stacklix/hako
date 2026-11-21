using System;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Net.WebSockets;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace Hako.Core;

// The session key is delivered only through the authenticated cloud connection.
// HTTP carries AES-GCM ciphertext, never this key or unencrypted device data.
internal sealed class AgentLanEndpoint(IAgentDispatcher dispatcher)
{
    internal const string Command = "query.network.lan";
    private readonly byte[] key = RandomNumberGenerator.GetBytes(32);
    internal int Port { get; set; }
    internal Func<string, WebSocket, CancellationToken, Task>? OpenStream { get; set; }
    internal object Snapshot() => new { enabled = Port > 0, protocol = "hako-agent-lan-v1", port = Port,
        addresses = Addresses(), token = Port > 0 ? Convert.ToBase64String(key) : null };
    internal static string[] Addresses() => NetworkInterface.GetAllNetworkInterfaces()
        .Where(value => value.OperationalStatus == OperationalStatus.Up && value.NetworkInterfaceType != NetworkInterfaceType.Loopback)
        .SelectMany(value => value.GetIPProperties().UnicastAddresses)
        .Select(value => value.Address).Where(IsPrivateIPv4).Select(value => value.ToString()).Distinct().Order().ToArray();
    internal static bool IsPrivateIPv4(IPAddress address)
    {
        if (address.AddressFamily != AddressFamily.InterNetwork) return false;
        var b = address.GetAddressBytes();
        return b[0] == 10 || b[0] == 172 && b[1] is >= 16 and <= 31 || b[0] == 192 && b[1] == 168;
    }
    internal static byte[] Seal(byte[] key, byte[] plain, string direction)
    {
        var combined = new byte[12 + plain.Length + 16];
        RandomNumberGenerator.Fill(combined.AsSpan(0, 12));
        using var cipher = new AesGcm(key, 16);
        cipher.Encrypt(combined.AsSpan(0, 12), plain, combined.AsSpan(12, plain.Length), combined.AsSpan(12 + plain.Length),
            Encoding.UTF8.GetBytes("hako-agent-lan-v1:" + direction));
        return combined;
    }
    internal static byte[] Open(byte[] key, byte[] combined, string direction)
    {
        if (combined.Length is < 28 or > 65564) throw new InvalidDataException("Invalid LAN payload size.");
        var plain = new byte[combined.Length - 28];
        using var cipher = new AesGcm(key, 16);
        cipher.Decrypt(combined.AsSpan(0, 12), combined.AsSpan(12, plain.Length), combined.AsSpan(12 + plain.Length), plain,
            Encoding.UTF8.GetBytes("hako-agent-lan-v1:" + direction));
        return plain;
    }
    internal async Task<byte[]> HandleAsync(byte[] body, CancellationToken token)
    {
        using var wire = JsonDocument.Parse(body);
        if (wire.RootElement.GetProperty("version").GetInt32() != 1) throw new InvalidDataException("Invalid LAN version.");
        using var request = JsonDocument.Parse(Open(key, Convert.FromBase64String(wire.RootElement.GetProperty("payload").GetString()!), "request"));
        var root = request.RootElement;
        var id = root.GetProperty("id").GetString();
        if (!Guid.TryParse(id, out _) || Math.Abs((double)DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() - root.GetProperty("timestamp").GetInt64()) > 30000)
            throw new InvalidDataException("Expired LAN request.");
        object reply;
        try
        {
            var method = root.GetProperty("method").GetString()!;
            if (!method.StartsWith("query.", StringComparison.Ordinal))
                throw new AgentActionException("query_only", "局域网数据通道只支持 query 命令。");
            using var budget = CancellationTokenSource.CreateLinkedTokenSource(token);
            budget.CancelAfter(TimeSpan.FromSeconds(8));
            reply = new { id, result = await dispatcher.InvokeAsync(method, root.GetProperty("version").GetInt32(), root.GetProperty("params"), budget.Token) };
        }
        catch (AgentActionException error) { reply = new { id, error = new { code = error.Code, message = error.Message } }; }
        catch (Exception error) when (error is not OperationCanceledException || !token.IsCancellationRequested)
        { reply = new { id, error = new { code = "query_failed", message = "局域网数据查询失败。" } }; }
        var plain = JsonSerializer.SerializeToUtf8Bytes(reply, AgentConnection.Json);
        if (plain.Length > 65536) plain = JsonSerializer.SerializeToUtf8Bytes(new { id, error = new { code = "result_too_large", message = "查询结果超过大小限制。" } });
        return JsonSerializer.SerializeToUtf8Bytes(new { version = 1, payload = Convert.ToBase64String(Seal(key, plain, "response")) });
    }
}
