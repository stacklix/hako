using System;
using System.Runtime.InteropServices;
using System.Text.RegularExpressions;
using Microsoft.Win32.SafeHandles;

namespace Hako.Platform;

public sealed record ProcessLaunch(string Kind, string? Target = null)
{
    [System.Text.Json.Serialization.JsonIgnore]
    public string Summary => Kind switch
    {
        "script" => Target?.Replace('\\', '/').Split('/')[^1] ?? "Python 脚本",
        "module" => "-m " + Target,
        "inline" => "-c 代码",
        "stdin" => "标准输入",
        "interactive" => "交互解释器",
        _ => "启动信息暂不可用"
    };
}

internal static class PythonProcessLaunch
{
    public static bool IsPython(string? name) => name is not null
        && Regex.IsMatch(name, @"\Apython(?:w)?(?:[0-9]+(?:\.[0-9]+)*t?)?\z", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern SafeProcessHandle OpenProcess(uint access, [MarshalAs(UnmanagedType.Bool)] bool inherit, int pid);
    [DllImport("shell32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr CommandLineToArgvW(string commandLine, out int count);
    [DllImport("kernel32.dll")]
    private static extern IntPtr LocalFree(IntPtr memory);
    [UnmanagedFunctionPointer(CallingConvention.Winapi)]
    private delegate int QueryProcess(SafeProcessHandle process, int informationClass, IntPtr buffer, int size, out int required);

    public static ProcessLaunch? Read(int pid, string? name)
    {
        if (!IsPython(name)) return null;
        var command = ReadCommandLine(pid);
        return command is null ? new("unavailable") : Parse(command);
    }

    internal static string? ReadCommandLine(int pid)
    {
        using var process = OpenProcess(0x1000, false, pid); // QUERY_LIMITED_INFORMATION
        if (process.IsInvalid) return null;
        if (!NativeLibrary.TryLoad("ntdll.dll", typeof(PythonProcessLaunch).Assembly, DllImportSearchPath.System32, out var library)) return null;
        try
        {
            if (!NativeLibrary.TryGetExport(library, "NtQueryInformationProcess", out var address)) return null;
            var query = Marshal.GetDelegateForFunctionPointer<QueryProcess>(address);
            // ProcessCommandLineInformation (60) returns a self-contained UNICODE_STRING.
            // It can be unavailable or denied; never elevate or read other process memory.
            query(process, 60, IntPtr.Zero, 0, out var size);
            for (var attempt = 0; attempt < 3; attempt++)
            {
                if (size < Marshal.SizeOf<ProcessSnapshot.UnicodeString>() || size > 128 * 1024) return null;
                var allocated = size;
                var buffer = Marshal.AllocHGlobal(allocated);
                try
                {
                    var status = query(process, 60, buffer, allocated, out size);
                    if (status == unchecked((int)0xC0000004) || status == unchecked((int)0xC0000023)) continue;
                    if (status < 0 || size > allocated) return null;
                    var value = Marshal.PtrToStructure<ProcessSnapshot.UnicodeString>(buffer);
                    var offset = value.Buffer.ToInt64() - buffer.ToInt64();
                    if (value.Length == 0 || (value.Length & 1) != 0 || value.Length > value.MaximumLength
                        || offset < 0 || offset > allocated - value.Length) return null;
                    return Marshal.PtrToStringUni(value.Buffer, value.Length / 2);
                }
                finally { Marshal.FreeHGlobal(buffer); }
            }
            return null;
        }
        finally { NativeLibrary.Free(library); }
    }

    // Return only the entry point, never script arguments, inline code or environment.
    internal static ProcessLaunch Parse(string commandLine)
    {
        if (string.IsNullOrWhiteSpace(commandLine) || commandLine.Length > 65536) return new("unavailable");
        var argv = CommandLineToArgvW(commandLine, out var count);
        if (argv == IntPtr.Zero) return new("unavailable");
        try
        {
            string Arg(int index) => Marshal.PtrToStringUni(Marshal.ReadIntPtr(argv, index * IntPtr.Size)) ?? "";
            ProcessLaunch Target(string kind, string value) => !string.IsNullOrWhiteSpace(value) && value.Length <= 2048
                && value.IndexOfAny(['\r', '\n', '\0']) < 0 ? new(kind, value) : new("unavailable");
            for (var i = 1; i < count; i++)
            {
                var arg = Arg(i);
                if (arg == "-m") return i + 1 < count ? Target("module", Arg(i + 1)) : new("unavailable");
                if (arg.StartsWith("-m", StringComparison.Ordinal) && arg.Length > 2) return Target("module", arg[2..]);
                if (arg.StartsWith("-c", StringComparison.Ordinal)) return new("inline");
                if (arg == "-") return new("stdin");
                if (arg == "--") return i + 1 < count ? Target("script", Arg(i + 1)) : new("interactive");
                if (arg is "-W" or "-X" or "--check-hash-based-pycs")
                {
                    if (++i >= count) return new("unavailable");
                    continue;
                }
                if (arg.StartsWith("-W", StringComparison.Ordinal) || arg.StartsWith("-X", StringComparison.Ordinal)
                    || arg.StartsWith("--check-hash-based-pycs=", StringComparison.Ordinal)) continue;
                if (arg.StartsWith('-'))
                {
                    if (arg.Length > 1 && Regex.IsMatch(arg[1..], "\\A[bBdEhiIOPqRsSuvVx]+\\z")) continue;
                    return new("unavailable");
                }
                return Target("script", arg);
            }
            return new("interactive");
        }
        finally { LocalFree(argv); }
    }
}
