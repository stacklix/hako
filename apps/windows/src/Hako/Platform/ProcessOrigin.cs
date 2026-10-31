using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace Hako.Platform;

internal static class ProcessOrigin
{
    // Only an unreadable core Windows process uses a name fallback. Service
    // sessions also contain third-party applications, so SessionId is not origin.
    private static readonly HashSet<string> CoreNames = new(StringComparer.OrdinalIgnoreCase)
    {
        "System", "Registry", "Memory Compression", "Secure System", "smss", "csrss", "wininit", "winlogon",
        "services", "svchost", "lsass", "lsaiso", "spoolsv", "fontdrvhost", "dwm", "WUDFHost",
        "sihost", "taskhostw", "RuntimeBroker", "conhost", "dllhost", "audiodg", "SearchIndexer"
    };

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern SafeProcessHandle OpenProcess(uint access, [MarshalAs(UnmanagedType.Bool)] bool inherit, int pid);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool QueryFullProcessImageName(SafeProcessHandle process, uint flags, StringBuilder path, ref uint size);

    public static string? ReadExecutablePath(int pid)
    {
        using var process = OpenProcess(0x1000, false, pid); // PROCESS_QUERY_LIMITED_INFORMATION
        if (process.IsInvalid) return null;
        foreach (var capacity in new[] { 1024, 32768 })
        {
            var path = new StringBuilder(capacity);
            var size = (uint)capacity;
            if (QueryFullProcessImageName(process, 0, path, ref size)) return path.ToString();
            if (Marshal.GetLastWin32Error() != 122) break;
        }
        return null;
    }

    public static string? Classify(string? name, string? executablePath, string? windowsDirectory = null)
    {
        if (!string.IsNullOrWhiteSpace(executablePath))
        {
            try
            {
                var path = executablePath.StartsWith(@"\\?\", StringComparison.Ordinal) ? executablePath[4..] : executablePath;
                var directory = windowsDirectory ?? Environment.GetFolderPath(Environment.SpecialFolder.Windows);
                if (Path.IsPathFullyQualified(path) && Path.IsPathFullyQualified(directory))
                {
                    var root = Path.TrimEndingDirectorySeparator(Path.GetFullPath(directory)) + Path.DirectorySeparatorChar;
                    return Path.GetFullPath(path).StartsWith(root, StringComparison.OrdinalIgnoreCase) ? "system" : "user";
                }
            }
            catch (Exception error) when (error is ArgumentException or NotSupportedException or PathTooLongException) { }
        }
        if (string.IsNullOrWhiteSpace(name)) return null;
        return CoreNames.Contains(name) ? "system" : "user";
    }
}
