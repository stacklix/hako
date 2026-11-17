using System;
using System.Collections.Generic;
using System.IO;
using System.Net.Http;
using System.Net.Http.Json;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace Hako.Core;

internal static class AgentDataQuery
{
    internal static async Task<CommandReply> ExecuteAsync(AgentSettings settings, AgentCommand command, CancellationToken token,
        HttpMessageHandler? handler = null)
    {
        try
        {
            CliParser.Validate(command);
            settings.Validate();
            var origin = settings.Origin();
            var sql = command.Options.GetValueOrDefault("sql", "");
            if (command.Options.TryGetValue("sql-file", out var path))
            {
                if (new FileInfo(path).Length > 20000) throw new CliUsageException("SQL 文件不能超过 20000 字节。");
                sql = await File.ReadAllTextAsync(path, new UTF8Encoding(false, true), token);
            }
            if (command.Command == "server query" && (string.IsNullOrWhiteSpace(sql) || Encoding.UTF8.GetByteCount(sql) > 20000))
                throw new CliUsageException("SQL 不能为空或超过 20000 字节。");
            using var rsa = RSA.Create(); rsa.ImportFromPem(settings.PrivateKey);
            var keyId = AgentSettings.KeyId(rsa);
            var payload = Convert.ToBase64String(JsonSerializer.SerializeToUtf8Bytes(new {
                operation = command.Command == "server schema" ? "schema" : "query", sql,
                limit = int.Parse(command.Options.GetValueOrDefault("limit", "100")),
                offset = int.Parse(command.Options.GetValueOrDefault("offset", "0")),
                issuedAt = DateTimeOffset.UtcNow.ToUnixTimeSeconds(),
                nonce = Convert.ToBase64String(RandomNumberGenerator.GetBytes(32)).TrimEnd('=').Replace('+', '-').Replace('/', '_')
            }, AgentConnection.Json));
            var proof = Encoding.UTF8.GetBytes("hako-agent-data/v1\n" + origin.GetLeftPart(UriPartial.Authority) + "\n" + settings.Username + "\n" + keyId + "\n" + payload);
            var signature = Convert.ToBase64String(rsa.SignData(proof, HashAlgorithmName.SHA256, RSASignaturePadding.Pss));
            using var client = new HttpClient(handler ?? new HttpClientHandler { AllowAutoRedirect = false }) {
                Timeout = TimeSpan.FromSeconds(15), MaxResponseContentBufferSize = 8 * 1024 * 1024
            };
            using var response = await client.PostAsJsonAsync(new Uri(origin, "/api/v1/agents/data-query"),
                new { settings.Username, keyId, payload, signature }, AgentConnection.Json, token);
            if (!response.IsSuccessStatusCode)
            {
                string code = "server_query_failed", message = "线上数据查询失败（HTTP " + (int)response.StatusCode + "）。";
                if ((int)response.StatusCode is >= 300 and < 400)
                    return CommandReply.Failure(1, code, "服务端返回重定向，已拒绝转发设备认证信息，请核对服务器根地址。");
                try
                {
                    using var failure = JsonDocument.Parse(await response.Content.ReadAsByteArrayAsync(token));
                    if (failure.RootElement.TryGetProperty("error", out var error)) code = error.GetString() ?? code;
                    if (failure.RootElement.TryGetProperty("message", out var detail)) message = detail.GetString() ?? message;
                }
                catch (JsonException) { }
                if (code == "agent_data_query_disabled") message = "此 Agent 尚未获准查询线上数据，请管理员在后台「设备代理」中开启数据查询权限。";
                if (response.StatusCode == System.Net.HttpStatusCode.NotFound) message = "当前服务端没有提供 Agent 数据查询接口，请升级服务端。";
                return CommandReply.Failure(1, code, message);
            }
            using var result = JsonDocument.Parse(await response.Content.ReadAsByteArrayAsync(token));
            return CommandReply.Success(result.RootElement.Clone(), JsonSerializer.Serialize(result.RootElement, new JsonSerializerOptions { WriteIndented = true }));
        }
        catch (CliUsageException error) { return CommandReply.Failure(2, "invalid_arguments", error.Message); }
        catch (OperationCanceledException) { return CommandReply.Failure(4, "timeout", "线上数据查询已取消或超时。"); }
        catch (Exception error) when (error is HttpRequestException or IOException or JsonException or CryptographicException or ArgumentException or UnauthorizedAccessException)
        { return CommandReply.Failure(1, "server_query_failed", "线上数据查询失败，请检查服务端地址、网络、设备密钥及 SQL 文件。"); }
    }
}
