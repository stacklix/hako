using System;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using Hako.Core;

namespace Hako.Platform;

internal static class AndroidVideoPower
{
    internal static bool? State(string display, string power = "")
    {
        var state = Regex.Match(display, @"mScreenState=(OFF|ON|DOZE_SUSPEND|DOZE|ON_SUSPEND|VR)\b").Groups[1].Value;
        if (state.Length > 0) return state is "ON" or "ON_SUSPEND" or "VR";
        var legacy = Regex.Match(power, @"mScreenOn=(true|false)\b").Groups[1].Value;
        if (legacy.Length > 0) return legacy == "true";
        return null;
    }
    internal static async Task SetAsync(IAndroidAdb adb, AndroidEndpoint endpoint, bool awake)
    {
        using var budget = new CancellationTokenSource(TimeSpan.FromSeconds(8));
        var legacy = false;
        async Task<bool> ReadState()
        {
            var display = Encoding.UTF8.GetString(await adb.RunAsync(["-t", endpoint.TransportId, "shell", "dumpsys display"], budget.Token));
            if (State(display) is { } current) return current;
            var power = Encoding.UTF8.GetString(await adb.RunAsync(["-t", endpoint.TransportId, "shell", "dumpsys power"], budget.Token));
            legacy = true;
            return State(display, power) ?? throw new InvalidOperationException("无法确认设备屏幕状态。");
        }
        try
        {
            if (await ReadState() == awake) return;
            // KitKat has no reliable dedicated wake/sleep keys. Toggle once only
            // after confirming the opposite state; never toggle while state is unknown.
            await adb.RunAsync(["-t", endpoint.TransportId, "shell", "input", "keyevent", legacy ? "26" : awake ? "224" : "223"], budget.Token);
            while (await ReadState() != awake) await Task.Delay(150, budget.Token);
        }
        catch (Exception error)
        {
            throw new AgentActionException(awake ? "screen_wake_failed" : "screen_sleep_failed",
                (awake ? "自动亮屏未成功" : "自动息屏未成功") + "，请检查 ADB 连接及手机的「USB 调试（安全设置）」授权。" +
                (error is OperationCanceledException ? "屏幕状态回查超时。" : ""));
        }
    }
}
