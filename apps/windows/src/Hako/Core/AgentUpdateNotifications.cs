using System;
using System.IO;
using System.Linq;
using System.Net.Http;
using System.Net.Http.Json;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Hako.Platform;

namespace Hako.Core;

internal static class AgentUpdateNotifications
{
    internal sealed record Notice(string UpdateId, string Stage, string FromVersion, string ToVersion, long OccurredAt, bool Running);
    internal sealed record Receipt(string Scope, Notice Event, string Status = "pending", string? Error = null);
    private static string DirectoryFor(string profile) => AgentGuardianControl.FileFor(profile, "update-notifications");
    internal static string UpdateId(string hash, DateTimeOffset started) =>
        new Guid(SHA256.HashData(Encoding.UTF8.GetBytes(hash + "\n" + started.ToUnixTimeMilliseconds()))[..16]).ToString();
    internal static Notice Create(string id, string stage, string from, string to, bool running) =>
        new(id, stage, from, to, DateTimeOffset.UtcNow.ToUnixTimeMilliseconds(), running);
    private static void Validate(Notice value)
    {
        if (!Guid.TryParseExact(value.UpdateId, "D", out _) || value.Stage is not ("started" or "completed" or "failed") ||
            !Release(value.ToVersion) || value.FromVersion is null || value.FromVersion.Length > 0 && !Release(value.FromVersion) || value.OccurredAt <= 0)
            throw new InvalidDataException("Invalid Agent update notification.");
    }
    private static bool Release(string? value) => value is not null && value.Length <= 40 &&
        System.Text.RegularExpressions.Regex.IsMatch(value, @"\A[0-9]+\.[0-9]+\.[0-9]+\z");

    // Notification failures never stop an otherwise valid installation. Durable
    // pending receipts are retried by the guardian, using the original phase ID.
    internal static async Task<string> RecordAsync(string profile, Notice value, CancellationToken token = default,
        Func<AgentSettings, Notice, CancellationToken, Task<string>>? send = null)
    {
        Validate(value);
        var recorded = false;
        try
        {
            var settings = new AgentSettingsStore(profile).Load();
            var directory = DirectoryFor(profile); Directory.CreateDirectory(directory);
            using (var timeout = CancellationTokenSource.CreateLinkedTokenSource(token))
            {
                timeout.CancelAfter(TimeSpan.FromSeconds(8));
                using var lease = await AgentGuardianRefresh.LockAsync(Path.Combine(directory, "outbox.lock"), timeout.Token);
                var file = Path.Combine(directory, value.UpdateId.ToLowerInvariant() + "-" + value.Stage + ".json");
                if (!File.Exists(file)) AgentGuardianControl.Write(file, new Receipt(CommandHost.Scope(profile, settings), value));
                recorded = true;
            }
            await FlushAsync(profile, send, token);
            var receipt = AgentGuardianControl.Read<Receipt>(Path.Combine(directory, value.UpdateId.ToLowerInvariant() + "-" + value.Stage + ".json"));
            return receipt?.Status ?? "pending";
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or System.Security.Cryptography.CryptographicException or
            HttpRequestException or OperationCanceledException or JsonException or ArgumentException or InvalidOperationException or System.ComponentModel.Win32Exception)
        { return recorded ? "pending" : "failed"; }
    }

    internal static async Task FlushAsync(string profile, Func<AgentSettings, Notice, CancellationToken, Task<string>>? send = null, CancellationToken token = default)
    {
        var directory = DirectoryFor(profile);
        if (!Directory.Exists(directory)) return;
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(token);
        timeout.CancelAfter(TimeSpan.FromSeconds(12));
        using var lease = await AgentGuardianRefresh.LockAsync(Path.Combine(directory, "outbox.lock"), timeout.Token);
        var settings = new AgentSettingsStore(profile).Load();
        var scope = CommandHost.Scope(profile, settings);
        var pending = Directory.EnumerateFiles(directory, "*.json").Select(file => (file, receipt: AgentGuardianControl.Read<Receipt>(file)))
            .Where(item => item.receipt?.Status == "pending")
            .OrderBy(item => item.receipt!.Event.OccurredAt).ThenBy(item => item.receipt!.Event.Stage == "started" ? 0 : 1).Take(64).ToArray();
        foreach (var (file, receipt) in pending)
        {
            token.ThrowIfCancellationRequested();
            var entry = receipt!;
            Validate(entry.Event);
            if (entry.Scope != scope)
            {
                AgentGuardianControl.Write(file, entry with { Status = "suppressed", Error = "Agent identity or server changed." });
                continue;
            }
            try
            {
                var status = await (send is null ? SendAsync(settings, entry.Event, timeout.Token) : send(settings, entry.Event, timeout.Token));
                if (status is not ("queued" or "provider_accepted" or "failed" or "unknown" or "suppressed" or "skipped" or "sending"))
                    throw new InvalidDataException("Invalid notification receipt.");
                AgentGuardianControl.Write(file, entry with { Status = status, Error = null });
            }
            catch (Exception error) when (error is HttpRequestException or OperationCanceledException or JsonException or IOException or CryptographicException or ArgumentException)
            {
                AgentGuardianControl.Write(file, entry with { Error = error.GetType().Name });
                break; // Preserve phase order while the server is unavailable.
            }
        }
    }

    internal static async Task<string> SendAsync(AgentSettings settings, Notice value, CancellationToken token, HttpMessageHandler? handler = null)
    {
        settings.Validate();
        var origin = settings.Origin();
        using var key = RSA.Create(); key.ImportFromPem(settings.PrivateKey);
        var keyId = AgentSettings.KeyId(key);
        var payload = Convert.ToBase64String(JsonSerializer.SerializeToUtf8Bytes(value, AgentConnection.Json));
        var proof = Encoding.UTF8.GetBytes("hako-agent-update/v1\n" + origin.GetLeftPart(UriPartial.Authority) + "\n" + settings.Username + "\n" + keyId + "\n" + payload);
        var signature = Convert.ToBase64String(key.SignData(proof, HashAlgorithmName.SHA256, RSASignaturePadding.Pss));
        using var http = handler is null ? new HttpClient(new HttpClientHandler { AllowAutoRedirect = false }) : new HttpClient(handler, false);
        http.Timeout = TimeSpan.FromSeconds(8); http.MaxResponseContentBufferSize = 8192;
        using var response = await http.PostAsJsonAsync(new Uri(origin, "/api/v1/agents/update-notifications"), new { settings.Username, keyId, payload, signature }, AgentConnection.Json, token);
        response.EnsureSuccessStatusCode();
        using var result = JsonDocument.Parse(await response.Content.ReadAsByteArrayAsync(token));
        if (!result.RootElement.TryGetProperty("status", out var status) || status.ValueKind != JsonValueKind.String)
            throw new InvalidDataException("Missing notification status.");
        return status.GetString()!;
    }

    internal static async Task WatchAsync(string profile, CancellationToken token)
    {
        while (!token.IsCancellationRequested)
        {
            try { await FlushAsync(profile, token: token); }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException or JsonException or CryptographicException or OperationCanceledException or ArgumentException or InvalidOperationException or System.ComponentModel.Win32Exception) { }
            try { await Task.Delay(TimeSpan.FromSeconds(30), token); } catch (OperationCanceledException) { break; }
        }
    }
}
