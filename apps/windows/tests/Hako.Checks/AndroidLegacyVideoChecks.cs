using System;
using System.Collections.Generic;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using Hako.Core;
using Hako.Platform;

internal static class AndroidLegacyVideoChecks
{
    private sealed class Adb(bool unknown = false) : IAndroidAdb
    {
        public string? Executable => "fixture";
        internal bool Awake;
        internal readonly List<string> Keys = [];
        public Task<byte[]> RunAsync(string[] args, CancellationToken token, string? input = null, int limit = 2097152)
        {
            if (args[0] != "-t" || args[1] != "19") throw new Exception("Legacy power control changed its pinned endpoint");
            if (args[^2] == "keyevent") {
                Keys.Add(args[^1]);
                if (args[^1] != "26") throw new Exception("Legacy device received an unavailable dedicated power key");
                Awake = !Awake;
            }
            return Task.FromResult(Encoding.UTF8.GetBytes(args[^1] == "dumpsys power" && !unknown
                ? "mWakefulness=" + (Awake ? "Awake" : "Asleep") + "\nmScreenOn=" + (Awake ? "true" : "false")
                : "DisplayDeviceInfo{480 x 854}, mBlanked=true"));
        }
    }
    internal static async Task RunAsync()
    {
        using var resource = typeof(AndroidVideoSource).Assembly.GetManifestResourceStream("Hako.video-api19")
            ?? throw new Exception("Legacy video resource not embedded");
        var hash = Convert.ToHexString(await System.Security.Cryptography.SHA256.HashDataAsync(resource)).ToLowerInvariant();
        if (hash != AndroidVideoSource.LegacySha256) throw new Exception("Legacy encoder integrity mismatch");
        var adb = new Adb(); var endpoint = new AndroidEndpoint("legacy", "19", "usb", "device");
        await AndroidVideoPower.SetAsync(adb, endpoint, true);
        await AndroidVideoPower.SetAsync(adb, endpoint, true);
        await AndroidVideoPower.SetAsync(adb, endpoint, false);
        await AndroidVideoPower.SetAsync(adb, endpoint, false);
        if (adb.Awake || string.Join(",", adb.Keys) != "26,26") throw new Exception("KitKat wake/sleep toggled twice or was skipped");
        var unavailable = new Adb(unknown: true);
        try { await AndroidVideoPower.SetAsync(unavailable, endpoint, true); throw new Exception("Unknown power state allowed a blind toggle"); }
        catch (AgentActionException error) when (error.Code == "screen_wake_failed") { }
        if (unavailable.Keys.Count != 0) throw new Exception("Unknown state sent an unsafe power toggle");
        Console.WriteLine("PASS: API19 encoder integrity, KitKat power state, idempotent confirmed toggles and unknown-state rejection.");
    }
}
