using System;
using System.IO;
using System.IO.Compression;
using System.Text;
using Hako.Core;

namespace Hako.Platform;

// Read the binary manifest locally; Android's package installer remains the
// authority for signature verification. No uninstall/downgrade flags are used.
internal static class AndroidApk
{
    internal sealed record Metadata(string PackageName, long VersionCode);
    internal static Metadata Read(string path)
    {
        using var zip = ZipFile.OpenRead(path);
        var entry = zip.GetEntry("AndroidManifest.xml") ?? throw Invalid();
        if (entry.Length is < 8 or > 4 * 1024 * 1024) throw Invalid();
        using var input = entry.Open(); using var bytes = new MemoryStream(); input.CopyTo(bytes);
        var data = bytes.ToArray(); string[] strings = [];
        int I(int p) { if (p < 0 || p + 4 > data.Length) throw Invalid(); return BitConverter.ToInt32(data, p); }
        int H(int p) { if (p < 0 || p + 2 > data.Length) throw Invalid(); return BitConverter.ToUInt16(data, p); }
        string S(int n) => n >= 0 && n < strings.Length ? strings[n] : throw Invalid();
        int Length8(ref int p) { if (p >= data.Length) throw Invalid(); var n = data[p++]; return (n & 128) == 0 ? n : ((n & 127) << 8) | data[p++]; }
        int Length16(ref int p) { var n = H(p); p += 2; if ((n & 32768) == 0) return n; var low = H(p); p += 2; return ((n & 32767) << 16) | low; }
        if (H(0) != 3) throw Invalid();
        for (var offset = H(2); offset + 8 <= data.Length;)
        {
            var type = H(offset); var header = H(offset + 2); var size = I(offset + 4);
            if (header < 8 || size < header || size > data.Length - offset) throw Invalid();
            if (type == 1)
            {
                var count = I(offset + 8); if (count is < 1 or > 100000) throw Invalid();
                var utf8 = (I(offset + 16) & 256) != 0; var start = offset + I(offset + 20);
                strings = new string[count];
                for (var n = 0; n < count; n++)
                {
                    var p = checked(start + I(offset + header + n * 4));
                    if (utf8) { _ = Length8(ref p); var length = Length8(ref p); if (p + length > data.Length) throw Invalid(); strings[n] = Encoding.UTF8.GetString(data, p, length); }
                    else { var length = checked(Length16(ref p) * 2); if (p + length > data.Length) throw Invalid(); strings[n] = Encoding.Unicode.GetString(data, p, length); }
                }
            }
            if (type == 0x102 && S(I(offset + 20)) == "manifest")
            {
                var start = offset + 16 + H(offset + 24); var stride = H(offset + 26); var count = H(offset + 28);
                if (stride < 20 || count > 1000) throw Invalid();
                string? package = null; long version = -1; uint major = 0;
                for (var n = 0; n < count; n++)
                {
                    var p = checked(start + n * stride); if (p + 20 > offset + size) throw Invalid();
                    var name = S(I(p + 4)); var raw = I(p + 8); var kind = data[p + 15]; var value = I(p + 16);
                    if (name == "package") package = S(raw >= 0 ? raw : value);
                    if (name == "versionCode") version = kind is 16 or 17 ? (uint)value : long.Parse(S(raw >= 0 ? raw : value), System.Globalization.CultureInfo.InvariantCulture);
                    if (name == "versionCodeMajor" && kind is 16 or 17) major = (uint)value;
                }
                if (package != "me.stackli.doppel" || version < 0 || major > int.MaxValue) throw Invalid();
                return new(package, ((long)major << 32) | version);
            }
            offset += size;
        }
        throw Invalid();
    }
    private static AgentActionException Invalid() => new("invalid_apk", "APK 无效或包名不是 Nami（me.stackli.doppel）。");
}
