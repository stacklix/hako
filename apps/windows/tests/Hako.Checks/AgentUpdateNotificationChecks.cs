using System;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Net.Http;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Hako.Core;

internal static class AgentUpdateNotificationChecks
{
    private sealed class Handler(Func<HttpRequestMessage, Task<HttpResponseMessage>> handle) : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token) => handle(request);
    }
    internal static async Task RunAsync()
    {
        var profile = Path.Combine(Path.GetTempPath(), "hako-update-notices-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(profile);
        try
        {
            using var key = RSA.Create(2048);
            var settings = new AgentSettings("https://fixture.example", "owner", key.ExportPkcs8PrivateKeyPem());
            var store = new AgentSettingsStore(profile); store.Save(settings);
            var id = Guid.NewGuid().ToString();
            var started = AgentUpdateNotifications.Create(id, "started", "1.4.3", "1.4.4", false);
            using var handler = new Handler(async request =>
            {
                if (request.RequestUri?.AbsolutePath != "/api/v1/agents/update-notifications") throw new Exception("Wrong update endpoint");
                var body = await request.Content!.ReadAsStringAsync();
                if (body.Contains("PRIVATE KEY", StringComparison.Ordinal)) throw new Exception("Private key sent in notification");
                using var document = JsonDocument.Parse(body); var root = document.RootElement;
                var payload = root.GetProperty("payload").GetString()!;
                var proof = Encoding.UTF8.GetBytes("hako-agent-update/v1\nhttps://fixture.example\nowner\n" + AgentSettings.KeyId(key) + "\n" + payload);
                if (!key.VerifyData(proof, Convert.FromBase64String(root.GetProperty("signature").GetString()!), HashAlgorithmName.SHA256, RSASignaturePadding.Pss))
                    throw new Exception("Upgrade notice signature mismatch");
                using var notice = JsonDocument.Parse(Convert.FromBase64String(payload));
                if (notice.RootElement.GetProperty("stage").GetString() != "started") throw new Exception("Signed notice changed");
                return new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent("{\"status\":\"queued\"}") };
            });
            if (await AgentUpdateNotifications.SendAsync(settings, started, default, handler) != "queued") throw new Exception("Lost queue status");
            static Task<string> Offline(AgentSettings _, AgentUpdateNotifications.Notice __, CancellationToken ___) => throw new HttpRequestException("fixture offline");
            if (await AgentUpdateNotifications.RecordAsync(profile, started, send: Offline) != "pending") throw new Exception("Offline receipt lost");
            var completed = started with { Stage = "completed", Running = true };
            await AgentUpdateNotifications.RecordAsync(profile, completed, send: Offline);
            var sent = new List<string>();
            Task<string> Send(AgentSettings _, AgentUpdateNotifications.Notice notice, CancellationToken __) { sent.Add(notice.Stage); return Task.FromResult("queued"); }
            await AgentUpdateNotifications.FlushAsync(profile, Send);
            await AgentUpdateNotifications.FlushAsync(profile, Send);
            await AgentUpdateNotifications.RecordAsync(profile, completed, send: Send);
            if (string.Join(",", sent) != "started,completed") throw new Exception("Phases reordered or acknowledged notice resent");
            var failed = started with { Stage = "failed" };
            await AgentUpdateNotifications.RecordAsync(profile, failed, send: Offline);
            store.Save(settings with { Username = "other" });
            await AgentUpdateNotifications.FlushAsync(profile, Send);
            if (sent.Count != 2) throw new Exception("Old identity sent an upgrade notice to a new account");
            var receipt = AgentGuardianControl.Read<AgentUpdateNotifications.Receipt>(AgentGuardianControl.FileFor(profile, "update-notifications/" + id + "-failed.json"));
            if (receipt?.Status != "suppressed") throw new Exception("Identity change did not suppress old receipt");
            store.Save(settings);
            var uncertain = started with { UpdateId = Guid.NewGuid().ToString() };
            var attempts = 0;
            Task<string> Unknown(AgentSettings _, AgentUpdateNotifications.Notice __, CancellationToken ___) { attempts++; return Task.FromResult("unknown"); }
            await AgentUpdateNotifications.RecordAsync(profile, uncertain, send: Unknown);
            await AgentUpdateNotifications.FlushAsync(profile, Unknown);
            if (attempts != 1) throw new Exception("An uncertain APNs delivery was retried");
            var blocked = Path.Combine(profile, "blocked-profile");
            await File.WriteAllTextAsync(blocked, "fixture");
            if (await AgentUpdateNotifications.RecordAsync(blocked, started, send: Send) != "failed")
                throw new Exception("A failed local write must not claim a durable pending notification");
            Console.WriteLine("PASS: signed upgrade phases, durable offline recovery, phase ordering, duplicate suppression, account isolation and unknown outcome without resend");
        }
        finally { Directory.Delete(profile, true); }
    }
}
