using System;
using System.Buffers.Binary;
using System.IO;
using System.Net.WebSockets;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace Hako.Platform;

// Binary network payloads are converted only on the same-machine JSON RPC hop.
internal static class WorkshopBinaryFrame
{
    internal const int MaximumBytes = 36 * 1024;
    internal static JsonDocument Decode(byte[] bytes)
    {
        if (bytes.Length < 5 || bytes.Length > MaximumBytes) throw new InvalidDataException("Invalid binary frame size.");
        var size = BinaryPrimitives.ReadUInt32BigEndian(bytes);
        if (size is 0 or > 1024 || 4L + size >= bytes.Length) throw new InvalidDataException("Invalid binary routing header.");
        using var header = JsonDocument.Parse(bytes.AsMemory(4, (int)size));
        var id = CodexJson.Required(header.RootElement, "id", 80);
        var computerId = CodexJson.Text(header.RootElement, "computerId");
        return JsonDocument.Parse(JsonSerializer.SerializeToUtf8Bytes(new {
            kind = "call", id, computerId, method = "image.upload.binary",
            @params = new { packet = Convert.ToBase64String(bytes, 4 + (int)size, bytes.Length - 4 - (int)size) }
        }));
    }
    internal static async Task<JsonDocument> ReadAsync(WebSocket socket, CancellationToken token)
    {
        using var bytes = new MemoryStream();
        var buffer = new byte[4096];
        WebSocketMessageType? type = null;
        while (true)
        {
            var frame = await socket.ReceiveAsync(buffer, token);
            if (frame.MessageType is not (WebSocketMessageType.Text or WebSocketMessageType.Binary) ||
                type is not null && type != frame.MessageType) throw new IOException("Invalid workshop frame.");
            type = frame.MessageType;
            var limit = type == WebSocketMessageType.Binary ? MaximumBytes : 17 * 1024;
            if (bytes.Length + frame.Count > limit) throw new InvalidDataException("Workshop frame too large.");
            bytes.Write(buffer, 0, frame.Count);
            if (frame.EndOfMessage) return type == WebSocketMessageType.Binary ? Decode(bytes.ToArray()) : JsonDocument.Parse(bytes.ToArray());
        }
    }
}
