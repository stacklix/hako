using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace Hako.Platform;

internal sealed record WorkshopQuotaWindow(double UsedPercent, int? WindowDurationMins, long? ResetsAt);
internal sealed record WorkshopQuotaCredits(bool HasCredits, bool Unlimited, string? Balance);
internal sealed record WorkshopQuotaBucket(string Id, string Name, string Model,
    WorkshopQuotaWindow? Primary, WorkshopQuotaWindow? Secondary, WorkshopQuotaCredits? Credits = null);

internal sealed partial class CodeWorkshop
{
    public async Task<object?> QuotaAsync(JsonElement parameters, CancellationToken token)
    {
        CodexJson.Keys(parameters);
        var result = await ReadAsync("account/rateLimits/read", new { }, token);
        // Return only displayable quota/credit metadata, never account IDs or auth tokens.
        return new { buckets = QuotaBuckets(result), checkedAt = DateTimeOffset.UtcNow.ToUnixTimeSeconds() };
    }

    internal static WorkshopQuotaBucket[] QuotaBuckets(JsonElement result)
    {
        var buckets = new List<WorkshopQuotaBucket>();
        var map = CodexJson.Field(result, "rateLimitsByLimitId");
        if (map.ValueKind == JsonValueKind.Object && map.EnumerateObject().Any())
        {
            foreach (var entry in map.EnumerateObject()) Add(entry.Name, entry.Value);
        }
        else Add(CodexJson.Text(CodexJson.Field(result, "rateLimits"), "limitId"), CodexJson.Field(result, "rateLimits"));
        return buckets.OrderBy(bucket => bucket.Id == "codex" ? 0 : 1).ThenBy(bucket => bucket.Id, StringComparer.Ordinal).ToArray();

        void Add(string id, JsonElement value)
        {
            var primary = Window(CodexJson.Field(value, "primary"));
            var secondary = Window(CodexJson.Field(value, "secondary"));
            var credits = Credits(CodexJson.Field(value, "credits"));
            if (primary is null && secondary is null && credits is null) return;
            buckets.Add(new(CodexJson.Clip(id, 100), CodexJson.Clip(CodexJson.Text(value, "limitName"), 100),
                CodexJson.Clip(CodexJson.Text(value, "normalModelSlug"), 100), primary, secondary, credits));
        }
    }

    private static WorkshopQuotaCredits? Credits(JsonElement value)
    {
        var available = CodexJson.Field(value, "hasCredits");
        var unlimited = CodexJson.Field(value, "unlimited");
        if (available.ValueKind is not (JsonValueKind.True or JsonValueKind.False) ||
            unlimited.ValueKind is not (JsonValueKind.True or JsonValueKind.False)) return null;
        var balance = CodexJson.Text(value, "balance").Trim();
        var valid = balance.Length is > 0 and <= 100 &&
            decimal.TryParse(balance, NumberStyles.AllowDecimalPoint, CultureInfo.InvariantCulture, out var amount) && amount >= 0;
        return new(available.GetBoolean(), unlimited.GetBoolean(), valid ? balance : null);
    }

    private static WorkshopQuotaWindow? Window(JsonElement value)
    {
        var used = CodexJson.Field(value, "usedPercent");
        if (used.ValueKind != JsonValueKind.Number || !used.TryGetDouble(out var percent) || !double.IsFinite(percent) || percent < 0) return null;
        var duration = CodexJson.Field(value, "windowDurationMins");
        var reset = CodexJson.Field(value, "resetsAt");
        return new(percent,
            duration.ValueKind == JsonValueKind.Number && duration.TryGetInt32(out var minutes) && minutes > 0 ? minutes : null,
            reset.ValueKind == JsonValueKind.Number && reset.TryGetInt64(out var seconds) && seconds > 0 ? seconds : null);
    }
}
