using System;
using System.Security.Cryptography;

namespace Hako.Core;

public static class AgentKeys
{
    public static string GeneratePrivateKey()
    {
        using var rsa = RSA.Create(3072);
        return rsa.ExportPkcs8PrivateKeyPem();
    }

    public static string NormalizePrivateKey(string pem)
    {
        using var rsa = RSA.Create();
        rsa.ImportFromPem(pem);
        if (rsa.KeySize < 2048) throw new ArgumentException("RSA 密钥至少为 2048 位。");
        return rsa.ExportPkcs8PrivateKeyPem();
    }

    public static string ExportPublicKey(string privateKey)
    {
        using var rsa = RSA.Create();
        rsa.ImportFromPem(privateKey);
        return rsa.ExportSubjectPublicKeyInfoPem();
    }
}
