using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Net.Http;
using System.Net.WebSockets;
using System.Security.Authentication;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Hako.Core;

namespace Hako.Platform;

internal sealed class WorkshopConnection(IWorkshopDispatcher dispatcher, Action<string> identified, bool commandHost = false, string? profileDirectory = null) : IAsyncDisposable
{
    private readonly WorkshopConnectionLog diagnostics = new(profileDirectory, commandHost);
    private readonly WorkshopDiagnosticReports? reports = profileDirectory is null || commandHost ? null : WorkshopDiagnosticReports.ForProfile(profileDirectory);
    private CancellationTokenSource? lifetime;
    private Task? running;
    internal string State { get; private set; } = "disconnected";
    internal string? ComputerId { get; private set; }

    internal async Task StartAsync(AgentSettings settings)
    {
        await StopAsync();
        settings.Validate();
        dispatcher.SetNotificationScope(NotificationScope(settings));
        lifetime = new CancellationTokenSource();
        running = RunAsync(settings, lifetime.Token);
    }
    internal async Task StopAsync()
    {
        if (lifetime is not null)
        {
            await lifetime.CancelAsync();
            if (running is not null) try { await running; } catch (OperationCanceledException) { }
            lifetime.Dispose(); lifetime = null;
        }
        State = "disconnected";
        dispatcher.SetNotificationScope(null);
    }
    public async ValueTask DisposeAsync() => await StopAsync();

    private async Task RunAsync(AgentSettings settings, CancellationToken token)
    {
        var origin = settings.Origin();
        var uri = new UriBuilder(origin) { Scheme = origin.Scheme == "https" ? "wss" : "ws", Path = commandHost ? "/ws/workshop/command-agent" : "/ws/workshop/agent" }.Uri;
        var attempt = 0;
        Stopwatch? recovery = null;
        while (!token.IsCancellationRequested)
        {
            var id = Guid.NewGuid().ToString("N");
            var elapsed = Stopwatch.StartNew();
            var stage = "compatibility";
            string? registered = null;
            using var socket = new ClientWebSocket();
            attempt++;
            diagnostics.Write(id, "connecting", stage, 0, attempt);
            try
            {
                State = "connecting";
                await ServerCompatibility.WaitAsync(origin,
                    warning => State = warning is null ? "connecting" : "version_mismatch", token);
                stage = "connect";
                using (var authentication = CancellationTokenSource.CreateLinkedTokenSource(token))
                {
                    authentication.CancelAfter(TimeSpan.FromSeconds(10));
                    await socket.ConnectAsync(uri, authentication.Token);
                    stage = "authenticate";
                    using var rsa = RSA.Create(); rsa.ImportFromPem(settings.PrivateKey);
                    var keyId = AgentSettings.KeyId(rsa);
                    var registration = commandHost ? null : await WorkshopRegistration.ReadAsync(profileDirectory, authentication.Token);
                    registered = registration is null ? null : JsonSerializer.Serialize(registration, WorkshopProtocol.Json);
                    await Send(socket, new { kind = "hello", protocol = WorkshopProtocol.Name, account = settings.Username, keyId, registration, diagnostics = reports is not null, cursor = reports?.ServerCursor ?? 0 }, authentication.Token);
                    using var challenge = await Read(socket, authentication.Token);
                    var frame = challenge.RootElement;
                    if (CodexJson.Text(frame, "kind") != "challenge" || CodexJson.Text(frame, "protocol") != WorkshopProtocol.Name)
                        throw new AuthenticationException("代码工坊认证协议不匹配。");
                    var payload = Convert.FromBase64String(frame.GetProperty("payload").GetString()!);
                    var expected = "hako-workshop-auth/v1\n" + origin.GetLeftPart(UriPartial.Authority) + "\n" + settings.Username + "\n" + keyId + "\n";
                    if (!Encoding.UTF8.GetString(payload).StartsWith(expected, StringComparison.Ordinal)) throw new AuthenticationException("代码工坊认证挑战不匹配。");
                    var signature = Convert.ToBase64String(rsa.SignData(payload, HashAlgorithmName.SHA256, RSASignaturePadding.Pss));
                    await Send(socket, new { kind = "proof", signature }, authentication.Token);
                    using var welcome = await Read(socket, authentication.Token);
                    if (CodexJson.Text(welcome.RootElement, "kind") != "welcome" || CodexJson.Text(welcome.RootElement, "protocol") != WorkshopProtocol.Name)
                        throw new AuthenticationException("代码工坊认证失败。");
                    ComputerId = welcome.RootElement.GetProperty("computerId").GetString()!;
                    identified(ComputerId);
                }
                State = "connected";
                stage = "serve";
                diagnostics.Write(id, "connected", stage, elapsed.ElapsedMilliseconds, attempt, recovery?.ElapsedMilliseconds);
                recovery = null;
                attempt = 0;
                await Serve(socket, NotificationScope(settings), token, id, registered);
            }
            catch (OperationCanceledException) when (token.IsCancellationRequested)
            { diagnostics.Write(id, "stopped", stage, elapsed.ElapsedMilliseconds, attempt, closeCode: socket.CloseStatus); break; }
            catch (AuthenticationException error)
            { diagnostics.Write(id, "authentication_failed", stage, elapsed.ElapsedMilliseconds, attempt, error: error, closeCode: socket.CloseStatus); State = "authentication_failed"; return; }
            catch (Exception error) when (error is HttpRequestException or WebSocketException or IOException or OperationCanceledException or JsonException or InvalidOperationException or FormatException or KeyNotFoundException)
            {
                diagnostics.Write(id, "disconnected", stage, elapsed.ElapsedMilliseconds, attempt, error: error, closeCode: socket.CloseStatus);
                recovery ??= Stopwatch.StartNew();
                State = "retrying";
            }
            try { await Task.Delay(TimeSpan.FromSeconds(3), token); } catch (OperationCanceledException) { break; }
        }
    }

    internal static string NotificationScope(AgentSettings settings)
    {
        using var key = RSA.Create(); key.ImportFromPem(settings.PrivateKey);
        return Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(settings.Origin().GetLeftPart(UriPartial.Authority) + "\n" + settings.Username + "\n" + AgentSettings.KeyId(key))));
    }

    private async Task Serve(ClientWebSocket socket, string scope, CancellationToken token, string connectionId, string? registered)
    {
        using var connection = CancellationTokenSource.CreateLinkedTokenSource(token);
        using var writing = new SemaphoreSlim(1, 1);
        var requests = new List<Task>();
        var streams = new Dictionary<string, (CancellationTokenSource Lifetime, Task Worker)>();
        var diagnosticStorageFailed = false;
        async Task Publish(object value)
        {
            using var deadline = CancellationTokenSource.CreateLinkedTokenSource(connection.Token);
            deadline.CancelAfter(TimeSpan.FromSeconds(5));
            await writing.WaitAsync(deadline.Token);
            try { await Send(socket, value, deadline.Token); } finally { writing.Release(); }
        }
        var notifications = Task.Run(async () =>
        {
            try { await dispatcher.WatchTerminalsAsync(scope, item => Publish(new { kind = "terminal", operationId = item.OperationId, questionId = item.QuestionId, result = item }), connection.Token); }
            catch (OperationCanceledException) when (connection.IsCancellationRequested) { }
            catch { connection.Cancel(); socket.Abort(); throw; }
        });
        try
        {
            while (!connection.IsCancellationRequested)
            {
                using var deadline = CancellationTokenSource.CreateLinkedTokenSource(connection.Token);
                deadline.CancelAfter(TimeSpan.FromSeconds(65));
                using var message = await Read(socket, deadline.Token);
                var frame = message.RootElement.Clone();
                var kind = CodexJson.Text(frame, "kind");
                if (kind == "diagnostics" && reports is not null)
                {
                    if (!diagnosticStorageFailed) try { reports.AppendServer(frame.GetProperty("records")); }
                    catch (Exception error) when (error is IOException or UnauthorizedAccessException or JsonException or InvalidOperationException or KeyNotFoundException or WorkshopException)
                    {
                        diagnosticStorageFailed = true; // Preserve the cursor for replay on the next connection.
                        diagnostics.Write(connectionId, "report_store_failed", "diagnostics", 0, 0, error: error);
                    }
                    continue;
                }
                if (kind == "keepalive")
                {
                    await Publish(new { kind = "alive" });
                    if (!commandHost)
                    {
                        var registration = await WorkshopRegistration.ReadAsync(profileDirectory, connection.Token);
                        var value = JsonSerializer.Serialize(registration, WorkshopProtocol.Json);
                        if (value != registered) { await Publish(new { kind = "register", registration }); registered = value; }
                    }
                    continue;
                }
                if (kind == "terminal_ack")
                {
                    var operationId = CodexJson.Text(frame, "operationId");
                    if (!Guid.TryParse(operationId, out var acknowledged)) throw new InvalidDataException("Invalid terminal acknowledgement.");
                    await dispatcher.AcknowledgeTerminalAsync(scope, acknowledged.ToString("D"), CodexJson.Text(frame, "questionId"), connection.Token);
                    continue;
                }
                var id = frame.GetProperty("id").GetString()!;
                if (kind == "unwatch") { if (streams.TryGetValue(id, out var old)) old.Lifetime.Cancel(); continue; }
                if (kind == "watch")
                {
                    foreach (var key in new List<string>(streams.Keys))
                        if (streams[key].Worker.IsCompleted) { streams[key].Lifetime.Dispose(); streams.Remove(key); }
                    if (streams.Count >= 16 || streams.ContainsKey(id))
                    { await Publish(new { kind = "failure", id, error = new WorkshopError("workshop_busy", "代码工坊订阅已满。") }); continue; }
                    var stream = CancellationTokenSource.CreateLinkedTokenSource(connection.Token);
                    var parameters = JsonSerializer.SerializeToElement(new { operationId = frame.GetProperty("operationId").GetString(), cursor = frame.GetProperty("cursor").GetInt64() });
                    streams[id] = (stream, Task.Run(async () =>
                    {
                        try { await dispatcher.WatchAsync(parameters, page => Publish(new { kind = "event", id, result = page }), stream.Token); }
                        catch (OperationCanceledException) when (stream.IsCancellationRequested) { }
                        catch (Exception error) { await Publish(new { kind = "failure", id, error = WorkshopProtocol.Failure(error) }); }
                    }));
                    continue;
                }
                if (kind != "call") throw new InvalidDataException("Invalid workshop frame.");
                requests.RemoveAll(task => task.IsCompleted);
                if (requests.Count >= WorkshopProtocol.RequestLimit)
                { await Publish(new { kind = "failure", id, error = new WorkshopError("workshop_busy", "代码工坊请求已满。") }); continue; }
                requests.Add(Task.Run(async () =>
                {
                    try
                    {
                        var result = await dispatcher.CallAsync(frame.GetProperty("method").GetString()!, frame.GetProperty("params"), connection.Token);
                        await Publish(new { kind = "result", id, result });
                    }
                    catch (OperationCanceledException) when (connection.IsCancellationRequested) { }
                    catch (Exception error) { await Publish(new { kind = "failure", id, error = WorkshopProtocol.Failure(error) }); }
                }));
            }
        }
        finally
        {
            connection.Cancel(); socket.Abort();
            try { await notifications; } catch { }
            try { await Task.WhenAll(requests); } catch { }
            foreach (var stream in streams.Values) { try { await stream.Worker; } catch { } finally { stream.Lifetime.Dispose(); } }
        }
    }
    private static async Task Send(WebSocket socket, object frame, CancellationToken token)
    {
        var bytes = JsonSerializer.SerializeToUtf8Bytes(frame, WorkshopProtocol.Json);
        if (bytes.Length > 64 * 1024) throw new InvalidDataException("Workshop frame too large.");
        await socket.SendAsync(bytes, WebSocketMessageType.Text, true, token);
    }
    private static async Task<JsonDocument> Read(WebSocket socket, CancellationToken token)
    {
        return await WorkshopBinaryFrame.ReadAsync(socket, token);
    }
}
