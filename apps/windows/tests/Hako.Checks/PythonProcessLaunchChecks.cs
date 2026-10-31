using System;
using System.Diagnostics;
using System.IO;
using System.Text.Json;
using System.Threading.Tasks;
using Hako.Core;
using Hako.Platform;

internal static class PythonProcessLaunchChecks
{
    public static async Task RunAsync()
    {
        foreach (var (command, expected) in new (string, ProcessLaunch)[]
        {
            ("python.exe serve.py --token secret", new("script", "serve.py")),
            ("\"C:\\Program Files\\Python\\pythonw.exe\" -u \"C:\\My App\\serve debug.py\" --key secret", new("script", @"C:\My App\serve debug.py")),
            ("python -B -X utf8 -W ignore -m http.server 8003 --bind 127.0.0.1", new("module", "http.server")),
            ("python -Xutf8 -Wignore -uB -mhttp.server 8003", new("module", "http.server")),
            ("python --check-hash-based-pycs always app.pyz", new("script", "app.pyz")),
            ("python -- -named-script.py", new("script", "-named-script.py")),
            ("python -c \"print('private code')\"", new("inline")),
            ("python -cprivate_code", new("inline")),
            ("python - --token secret", new("stdin")),
            ("python -I -u", new("interactive")),
            ("python -X", new("unavailable")), ("python -m", new("unavailable")),
            ("python --unknown secret app.py", new("unavailable")),
            ("", new("unavailable")), ("python " + new string('x', 2049), new("unavailable"))
        })
        {
            var result = PythonProcessLaunch.Parse(command);
            if (result != expected) throw new Exception($"Python launch kind/target mismatch; expected {expected.Kind}");
            if (JsonSerializer.Serialize(result).Contains("secret", StringComparison.Ordinal))
                throw new Exception("Python launch leaked script arguments");
        }
        if (!PythonProcessLaunch.IsPython("pythonw") || !PythonProcessLaunch.IsPython("python3.13t")
            || PythonProcessLaunch.IsPython("my-python-service") || PythonProcessLaunch.Read(Environment.ProcessId, "node") != null
            || PythonProcessLaunch.Read(-1, "python")?.Kind != "unavailable")
            throw new Exception("Interpreter selection / unreadable launch handling failed");

        var start = new ProcessStartInfo(Environment.ProcessPath!)
        {
            UseShellExecute = false, CreateNoWindow = true, WindowStyle = ProcessWindowStyle.Hidden,
            RedirectStandardOutput = true, RedirectStandardError = true
        };
        if (Path.GetFileNameWithoutExtension(Environment.ProcessPath)!.Equals("dotnet", StringComparison.OrdinalIgnoreCase))
            start.ArgumentList.Add(typeof(Program).Assembly.Location);
        start.ArgumentList.Add(@"C:\Test App\hako-launch-fixture.py");
        start.ArgumentList.Add("--token"); start.ArgumentList.Add("private-fixture-value");
        using var child = Process.Start(start)!;
        try
        {
            var ready = await child.StandardOutput.ReadLineAsync().WaitAsync(TimeSpan.FromSeconds(10));
            if (ready != "ready") throw new Exception("Launch fixture did not start");
            var launch = PythonProcessLaunch.Read(child.Id, "python");
            if (launch != new ProcessLaunch("script", @"C:\Test App\hako-launch-fixture.py"))
                throw new Exception("Native command-line query did not preserve the quoted script path");
            var merged = NetworkListeners.Merge([new("TCP", 8003, "127.0.0.1", child.Id)],
                _ => new("python", DateTimeOffset.UtcNow.AddMinutes(-1), Launch: launch), DateTimeOffset.UtcNow);
            var result = JsonSerializer.Serialize(merged, AgentConnection.Json);
            if (!result.Contains("hako-launch-fixture.py", StringComparison.Ordinal) || result.Contains("private-fixture-value", StringComparison.Ordinal)
                || result.Contains("displayName", StringComparison.Ordinal))
                throw new Exception("Listener launch JSON omitted the entry point or leaked non-target data");
        }
        finally { if (!child.HasExited) { child.Kill(); await child.WaitForExitAsync(); } }
        Console.WriteLine("PASS: native process launch query, quoted Python scripts, modules, interpreter flags, unavailable metadata and argument/code exclusion");
    }
}
