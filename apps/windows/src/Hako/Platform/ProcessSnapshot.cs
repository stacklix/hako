using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;

namespace Hako.Platform;

// SystemProcessInformation supplies creation times without opening each target
// process. Opening a service process can fail even with QUERY_LIMITED_INFORMATION.
internal static class ProcessSnapshot
{
    [StructLayout(LayoutKind.Sequential)]
    internal struct UnicodeString
    {
        public ushort Length, MaximumLength;
        public IntPtr Buffer;
    }

    // Prefix of the SYSTEM_PROCESS_INFORMATION layout used by the .NET runtime:
    // https://github.com/dotnet/runtime/blob/main/src/libraries/Common/src/Interop/Windows/NtDll/Interop.SYSTEM_PROCESS_INFORMATION.cs
    [StructLayout(LayoutKind.Sequential)]
    internal struct Header
    {
        public uint NextEntryOffset, NumberOfThreads;
        public long Reserved1, Reserved2, Reserved3;
        public long CreateTime, UserTime, KernelTime;
        public UnicodeString ImageName;
        public int BasePriority;
        public IntPtr ProcessId;
        public IntPtr InheritedFromProcessId;
        public uint HandleCount, SessionId;
    }

    [UnmanagedFunctionPointer(CallingConvention.Winapi)]
    private delegate int QueryInformation(int informationClass, IntPtr buffer, uint size, out uint required);

    public static IReadOnlyDictionary<int, NetworkListeners.ProcessInfo>? Capture(CancellationToken token)
    {
        // This native API may change; load dynamically and fall back to individual
        // process reads if unavailable or if the returned layout is invalid.
        if (!NativeLibrary.TryLoad("ntdll.dll", typeof(ProcessSnapshot).Assembly, DllImportSearchPath.System32, out var library))
            return null;
        try
        {
            if (!NativeLibrary.TryGetExport(library, "NtQuerySystemInformation", out var address)) return null;
            var query = Marshal.GetDelegateForFunctionPointer<QueryInformation>(address);
            var size = 256 * 1024;
            for (var attempt = 0; attempt < 8; attempt++)
            {
                token.ThrowIfCancellationRequested();
                if (size > 64 * 1024 * 1024) return null;
                var buffer = Marshal.AllocHGlobal(size);
                try
                {
                    var status = query(5, buffer, (uint)size, out var required);
                    if (status == unchecked((int)0xC0000004) || status == unchecked((int)0xC0000023))
                    {
                        if (required > 64 * 1024 * 1024) return null;
                        size = Math.Max(size * 2, checked((int)required + 65536));
                        continue;
                    }
                    if (status < 0 || required > size || required < Marshal.SizeOf<Header>()) return null;
                    try { return Parse(buffer, (int)required, token); }
                    catch (InvalidDataException) { return null; }
                }
                finally { Marshal.FreeHGlobal(buffer); }
            }
            return null;
        }
        finally { NativeLibrary.Free(library); }
    }

    internal static IReadOnlyDictionary<int, NetworkListeners.ProcessInfo> Parse(IntPtr buffer, int length, CancellationToken token)
    {
        var processes = new Dictionary<int, NetworkListeners.ProcessInfo>();
        var headerSize = Marshal.SizeOf<Header>();
        var offset = 0;
        while (true)
        {
            token.ThrowIfCancellationRequested();
            if (offset < 0 || offset > length - headerSize) throw new InvalidDataException("进程快照边界无效。");
            var header = Marshal.PtrToStructure<Header>(IntPtr.Add(buffer, offset));
            var remaining = length - offset;
            if (header.NextEntryOffset != 0 && (header.NextEntryOffset < headerSize || header.NextEntryOffset > remaining - headerSize))
                throw new InvalidDataException("进程快照偏移无效。");
            var pid = header.ProcessId.ToInt64();
            if (pid > 0 && pid <= int.MaxValue)
            {
                string? name = null;
                var nameLength = header.ImageName.Length;
                if (nameLength > 0)
                {
                    var nameOffset = header.ImageName.Buffer.ToInt64() - buffer.ToInt64();
                    if ((nameLength & 1) != 0 || nameLength > header.ImageName.MaximumLength || nameOffset < 0 || nameOffset > length - nameLength)
                        throw new InvalidDataException("进程快照名称无效。");
                    name = Marshal.PtrToStringUni(header.ImageName.Buffer, nameLength / 2);
                    // Match Process.ProcessName, preserving dots within the name.
                    if (name?.EndsWith(".exe", StringComparison.OrdinalIgnoreCase) == true) name = name[..^4];
                }
                DateTimeOffset? started = null;
                if (header.CreateTime > 0)
                {
                    try { started = new DateTimeOffset(DateTime.FromFileTimeUtc(header.CreateTime)); }
                    catch (ArgumentOutOfRangeException) { throw new InvalidDataException("进程快照时间无效。"); }
                }
                if (header.SessionId > int.MaxValue) throw new InvalidDataException("进程快照会话无效。");
                if (!processes.TryAdd((int)pid, new(name, started, (int)header.SessionId))) throw new InvalidDataException("进程快照 PID 重复。");
            }
            if (header.NextEntryOffset == 0) break;
            offset += (int)header.NextEntryOffset;
        }
        return processes;
    }
}
