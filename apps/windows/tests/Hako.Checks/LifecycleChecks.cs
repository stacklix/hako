using System;
using System.IO;
using System.Linq;
using System.Text.Json;
using Hako.Core;

internal static class LifecycleChecks
{
    internal static void Run()
    {
        var directory = Path.Combine(Path.GetTempPath(), "hako-lifecycle-" + Guid.NewGuid().ToString("N"));
        try
        {
            var log = new AgentLifecycleLog(directory, background: true);
            log.Ready();
            log.Heartbeat();
            log.ExitRequested("cli_exit");
            log.Complete(0);
            var statePath = Path.Combine(directory, "logs", "agent-session.json");
            using (var state = JsonDocument.Parse(File.ReadAllText(statePath)))
            {
                if (state.RootElement.GetProperty("endedAt").ValueKind != JsonValueKind.String ||
                    state.RootElement.GetProperty("exitReason").GetString() != "cli_exit")
                    throw new Exception("A clean shutdown did not persist its exit reason.");
            }
            var crashed = new AgentLifecycleLog(directory, background: false);
            try { throw new InvalidOperationException("SECRET-MUST-NOT-APPEAR"); }
            catch (Exception error) { crashed.Exception("dispatcher", error, terminating: true); }
            crashed.Complete(1);
            var restarted = new AgentLifecycleLog(directory, background: true);
            restarted.ExitRequested("windows_shutdown");
            restarted.Complete(0);
            var logPath = Path.Combine(directory, "logs", "agent-lifecycle.jsonl");
            var lines = File.ReadAllLines(logPath).Select(line => JsonSerializer.Deserialize<JsonElement>(line)).ToArray();
            if (lines.Count(line => line.GetProperty("event").GetString() == "previous_unclean_exit") != 1)
                throw new Exception("Restart did not distinguish a clean stop from an unclean stop.");
            if (File.ReadAllText(logPath).Contains("SECRET-MUST-NOT-APPEAR", StringComparison.Ordinal))
                throw new Exception("Exception message leaked into the lifecycle log.");
            var fault = lines.Single(line => line.GetProperty("event").GetString() == "exception").GetProperty("details");
            if (fault.GetProperty("type").GetString() != typeof(InvalidOperationException).FullName ||
                fault.GetProperty("stack").ValueKind != JsonValueKind.String)
                throw new Exception("Crash type and stack were not recorded.");
            var rotated = new AgentLifecycleLog(Path.Combine(directory, "rotation"), background: true, maxLogBytes: 512);
            for (var i = 0; i < 40; i++) rotated.Heartbeat();
            rotated.Complete(0);
            var files = Directory.GetFiles(Path.Combine(directory, "rotation", "logs"), "agent-lifecycle.jsonl*");
            if (files.Length != 4 || files.Any(file => new FileInfo(file).Length > 2048))
                throw new Exception("Lifecycle log retention is not bounded.");
            foreach (var file in files)
                foreach (var line in File.ReadLines(file)) using (JsonDocument.Parse(line)) { }
            // Logging failure must not prevent the Agent from starting or stopping.
            var blocked = Path.Combine(directory, "blocked");
            File.WriteAllText(blocked, "");
            var unavailable = new AgentLifecycleLog(blocked, background: true);
            unavailable.Heartbeat();
            unavailable.Complete(0);
            Console.WriteLine("PASS: lifecycle exit reasons, unclean restart detection, heartbeat, exception privacy, rotation and unavailable storage.");
        }
        finally { if (Directory.Exists(directory)) Directory.Delete(directory, true); }
    }
}
