using System;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using Hako.Platform;
using Hako.Core;

namespace Hako.Features.SystemMonitor;

public partial class MonitorView : UserControl, IDisposable
{
    private readonly SystemMetrics metrics;
    private readonly GuardianConnection guardian;
    private readonly CancellationTokenSource lifetime = new();
    public MonitorView(SystemMetrics metrics, GuardianConnection guardian) { InitializeComponent(); this.metrics = metrics; this.guardian = guardian; }
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
            var systemPorts = listeners.PortsForCategory("system");
            var userPorts = listeners.PortsForCategory("user");
            ListenerPorts.ItemsSource = PortRows(systemPorts);
            UserListenerPorts.ItemsSource = PortRows(userPorts);
            SystemListenerTab.Header = $"系统 ({systemPorts.Length})";
            UserListenerTab.Header = $"用户 ({userPorts.Length})";
            SystemListenerEmpty.Text = systemPorts.Length == 0 ? "暂无系统监听端口" : "";
            UserListenerEmpty.Text = userPorts.Length == 0 ? "暂无用户监听端口" : "";
            ListenerStatus.Text = $"{listeners.Ports.Length} 个端口 · {DateTimeOffset.Parse(listeners.CollectedAt).ToLocalTime():HH:mm:ss} 采集\n" +
                "Windows 自带程序归系统，第三方程序及其后台服务归用户。\n" +
                "同协议同端口合并 IP；UDP 显示绑定端口；运行时长为采集时的进程存活时间。" +
                (listeners.Warnings.Length == 0 ? "" : "\n" + string.Join("\n", listeners.Warnings));
        }
        catch (OperationCanceledException) { }
        catch (Exception error) { ListenerStatus.Text = "刷新失败（保留上次结果）：" + error.Message; }
        finally { Refresh.IsEnabled = true; }
    }
    private static object[] PortRows(ListenerPort[] ports) => ports.Select(port => (object)new
    {
        Title = $"{port.Protocol} {port.Port} · " + string.Join("、", port.Processes.Select(process => process.DisplayName)),
        Detail = string.Join("\n\n", port.Processes.Select(process =>
            $"进程：{process.ProcessName ?? "暂不可用"} · PID {process.ProcessId}\n" +
            (process.Launch is { } launch ? $"启动项：{launch.Summary}\n" + (launch.Target is { } target ? $"{(launch.Kind == "script" ? "脚本路径" : "模块名称")}：{target}\n" : "") : "") +
            (process.Category is null ? "分类暂不可用\n" : "") +
            $"启动时间：{(process.StartedAt is { } at ? DateTimeOffset.Parse(at).ToLocalTime().ToString("yyyy-MM-dd HH:mm:ss") : "暂不可用")}\n" +
            $"运行时长：{(process.UptimeSeconds is { } seconds ? FormatUptime(seconds) : "暂不可用")}\n" +
            "监听 IP：" + string.Join("、", process.Addresses)))
    }).ToArray();
    private static string FormatUptime(long seconds)
    {
        var time = TimeSpan.FromSeconds(seconds);
        return $"{time.Days} 天 {time.Hours} 小时 {time.Minutes} 分 {time.Seconds} 秒";
    }
    private async void ServicesLoaded(object sender, RoutedEventArgs e) => await ReadServicesAsync();
    private async void RefreshServicesClick(object sender, RoutedEventArgs e) => await ReadServicesAsync();
    private async Task ReadServicesAsync()
    {
        if (!RefreshServices.IsEnabled) return;
        RefreshServices.IsEnabled = false;
        ServiceStatus.Text = "正在检查登记服务…";
        try
        {
            var snapshot = await guardian.AdminAsync<RegisteredServiceSnapshot>(RegisteredServices.Command, new { }, lifetime.Token);
            Services.ItemsSource = snapshot.Services.Select(service => new
            {
                service.Name, service.CanStart,
                Title = $"{service.Name} · {service.Port} · {ServiceState(service.Status)}" +
                    (service.Http?.StatusCode is int code ? $" · HTTP {code} · {service.Http.ElapsedMs} ms" : ""),
                Detail = (service.Description is { Length: > 0 } description ? description + "\n" : "") +
                    (service.Startup is { } startup && service.Status == "stopped" ? startup.Message + "\n" : "") +
                    (!service.CanStart && service.Status == "stopped" && service.Startup is null ? "尚未登记 startCommand 启动命令。\n" : "") +
                    (service.Http is { } http ? $"探测地址：{http.Url}\n" + (http.Failure is { } failure ? failure + "\n" : "") : "") +
                    string.Join("\n", service.Processes.Select(process =>
                        $"监听进程：{process.DisplayName} · PID {process.ProcessId}\n" +
                        $"运行时长：{(process.UptimeSeconds is { } seconds ? FormatUptime(seconds) : "暂不可用")}\n" +
                        "监听 IP：" + string.Join("、", process.Addresses)))
            }).ToArray();
            ServiceStatus.Text = snapshot.Services.Length == 0 ? "尚未登记服务。" :
                $"{snapshot.Services.Length} 个登记服务 · {snapshot.Services.Count(service => service.Status == "responding")} 个已响应 · {DateTimeOffset.Parse(snapshot.CollectedAt).ToLocalTime():HH:mm:ss} 检查";
            if (snapshot.Warnings.Length > 0) ServiceStatus.Text += "\n" + string.Join("\n", snapshot.Warnings);
        }
        catch (OperationCanceledException) { }
        catch (Exception error) { Services.ItemsSource = null; ServiceStatus.Text = "检查失败：" + error.Message; }
        finally { RefreshServices.IsEnabled = true; }
    }
    private async void StartServiceClick(object sender, RoutedEventArgs e)
    {
        if (sender is not Button { Tag: string name } button) return;
        button.IsEnabled = false;
        try
        {
            var reply = await guardian.AdminAsync<ServiceStartReply>(RegisteredServices.StartCommand, new { name, requestId = Guid.NewGuid().ToString("D") }, lifetime.Token);
            await ReadServicesAsync();
            ServiceStatus.Text += "\n" + reply.Message;
        }
        catch (OperationCanceledException) { }
        catch (Exception error) { ServiceStatus.Text = "启动请求失败：" + error.Message + " 请先刷新确认状态。"; }
    }
    private static string ServiceState(string status) => status switch
    {
        "responding" => "已响应", "http_error" => "服务异常", "stopped" => "未监听",
        "unreachable" => "HTTP 探测失败", _ => "状态未知"
    };
    public void Dispose() { lifetime.Cancel(); lifetime.Dispose(); }
}
