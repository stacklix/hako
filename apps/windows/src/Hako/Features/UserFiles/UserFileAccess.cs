using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
using Hako.Core;

namespace Hako.Platform;

// Pin every ancestor without FILE_SHARE_DELETE. All leaf handles are opened with
// OPEN_REPARSE_POINT, inspected, and used directly rather than reopening a path.
internal sealed class UserFileAccess : IDisposable
{
    private readonly List<SafeFileHandle> directories = new();
    internal string Target { get; }
    internal bool IsRoot { get; }
    internal UserFileAccess(string root, string relative, bool directory = false)
    {
        var parts = Parts(relative);
        root = Path.TrimEndingDirectorySeparator(Path.GetFullPath(root));
        Target = parts.Aggregate(root, (current, part) => Path.Combine(current, part)); IsRoot = parts.Length == 0;
        try
        {
            var drive = Path.GetPathRoot(root)!;
            var current = drive;
            Pin(current);
            foreach (var part in root[drive.Length..].Split(Path.DirectorySeparatorChar, StringSplitOptions.RemoveEmptyEntries))
            { current = Path.Combine(current, part); Pin(current); }
            foreach (var part in parts.Take(directory ? parts.Length : Math.Max(0, parts.Length - 1)))
            { current = Path.Combine(current, part); Pin(current); }
            var canonical = new System.Text.StringBuilder(32768);
            var length = GetFinalPathNameByHandle(directories[^1], canonical, (uint)canonical.Capacity, 0);
            if (length == 0 || length >= canonical.Capacity) throw new Win32Exception(Marshal.GetLastWin32Error());
            var parent = canonical.ToString();
            if (parent.StartsWith("\\\\?\\UNC\\", StringComparison.OrdinalIgnoreCase)) parent = "\\\\" + parent[8..];
            else if (parent.StartsWith("\\\\?\\", StringComparison.Ordinal)) parent = parent[4..];
            Target = directory || IsRoot ? parent : Path.Combine(parent, parts[^1]);
        }
        catch { Dispose(); throw; }
    }
    internal static string[] Parts(string relative)
    {
        if (relative.Length > 2048 || relative.Contains('\\') || Path.IsPathRooted(relative)) throw Invalid();
        if (relative.Length == 0) return [];
        var parts = relative.Split('/');
        foreach (var part in parts) ValidateName(part);
        return parts;
    }
    internal static void ValidateName(string part)
    {
        var stem = part.Split('.')[0].TrimEnd(' ').ToUpperInvariant();
        if (part.Length is 0 or > 255 || part is "." or ".." || part.EndsWith('.') || part.EndsWith(' ')
            || part.IndexOfAny(Path.GetInvalidFileNameChars()) >= 0 || part.Contains('/')
            || stem is "CON" or "PRN" or "AUX" or "NUL" or "CONIN$" or "CONOUT$"
            || stem.Length == 4 && (stem.StartsWith("COM", StringComparison.Ordinal) || stem.StartsWith("LPT", StringComparison.Ordinal))
                && "123456789¹²³".Contains(stem[3])) throw Invalid();
    }
    private void Pin(string path) { var handle = Open(path, 0x81, out var info); if (!info.Directory) { handle.Dispose(); throw Invalid(); } directories.Add(handle); }
    internal static AgentActionException Invalid() => new("invalid_params", "文件路径或名称无效，只能使用用户目录中的相对路径。");
    internal static SafeFileHandle Open(string path, uint access, out Info info, uint creation = 3, uint share = 3)
    {
        var handle = CreateFile(path, access, share, IntPtr.Zero, creation, 0x02200000, IntPtr.Zero);
        if (handle.IsInvalid) { var error = Marshal.GetLastWin32Error(); handle.Dispose(); throw new Win32Exception(error); }
        try
        {
            if (!GetFileInformationByHandle(handle, out info)) throw new Win32Exception(Marshal.GetLastWin32Error());
            if ((info.Attributes & (uint)FileAttributes.ReparsePoint) != 0 || !info.Directory && info.Links > 1)
                throw new AgentActionException("file_link", "链接文件和链接目录不可访问或修改，以免操作用户目录以外的文件。");
            return handle;
        }
        catch { handle.Dispose(); throw; }
    }
    internal static void Delete(SafeFileHandle handle)
    {
        var value = Marshal.AllocHGlobal(4);
        try { Marshal.WriteInt32(value, 1); if (!SetFileInformationByHandle(handle, 4, value, 4)) throw new Win32Exception(Marshal.GetLastWin32Error()); }
        finally { Marshal.FreeHGlobal(value); }
    }
    internal static void Rename(SafeFileHandle handle, string destination, bool replace = false)
    {
        var bytes = System.Text.Encoding.Unicode.GetBytes(destination);
        var rootOffset = IntPtr.Size == 8 ? 8 : 4;
        var nameLengthOffset = rootOffset + IntPtr.Size;
        var nameOffset = nameLengthOffset + 4;
        var buffer = Marshal.AllocHGlobal(nameOffset + bytes.Length + 2);
        try
        {
            for (var i = 0; i < nameOffset; i++) Marshal.WriteByte(buffer, i, 0);
            // POSIX replacement keeps existing readers on the old file while
            // new opens immediately see the verified replacement.
            Marshal.WriteInt32(buffer, replace ? 3 : 0);
            Marshal.WriteInt32(buffer, nameLengthOffset, bytes.Length);
            Marshal.Copy(bytes, 0, IntPtr.Add(buffer, nameOffset), bytes.Length);
            Marshal.WriteInt16(buffer, nameOffset + bytes.Length, 0);
            if (!SetFileInformationByHandle(handle, 22, buffer, (uint)(nameOffset + bytes.Length + 2))) throw new Win32Exception(Marshal.GetLastWin32Error());
        }
        finally { Marshal.FreeHGlobal(buffer); }
    }
    internal static void PreserveMetadata(SafeFileHandle source, SafeFileHandle target, Info info)
    {
        // Keep private files private when replacing them with an atomic save.
        var error = GetSecurityInfo(source, 1, 4, out _, out _, out var dacl, out _, out var security);
        if (error != 0) throw new Win32Exception((int)error);
        try
        {
            if (!GetSecurityDescriptorControl(security, out var control, out _)) throw new Win32Exception(Marshal.GetLastWin32Error());
            error = SetSecurityInfo(target, 1, 4u | ((control & 0x1000) != 0 ? 0x80000000u : 0x20000000u), IntPtr.Zero, IntPtr.Zero, dacl, IntPtr.Zero);
            if (error != 0) throw new Win32Exception((int)error);
        }
        finally { LocalFree(security); }
        var basic = Marshal.AllocHGlobal(40);
        try
        {
            for (var i = 0; i < 40; i++) Marshal.WriteByte(basic, i, 0);
            Marshal.WriteInt64(basic, ((long)(uint)info.Created.dwHighDateTime << 32) | (uint)info.Created.dwLowDateTime);
            var attributes = info.Attributes & (uint)(FileAttributes.Hidden | FileAttributes.System | FileAttributes.Archive | FileAttributes.NotContentIndexed);
            Marshal.WriteInt32(basic, 32, (int)(attributes == 0 ? (uint)FileAttributes.Normal : attributes));
            if (!SetFileInformationByHandle(target, 0, basic, 40)) throw new Win32Exception(Marshal.GetLastWin32Error());
        }
        finally { Marshal.FreeHGlobal(basic); }
    }
    public void Dispose() { for (var i = directories.Count - 1; i >= 0; i--) directories[i].Dispose(); directories.Clear(); }
    [StructLayout(LayoutKind.Sequential)]
    internal struct Info
    {
        internal uint Attributes;
        internal System.Runtime.InteropServices.ComTypes.FILETIME Created, Accessed, Written;
        internal uint Volume, SizeHigh, SizeLow, Links, IndexHigh, IndexLow;
        internal readonly bool Directory => (Attributes & (uint)FileAttributes.Directory) != 0;
        internal readonly long Size => ((long)SizeHigh << 32) | SizeLow;
    }
    [DllImport("kernel32.dll", EntryPoint = "CreateFileW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern SafeFileHandle CreateFile(string path, uint access, uint share, IntPtr security, uint creation, uint flags, IntPtr template);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetFileInformationByHandle(SafeFileHandle file, out Info info);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool SetFileInformationByHandle(SafeFileHandle file, int kind, IntPtr info, uint size);
    [DllImport("kernel32.dll", EntryPoint = "GetFinalPathNameByHandleW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern uint GetFinalPathNameByHandle(SafeFileHandle file, System.Text.StringBuilder path, uint length, uint flags);
    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern uint GetSecurityInfo(SafeFileHandle handle, int type, uint information, out IntPtr owner, out IntPtr group, out IntPtr dacl, out IntPtr sacl, out IntPtr descriptor);
    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern bool GetSecurityDescriptorControl(IntPtr descriptor, out ushort control, out uint revision);
    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern uint SetSecurityInfo(SafeFileHandle handle, int type, uint information, IntPtr owner, IntPtr group, IntPtr dacl, IntPtr sacl);
    [DllImport("kernel32.dll")]
    private static extern IntPtr LocalFree(IntPtr memory);
}
