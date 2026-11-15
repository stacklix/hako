using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Net.Sockets;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Hako.Core;

namespace Hako.Platform;

public sealed record ServiceHttpStatus(string Url, int? StatusCode, long ElapsedMs, string? Failure);
public sealed record RegisteredServiceStatus(string Name, int Port, string? Description, string Status,
    ListenerProcess[] Processes, ServiceHttpStatus? Http, bool CanStart = false, ServiceStartupStatus? Startup = null);
public sealed record RegisteredServiceSnapshot(string CollectedAt, RegisteredServiceStatus[] Services, string[] Warnings);

// Only names, ports and descriptions are copied from the local registry.
// Probe addresses come from the OS listener table, never from arbitrary URLs in JSON.
public sealed partial class RegisteredServices : IDisposable
{
    public const string Command = "query.services.status";
    private const int MaximumRegistryBytes = 256 * 1024;
    private sealed record Registration(string Name, int Port, string? Description, string? StartCommand, string? WorkingDirectory);
    private readonly string registryPath;
    private readonly Func<CancellationToken, Task<ListenerSnapshot>>? readListeners;
    private readonly HttpClient client;
    private readonly TimeSpan timeout;
    private readonly SemaphoreSlim probes = new(8, 8);

    public RegisteredServices(string? registryPath = null,
        Func<CancellationToken, Task<ListenerSnapshot>>? readListeners = null,
        HttpMessageHandler? handler = null, TimeSpan? timeout = null, string? startupDirectory = null)
    {
        this.registryPath = registryPath ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".codex", "server.json");
        this.readListeners = readListeners;
        this.timeout = timeout ?? TimeSpan.FromSeconds(3);
        this.startupDirectory = startupDirectory ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "Hako", "service-starts");
        client = new HttpClient(handler ?? new SocketsHttpHandler
        {
            UseProxy = false, AllowAutoRedirect = false, UseCookies = false,
            Credentials = null, ConnectTimeout = TimeSpan.FromSeconds(2),
            MaxResponseHeadersLength = 16
        }) { Timeout = Timeout.InfiniteTimeSpan };
    }

    public async Task<RegisteredServiceSnapshot> ReadAsync(CancellationToken token)
    {
        var registrations = await ReadRegistryAsync(token);
        if (registrations.Length == 0) return new(DateTimeOffset.UtcNow.ToString("O"), [], []);
        ListenerSnapshot listeners;
        try
        {
            listeners = readListeners is not null ? await readListeners(token)
                : await new NetworkListeners().ReadAsync(token, registrations.Select(service => service.Port).ToHashSet());
        }
        catch (AgentActionException)
        {
            return new(DateTimeOffset.UtcNow.ToString("O"), registrations.Select(service =>
                new RegisteredServiceStatus(service.Name, service.Port, service.Description, "unknown", [], null)).ToArray(),
                ["无法读取本机 TCP 监听信息，暂时无法确认服务状态。"]);
        }
        // A partially unreadable TCP table cannot prove that a service has stopped.
        var incomplete = listeners.Warnings.Any(warning => warning.StartsWith("TCP ", StringComparison.Ordinal));
        var services = await Task.WhenAll(registrations.Select(async service =>
        {
            var processes = listeners.Ports.FirstOrDefault(port => port.Protocol == "TCP" && port.Port == service.Port)?.Processes ?? [];
            if (processes.Length == 0)
                return new RegisteredServiceStatus(service.Name, service.Port, service.Description, incomplete ? "unknown" : "stopped", [], null);
            var addresses = processes.SelectMany(process => process.Addresses).Select(ProbeAddress)
                .Where(address => address is not null).Cast<IPAddress>().Distinct()
                .OrderByDescending(IPAddress.IsLoopback).ThenBy(address => address.AddressFamily == AddressFamily.InterNetwork ? 0 : 1).ToArray();
            if (addresses.Length == 0)
                return new RegisteredServiceStatus(service.Name, service.Port, service.Description, "unknown", processes, null);
            using var budget = CancellationTokenSource.CreateLinkedTokenSource(token);
            budget.CancelAfter(timeout);
            ServiceHttpStatus? http = null;
            foreach (var address in addresses)
            {
                http = await ProbeAsync(new UriBuilder("http", address.ToString(), service.Port, "/").Uri, token, budget.Token);
                if (http.StatusCode is not null || budget.IsCancellationRequested) break;
            }
            var status = http?.StatusCode is int code ? code >= 500 ? "http_error" : "responding" : "unreachable";
            return new RegisteredServiceStatus(service.Name, service.Port, service.Description, status, processes, http);
        }));
        token.ThrowIfCancellationRequested();
        services = services.Select(service =>
        {
            var registration = registrations.First(item => item.Name == service.Name);
            var startup = ReadStartup(service.Name);
            return service with { CanStart = registration.StartCommand is not null && service.Status == "stopped"
                && startup?.State is not ("starting" or "unknown"), Startup = startup };
        }).ToArray();
        var result = new RegisteredServiceSnapshot(DateTimeOffset.UtcNow.ToString("O"), services, listeners.Warnings);
        if (JsonSerializer.SerializeToUtf8Bytes(result, AgentConnection.Json).Length > 48 * 1024)
            throw new AgentActionException("result_too_large", "服务监控数据超出消息大小限制。");
        return result;
    }

    private async Task<Registration[]> ReadRegistryAsync(CancellationToken token)
    {
        try
        {
            await using var file = new FileStream(registryPath, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete,
                4096, FileOptions.Asynchronous | FileOptions.SequentialScan);
            var buffer = new byte[MaximumRegistryBytes + 1];
            var count = 0;
            while (count < buffer.Length)
            {
                var read = await file.ReadAsync(buffer.AsMemory(count), token);
                if (read == 0) break;
                count += read;
            }
            if (count > MaximumRegistryBytes) throw InvalidRegistry();
            // UTF-8 BOM is an encoding marker, not part of the registry JSON.
            var offset = count >= 3 && buffer[0] == 0xef && buffer[1] == 0xbb && buffer[2] == 0xbf ? 3 : 0;
            using var document = JsonDocument.Parse(buffer.AsMemory(offset, count - offset));
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object || !root.TryGetProperty("version", out var version)
                || version.ValueKind != JsonValueKind.Number || !version.TryGetInt32(out var number) || number != 1
                || !root.TryGetProperty("services", out var services) || services.ValueKind != JsonValueKind.Array
                || services.GetArrayLength() > 128) throw InvalidRegistry();
            var names = new HashSet<string>(StringComparer.Ordinal);
            var result = new List<Registration>();
            foreach (var entry in services.EnumerateArray())
            {
                if (entry.ValueKind != JsonValueKind.Object || !entry.TryGetProperty("name", out var nameValue)
                    || nameValue.ValueKind != JsonValueKind.String || nameValue.GetString() is not { } name
                    || string.IsNullOrWhiteSpace(name) || name.Length > 200 || !names.Add(name)
                    || !entry.TryGetProperty("port", out var portValue) || portValue.ValueKind != JsonValueKind.Number
                    || !portValue.TryGetInt32(out var port) || port is < 1 or > 65535) throw InvalidRegistry();
                string? description = null;
                if (entry.TryGetProperty("description", out var detail) && detail.ValueKind != JsonValueKind.Null)
                {
                    if (detail.ValueKind != JsonValueKind.String || detail.GetString() is not { } text || text.Length > 1000)
                        throw InvalidRegistry();
                    description = text;
                }
                string? command = null, directory = null;
                if (entry.TryGetProperty("startCommand", out var startup) && startup.ValueKind != JsonValueKind.Null)
                {
                    if (startup.ValueKind != JsonValueKind.String || startup.GetString() is not { } text
                        || string.IsNullOrWhiteSpace(text) || text.Length > 8192 || text.Contains('\0')) throw InvalidRegistry();
                    command = text;
                }
                if (entry.TryGetProperty("workingDirectory", out var location) && location.ValueKind != JsonValueKind.Null)
                {
                    if (location.ValueKind != JsonValueKind.String || location.GetString() is not { } text
                        || string.IsNullOrWhiteSpace(text) || text.Contains('\0') || !Path.IsPathFullyQualified(text)) throw InvalidRegistry();
                    directory = text;
                }
                result.Add(new(name, port, description, command, directory));
            }
            return result.ToArray();
        }
        catch (FileNotFoundException) { throw new AgentActionException("registry_missing", "设备尚未创建 ~/.codex/server.json 服务登记表。"); }
        catch (DirectoryNotFoundException) { throw new AgentActionException("registry_missing", "设备尚未创建 ~/.codex/server.json 服务登记表。"); }
        catch (JsonException) { throw InvalidRegistry(); }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        { throw new AgentActionException("registry_unavailable", "无法读取设备的服务登记表，请检查文件权限后刷新。"); }
    }

    private static AgentActionException InvalidRegistry() => new("registry_invalid", "server.json 格式无效：需要 version: 1 和 services 数组，服务名称须唯一、端口须在 1–65535 之间（最多 128 项）。");

    private static IPAddress? ProbeAddress(string value)
    {
        if (!IPAddress.TryParse(value, out var address)) return null;
        if (address.Equals(IPAddress.Any)) return IPAddress.Loopback;
        if (address.Equals(IPAddress.IPv6Any)) return IPAddress.IPv6Loopback;
        return address;
    }

    private async Task<ServiceHttpStatus> ProbeAsync(Uri url, CancellationToken caller, CancellationToken budget)
    {
        var watch = Stopwatch.StartNew();
        var entered = false;
        try
        {
            await probes.WaitAsync(budget);
            entered = true;
            using var request = new HttpRequestMessage(HttpMethod.Get, url);
            using var response = await client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, budget);
            return new(url.AbsoluteUri, (int)response.StatusCode, watch.ElapsedMilliseconds, null);
        }
        catch (OperationCanceledException) when (!caller.IsCancellationRequested)
        { return new(url.AbsoluteUri, null, watch.ElapsedMilliseconds, "HTTP 探测超时。"); }
        catch (HttpRequestException)
        { return new(url.AbsoluteUri, null, watch.ElapsedMilliseconds, "未收到有效 HTTP 响应，端口仍在监听。"); }
        finally { if (entered) probes.Release(); }
    }

    public void Dispose() { client.Dispose(); probes.Dispose(); }
}
