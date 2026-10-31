using System;
using System.Linq;
using System.Threading;
using System.Windows;
using System.Windows.Controls;
using Hako.Platform;

namespace Hako.Features.SystemMonitor;

public partial class MonitorView : UserControl, IDisposable
{
    private readonly SystemMetrics metrics;
    private readonly CancellationTokenSource lifetime = new();
    public MonitorView(SystemMetrics metrics) { InitializeComponent(); this.metrics = metrics; }
    public void Display(Metrics value)
    {
        Cpu.Text = $"{value.CpuUsagePercent:F1}%";
        Memory.Text = $"{value.MemoryUsagePercent:F1}%";
        MemorySize.Text = $"{value.MemoryUsedBytes / 1073741824.0:F1} / {value.MemoryTotalBytes / 1073741824.0:F1} GiB";
        var network = value.Network;
        NetworkRate.Text = network?.Available == true
            ? $"↓ {NetworkTraffic.FormatRate(network.DownloadBytesPerSecond)}   ↑ {NetworkTraffic.FormatRate(network.UploadBytesPerSecond)}" : "—";
        NetworkScope.Text = network?.Available == true ? $"{network.InterfaceCount} 个物理网卡合计，含局域网流量"
            : network?.Message ?? "网络速率暂不可用";
        SampleTime.Text = $"采样于 {DateTimeOffset.Parse(value.SampledAt).ToLocalTime():yyyy-MM-dd HH:mm:ss} · 窗口 {value.SampleWindowMs} ms";
    }
    private async void RefreshClick(object sender, RoutedEventArgs e)
    {
        Refresh.IsEnabled = false;
        try
        {
            SampleTime.Text = "正在采样…";
            try { Display(await metrics.SampleAsync(lifetime.Token)); }
            catch (Exception error) when (error is not OperationCanceledException)
            { SampleTime.Text = "系统指标采样失败：" + error.Message; }
            ListenerStatus.Text = "正在读取监听端口…";
            var listeners = await new NetworkListeners().ReadAsync(lifetime.Token);
            ListenerPorts.ItemsSource = listeners.Ports.Select(port => new
            {
                Title = $"{port.Protocol} {port.Port} · " + string.Join("、", port.Processes.Select(process => process.ProcessName ?? $"PID {process.ProcessId}")),
                Detail = string.Join("\n\n", port.Processes.Select(process =>
                    $"进程：{process.ProcessName ?? "暂不可用"} · PID {process.ProcessId}\n" +
                    $"启动时间：{(process.StartedAt is { } at ? DateTimeOffset.Parse(at).ToLocalTime().ToString("yyyy-MM-dd HH:mm:ss") : "暂不可用")}\n" +
                    $"运行时长：{(process.UptimeSeconds is { } seconds ? FormatUptime(seconds) : "暂不可用")}\n" +
                    "监听 IP：" + string.Join("、", process.Addresses)))
            }).ToArray();
            ListenerStatus.Text = $"{listeners.Ports.Length} 个端口 · {DateTimeOffset.Parse(listeners.CollectedAt).ToLocalTime():HH:mm:ss} 采集\n" +
                "同协议同端口合并 IP；UDP 显示绑定端口；运行时长为采集时的进程存活时间。" +
                (listeners.Warnings.Length == 0 ? "" : "\n" + string.Join("\n", listeners.Warnings));
        }
        catch (OperationCanceledException) { }
        catch (Exception error) { ListenerStatus.Text = "刷新失败（保留上次结果）：" + error.Message; }
        finally { Refresh.IsEnabled = true; }
    }
    private static string FormatUptime(long seconds)
    {
        var time = TimeSpan.FromSeconds(seconds);
        return $"{time.Days} 天 {time.Hours} 小时 {time.Minutes} 分 {time.Seconds} 秒";
    }
    public void Dispose() { lifetime.Cancel(); lifetime.Dispose(); }
}
