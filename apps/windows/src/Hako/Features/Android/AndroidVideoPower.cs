using System;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using Hako.Core;

namespace Hako.Platform;

internal static class AndroidVideoPower
{
    internal static async Task SetAsync(IAndroidAdb adb, AndroidEndpoint endpoint, bool awake)
    {
        using var budget = new CancellationTokenSource(TimeSpan.FromSeconds(8));
        async Task<bool> Matches()
        {
            var display = Encoding.UTF8.GetString(await adb.RunAsync(["-t", endpoint.TransportId, "shell", "dumpsys display"], budget.Token));
            var state = Regex.Match(display, @"mScreenState=(OFF|ON|DOZE_SUSPEND|DOZE|ON_SUSPEND|VR)\b").Groups[1].Value;
            return awake ? state is "ON" or "ON_SUSPEND" or "VR" : state is "OFF" or "DOZE" or "DOZE_SUSPEND";
        }
        try
        {
            if (await Matches()) return;
            await adb.RunAsync(["-t", endpoint.TransportId, "shell", "input", "keyevent", awake ? "224" : "223"], budget.Token);
            while (!await Matches()) await Task.Delay(150, budget.Token);
        }
        catch (Exception error)
        {
            throw new AgentActionException(awake ? "screen_wake_failed" : "screen_sleep_failed",
                (awake ? "自动亮屏未成功" : "自动息屏未成功") + "，请检查 ADB 连接及手机的「USB 调试（安全设置）」授权。" +
                (error is OperationCanceledException ? "屏幕状态回查超时。" : ""));
        }
    }
}
