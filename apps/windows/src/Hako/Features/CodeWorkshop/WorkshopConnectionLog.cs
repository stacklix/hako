using System;
using System.Diagnostics;
using System.IO;
using System.Net.Sockets;
using System.Net.WebSockets;
using System.Text.Json;

namespace Hako.Platform;

// Each process/role owns one bounded log. Exception messages may contain secrets.
internal sealed class WorkshopConnectionLog(string? profile, bool commandHost, long maximumBytes = 1_048_576)
{
    private readonly object gate = new();
    internal void Write(string connectionId, string name, string stage, long elapsedMs, int attempt,
        long? downtimeMs = null, Exception? error = null, WebSocketCloseStatus? closeCode = null)
    {
        if (profile is null) return;
        try
        {
            lock (gate)
            {
                var directory = Path.Combine(profile, "logs");
                Directory.CreateDirectory(directory);
                var path = Path.Combine(directory, commandHost ? "command-workshop-connection.jsonl" : "workshop-connection.jsonl");
                if (File.Exists(path) && new FileInfo(path).Length >= maximumBytes)
                    File.Move(path, path + ".previous", true);
                File.AppendAllText(path, JsonSerializer.Serialize(new {
                    time = DateTimeOffset.UtcNow, processId = Environment.ProcessId, connectionId,
                    role = commandHost ? "command_agent" : "agent", @event = name, stage, elapsedMs, attempt, downtimeMs,
                    errorType = error?.GetType().Name, hResult = error?.HResult,
                    innerType = error?.InnerException?.GetType().Name,
                    socketError = (error as SocketException ?? error?.InnerException as SocketException)?.SocketErrorCode.ToString(),
                    webSocketError = (error as WebSocketException)?.WebSocketErrorCode.ToString(),
                    closeCode = closeCode is null ? (int?)null : (int)closeCode
                }) + "\n");
            }
        }
        catch (Exception logError) when (logError is IOException or UnauthorizedAccessException or System.Security.SecurityException)
        { Debug.WriteLine("Workshop connection log unavailable: " + logError.GetType().Name); }
    }
}
