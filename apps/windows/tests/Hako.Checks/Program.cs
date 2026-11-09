using System;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Hako.Core;
using Hako.Platform;

internal static class Program
{
    private static void CheckServerCompatibility()
    {
        if (ServerCompatibility.WarningFor("""{"serverVersion":"0.1.0","minimumAgentVersion":"1.0.0"}"""u8, "1.0.0") is not null)
            throw new Exception("Agent rejected matching version floors");
        if (ServerCompatibility.WarningFor("""{"serverVersion":"0.1.10","minimumAgentVersion":"1.0.9"}"""u8, "1.0.10") is not null)
            throw new Exception("Agent did not compare compatible patch versions numerically");
        if (ServerCompatibility.WarningFor("""{"serverVersion":"0.1.0","minimumAgentVersion":"1.0.2"}"""u8, "1.0.1")?.EndsWith("请升级 Hako Agent。", StringComparison.Ordinal) != true)
            throw new Exception("Agent accepted a patch version below the required floor");
        var outdatedAgent = ServerCompatibility.WarningFor("""{"serverVersion":"0.1.0","minimumAgentVersion":"1.1.0"}"""u8, "1.0.0");
        if (outdatedAgent?.EndsWith("请升级 Hako Agent。", StringComparison.Ordinal) != true)
            throw new Exception("Agent did not warn about its own version floor");
        var outdatedServer = ServerCompatibility.WarningFor("""{"serverVersion":"0.0.9","minimumAgentVersion":"1.0.0"}"""u8, "1.0.0");
        if (outdatedServer?.EndsWith("请升级 服务端。", StringComparison.Ordinal) != true)
            throw new Exception("Agent did not warn about the server version floor");
        var newerAgent = ServerCompatibility.WarningFor("""{"serverVersion":"0.1.0","minimumAgentVersion":"1.9.0"}"""u8, "1.10.0");
        if (newerAgent?.EndsWith("请升级 服务端。", StringComparison.Ordinal) != true)
            throw new Exception("Agent accepted a newer minor version than the server supports");
        var newerServer = ServerCompatibility.WarningFor("""{"serverVersion":"0.2.0","minimumAgentVersion":"1.0.0"}"""u8, "1.0.0");
        if (newerServer?.EndsWith("请升级 Hako Agent。", StringComparison.Ordinal) != true)
            throw new Exception("Agent accepted a newer server minor version");
        var both = ServerCompatibility.WarningFor("""{"serverVersion":"0.0.9","minimumAgentVersion":"1.1.0"}"""u8, "1.0.0");
        if (both != outdatedAgent + "\n\n" + outdatedServer)
            throw new Exception("Agent did not report both incompatible versions together");
        if (ServerCompatibility.WarningFor("""{"serverVersion":"0.1.0"}"""u8, "1.0.0")?.Contains("版本信息无效") != true)
            throw new Exception("Agent accepted incomplete version metadata");
    }

    private static async Task<int> Main(string[] args)
    {
        try
        {
            if (args.Length > 0 && Path.GetFileName(args[0]) == "hako-launch-fixture.py")
            {
                Console.WriteLine("ready");
                await Task.Delay(TimeSpan.FromSeconds(30));
                return 0;
            }
            if (args.Length == 1 && args[0] == "network-listeners")
            {
                Console.WriteLine(JsonSerializer.Serialize(await new NetworkListeners().ReadAsync(CancellationToken.None), AgentConnection.Json));
                return 0;
            }
            if (args.Length == 1 && args[0] == "git-repositories")
            {
                await GitRepositoryChecks.RunAsync();
                return 0;
            }
            if (args.Length == 3 && args[0] == "codex-usage")
            {
                await using var usage = new CodexUsage(args[1], args[2]);
                Console.WriteLine(JsonSerializer.Serialize(await usage.CollectAsync(CancellationToken.None), AgentConnection.Json));
                return 0;
            }
            if (args.Length == 4 && args[0] == "agent")
            {
                await using var agent = new AgentConnection(new SystemMetrics());
                agent.StatusChanged += text => Console.WriteLine(text);
                await agent.StartAsync(new AgentSettings(args[1], args[2], File.ReadAllText(args[3])));
                await Task.Delay(TimeSpan.FromSeconds(30));
                return 0;
            }
            CheckServerCompatibility();
            StartupChecks.Run();
            NetworkTrafficChecks.Run();
            await NetworkListenerChecks.RunAsync();
            await PythonProcessLaunchChecks.RunAsync();
            byte[] secret = RandomNumberGenerator.GetBytes(64);
            var encrypted = DataProtection.Protect(secret);
            if (CryptographicOperations.FixedTimeEquals(secret, encrypted) || !CryptographicOperations.FixedTimeEquals(secret, DataProtection.Unprotect(encrypted)))
                throw new Exception("DPAPI roundtrip failed");
            encrypted[encrypted.Length / 2] ^= 1;
            bool rejected = false;
            try { DataProtection.Unprotect(encrypted); } catch { rejected = true; }
            if (!rejected) throw new Exception("Tampered DPAPI data accepted");
            using var rsa = RSA.Create(2048);
            var data = RandomNumberGenerator.GetBytes(32);
            var signature = rsa.SignData(data, HashAlgorithmName.SHA256, RSASignaturePadding.Pss);
            if (!rsa.VerifyData(data, signature, HashAlgorithmName.SHA256, RSASignaturePadding.Pss)) throw new Exception("RSA signing failed");
            var generated = AgentKeys.GeneratePrivateKey();
            using var generatedPrivate = RSA.Create(); generatedPrivate.ImportFromPem(generated);
            if (generatedPrivate.KeySize != 3072) throw new Exception("Generated RSA key size is incorrect");
            var publicPem = AgentKeys.ExportPublicKey(generated);
            if (publicPem.Contains("PRIVATE KEY", StringComparison.Ordinal)) throw new Exception("Public export contains a private key");
            using var exportedPublic = RSA.Create(); exportedPublic.ImportFromPem(publicPem);
            var generatedSignature = generatedPrivate.SignData(data, HashAlgorithmName.SHA256, RSASignaturePadding.Pss);
            if (!exportedPublic.VerifyData(data, generatedSignature, HashAlgorithmName.SHA256, RSASignaturePadding.Pss)) throw new Exception("Exported public key does not match generated private key");
            using var imported = RSA.Create(); imported.ImportFromPem(AgentKeys.NormalizePrivateKey(generatedPrivate.ExportRSAPrivateKeyPem()));
            if (AgentSettings.KeyId(imported) != AgentSettings.KeyId(exportedPublic)) throw new Exception("Private import changed public key identity");
            var settings = new AgentSettings("https://example.com", "owner", rsa.ExportPkcs8PrivateKeyPem());
            settings.Validate();
            try { (settings with { Url = "http://example.com" }).Validate(); throw new Exception("Insecure public URL accepted"); }
            catch (ArgumentException) { }
            var dispatcher = new AgentDispatcher(new SystemMetrics());
            if (!dispatcher.Capabilities.SequenceEqual(new[] {
                new AgentCapability("query.system.metrics", 1), new AgentCapability("query.codex.usage", 1),
                new AgentCapability("query.network.listeners", 1), new AgentCapability("action.network.http.check", 1),
                new AgentCapability("action.git.commit", 1), new AgentCapability("action.git.push", 1),
                new AgentCapability("action.git.pull", 1),
                new AgentCapability("query.git.repositories", 1), new AgentCapability("query.git.repository", 1),
                new AgentCapability("query.git.operation", 1), new AgentCapability("query.git.remote", 1)
            }))
                throw new Exception("Agent capabilities do not match registered actions");
            using var emptyParams = JsonDocument.Parse("{}");
            using var invalidParams = JsonDocument.Parse("{\"unexpected\":true}");
            using var arrayParams = JsonDocument.Parse("[]");
            foreach (var parameters in new[] { invalidParams.RootElement, arrayParams.RootElement })
            {
                try { await dispatcher.InvokeAsync("query.system.metrics", 1, parameters, CancellationToken.None); throw new Exception("Invalid action params accepted"); }
                catch (AgentActionException e) when (e.Code == "invalid_params") { }
            }
            try { await dispatcher.InvokeAsync("future.unsupported", 1, emptyParams.RootElement, CancellationToken.None); throw new Exception("Unknown action accepted"); }
            catch (AgentActionException e) when (e.Code == "unsupported_method") { }
            Metrics? observedMetrics = null;
            dispatcher.MetricsReceived += value => observedMetrics = value;
            var metrics = (Metrics)(await dispatcher.InvokeAsync("query.system.metrics", 1, emptyParams.RootElement, CancellationToken.None))!;
            if (observedMetrics != metrics) throw new Exception("Remote sampling did not update local metrics");
            if (metrics.CpuUsagePercent < 0 || metrics.CpuUsagePercent > 100 || metrics.MemoryUsagePercent <= 0 ||
                metrics.MemoryUsagePercent > 100 || metrics.MemoryUsedBytes > metrics.MemoryTotalBytes || metrics.SampleWindowMs < 900)
                throw new Exception("Invalid real system metrics");
            if (metrics.Network is null || (metrics.Network.Available &&
                (metrics.Network.DownloadBytesPerSecond is not >= 0 || metrics.Network.UploadBytesPerSecond is not >= 0)))
                throw new Exception("Network metrics were not included in the system query");
            if (metrics.Disk is not { } disk || disk.Volumes.Any(volume => volume.TotalBytes == 0 || volume.UsedBytes > volume.TotalBytes) ||
                (disk.ReadBytesPerSecond is double read && (!double.IsFinite(read) || read < 0)) ||
                (disk.WriteBytesPerSecond is double write && (!double.IsFinite(write) || write < 0)))
                throw new Exception("Disk metrics are missing or invalid");
            Console.WriteLine($"PASS: real disk sample, volumes={disk.Volumes.Length}, read B/s={disk.ReadBytesPerSecond}, write B/s={disk.WriteBytesPerSecond}");
            Console.WriteLine($"PASS: DPAPI tamper detection, RSA generation/public export/import, RSA-PSS, URL validation, action dispatcher/capabilities/params, real CPU {metrics.CpuUsagePercent:F1}%, memory {metrics.MemoryUsagePercent:F1}%");
            await CapabilityChecks.RunAsync();
            await GitRepositoryChecks.RunAsync();
            await CodexUsageChecks.RunAsync();
            await CliChecks.RunAsync();
            return 0;
        }
        catch (Exception error) { Console.Error.WriteLine(error); return 1; }
    }
}
