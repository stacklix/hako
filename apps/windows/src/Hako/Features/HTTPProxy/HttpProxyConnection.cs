using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net.WebSockets;
using System.Security.Authentication;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Hako.Platform;

namespace Hako.Core;

// An independent authenticated network service. It never invokes AgentDispatcher,
// the main-process RPC, monitoring request slots, telemetry or SSH.
internal static class HttpProxyConnection
{
    internal static async Task RunAsync(AgentSettings settings, CancellationToken token, Action<bool>? stateChanged = null)
    {
        var origin = settings.Origin();
        var uri = new UriBuilder(origin) { Scheme = origin.Scheme == "https" ? "wss" : "ws", Path = "/ws/proxy/agent" }.Uri;
        var attempt = 0;
        while (!token.IsCancellationRequested)
        {
            try
            {
                await ServerCompatibility.WaitAsync(origin, _ => { }, token);
                using var socket = new ClientWebSocket();
                using (var auth = CancellationTokenSource.CreateLinkedTokenSource(token))
                {
                    auth.CancelAfter(TimeSpan.FromSeconds(10));
                    await socket.ConnectAsync(uri, auth.Token);
                    using var rsa = RSA.Create(); rsa.ImportFromPem(settings.PrivateKey);
                    var keyID = AgentSettings.KeyId(rsa);
                    await Send(socket, new { type = "hello", version = 1, username = settings.Username, keyId = keyID }, auth.Token);
                    using var challenge = await Receive(socket, auth.Token);
                    if (challenge.RootElement.GetProperty("type").GetString() != "challenge") throw new AuthenticationException();
                    var payload = Convert.FromBase64String(challenge.RootElement.GetProperty("payload").GetString()!);
                    var expected = "hako-proxy-auth/v1\n" + origin.GetLeftPart(UriPartial.Authority) + "\n" + settings.Username + "\n" + keyID + "\n";
                    if (!Encoding.UTF8.GetString(payload).StartsWith(expected, StringComparison.Ordinal)) throw new AuthenticationException();
                    await Send(socket, new { type = "authenticate", signature = Convert.ToBase64String(rsa.SignData(payload, HashAlgorithmName.SHA256, RSASignaturePadding.Pss)) }, auth.Token);
                    using var ack = await Receive(socket, auth.Token);
                    if (ack.RootElement.GetProperty("type").GetString() != "authenticated") throw new AuthenticationException();
                }
                attempt = 0;
                stateChanged?.Invoke(true);
                using var connection = CancellationTokenSource.CreateLinkedTokenSource(token);
                using var writing = new SemaphoreSlim(1, 1);
                var workers = new List<Task>();
                async Task Write(object value)
                {
                    using var deadline = CancellationTokenSource.CreateLinkedTokenSource(connection.Token);
                    deadline.CancelAfter(TimeSpan.FromSeconds(5));
                    await writing.WaitAsync(deadline.Token);
                    try { await Send(socket, value, deadline.Token); }
                    finally { writing.Release(); }
                }
                try
                {
                    while (!connection.IsCancellationRequested)
                    {
                        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(connection.Token);
                        deadline.CancelAfter(TimeSpan.FromSeconds(65));
                        using var message = await Receive(socket, deadline.Token);
                        var root = message.RootElement;
                        switch (root.GetProperty("type").GetString())
                        {
                            case "ping": await Write(new { type = "pong" }); break;
                            case "request":
                                workers.RemoveAll(task => task.IsCompleted);
                                var request = root.Clone();
                                if (workers.Count >= 4)
                                {
                                    await Write(new { type = "response", id = root.GetProperty("id").GetString(), error = new { code = "proxy_busy", message = "HTTP 代理繁忙，请稍后重试。" } });
                                    break;
                                }
                                workers.Add(Task.Run(async () =>
                                {
                                    var id = request.GetProperty("id").GetString();
                                    object response;
                                    try { response = new { type = "response", id, result = await ExecuteAsync(request, connection.Token) }; }
                                    catch (AgentActionException e) { response = new { type = "response", id, error = new { code = e.Code, message = e.Message } }; }
                                    catch (Exception e) when (e is not OperationCanceledException) { response = new { type = "response", id, error = new { code = "proxy_failed", message = "HTTP 代理执行失败。" } }; }
                                    try { await Write(response); } catch { connection.Cancel(); socket.Abort(); }
                                }));
                                break;
                            default: throw new InvalidDataException("Unknown proxy transport message.");
                        }
                    }
                }
                finally
                {
                    connection.Cancel(); socket.Abort();
                    try { await Task.WhenAll(workers); } catch (OperationCanceledException) { }
                }
            }
            catch (OperationCanceledException) when (token.IsCancellationRequested) { return; }
            catch (Exception) { /* Only this service reconnects; device commands stay connected. */ }
            finally { stateChanged?.Invoke(false); }
            await Task.Delay(TimeSpan.FromSeconds(Math.Min(30, Math.Pow(2, Math.Min(++attempt, 5)))), token);
        }
    }

    internal static Task<object?> ExecuteAsync(JsonElement envelope, CancellationToken token)
    {
        if (envelope.ValueKind != JsonValueKind.Object || envelope.EnumerateObject().Any(p => p.Name is not ("type" or "id" or "version" or "request")) ||
            !envelope.TryGetProperty("version", out var version) || version.ValueKind != JsonValueKind.Number || !version.TryGetInt32(out var number) || number != 1 ||
            !envelope.TryGetProperty("request", out var request) || request.ValueKind != JsonValueKind.Object)
            throw new AgentActionException("invalid_proxy_request", "HTTP 代理请求需要版本 1 和请求对象。");
        return HttpProxy.SendAsync(request, token);
    }
    private static Task Send(ClientWebSocket socket, object message, CancellationToken token) =>
        socket.SendAsync(new ArraySegment<byte>(JsonSerializer.SerializeToUtf8Bytes(message, AgentConnection.Json)), WebSocketMessageType.Text, true, token);
    private static async Task<JsonDocument> Receive(ClientWebSocket socket, CancellationToken token)
    {
        using var data = new MemoryStream(); var bytes = new byte[16384];
        while (true)
        {
            var frame = await socket.ReceiveAsync(bytes.AsMemory(), token);
            if (frame.MessageType != WebSocketMessageType.Text || data.Length + frame.Count > 1024 * 1024) throw new IOException("Invalid proxy envelope.");
            data.Write(bytes, 0, frame.Count);
            if (frame.EndOfMessage) return JsonDocument.Parse(data.ToArray());
        }
    }
}
