using System;
using System.IO;
using System.Security.Cryptography;
using System.Threading;
using System.Threading.Tasks;
using Hako.Core;
using Hako.Platform;

internal static class Program
{
    private static async Task<int> Main(string[] args)
    {
        try
        {
            if (args.Length == 4 && args[0] == "agent")
            {
                await using var agent = new AgentConnection(new SystemMetrics());
                agent.StatusChanged += text => Console.WriteLine(text);
                await agent.StartAsync(new AgentSettings(args[1], args[2], File.ReadAllText(args[3])));
                await Task.Delay(TimeSpan.FromSeconds(30));
                return 0;
            }
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
            var metrics = await new SystemMetrics().SampleAsync(CancellationToken.None);
            if (metrics.CpuUsagePercent < 0 || metrics.CpuUsagePercent > 100 || metrics.MemoryUsagePercent <= 0 ||
                metrics.MemoryUsagePercent > 100 || metrics.MemoryUsedBytes > metrics.MemoryTotalBytes || metrics.SampleWindowMs < 900)
                throw new Exception("Invalid real system metrics");
            Console.WriteLine($"PASS: DPAPI tamper detection, RSA generation/public export/import, RSA-PSS, URL validation, real CPU {metrics.CpuUsagePercent:F1}%, memory {metrics.MemoryUsagePercent:F1}%");
            await CliChecks.RunAsync();
            return 0;
        }
        catch (Exception error) { Console.Error.WriteLine(error); return 1; }
    }
}
