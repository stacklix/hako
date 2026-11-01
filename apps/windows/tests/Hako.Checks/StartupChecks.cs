using System;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using Hako.Core;
using Hako.Platform;

internal static class StartupChecks
{
    private static void Check(bool condition, string message) { if (!condition) throw new Exception(message); }

    public static void Run()
    {
        var root = Path.Combine(Path.GetTempPath(), "hako-startup-check-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        try
        {
            var executable = Path.Combine(root, "应用 with spaces", "Hako.exe");
            Directory.CreateDirectory(Path.GetDirectoryName(executable)!);
            File.Copy(Environment.ProcessPath!, executable);
            var startupDirectory = Path.Combine(root, "startup");
            var profile = Path.Combine(root, "用户 profile with spaces");
            var startup = new AgentStartup(executable, profile, startupDirectory);
            Check(!startup.IsEnabled && !Directory.Exists(startupDirectory), "Reading startup state must not create a registration");
            startup.SetEnabled(true);
            Check(new AgentStartup(executable, profile, startupDirectory).IsEnabled, "Startup registration did not persist");
            var command = ReadShortcut(startup.ShortcutPath);
            Check(string.Equals(command.Target, executable, StringComparison.OrdinalIgnoreCase), "Shortcut target is not the selected executable");
            var args = SplitCommandLine("\"" + command.Target + "\" " + command.Arguments);
            var invocation = CliParser.Parse(args.Skip(1).ToArray());
            Check(invocation.Background && invocation.Profile.Store.DirectoryPath == profile, "Startup lost background mode or the quoted profile path");

            startup.SetEnabled(true);
            Check(Directory.GetFiles(startupDirectory).Length == 1, "Enabling twice created duplicate shortcuts");
            var other = new AgentStartup(executable, profile + " other", startupDirectory);
            other.SetEnabled(true);
            Check(other.ShortcutPath != startup.ShortcutPath, "Independent profiles share a startup registration");
            startup.SetEnabled(false);
            startup.SetEnabled(false);
            Check(!startup.IsEnabled && other.IsEnabled, "Disabling removed another profile's shortcut");

            var defaults = new AgentStartup(executable, AgentSettingsStore.DefaultDirectory, startupDirectory);
            defaults.SetEnabled(true);
            Check(Path.GetFileName(defaults.ShortcutPath) == "Hako Agent.lnk" && ReadShortcut(defaults.ShortcutPath).Arguments == "--background",
                "Default startup shortcut must match the documented manual shortcut");
            var original = File.ReadAllBytes(defaults.ShortcutPath);
            try
            {
                new AgentStartup(Path.Combine(root, "missing.exe"), AgentSettingsStore.DefaultDirectory, startupDirectory).SetEnabled(true);
                throw new Exception("Missing executable was accepted for startup");
            }
            catch (FileNotFoundException) { }
            Check(File.ReadAllBytes(defaults.ShortcutPath).SequenceEqual(original), "Failed enable destroyed an existing startup registration");

            var driveRoot = Path.GetPathRoot(root)!;
            var rootProfile = new AgentStartup(executable, driveRoot, startupDirectory, assemblyPath: Path.Combine(root, "test assembly.dll"));
            rootProfile.SetEnabled(true);
            command = ReadShortcut(rootProfile.ShortcutPath);
            args = SplitCommandLine("\"" + command.Target + "\" " + command.Arguments);
            Check(args[1] == Path.Combine(root, "test assembly.dll") && args[2] == "--background" && args[3] == "--data-dir" && args[4] == driveRoot,
                "Assembly path or trailing root backslash was not quoted correctly");

            var blocked = Path.Combine(root, "blocked");
            File.WriteAllText(blocked, "not a directory");
            var failing = new AgentStartup(executable, profile, blocked);
            try { failing.SetEnabled(true); throw new Exception("Unwritable startup location was accepted"); }
            catch (IOException) { }
            Check(!failing.IsEnabled && File.ReadAllText(blocked) == "not a directory", "Failed startup write changed registration state");
            Check(!Directory.GetFiles(startupDirectory).Any(file => Path.GetFileName(file).StartsWith("Hako-", StringComparison.Ordinal)),
                "Temporary startup shortcuts were left behind");
        }
        finally
        {
            if (!Path.GetFullPath(root).StartsWith(Path.GetFullPath(Path.GetTempPath()), StringComparison.OrdinalIgnoreCase))
                throw new Exception("Unsafe startup test cleanup path");
            Directory.Delete(root, true);
        }
        Console.WriteLine("PASS: real startup shortcuts, persistence, background/profile arguments, quoted Unicode/root paths, idempotency, profile isolation and failed writes");
    }

    private static (string Target, string Arguments) ReadShortcut(string path)
    {
        return WindowsShortcut.Read(path);
    }

    private static string[] SplitCommandLine(string command)
    {
        var pointer = CommandLineToArgvW(command, out var count);
        if (pointer == IntPtr.Zero) throw new Exception("Windows command-line parsing failed");
        try { return Enumerable.Range(0, count).Select(i => Marshal.PtrToStringUni(Marshal.ReadIntPtr(pointer, i * IntPtr.Size))!).ToArray(); }
        finally { LocalFree(pointer); }
    }
    [DllImport("shell32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr CommandLineToArgvW(string command, out int count);
    [DllImport("kernel32.dll")]
    private static extern IntPtr LocalFree(IntPtr pointer);
}
