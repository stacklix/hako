using System;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using Hako.Core;
using Hako.Platform;
using Microsoft.Win32;

namespace Hako.Shell;

public partial class AndroidManagementView : UserControl
{
    private readonly AndroidManager manager;
    private readonly DispatcherTimer timer = new() { Interval = TimeSpan.FromSeconds(2) };
    private bool refreshing;
    private string? requestId, displayedImage;
    internal AndroidManagementView(AndroidManager manager)
    {
        this.manager = manager; InitializeComponent();
        Loaded += async (_, _) => { timer.Start(); await RefreshAsync(); };
        Unloaded += (_, _) => timer.Stop();
        timer.Tick += async (_, _) => { if (requestId is not null) await ReadOperation(); };
    }
    private static JsonElement Json(object? value) => JsonSerializer.SerializeToElement(value, AgentConnection.Json);
    private AndroidManagedDevice? Selected => Devices.SelectedItem as AndroidManagedDevice;
    private AndroidEndpoint? Route => Connections.SelectedItem as AndroidEndpoint;
    private async Task Safe(Func<Task> action)
    { try { Message.Text = ""; await action(); } catch (Exception error) { Message.Text = error.Message; } }
    private async Task RefreshAsync()
    {
        if (refreshing) return; refreshing = true;
        try
        {
            var id = Selected?.Id; var inventory = await manager.ListAsync(default);
            Devices.ItemsSource = inventory.Devices;
            Devices.SelectedItem = inventory.Devices.FirstOrDefault(d => d.Id == id) ?? inventory.Devices.FirstOrDefault();
            if (!inventory.AdbAvailable) Message.Text = "未找到 ADB。请点击「下载官方 ADB 工具」，或将 Android SDK 平台工具加入 PATH。";
            await ShowDevice();
        }
        finally { refreshing = false; }
    }
    private async Task ShowDevice()
    {
        if (Selected is not { } device) return;
        DeviceName.Text = device.Name;
        DeviceState.Text = $"{device.Model} · Android {device.AndroidVersion} · Agent {device.AgentId ?? "未关联"}";
        var previous = Route?.Serial; Connections.ItemsSource = device.Connections;
        Connections.SelectedItem = device.Connections.FirstOrDefault(c => c.Serial == previous && c.State == "device")
            ?? device.Connections.OrderBy(c => c.Kind == "usb" ? 0 : 1).FirstOrDefault(c => c.State == "device") ?? device.Connections.FirstOrDefault();
        if (Route?.State != "device") { Overview.Text = "ADB 连接不可用，请在手机上允许 USB 调试或重新连接无线调试。"; return; }
        var value = (AndroidDetail)(await manager.QueryAsync("query.android.device", Json(new { deviceId = device.Id, serial = Route.Serial }), default))!;
        string Bytes(long? n) => n is null ? "暂不可用" : $"{n / 1073741824d:F2} GB";
        var screen = value.Screen switch { "on" => "亮屏", "off" => "熄屏", "doze" => "息屏显示", _ => "未知" };
        Overview.Text = $"型号　{device.Model}\n系统　Android {device.AndroidVersion}\n可用内存　{Bytes(value.MemoryAvailableBytes)}\n可用存储　{Bytes(value.StorageAvailableBytes)}\n开机时长　{value.UptimeSeconds / 3600:F1} 小时\n屏幕状态　{screen}\n电池电量　{value.BatteryPercent?.ToString() ?? "—"}%\nNami 版本　{value.NamiVersion ?? "未安装或未确认"}\n应用进程　{(value.ProcessRunning ? "运行中" : "未运行")}\nAgent 进程　{(value.AgentProcessRunning ? "运行中（在线状态需另行确认）" : "未运行")}";
        ScreenState.Text = "屏幕状态：" + screen;
        var records = Json(await manager.QueryAsync("query.android.operations", Json(new { deviceId = device.Id }), default));
        Records.Text = string.Join("\n\n", records.GetProperty("operations").Deserialize<AndroidOperation[]>(AgentConnection.Json)!.Select(o => $"{o.CreatedAt}\n{o.Kind} · {o.Status}\n{o.Message}\n{o.Id}"));
    }
    private async void RefreshClick(object sender, RoutedEventArgs e) => await Safe(RefreshAsync);
    private async void DeviceChanged(object sender, SelectionChangedEventArgs e) { if (!refreshing) await Safe(ShowDevice); }
    private void ConnectionChanged(object sender, SelectionChangedEventArgs e) { }
    private async Task Start(string operation, object? extra = null)
    {
        var parameters = extra is null ? new System.Collections.Generic.Dictionary<string, object?>() : Json(extra).EnumerateObject().ToDictionary(p => p.Name, p => (object?)p.Value.Clone());
        parameters["requestId"] = Guid.NewGuid().ToString("D"); parameters["operation"] = operation;
        if (!parameters.ContainsKey("deviceId") && Selected is { } device) parameters["deviceId"] = device.Id;
        if (!parameters.ContainsKey("serial") && Route is { } route) parameters["serial"] = route.Serial;
        var result = (AndroidOperation)(await manager.ActionAsync("action.android.execute", Json(parameters), default))!;
        requestId = result.Id; Message.Text = result.Message;
    }
    private async void ActionClick(object sender, RoutedEventArgs e) => await Safe(async () =>
    {
        if (Selected is null || Route?.State != "device") throw new IOException("请先选择已授权且连接正常的手机。");
        var operation = (string)((Button)sender).Tag;
        if (operation is "sleep" or "restart" && MessageBox.Show("目标：" + Selected.Name + "。此操作可能中断手机当前任务，是否继续？", "确认操作", MessageBoxButton.OKCancel) != MessageBoxResult.OK) return;
        await Start(operation);
    });
    private async Task ReadOperation() => await Safe(async () =>
    {
        if (requestId is null) return;
        var operation = (AndroidOperation)(await manager.QueryAsync("query.android.operation", Json(new { requestId }), default))!;
        Message.Text = operation.Status + " · " + operation.Message;
        if (operation.Status is "queued" or "running") return;
        if (operation.Artifact is not null && displayedImage != operation.Id)
        {
            using var bytes = new MemoryStream(); long total;
            do { var block = Json(await manager.QueryAsync("query.android.artifact", Json(new { requestId = operation.Id, offset = bytes.Length }), default)); total = block.GetProperty("total").GetInt64();
                await bytes.WriteAsync(Convert.FromBase64String(block.GetProperty("data").GetString()!)); } while (bytes.Length < total);
            bytes.Position = 0; var image = new BitmapImage(); image.BeginInit(); image.CacheOption = BitmapCacheOption.OnLoad; image.StreamSource = bytes; image.EndInit(); image.Freeze(); Screenshot.Source = image; displayedImage = operation.Id;
        }
        requestId = null; await RefreshAsync();
    });
    private async void ToolsClick(object sender, RoutedEventArgs e) => await Safe(() => Start("tools"));
    private async void LogsClick(object sender, RoutedEventArgs e) => await Safe(async () =>
    {
        if (Selected is null || Route is null) return;
        var result = Json(await manager.QueryAsync("query.android.logs", Json(new { deviceId = Selected.Id, serial = Route.Serial }), default));
        Logs.Text = result.GetProperty("text").GetString();
    });
    private async void InstallClick(object sender, RoutedEventArgs e) => await Safe(async () =>
    {
        if (Selected is null || Route?.State != "device") throw new IOException("请先选择已连接手机。");
        var target = Selected; var targetRoute = Route;
        var picker = new OpenFileDialog { Filter = "Android APK|*.apk" }; if (picker.ShowDialog() != true) return;
        var metadata = AndroidApk.Read(picker.FileName);
        if (MessageBox.Show($"目标：{Selected.Name}\n包名：{metadata.PackageName}\n版本代码：{metadata.VersionCode}\n保留应用数据，签名由 Android 安装器校验。是否覆盖安装？", "确认覆盖安装", MessageBoxButton.OKCancel) != MessageBoxResult.OK) return;
        var info = new FileInfo(picker.FileName); if (info.Length > 256 * 1024 * 1024) throw new IOException("APK 不能超过 256 MB。");
        var uploadId = Guid.NewGuid().ToString("D");
        using var file = File.OpenRead(picker.FileName); var hash = Convert.ToHexString(await SHA256.HashDataAsync(file)).ToLowerInvariant(); file.Position = 0;
        var buffer = new byte[8192]; long offset = 0;
        while (true) { var count = await file.ReadAsync(buffer); if (count == 0) break;
            _ = await manager.ActionAsync("action.android.upload", Json(new { uploadId, fileName = info.Name, length = info.Length, sha256 = hash, offset, data = Convert.ToBase64String(buffer, 0, count) }), default); offset += count; }
        await Start("install", new { uploadId, deviceId = target.Id, serial = targetRoute.Serial });
    });
    private void PairClick(object sender, RoutedEventArgs e)
    {
        var window = new Window { Title = "无线调试配对 / 连接", Width = 420, Height = 410, Owner = Window.GetWindow(this), WindowStartupLocation = WindowStartupLocation.CenterOwner };
        var form = new StackPanel { Margin = new Thickness(22) };
        form.Children.Add(new TextBlock { Text = "手机与电脑同网。配对端口和连接端口不同。", TextWrapping = TextWrapping.Wrap });
        var address = new TextBox { Margin = new Thickness(0, 5, 0, 12) }; var code = new PasswordBox { Margin = new Thickness(0, 5, 0, 12) };
        form.Children.Add(new TextBlock { Text = "手机 IPv4:端口" }); form.Children.Add(address);
        form.Children.Add(new TextBlock { Text = "配对码（配对时填写）" }); form.Children.Add(code);
        var result = new TextBlock { TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 12, 0, 0) };
        foreach (var kind in new[] { "pair", "connect" })
        {
            var button = new Button { Content = kind == "pair" ? "配对" : "连接", Padding = new Thickness(12, 8, 12, 8), Margin = new Thickness(0, 4, 0, 0) };
            button.Click += async (_, _) => { button.IsEnabled = false; try { await Start(kind, new { address = address.Text.Trim(), code = code.Password }); code.Clear(); result.Text = "已提交，请查看主界面执行结果。配对完成后使用连接端口建立连接。"; } catch (Exception error) { result.Text = error.Message; } finally { button.IsEnabled = true; } };
            form.Children.Add(button);
        }
        form.Children.Add(result); window.Content = form; window.ShowDialog();
    }
}
