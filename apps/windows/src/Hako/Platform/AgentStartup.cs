using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
using System.Security.Cryptography;
using System.Text;
using Hako.Core;

namespace Hako.Platform;

public sealed class AgentStartup
{
    private readonly string executable;
    private readonly string arguments;
    public string ShortcutPath { get; }
    public bool IsEnabled
    {
        get
        {
            if (!File.Exists(ShortcutPath)) return false;
            var saved = WindowsShortcut.Read(ShortcutPath);
            return string.Equals(saved.Target, executable, StringComparison.OrdinalIgnoreCase) && saved.Arguments == arguments;
        }
    }

    public AgentStartup(string executable, string profileDirectory, string? startupDirectory = null, string? assemblyPath = null)
    {
        this.executable = Path.GetFullPath(executable);
        var profile = Path.TrimEndingDirectorySeparator(Path.GetFullPath(profileDirectory));
        var isDefault = string.Equals(profile, AgentSettingsStore.DefaultDirectory, StringComparison.OrdinalIgnoreCase);
        var suffix = isDefault ? "" : "-" + Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(profile.ToUpperInvariant())))[..12];
        startupDirectory ??= Environment.GetFolderPath(Environment.SpecialFolder.Startup, Environment.SpecialFolderOption.DoNotVerify);
        if (string.IsNullOrWhiteSpace(startupDirectory)) throw new IOException("无法找到当前用户的启动文件夹。");
        ShortcutPath = Path.Combine(Path.GetFullPath(startupDirectory), "Hako Agent" + suffix + ".lnk");
        arguments = assemblyPath is null ? "" : QuotePath(Path.GetFullPath(assemblyPath)) + " ";
        arguments += "--background";
        if (!isDefault) arguments += " --data-dir " + QuotePath(profile);
    }

    public static AgentStartup ForCurrentProcess(string profileDirectory)
    {
        var executable = Environment.ProcessPath ?? throw new IOException("无法找到 Hako 可执行文件。");
        var assembly = string.Equals(Path.GetFileNameWithoutExtension(executable), "dotnet", StringComparison.OrdinalIgnoreCase)
            ? Path.Combine(AppContext.BaseDirectory, "Hako.dll") : null;
        return new AgentStartup(executable, profileDirectory, assemblyPath: assembly);
    }

    public void SetEnabled(bool enabled)
    {
        if (!enabled) { File.Delete(ShortcutPath); return; }
        if (!File.Exists(executable)) throw new FileNotFoundException("Hako 可执行文件已移动，请从新位置打开后重试。", executable);
        var directory = Path.GetDirectoryName(ShortcutPath)!;
        Directory.CreateDirectory(directory);
        var temporary = Path.Combine(directory, "Hako-" + Guid.NewGuid().ToString("N") + ".lnk");
        try
        {
            WindowsShortcut.Save(temporary, executable, arguments);
            File.Move(temporary, ShortcutPath, overwrite: true);
        }
        finally
        {
            if (File.Exists(temporary)) File.Delete(temporary);
        }
    }

    private static string QuotePath(string path)
    {
        // Windows paths cannot contain quotes. Double trailing backslashes before the closing quote.
        return "\"" + path + new string('\\', path.Length - path.TrimEnd('\\').Length) + "\"";
    }
}

internal static class WindowsShortcut
{
    private static object Create() => Activator.CreateInstance(Type.GetTypeFromCLSID(new Guid("00021401-0000-0000-C000-000000000046"), throwOnError: true)!)!;

    internal static void Save(string path, string executable, string arguments)
    {
        var instance = Create();
        try
        {
            var link = (IShellLinkW)instance;
            link.SetPath(executable);
            link.SetArguments(arguments);
            link.SetWorkingDirectory(Path.GetDirectoryName(executable)!);
            link.SetDescription("登录 Windows 后在托盘运行 Hako Agent");
            link.SetIconLocation(executable, 0);
            ((IPersistFile)instance).Save(path, true);
        }
        finally { Marshal.FinalReleaseComObject(instance); }
    }

    internal static (string Target, string Arguments) Read(string path)
    {
        var instance = Create();
        try
        {
            ((IPersistFile)instance).Load(path, 0);
            var link = (IShellLinkW)instance;
            var target = new StringBuilder(32768);
            var arguments = new StringBuilder(32768);
            link.GetPath(target, target.Capacity, IntPtr.Zero, 0);
            link.GetArguments(arguments, arguments.Capacity);
            return (target.ToString(), arguments.ToString());
        }
        finally { Marshal.FinalReleaseComObject(instance); }
    }

    [ComImport, Guid("000214F9-0000-0000-C000-000000000046"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IShellLinkW
    {
        void GetPath([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder path, int count, IntPtr findData, uint flags);
        void GetIDList(out IntPtr list);
        void SetIDList(IntPtr list);
        void GetDescription([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder description, int count);
        void SetDescription([MarshalAs(UnmanagedType.LPWStr)] string description);
        void GetWorkingDirectory([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder directory, int count);
        void SetWorkingDirectory([MarshalAs(UnmanagedType.LPWStr)] string directory);
        void GetArguments([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder arguments, int count);
        void SetArguments([MarshalAs(UnmanagedType.LPWStr)] string arguments);
        void GetHotkey(out short hotkey);
        void SetHotkey(short hotkey);
        void GetShowCmd(out int command);
        void SetShowCmd(int command);
        void GetIconLocation([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder path, int count, out int index);
        void SetIconLocation([MarshalAs(UnmanagedType.LPWStr)] string path, int index);
        void SetRelativePath([MarshalAs(UnmanagedType.LPWStr)] string path, uint reserved);
        void Resolve(IntPtr window, uint flags);
        void SetPath([MarshalAs(UnmanagedType.LPWStr)] string path);
    }
}
