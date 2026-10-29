using System;
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
        try { SampleTime.Text = "正在采样…"; Display(await metrics.SampleAsync(lifetime.Token)); }
        catch (OperationCanceledException) { }
        catch (Exception error) { SampleTime.Text = "采样失败：" + error.Message; }
        finally { Refresh.IsEnabled = true; }
    }
    public void Dispose() { lifetime.Cancel(); lifetime.Dispose(); }
}
