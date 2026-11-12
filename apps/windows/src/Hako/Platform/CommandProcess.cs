using System;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

namespace Hako.Platform;

internal static class DetachedAgentProcess
{
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct StartupInfo
    {
        public int Size;
        public string? Reserved, Desktop, Title;
        public int X, Y, Width, Height, CharactersX, CharactersY, Fill, Flags;
        public short Show, ReservedSize;
        public IntPtr ReservedPointer, Input, Output, Error;
    }
    [StructLayout(LayoutKind.Sequential)]
    private struct ProcessInfo { public IntPtr Process, Thread; public int ProcessId, ThreadId; }
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CreateProcessW(string application, StringBuilder arguments, IntPtr processAttributes,
        IntPtr threadAttributes, bool inherit, uint flags, IntPtr environment, string directory,
        ref StartupInfo startup, out ProcessInfo information);
    [DllImport("kernel32.dll")] private static extern bool CloseHandle(IntPtr handle);

    private static string Quote(string value)
    {
        if (value.Contains('"') || value.Contains('\0')) throw new ArgumentException("Invalid process argument.");
        return "\"" + value + new string('\\', value.Length - value.TrimEnd('\\').Length) + "\"";
    }
    internal static Process Start(string executable, string[] arguments, bool breakAway = false)
    {
        executable = Path.GetFullPath(executable);
        var command = new StringBuilder(Quote(executable));
        foreach (var argument in arguments) command.Append(' ').Append(Quote(argument));
        var startup = new StartupInfo { Size = Marshal.SizeOf<StartupInfo>(), Flags = 1 };
        // Bootstrap has no command job. The restart helper explicitly leaves the
        // command's job, whose BREAKAWAY_OK limit is controlled by this app.
        if (!CreateProcessW(executable, command, IntPtr.Zero, IntPtr.Zero, false, 0x08000000u | (breakAway ? 0x01000000u : 0),
            IntPtr.Zero, Path.GetDirectoryName(executable)!, ref startup, out var process))
            throw new Win32Exception(Marshal.GetLastWin32Error(), "无法启动独立进程。");
        try { return Process.GetProcessById(process.ProcessId); }
        finally { CloseHandle(process.Thread); CloseHandle(process.Process); }
    }
}

internal sealed class CommandProcessJob : IDisposable
{
    [StructLayout(LayoutKind.Sequential)]
    private struct BasicLimits
    {
        public long ProcessTime, JobTime;
        public uint Flags;
        public UIntPtr Minimum, Maximum;
        public uint Active;
        public UIntPtr Affinity;
        public uint Priority, Scheduling;
    }
    [StructLayout(LayoutKind.Sequential)]
    private struct IoCounters { public ulong Read, Write, Other, ReadBytes, WriteBytes, OtherBytes; }
    [StructLayout(LayoutKind.Sequential)]
    private struct Limits
    {
        public BasicLimits Basic;
        public IoCounters Io;
        public UIntPtr ProcessMemory, JobMemory, PeakProcessMemory, PeakJobMemory;
    }
    [DllImport("kernel32.dll", SetLastError = true)] private static extern IntPtr CreateJobObjectW(IntPtr attributes, string? name);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool SetInformationJobObject(IntPtr job, int kind, ref Limits limits, int size);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool TerminateJobObject(IntPtr job, uint exitCode);
    [DllImport("kernel32.dll")] private static extern bool CloseHandle(IntPtr handle);
    private IntPtr handle;
    internal CommandProcessJob(bool allowBackgroundProcesses = false)
    {
        handle = CreateJobObjectW(IntPtr.Zero, null);
        const uint killOnClose = 0x2000, breakaway = 0x0800, silentBreakaway = 0x1000;
        // Keep the submitting shell in the job, while opted-in descendants
        // live independently after that shell exits or is stopped.
        var limits = new Limits { Basic = new BasicLimits {
            Flags = killOnClose | breakaway | (allowBackgroundProcesses ? silentBreakaway : 0) } };
        if (handle == IntPtr.Zero || !SetInformationJobObject(handle, 9, ref limits, Marshal.SizeOf<Limits>()))
        { var error = Marshal.GetLastWin32Error(); Dispose(); throw new Win32Exception(error); }
    }
    internal void Assign(Process process)
    {
        if (!AssignProcessToJobObject(handle, process.Handle)) throw new Win32Exception(Marshal.GetLastWin32Error());
    }
    internal void Stop()
    {
        if (!TerminateJobObject(handle, 1)) throw new Win32Exception(Marshal.GetLastWin32Error());
    }
    public void Dispose() { if (handle != IntPtr.Zero) { CloseHandle(handle); handle = IntPtr.Zero; } }
}
