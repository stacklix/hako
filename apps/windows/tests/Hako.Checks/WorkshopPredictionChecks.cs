using System;
using System.Text.Json;
using Hako.Platform;

internal static class WorkshopPredictionChecks
{
    internal static void Run()
    {
        WorkshopInputPrediction? Read(string turn, string text) => CodeWorkshop.ReadPrediction(
            JsonSerializer.SerializeToElement(new { sourceTurnId = turn, text }), "latest");
        if (Read("latest", "  查看修改  ") != new WorkshopInputPrediction("latest", "查看修改") ||
            Read("older", "旧建议") is not null || Read("latest", "  ") is not null ||
            Read("latest", "不应\n多行") is not null || Read("latest", new string('a', 201)) is not null)
            throw new Exception("Prediction validation accepted stale, empty or unbounded text");
        Console.WriteLine("PASS: predictions are bounded single messages scoped to the exact completed source turn");
    }
}
