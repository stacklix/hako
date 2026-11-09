using System;
using System.IO;
using System.Security.Cryptography;
using System.Text.Json;
using System.Text.RegularExpressions;
using Hako.Platform;

namespace Hako.Core;

public sealed record AgentSettings(string Url = "", string Username = "", string PrivateKey = "")
{
    public static AgentSettings Load() => new AgentSettingsStore().Load();
    public void Save() => new AgentSettingsStore().Save(this);

    public Uri Origin()
    {
        if (!Uri.TryCreate(Url.Trim(), UriKind.Absolute, out var uri) || uri.UserInfo.Length != 0 ||
            uri.Query.Length != 0 || uri.Fragment.Length != 0 || uri.AbsolutePath != "/" ||
            (uri.Scheme != "https" && !(uri.Scheme == "http" && uri.IsLoopback)))
            throw new ArgumentException("服务器地址必须是 HTTPS 根地址，例如 https://monitor.example.com；本机调试允许 HTTP。");
        return uri;
    }

    public void Validate()
    {
        ValidateConnectionSettings();
        using var rsa = RSA.Create();
        rsa.ImportFromPem(PrivateKey);
        if (rsa.KeySize < 2048) throw new ArgumentException("RSA 密钥至少为 2048 位。");
        _ = rsa.ExportParameters(true);
    }

    public void ValidateConnectionSettings()
    {
        _ = Origin();
        if (!Regex.IsMatch(Username, @"\A[A-Za-z0-9_-]{1,80}\z")) throw new ArgumentException("账号应为 1–80 位英文字母、数字、下划线或连字符。");
    }

    public static string KeyId(RSA rsa) => Convert.ToBase64String(SHA256.HashData(rsa.ExportSubjectPublicKeyInfo())).TrimEnd('=').Replace('+', '-').Replace('/', '_');
}

public sealed class AgentSettingsStore
{
    public static string DefaultDirectory => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Hako");
    public string DirectoryPath { get; }
    public string SettingsPath => Path.Combine(DirectoryPath, "agent.dat");
    public AgentSettingsStore(string? directory = null) => DirectoryPath = Path.TrimEndingDirectorySeparator(Path.GetFullPath(directory ?? DefaultDirectory));
    public AgentSettings Load() => File.Exists(SettingsPath)
        ? JsonSerializer.Deserialize<AgentSettings>(DataProtection.Unprotect(File.ReadAllBytes(SettingsPath))) ?? throw new InvalidDataException("设备配置格式无效。")
        : new();
    public void Save(AgentSettings settings)
    {
        Directory.CreateDirectory(DirectoryPath);
        var temporary = Path.Combine(DirectoryPath, "agent." + Guid.NewGuid().ToString("N") + ".tmp");
        try
        {
            File.WriteAllBytes(temporary, DataProtection.Protect(JsonSerializer.SerializeToUtf8Bytes(settings)));
            File.Move(temporary, SettingsPath, true);
        }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }
}
