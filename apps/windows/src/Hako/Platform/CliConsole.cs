using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using Hako.Core;

namespace Hako.Platform;

public static class CliConsole
{
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool AttachConsole(uint processId);
    [DllImport("kernel32.dll")] private static extern IntPtr GetStdHandle(int handle);
    [DllImport("kernel32.dll")] private static extern uint GetFileType(IntPtr handle);
    [DllImport("kernel32.dll")] private static extern bool GetConsoleMode(IntPtr handle, out uint mode);
    [DllImport("kernel32.dll")] private static extern bool SetStdHandle(int handle, IntPtr value);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool GetHandleInformation(IntPtr handle, out uint flags);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool SetHandleInformation(IntPtr handle, uint mask, uint flags);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] private static extern bool WriteConsoleW(IntPtr handle, string text, uint length, out uint written, IntPtr reserved);
    public static void Initialize()
    {
        var output = GetStdHandle(-11); var error = GetStdHandle(-12);
        bool errorValid = error != IntPtr.Zero && error != new IntPtr(-1) && GetFileType(error) != 0;
        if (output == IntPtr.Zero || output == new IntPtr(-1) || GetFileType(output) == 0)
        {
            _ = AttachConsole(uint.MaxValue);
            if (errorValid) SetStdHandle(-12, error);
        }
    }
    public static void Write(CommandReply reply, bool json)
    {
        var text = (json ? reply.ToJson() : reply.Text) + Environment.NewLine;
        bool error = !json && reply.ExitCode != 0;
        var handle = GetStdHandle(error ? -12 : -11);
        if (GetConsoleMode(handle, out _)) { WriteConsoleW(handle, text, (uint)text.Length, out _, IntPtr.Zero); return; }
        using var stream = error ? Console.OpenStandardError() : Console.OpenStandardOutput();
        using var writer = new StreamWriter(stream, new UTF8Encoding(false));
        writer.Write(text); writer.Flush();
    }
    public static IDisposable PreventStandardHandleInheritance() => new StandardHandleScope();
    private sealed class StandardHandleScope : IDisposable
    {
        private readonly System.Collections.Generic.List<(IntPtr Handle, uint Flags)> handles = new();
        public StandardHandleScope()
        {
            foreach (var standard in new[] { -10, -11, -12 })
            {
                var handle = GetStdHandle(standard);
                if (GetHandleInformation(handle, out var flags) && (flags & 1) != 0)
                {
                    if (!SetHandleInformation(handle, 1, 0)) throw new System.ComponentModel.Win32Exception();
                    handles.Add((handle, flags));
                }
            }
        }
        public void Dispose()
        {
            foreach (var (handle, flags) in handles) SetHandleInformation(handle, 1, flags & 1);
        }
    }
}
