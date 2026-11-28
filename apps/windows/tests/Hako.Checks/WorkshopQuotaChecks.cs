using System;
using System.Text.Json;
using System.Diagnostics;
using System.IO;
using System.Threading;
using System.Threading.Tasks;
using Hako.Platform;

internal static class WorkshopQuotaChecks
{
    internal static async Task RunAsync()
    {
        Run();
        var directory=Path.Combine(Path.GetTempPath(),"hako-quota-"+Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        try
        {
            Task<CodexAppServer> Start(CancellationToken token)
            {
                var process=new ProcessStartInfo(Environment.ProcessPath!);
                if (Path.GetFileNameWithoutExtension(Environment.ProcessPath!).Equals("dotnet",StringComparison.OrdinalIgnoreCase))
                    process.ArgumentList.Add(typeof(Program).Assembly.Location);
                process.ArgumentList.Add("--codex-workshop-fixture");
                process.Environment["HAKO_CODEX_TEST_PROJECT"]=directory;
                return CodexAppServer.StartAsync(token,process);
            }
            await using var service=new CodeWorkshop(Path.Combine(directory,"state"),directory,directory,Start);
            var empty=JsonSerializer.SerializeToElement(new { });
            var result=JsonSerializer.SerializeToElement(await service.QuotaAsync(empty,default),WorkshopProtocol.Json);
            if (result.GetProperty("buckets")[0].GetProperty("primary").GetProperty("usedPercent").GetDouble() != 25.5 ||
                result.GetProperty("buckets")[0].GetProperty("credits").GetProperty("balance").GetString() != "123.45" ||
                result.GetProperty("checkedAt").GetInt64() <= 0 || result.GetRawText().Contains("private-account"))
                throw new Exception("Read-only Codex quota RPC failed or exposed account identity.");
            try { await service.QuotaAsync(JsonSerializer.SerializeToElement(new { unexpected=true }),default); throw new Exception("Unknown quota parameter accepted."); }
            catch (WorkshopException error) when (error.Code == "invalid_params") { }
        }
        finally { Directory.Delete(directory,true); }
        Console.WriteLine("PASS: Codex quota stdio RPC, snapshot timestamp, privacy and strict query parameters.");
    }

    internal static void Run()
    {
        static JsonElement Json(string text) => JsonDocument.Parse(text).RootElement.Clone();
        var buckets = CodeWorkshop.QuotaBuckets(Json("""
            {"accountId":"private-account","rateLimitsByLimitId":{
              "other":{"limitName":"Other","normalModelSlug":"other-model","primary":{"usedPercent":120,"windowDurationMins":null,"resetsAt":null}},
              "codex":{"primary":{"usedPercent":25.5,"windowDurationMins":300,"resetsAt":1800000000},"secondary":{"usedPercent":60,"windowDurationMins":10080,"resetsAt":1800600000}},
              "empty":{"primary":null,"secondary":null},"invalid":{"primary":{"usedPercent":-1}}},
              "rateLimits":{"limitId":"duplicate","primary":{"usedPercent":25}}}
            """));
        if (buckets.Length != 2 || buckets[0].Id != "codex" || buckets[0].Primary?.UsedPercent != 25.5 ||
            buckets[0].Secondary?.WindowDurationMins != 10080 || buckets[1].Primary?.UsedPercent != 120 ||
            buckets[1].Primary?.ResetsAt is not null) throw new Exception("Quota windows lost, duplicated, reordered or invented.");
        var current = CodeWorkshop.QuotaBuckets(Json("""{"rateLimitsByLimitId":null,"rateLimits":{"limitId":"codex","primary":{"usedPercent":0,"resetsAt":0,"windowDurationMins":0}}}"""));
        if (current.Length != 1 || current[0].Primary?.ResetsAt is not null || current[0].Primary?.WindowDurationMins is not null)
            throw new Exception("Optional current API quota fields were not handled.");
        if (CodeWorkshop.QuotaBuckets(Json("{}" )).Length != 0) throw new Exception("Missing quotas became 100% available.");
        if (JsonSerializer.Serialize(buckets, WorkshopProtocol.Json).Contains("private-account")) throw new Exception("Account identity leaked into quota metadata.");
        var creditOnly = CodeWorkshop.QuotaBuckets(Json("""
            {"rateLimitsByLimitId":{"codex":{"credits":{"hasCredits":true,"unlimited":false,"balance":"123.45","accountId":"private-account","token":"private-token"}}}}
            """));
        if (creditOnly.Length != 1 || creditOnly[0].Primary is not null || creditOnly[0].Credits?.Balance != "123.45")
            throw new Exception("Credit balance must survive even without rate-limit windows.");
        var creditJson = JsonSerializer.Serialize(creditOnly, WorkshopProtocol.Json);
        if (creditJson.Contains("private-account") || creditJson.Contains("private-token")) throw new Exception("Credit normalization leaked private metadata.");
        foreach (var balance in new[] { "-1", "NaN", "private-token", "1,000", "1e999" })
        {
            var invalidCredits = CodeWorkshop.QuotaBuckets(JsonSerializer.SerializeToElement(new { rateLimits = new {
                limitId = "codex", credits = new { hasCredits = true, unlimited = false, balance }
            } }));
            if (invalidCredits[0].Credits?.Balance is not null) throw new Exception("Invalid credit balance was exposed.");
        }
        var unknown = CodeWorkshop.QuotaBuckets(Json("""{"rateLimits":{"limitId":"codex","credits":{"hasCredits":false,"unlimited":false,"balance":null}}}"""));
        if (unknown[0].Credits?.Balance is not null || unknown[0].Credits?.HasCredits != false)
            throw new Exception("Missing credit balance was fabricated.");
        var unlimited = CodeWorkshop.QuotaBuckets(Json("""{"rateLimits":{"limitId":"codex","credits":{"hasCredits":true,"unlimited":true,"balance":null}}}"""));
        if (unlimited[0].Credits?.Unlimited != true) throw new Exception("Unlimited credits were discarded.");
        Console.WriteLine("PASS: account quota buckets, optional windows, invalid values and privacy filtering.");
    }
}
