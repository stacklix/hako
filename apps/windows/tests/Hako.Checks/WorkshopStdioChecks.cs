using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Hako.Core;
using Hako.Platform;

internal static class WorkshopStdioChecks
{
    private static ProcessStartInfo Self(string argument)
    {
        var start = new ProcessStartInfo(Environment.ProcessPath!) { UseShellExecute = false, CreateNoWindow = true,
            RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true };
        if (Path.GetFileNameWithoutExtension(Environment.ProcessPath!).Equals("dotnet", StringComparison.OrdinalIgnoreCase))
            start.ArgumentList.Add(typeof(Program).Assembly.Location);
        start.ArgumentList.Add(argument);
        return start;
    }

    internal static async Task RunAsync()
    {
        using var process = Process.Start(Self("--workshop-stdio-bounded"))!;
        var output = process.StandardOutput.ReadToEndAsync();
        var errors = process.StandardError.ReadToEndAsync();
        try { await process.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(30)); }
        catch (TimeoutException)
        {
            process.Kill(entireProcessTree: true);
            await process.WaitForExitAsync();
            throw new Exception("Resident stdio readers starved the bounded RPC worker pool.");
        }
        var text = await output;
        if (process.ExitCode != 0) throw new Exception("Bounded stdio/RPC check failed: " + await errors + text);
        Console.Write(text);
    }

    internal static async Task RunBoundedAsync()
    {
        ThreadPool.GetMinThreads(out _, out var minimumIo);
        ThreadPool.GetMaxThreads(out _, out var maximumIo);
        if (!ThreadPool.SetMinThreads(1, minimumIo) || !ThreadPool.SetMaxThreads(4, maximumIo))
            throw new Exception("Cannot establish the isolated four-worker test pool.");
        var servers = new List<CodexAppServer>();
        try
        {
            for (var index = 0; index < 5; index++)
                servers.Add(await CodexAppServer.StartAsync(default, Self("--workshop-stdio-fixture")));
            await Task.Delay(50);
            var name = "Hako.StdioRegression." + Guid.NewGuid().ToString("N");
            await using var rpc = new LocalRpcServer(name, async (_, publish, _) => await publish(new { ok = true }));
            var result = await LocalRpc.CallAsync(name, LocalRpc.Request("probe"), default);
            if (!result.GetProperty("ok").GetBoolean()) throw new Exception("RPC reply was lost with resident stdio readers.");
            foreach (var server in servers)
                if (!((await server.RequestAsync("probe", new { }, default)).GetProperty("ok").GetBoolean()))
                    throw new Exception("A resident worker stopped receiving replies.");
            Console.WriteLine("PASS: ten idle stdout/stderr readers leave a four-worker pool responsive to local RPC and Codex replies.");
        }
        finally { foreach (var server in servers) await server.DisposeAsync(); }
    }

    internal static void Fixture()
    {
        while (Console.ReadLine() is { } line)
        {
            using var input = JsonDocument.Parse(line);
            if (!input.RootElement.TryGetProperty("id", out var id)) continue;
            Console.WriteLine(JsonSerializer.Serialize(new { id = id.Clone(), result = new { ok = true } }));
            Console.Out.Flush();
        }
    }
}
