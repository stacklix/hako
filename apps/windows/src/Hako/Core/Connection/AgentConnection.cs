using System;
using System.IO;
using System.Collections.Generic;
using System.Linq;
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
    public string? CompatibilityWarning { get; private set; }
    public event Action<Metrics>? MetricsReceived;
    private readonly IAgentDispatcher dispatcher;
    private readonly SemaphoreSlim writing = new(1, 1);
    private CancellationTokenSource? lifetime;
    private Task? running;
    private Task? proxyRunning;
    private volatile bool proxyOnline;
    private readonly SemaphoreSlim moduleGate = new(1, 1);
    private readonly Func<CancellationToken, Task>? openWorkshop;
    public static readonly JsonSerializerOptions Json = new() { PropertyNamingPolicy = JsonNamingPolicy.CamelCase };
    public AgentConnection(SystemMetrics metrics, CodexUsage? codexUsage = null, string? dataDirectory = null)
    {
        var local = new AgentDispatcher(metrics, codexUsage: codexUsage, dataDirectory: dataDirectory);
        local.MetricsReceived += value => MetricsReceived?.Invoke(value);
        dispatcher = local;
    }
    internal AgentConnection(IAgentDispatcher dispatcher, Func<CancellationToken, Task>? openWorkshop = null)
    { this.dispatcher = dispatcher; this.openWorkshop = openWorkshop; }

    public async Task StartAsync(AgentSettings settings)
    {
        await StopAsync();
        settings.Validate();
        lifetime = new CancellationTokenSource();
        running = RunAsync(settings, lifetime.Token);
    }
    public async Task StopAsync()
    {
        if (lifetime is null) { CompatibilityWarning = null; SetStatus("disconnected", "未连接"); return; }
        await lifetime.CancelAsync();
        if (running is not null) { try { await running; } catch (OperationCanceledException) { } }
        if (proxyRunning is not null) { try { await proxyRunning; } catch (OperationCanceledException) { } proxyRunning = null; }
        proxyOnline = false;
        lifetime.Dispose(); lifetime = null;
        CompatibilityWarning = null;
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
        var attempt = 0;
        while (!token.IsCancellationRequested)
        {
            try
            {
                SetStatus("connecting", "正在连接…");
                await ServerCompatibility.WaitAsync(origin, warning =>
                {
                    CompatibilityWarning = warning;
                    SetStatus(warning is null ? "connecting" : "version_mismatch",
                        warning is null ? "版本检查通过，正在连接…" : warning + "\n每 30 秒自动检查，版本兼容后自动连接。");
                }, token);
                using var socket = new ClientWebSocket();
                using (var authTimeout = CancellationTokenSource.CreateLinkedTokenSource(token))
                {
                    authTimeout.CancelAfter(TimeSpan.FromSeconds(10));
                    await socket.ConnectAsync(uri, authTimeout.Token);
                    SetStatus("authenticating", "正在验证身份…");
                    using var rsa = RSA.Create(); rsa.ImportFromPem(settings.PrivateKey);
                    var keyId = AgentSettings.KeyId(rsa);
                    var registration = WorkshopRegistration.Snapshot(settings.DirectPort);
                    var modules = new { workshop = openWorkshop is null ? null : new { version = 1, lan = new { addresses = registration.Addresses, port = registration.Port } }, proxy = new { version = 1 } };
                    await SendAsync(socket, new { type = "hello", version = ProtocolVersion, username = settings.Username, keyId, capabilities = dispatcher.Capabilities, modules, sshTunnel = true }, authTimeout.Token);
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
                var requestSlots = new AgentRequestSlots();
                using var moduleSlots = new SemaphoreSlim(4, 4);
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
                                var slot = requestSlots.TryAcquire();
                                if (slot is null)
                                    await SendAsync(socket, new { type = "response", id = request.GetProperty("id").GetString(), error = new { code = "agent_busy", message = "设备繁忙，请稍后重试。" } }, connection.Token);
                                else
                                    workers.Add(Task.Run(async () =>
                                    {
                                        using (slot) await ExecuteRequestAsync(socket, request, connection.Token);
                                    }));
                                break;
                            case "module_open":
                                workers.RemoveAll(task => task.IsCompleted);
                                var opening = root.Clone();
                                if (!await moduleSlots.WaitAsync(0, connection.Token))
                                    await SendAsync(socket, new { type = "module_response", id = root.GetProperty("id").GetString(), error = new { code = "module_busy", message = "模块正在打开，请稍后重试。" } }, connection.Token);
                                else workers.Add(Task.Run(async () => {
                                    try { await OpenModuleAsync(socket, opening, settings, connection.Token); }
                                    finally { moduleSlots.Release(); }
                                }));
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
                    if (ssh is not null) await ssh.DisposeAsync();
                    await StopTelemetryAsync();
                    try { await Task.WhenAll(workers); } catch (OperationCanceledException) { }
                }
            }
            catch (AuthenticationException)
            { SetStatus("authentication_failed", "身份验证失败，请检查账号、公钥配置和私钥后重新连接。"); return; }
            catch (OperationCanceledException) when (token.IsCancellationRequested) { return; }
            catch (Exception e) when (e is HttpRequestException or WebSocketException or IOException or OperationCanceledException or JsonException or InvalidOperationException or FormatException or KeyNotFoundException)
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

    private async Task ExecuteRequestAsync(ClientWebSocket socket, JsonElement request, CancellationToken token)
    {
        try
        {
            var id = request.GetProperty("id").GetString()!;
            object response;
            try
            {
                var (method, version, parameters) = ReadRequest(request);
                var result = await dispatcher.InvokeAsync(method, version, parameters, token);
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

    private async Task OpenModuleAsync(ClientWebSocket socket, JsonElement request, AgentSettings settings, CancellationToken token)
    {
        var id = request.GetProperty("id").GetString();
        object response;
        try
        {
            if (request.EnumerateObject().Any(p => p.Name is not ("type" or "id" or "module" or "version")) ||
                !request.TryGetProperty("version", out var version) || version.ValueKind != JsonValueKind.Number || !version.TryGetInt32(out var v) || v != 1 ||
                !request.TryGetProperty("module", out var name) || name.ValueKind != JsonValueKind.String)
                throw new AgentActionException("invalid_module_request", "模块打开请求无效。");
            var module = name.GetString();
            using var deadline = CancellationTokenSource.CreateLinkedTokenSource(token);
            deadline.CancelAfter(TimeSpan.FromSeconds(8));
            if (module == "proxy")
            {
                await moduleGate.WaitAsync(deadline.Token);
                try {
                    if (proxyRunning is null || proxyRunning.IsCompleted)
                        proxyRunning = HttpProxyConnection.RunAsync(settings, lifetime!.Token, online => proxyOnline = online);
                } finally { moduleGate.Release(); }
                while (!proxyOnline) await Task.Delay(50, deadline.Token);
            }
            else if (module == "workshop" && openWorkshop is not null) await openWorkshop(deadline.Token);
            else throw new AgentActionException("unsupported_module", "设备不支持此模块或版本。");
            token.ThrowIfCancellationRequested();
            var path = module == "proxy" ? "/ws/proxy/client/" + Status.AgentId : "/ws/workshop/client";
            response = new { type = "module_response", id, result = new { module, version = 1, path } };
        }
        catch (AgentActionException e) { response = new { type = "module_response", id, error = new { code = e.Code, message = e.Message } }; }
        catch (OperationCanceledException) when (!token.IsCancellationRequested) { response = new { type = "module_response", id, error = new { code = "module_timeout", message = "模块连接未就绪，请稍后重试。" } }; }
        catch (Exception e) when (e is not OperationCanceledException) { response = new { type = "module_response", id, error = new { code = "module_failed", message = "模块连接失败，请检查设备状态。" } }; }
        await SendAsync(socket, response, token);
    }

    internal static (string Method, int Version, JsonElement Parameters) ReadRequest(JsonElement request)
    {
        if (!request.TryGetProperty("method", out var method) || method.ValueKind != JsonValueKind.String || string.IsNullOrEmpty(method.GetString())
            || !request.TryGetProperty("version", out var version) || version.ValueKind != JsonValueKind.Number || !version.TryGetInt32(out var number) || number < 1
            || !request.TryGetProperty("params", out var parameters) || parameters.ValueKind != JsonValueKind.Object)
            throw new AgentActionException("invalid_request", "命令需要名称、正整数版本及对象参数。");
        foreach (var field in request.EnumerateObject())
            if (field.Name is not ("type" or "id" or "method" or "version" or "params"))
                throw new AgentActionException("invalid_request", "命令包含不支持的字段。");
        return (method.GetString()!, number, parameters);
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
            if (read.MessageType != WebSocketMessageType.Text || stream.Length + read.Count > 1024 * 1024) throw new IOException("消息格式或长度无效。");
            stream.Write(buffer, 0, read.Count);
            if (read.EndOfMessage) return JsonDocument.Parse(stream.ToArray());
        }
    }
}
