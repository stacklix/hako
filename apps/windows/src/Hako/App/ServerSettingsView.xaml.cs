using System;
using System.IO;
using System.Security.Cryptography;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using Hako.Core;
using Microsoft.Win32;

namespace Hako.Shell;

public partial class ServerSettingsView : UserControl
{
    private readonly Func<AgentSettings, Task> apply;
    private readonly Func<Task> clear;
    private readonly Func<string, Task> saveKey;
    private string privateKey = "";
    public ServerSettingsView(Func<AgentSettings, Task> apply, Func<Task> clear, Func<string, Task> saveKey) { InitializeComponent(); this.apply = apply; this.clear = clear; this.saveKey = saveKey; }
    public void Load(AgentSettings settings) { ServerUrl.Text = settings.Url; Username.Text = settings.Username; privateKey = settings.PrivateKey; UpdateKey(); }
    private void UpdateKey()
    {
        ExportPublicKey.IsEnabled = privateKey.Length > 0;
        if (privateKey.Length == 0) { KeyStatus.Text = "尚未配置"; return; }
        using var rsa = RSA.Create(); rsa.ImportFromPem(privateKey);
        KeyStatus.Text = $"RSA {rsa.KeySize} · 指纹 {AgentSettings.KeyId(rsa)}";
    }
    private async void ImportClick(object sender, RoutedEventArgs e)
    {
        try
        {
            var dialog = new OpenFileDialog { Title = "导入 RSA 私钥（未加密 PKCS#8 或 PKCS#1 PEM）", Filter = "PEM 私钥|*.pem;*.key|所有文件|*.*" };
            if (dialog.ShowDialog() != true) return;
            if (!ConfirmKeyReplacement()) return;
            IsEnabled = false;
            var normalized = AgentKeys.NormalizePrivateKey(await File.ReadAllTextAsync(dialog.FileName));
            await saveKey(normalized);
            privateKey = normalized; UpdateKey(); Message.Text = "私钥已导入并加密保存。请导出公钥登记到服务端，再保存并连接。";
        }
        catch (Exception error) { Message.Text = "导入失败：" + error.Message; }
        finally { IsEnabled = true; }
    }
    private bool ConfirmKeyReplacement() => privateKey.Length == 0 || MessageBox.Show("替换密钥会断开当前连接，需要重新登记服务端公钥。继续？", "替换设备密钥", MessageBoxButton.YesNo) == MessageBoxResult.Yes;
    private async void GenerateClick(object sender, RoutedEventArgs e)
    {
        if (!ConfirmKeyReplacement()) return;
        IsEnabled = false;
        try
        {
            Message.Text = "正在生成 RSA 3072 位公私钥对…";
            var generated = await Task.Run(AgentKeys.GeneratePrivateKey);
            await saveKey(generated);
            privateKey = generated; UpdateKey(); Message.Text = "公私钥对已生成并加密保存。请导出公钥登记到服务端，再保存并连接。";
        }
        catch (Exception error) { Message.Text = "生成失败：" + error.Message; }
        finally { IsEnabled = true; }
    }
    private void ExportClick(object sender, RoutedEventArgs e)
    {
        try
        {
            var dialog = new SaveFileDialog { Title = "导出服务端使用的公钥", FileName = "desktop.public.pem", Filter = "PEM 公钥|*.pem" };
            if (dialog.ShowDialog() == true)
            {
                File.WriteAllText(dialog.FileName, AgentKeys.ExportPublicKey(privateKey));
                Message.Text = "公钥已导出。将其登记到服务端后，点击保存并连接。";
            }
        }
        catch (Exception error) { Message.Text = "导出失败：" + error.Message; }
    }
    private async void SaveClick(object sender, RoutedEventArgs e)
    {
        IsEnabled = false;
        try { await apply(new AgentSettings(ServerUrl.Text.Trim().TrimEnd('/'), Username.Text.Trim(), privateKey)); Message.Text = "已加密保存，正在连接。"; }
        catch (Exception error) { Message.Text = error.Message; }
        finally { IsEnabled = true; }
    }
    private async void ClearClick(object sender, RoutedEventArgs e)
    {
        if (MessageBox.Show("清除本机服务器设置和私钥并断开连接？", "清除配置", MessageBoxButton.YesNo) != MessageBoxResult.Yes) return;
        IsEnabled = false;
        try { await clear(); Load(new AgentSettings()); Message.Text = "已清除。"; }
        catch (Exception error) { Message.Text = error.Message; }
        finally { IsEnabled = true; }
    }
}
