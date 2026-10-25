using System;
using System.Collections.Generic;
using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using Hako.Core;

internal static class CliChecks
{
    private static AgentCommand Command(string command, params string[] options)
    {
        var values = new Dictionary<string, string>();
        for (int i = 0; i < options.Length; i += 2) values.Add(options[i], options[i + 1]);
        return new AgentCommand(command, values);
    }
    private static void Check(bool condition, string message) { if (!condition) throw new Exception(message); }
    public static async Task RunAsync()
    {
        foreach (var args in new[] { new[] { "help" }, new[] { "--help" }, new[] { "-h" }, new[] { "config", "set", "--help" }, new[] { "help", "key" } })
            Check(CliParser.Parse(args).Request?.Command == "help", "Help aliases or subcommand help failed");
        try { CliParser.Parse(["status", "--wrong", "value"]); throw new Exception("Unknown CLI option accepted"); }
        catch (CliUsageException) { }
        var root = Path.Combine(Path.GetTempPath(), "hako-cli-check-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        try
        {
            var profile = new AgentProfile(root);
            Check(profile.PipeName != new AgentProfile().PipeName, "Independent profile shares the default pipe");
            await using var runtime = new AgentRuntime(profile.Store, true);
            await runtime.InitializeAsync(false);
            var configured = await runtime.ExecuteAsync(Command("config set", "url", "http://127.0.0.1:1", "account", "owner"));
            Check(configured.ExitCode == 0 && profile.Store.Load().PrivateKey.Length == 0, "Configuration before key generation failed");
            var created = await runtime.ExecuteAsync(Command("key generate"));
            Check(created.ExitCode == 0 && File.Exists(profile.Store.SettingsPath), "Generated key was not persisted");
            var key = profile.Store.Load().PrivateKey;
            var disk = Encoding.UTF8.GetString(File.ReadAllBytes(profile.Store.SettingsPath));
            Check(!disk.Contains("PRIVATE KEY", StringComparison.Ordinal), "Private key stored without encryption");
            Check(!created.ToJson().Contains("PRIVATE KEY", StringComparison.Ordinal), "CLI response leaks generated private key");
            Check((await runtime.ExecuteAsync(Command("key generate"))).ExitCode != 0 && profile.Store.Load().PrivateKey == key, "Existing key replaced without --force");
            var publicOutput = Path.Combine(root, "public key.pem");
            var exported = await runtime.ExecuteAsync(Command("key export-public", "output", publicOutput));
            Check(exported.ExitCode == 0 && File.ReadAllText(publicOutput).Contains("PUBLIC KEY", StringComparison.Ordinal), "Public key export failed");
            Check((await runtime.ExecuteAsync(Command("key export-public", "output", publicOutput))).ExitCode != 0, "Export overwrote an existing file without --force");
            using var privateRsa = RSA.Create(); privateRsa.ImportFromPem(key);
            using var publicRsa = RSA.Create(); publicRsa.ImportFromPem(File.ReadAllText(publicOutput));
            var data = RandomNumberGenerator.GetBytes(32);
            Check(publicRsa.VerifyData(data, privateRsa.SignData(data, HashAlgorithmName.SHA256, RSASignaturePadding.Pss), HashAlgorithmName.SHA256, RSASignaturePadding.Pss), "CLI public export does not match persisted private key");
            var invalidConfig = await runtime.ExecuteAsync(Command("config set", "url", "http://example.com"));
            Check(invalidConfig.ExitCode != 0 && profile.Store.Load().Url == "http://127.0.0.1:1", "Invalid configuration changed saved settings");

            bool exitRequested = false;
            await using (var server = new AgentPipeServer(profile, runtime, () => exitRequested = true))
            {
                CommandReply? response = null;
                for (int i = 0; i < 20 && response is null; i++) response = await AgentPipeClient.TrySendAsync(profile, Command("status"), 150);
                Check(response?.ExitCode == 0 && response.Data!.Value.GetProperty("running").GetBoolean(), "Shared runtime status via named pipe failed");
                response = await AgentPipeClient.TrySendAsync(profile, Command("config set", "account", "newowner"), 1000);
                Check(response?.ExitCode == 0 && profile.Store.Load().Username == "newowner", "IPC settings update not shared with runtime");
                response = await AgentPipeClient.TrySendAsync(profile, Command("metrics"), 1000);
                Check(response?.ExitCode == 0 && response.Data!.Value.GetProperty("memoryTotalBytes").GetUInt64() > 0, "IPC live metrics failed");
                response = await AgentPipeClient.TrySendAsync(profile, Command("exit"), 1000);
                Check(response?.ExitCode == 0, "IPC exit reply failed");
                for (int i = 0; i < 20 && !exitRequested; i++) await Task.Delay(10);
                Check(exitRequested, "IPC exit was not dispatched after the response");
            }
            using var oversized = new MemoryStream(new byte[] { 255, 255, 255, 127 });
            try { await CliWire.ReadAsync<AgentCommand>(oversized, CancellationToken.None); throw new Exception("Oversized IPC frame accepted"); }
            catch (InvalidDataException) { }
        }
        finally
        {
            if (!Path.GetFullPath(root).StartsWith(Path.GetFullPath(Path.GetTempPath()), StringComparison.OrdinalIgnoreCase)) throw new Exception("Unsafe test cleanup path");
            Directory.Delete(root, true);
        }
        Console.WriteLine("PASS: CLI help/parser, protected key persistence, safe export, profile isolation, IPC control and live metrics");
    }
}
