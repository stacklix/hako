using System;
using System.ComponentModel;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using Hako.Core;
using Hako.Features.SystemMonitor;
using Hako.Platform;
using Forms = System.Windows.Forms;

namespace Hako.Shell;

public partial class MainWindow : Window
{
    private readonly AgentRuntime runtime;
    private readonly MonitorView monitor;
    private readonly ServerSettingsView settings;
    private readonly Forms.NotifyIcon tray;
    private bool exiting;

    public MainWindow(AgentRuntime runtime, Func<Task> exit)
    {
        this.runtime = runtime;
        InitializeComponent();
        monitor = new MonitorView(runtime.Metrics);
        settings = new ServerSettingsView(ApplyAsync, ClearAsync, SaveKeyAsync);
        runtime.StatusChanged += StatusChanged;
        runtime.MetricsReceived += MetricsReceived;
        runtime.SettingsChanged += SettingsChanged;
        var menu = new Forms.ContextMenuStrip();
        menu.Items.Add("打开 Hako", null, (_, _) => Dispatcher.Invoke(ShowWindow));
        menu.Items.Add("退出", null, async (_, _) => await Dispatcher.InvokeAsync(exit).Task.Unwrap());
        tray = new Forms.NotifyIcon { Icon = System.Drawing.SystemIcons.Application, Text = "Hako · 设备代理", ContextMenuStrip = menu, Visible = true };
        tray.DoubleClick += (_, _) => Dispatcher.Invoke(ShowWindow);
        Closing += OnClosing;
        Loaded += (_, _) =>
        {
            Home();
            try
            {
                var saved = runtime.Store.Load();
                settings.Load(saved);
                ConnectionStatus.Text = runtime.Connection.Status.Message;
            }
            catch (Exception e) { ConnectionStatus.Text = "配置读取失败：" + e.Message; Page.Content = settings; }
        };
    }

    private Task ApplyAsync(AgentSettings value) => runtime.UpdateConfigurationAsync(value.Url, value.Username, connect: true);
    private async Task SaveKeyAsync(string privateKey)
    {
        await runtime.UpdatePrivateKeyAsync(privateKey, reloadForm: false);
        ConnectionStatus.Text = "设备密钥已保存，请登记服务端公钥后重新连接。";
    }
    private Task ClearAsync() => runtime.ClearAsync();
    private void StatusChanged(string text) => Dispatcher.InvokeAsync(() => ConnectionStatus.Text = text);
    private void MetricsReceived(Metrics result) => Dispatcher.InvokeAsync(() => monitor.Display(result));
    private void SettingsChanged(AgentSettings value, bool reloadForm) { if (reloadForm) Dispatcher.InvokeAsync(() => settings.Load(value)); }
    public void ShowWindow() { Show(); WindowState = WindowState.Normal; Activate(); }
    private void OnClosing(object? sender, CancelEventArgs e) { if (!exiting) { e.Cancel = true; Hide(); } }
    public void DisposeForExit()
    {
        exiting = true; runtime.StatusChanged -= StatusChanged; runtime.MetricsReceived -= MetricsReceived; runtime.SettingsChanged -= SettingsChanged;
        monitor.Dispose(); tray.Dispose();
    }
    private void HomeClick(object sender, RoutedEventArgs e) => Home();
    private void MonitorClick(object sender, RoutedEventArgs e) => Page.Content = monitor;
    private void SettingsClick(object sender, RoutedEventArgs e) => Page.Content = settings;
    private void Home()
    {
        var panel = new StackPanel();
        panel.Children.Add(new TextBlock { Text = "你的日常，收进一个盒子。", FontSize = 26, FontWeight = FontWeights.Bold, Margin = new Thickness(0, 20, 0, 12) });
        panel.Children.Add(new TextBlock { Text = "HAKO · 个人工具箱", Foreground = System.Windows.Media.Brushes.SlateGray, Margin = new Thickness(0, 0, 0, 30) });
        var button = new Button { Content = "设备监控\nCPU · 内存 · 远程查询", HorizontalContentAlignment = HorizontalAlignment.Left, Padding = new Thickness(24), FontSize = 18 };
        button.Click += MonitorClick; panel.Children.Add(button);
        panel.Children.Add(new TextBlock { Text = "关闭窗口后继续在系统托盘运行。通过托盘菜单退出应用。", TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 24, 0, 0) });
        Page.Content = panel;
    }
}
