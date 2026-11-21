using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;

namespace Hako.Core;

internal enum CodexWriterState { Free, Held, Unknown }

internal static class CodexWriterLock
{
    // Inspect the existing byte lock, not the existence or age of its file.
    // Never create/truncate the lock file or resume the thread to test ownership.
    internal static CodexWriterState Read(string home, string thread)
    {
        if (!Guid.TryParse(thread, out var id)) return CodexWriterState.Unknown;
        try
        {
            using var file = new FileStream(Path.Combine(home, "thread-writer-locks", id.ToString("D") + ".lock"),
                FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            var overlap = new NativeOverlapped();
            if (!LockFileEx(file.SafeFileHandle.DangerousGetHandle(), 3, 0, 1, 0, ref overlap))
                return Marshal.GetLastWin32Error() == 33 ? CodexWriterState.Held : CodexWriterState.Unknown;
            return UnlockFileEx(file.SafeFileHandle.DangerousGetHandle(), 0, 1, 0, ref overlap)
                ? CodexWriterState.Free : CodexWriterState.Unknown;
        }
        catch (Exception error) when (error is FileNotFoundException or DirectoryNotFoundException) { return CodexWriterState.Free; }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or DllNotFoundException or EntryPointNotFoundException)
        { return CodexWriterState.Unknown; }
    }

    [DllImport("kernel32", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool LockFileEx(IntPtr handle, uint flags, uint reserved, uint low, uint high, ref NativeOverlapped overlap);
    [DllImport("kernel32", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool UnlockFileEx(IntPtr handle, uint reserved, uint low, uint high, ref NativeOverlapped overlap);
}
