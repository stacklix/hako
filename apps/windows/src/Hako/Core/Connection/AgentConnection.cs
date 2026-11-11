using System;
using System.IO;
using System.Collections.Generic;
using System.Net.Http;
using System.Net.WebSockets;
using System.Security.Authentication;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Hako.Platform;

namespace Hako.Core;

public sealed class AgentConnection : IAsyncDisposable
{
    private const int ProtocolVersion = 4;
    public sealed record ConnectionState(string State, string Message, string? AgentId = null);
    private volatile ConnectionState status = new("disconnected", "未连接");
    public ConnectionState Status => status;
    public event Action<string>? StatusChanged;
    public event Action<string>? VersionWarning;
    public event Action<Metrics>? MetricsReceived;
    private readonly AgentDispatcher dispatcher;
    private readonly SemaphoreSlim writing = new(1, 1);
    private CancellationTokenSource? lifetime;
    private Task? running;
    public static readonly JsonSerializerOptions Json = new() { PropertyNamingPolicy = JsonNamingPolicy.CamelCase };
    public AgentConnection(SystemMetrics metrics, CodexUsage? codexUsage = null, string? dataDirectory = null)
    {
        dispatcher = new AgentDispatcher(metrics, codexUsage: codexUsage, dataDirectory: dataDirectory);
        dispatcher.MetricsReceived += value => MetricsReceived?.Invoke(value);
    }

    public async Task StartAsync(AgentSettings settings)
    {
        await StopAsync();
        settings.Validate();
        lifetime = new CancellationTokenSource();
        running = RunAsync(settings, lifetime.Token);
    }
    public async Task StopAsync()
    {
        if (lifetime is null) { SetStatus("disconnected", "未连接"); return; }
        await lifetime.CancelAsync();
        if (running is not null) { try { await running; } catch (OperationCanceledException) { } }
        lifetime.Dispose(); lifetime = null;
        SetStatus("disconnected", "未连接");
    }
    public async ValueTask DisposeAsync()
    {
        await StopAsync();
        await dispatcher.DisposeAsync();
    }
    private void SetStatus(string state, string message, string? agentId = null)
    {
        status = new ConnectionState(state, message, agentId);
        StatusChanged?.Invoke(message);
    }

    private async Task RunAsync(AgentSettings settings, CancellationToken token)
    {
        var origin = settings.Origin();
        var uri = new UriBuilder(origin) { Scheme = origin.Scheme == "https" ? "wss" : "ws", Path = "/ws/agent" }.Uri;
        string? lastVersionWarning = null;
        var attempt = 0;
        while (!token.IsCancellationRequested)
        {
            try
            {
                SetStatus("connecting", "正在连接…");
                // A version check is advisory. Keep attempting the WebSocket if the probe is unavailable.
                try
                {
                    var warning = await ServerCompatibility.CheckAsync(origin, token);
                    token.ThrowIfCancellationRequested();
                    if (warning is not null && warning != lastVersionWarning) VersionWarning?.Invoke(warning);
                    lastVersionWarning = warning;
                }
                catch (HttpRequestException) { }
                catch (OperationCanceledException) when (!token.IsCancellationRequested) { }
                using var socket = new ClientWebSocket();
                using (var authTimeout = CancellationTokenSource.CreateLinkedTokenSource(token))
                {
                    authTimeout.CancelAfter(TimeSpan.FromSeconds(10));
                    await socket.ConnectAsync(uri, authTimeout.Token);
                    SetStatus("authenticating", "正在验证身份…");
                    using var rsa = RSA.Create(); rsa.ImportFromPem(settings.PrivateKey);
                    var keyId = AgentSettings.KeyId(rsa);
                    await SendAsync(socket, new { type = "hello", version = ProtocolVersion, username = settings.Username, keyId, capabilities = dispatcher.Capabilities, sshTunnel = true }, authTimeout.Token);
                    using var challenge = await ReceiveAsync(socket, authTimeout.Token);
                    if (challenge.RootElement.GetProperty("type").GetString() != "challenge") throw new AuthenticationException("服务端未提供认证挑战。");
                    var payload = Convert.FromBase64String(challenge.RootElement.GetProperty("payload").GetString()!);
                    var expected = $"hako-agent-auth/v{ProtocolVersion}\n" + origin.GetLeftPart(UriPartial.Authority) + "\n" + settings.Username + "\n" + keyId + "\n";
                    if (!Encoding.UTF8.GetString(payload).StartsWith(expected, StringComparison.Ordinal)) throw new AuthenticationException("服务端认证挑战不匹配。");
                    var signature = Convert.ToBase64String(rsa.SignData(payload, HashAlgorithmName.SHA256, RSASignaturePadding.Pss));
                    await SendAsync(socket, new { type = "authenticate", signature }, authTimeout.Token);
                    using var ack = await ReceiveAsync(socket, authTimeout.Token);
                    if (ack.RootElement.GetProperty("type").GetString() != "authenticated") throw new AuthenticationException("认证失败。");
                    SetStatus("connected", "已连接 · 身份验证通过", ack.RootElement.GetProperty("agentId").GetString());
                }
                attempt = 0;
                using var connection = CancellationTokenSource.CreateLinkedTokenSource(token);
                var workers = new List<Task>();
                var workshopStreams = new Dictionary<string, (CancellationTokenSource Lifetime, Task Worker)>();
                CancellationTokenSource? telemetry = null;
                Task? telemetryWorker = null;
                string? telemetryId = null;
                AgentSshTunnel? ssh = null;

                async Task StopTelemetryAsync()
                {
                    if (telemetry is null) return;
                    await telemetry.CancelAsync();
                    if (telemetryWorker is not null) await telemetryWorker;
                    telemetry.Dispose();
                    telemetry = null;
                    telemetryWorker = null;
                    telemetryId = null;
                }

                try
                {
                    while (!connection.IsCancellationRequested)
                    {
                        using var receiveTimeout = CancellationTokenSource.CreateLinkedTokenSource(connection.Token);
                        receiveTimeout.CancelAfter(TimeSpan.FromSeconds(65));
                        using var message = await ReceiveAsync(socket, receiveTimeout.Token);
                        var root = message.RootElement;
                        switch (root.GetProperty("type").GetString())
                        {
                            case "ping": await SendAsync(socket, new { type = "pong" }, token); break;
                            case "request":
                                workers.RemoveAll(task => task.IsCompleted);
                                var request = root.Clone();
                                if (workers.Count >= 4)
                                    await SendAsync(socket, new { type = "response", id = request.GetProperty("id").GetString(), error = new { code = "agent_busy", message = "设备繁忙，请稍后重试。" } }, connection.Token);
                                else
                                    workers.Add(Task.Run(() => ExecuteRequestAsync(socket, request, connection.Token), connection.Token));
                                break;
                            case "telemetry_start":
                                await StopTelemetryAsync();
                                var id = root.GetProperty("id").GetString()!;
                                telemetryId = id;
                                telemetry = CancellationTokenSource.CreateLinkedTokenSource(connection.Token);
                                var telemetryToken = telemetry.Token;
                                telemetryWorker = Task.Run(() => RunTelemetryAsync(socket, id, telemetryToken, connection.Token));
                                break;
                            case "telemetry_stop":
                                if (root.GetProperty("id").GetString() == telemetryId) await StopTelemetryAsync();
                                break;
                            case "workshop_start":
                                var streamId = root.GetProperty("id").GetString()!;
                                foreach (var finished in new List<string>(workshopStreams.Keys))
                                    if (workshopStreams[finished].Worker.IsCompleted)
                                    { workshopStreams[finished].Lifetime.Dispose(); workshopStreams.Remove(finished); }
                                if (workshopStreams.ContainsKey(streamId) || workshopStreams.Count >= 16)
                                {
                                    await SendAsync(socket, new { type = "workshop_update", id = streamId,
                                        error = new CapabilityError("agent_busy", "实时订阅数量已满。") }, connection.Token);
                                    break;
                                }
                                var streamLifetime = CancellationTokenSource.CreateLinkedTokenSource(connection.Token);
                                var streamParameters = root.GetProperty("params").Clone();
                                workshopStreams.Add(streamId, (streamLifetime,
                                    Task.Run(() => RunWorkshopAsync(socket, streamId, streamParameters, streamLifetime.Token))));
                                break;
                            case "workshop_stop":
                                if (workshopStreams.TryGetValue(root.GetProperty("id").GetString()!, out var stream))
                                    stream.Lifetime.Cancel();
                                break;
                            case "ssh_open":
                                if (ssh is not null) await ssh.DisposeAsync();
                                ssh = new AgentSshTunnel(root.GetProperty("id").GetString()!,
                                    (frame, cancellation) => SendAsync(socket, frame, cancellation), connection.Token);
                                break;
                            case "ssh_data":
                                if (ssh is not null && root.GetProperty("id").GetString() == ssh.Id &&
                                    !ssh.TryWrite(root.GetProperty("data").GetBytesFromBase64()))
                                {
                                    var closedID = ssh.Id;
                                    await ssh.DisposeAsync();
                                    ssh = null;
                                    await SendAsync(socket, new { type = "ssh_closed", id = closedID }, connection.Token);
                                }
                                break;
                            case "ssh_close":
                                if (ssh is not null && root.GetProperty("id").GetString() == ssh.Id)
                                {
                                    await ssh.DisposeAsync();
                                    ssh = null;
                                }
                                break;
                            default: throw new InvalidDataException("未知的服务端消息。");
                        }
                    }
                }
                finally
                {
                    await connection.CancelAsync();
                    foreach (var stream in workshopStreams.Values)
                    { try { await stream.Worker; } finally { stream.Lifetime.Dispose(); } }
                    if (ssh is not null) await ssh.DisposeAsync();
                    await StopTelemetryAsync();
                    try { await Task.WhenAll(workers); } catch (OperationCanceledException) { }
                }
            }
            catch (AuthenticationException)
            { SetStatus("authentication_failed", "身份验证失败，请检查账号、公钥配置和私钥后重新连接。"); return; }
            catch (OperationCanceledException) when (token.IsCancellationRequested) { return; }
            catch (Exception e) when (e is WebSocketException or IOException or OperationCanceledException or JsonException or InvalidOperationException or FormatException or KeyNotFoundException)
            { SetStatus("retrying", "连接中断，等待重连…"); }
            attempt = Math.Min(attempt + 1, 5);
            try { await Task.Delay(TimeSpan.FromSeconds(Math.Min(30, Math.Pow(2, attempt)) + Random.Shared.NextDouble()), token); }
            catch (OperationCanceledException) { return; }
        }
    }

    private async Task RunTelemetryAsync(ClientWebSocket socket, string id, CancellationToken token, CancellationToken connection)
    {
        try
        {
            await dispatcher.RunTelemetryAsync(async (method, item) =>
            {
                token.ThrowIfCancellationRequested();
                object message = item.Error is { } error
                    ? new { type = "telemetry_update", id, method, version = item.Version, error }
                    : new { type = "telemetry_update", id, method, version = item.Version, result = item.Result };
                var payload = JsonSerializer.SerializeToUtf8Bytes(message, Json);
                if (payload.Length > 64 * 1024)
                    payload = JsonSerializer.SerializeToUtf8Bytes(new
                    {
                        type = "telemetry_update", id, method, version = item.Version,
                        error = new CapabilityError("result_too_large", "数据超出消息大小限制。")
                    }, Json);
                await SendPayloadAsync(socket, payload, connection);
            }, token);
        }
        catch (OperationCanceledException) when (token.IsCancellationRequested) { }
        catch { socket.Abort(); }
    }

    private async Task RunWorkshopAsync(ClientWebSocket socket, string id, JsonElement parameters, CancellationToken token)
    {
        try
        {
            await dispatcher.WatchWorkshopAsync(parameters,
                page => SendAsync(socket, new { type = "workshop_update", id, result = page }, token), token);
        }
        catch (OperationCanceledException) when (token.IsCancellationRequested) { }
        catch (Exception e)
        {
            try
            {
                var error = e is AgentActionException action ? new CapabilityError(action.Code, action.Message)
                    : new CapabilityError("stream_failed", "实时订阅中断，请重新连接。");
                await SendAsync(socket, new { type = "workshop_update", id, error }, token);
            }
            catch { socket.Abort(); }
        }
    }

    private async Task ExecuteRequestAsync(ClientWebSocket socket, JsonElement request, CancellationToken token)
    {
        try
        {
            var id = request.GetProperty("id").GetString()!;
            object response;
            try
            {
                var result = await dispatcher.InvokeAsync(request.GetProperty("method").GetString()!,
                    request.GetProperty("version").GetInt32(), request.GetProperty("params"), token);
                response = new { type = "response", id, result };
            }
            catch (AgentActionException e)
            { response = new { type = "response", id, error = new { code = e.Code, message = e.Message } }; }
            catch (Exception e) when (e is not OperationCanceledException)
            { response = new { type = "response", id, error = new { code = "execution_failed", message = "设备执行失败。" } }; }
            await SendAsync(socket, response, token);
        }
        catch (OperationCanceledException) when (token.IsCancellationRequested) { }
        catch { socket.Abort(); }
    }

    private Task SendAsync(ClientWebSocket socket, object value, CancellationToken token) =>
        SendPayloadAsync(socket, JsonSerializer.SerializeToUtf8Bytes(value, Json), token);

    private async Task SendPayloadAsync(ClientWebSocket socket, byte[] payload, CancellationToken token)
    {
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(token);
        deadline.CancelAfter(TimeSpan.FromSeconds(5));
        await writing.WaitAsync(deadline.Token);
        try { await socket.SendAsync(payload, WebSocketMessageType.Text, true, deadline.Token); }
        finally { writing.Release(); }
    }
    private static async Task<JsonDocument> ReceiveAsync(ClientWebSocket socket, CancellationToken token)
    {
        using var stream = new MemoryStream();
        var buffer = new byte[4096];
        while (true)
        {
            var read = await socket.ReceiveAsync(new ArraySegment<byte>(buffer), token);
            if (read.MessageType == WebSocketMessageType.Close)
            {
                if (read.CloseStatus == WebSocketCloseStatus.PolicyViolation) throw new AuthenticationException("服务端拒绝设备身份。");
                throw new IOException("连接已关闭。");
            }
            if (read.MessageType != WebSocketMessageType.Text || stream.Length + read.Count > 65536) throw new IOException("消息格式或长度无效。");
            stream.Write(buffer, 0, read.Count);
            if (read.EndOfMessage) return JsonDocument.Parse(stream.ToArray());
        }
    }
}
