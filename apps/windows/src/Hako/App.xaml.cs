using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using System.Windows;
using System.Threading;
using Hako.Core;
using Hako.Platform;
using Hako.Shell;

namespace Hako;
public partial class App : Application
{
    private Mutex? instance;
    private bool ownsInstance;
    private AgentRuntime? runtime;
    private AgentPipeServer? pipe;
    private MainWindow? window;
    private bool exiting;
    protected override async void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        CliInvocation invocation;
        try { invocation = CliParser.Parse(e.Args); }
        catch (Exception error)
        {
            CliConsole.Initialize();
            FinishCommand(CommandReply.Failure(2, "invalid_arguments", error.Message), e.Args.Contains("--json")); return;
        }
        if (invocation.Request is not null)
        {
            CliConsole.Initialize();
            CommandReply reply;
            try { reply = await RunCommandAsync(invocation); }
            catch (Exception error) when (error is OperationCanceledException or TimeoutException)
            { reply = CommandReply.Failure(4, "timeout", "命令超时，结果可能尚未确认，请查询 status 后重试。"); }
            catch (UnauthorizedAccessException)
            { reply = CommandReply.Failure(3, "instance_unavailable", "无法连接当前用户实例，请使用与 Agent 相同的 Windows 权限运行 CLI。"); }
            catch (Exception error) { reply = CommandReply.Failure(1, "operation_failed", error.Message); }
            FinishCommand(reply, invocation.Json); return;
        }
        try
        {
            instance = new Mutex(false, invocation.Profile.MutexName);
            var ownerDeadline = DateTime.UtcNow.AddSeconds(5);
            while (!TryOwnInstance())
            {
                var forwarded = await AgentPipeClient.TrySendAsync(invocation.Profile, new AgentCommand(invocation.Background ? "status" : "show", new()));
                if (forwarded is not null) { Shutdown(); return; }
                if (DateTime.UtcNow >= ownerDeadline)
                {
                    if (!invocation.Background) MessageBox.Show("Hako 已在运行，但本机控制接口不可用。若运行的是旧版，请先退出旧版再重试。", "Hako");
                    Shutdown(3); return;
                }
                await Task.Delay(100);
            }
            runtime = new AgentRuntime(invocation.Profile.Store, true);
            runtime.ShowRequested += () => Dispatcher.InvokeAsync(ShowMainWindow);
            await runtime.InitializeAsync(autoConnect: true);
            pipe = new AgentPipeServer(invocation.Profile, runtime, () => Dispatcher.InvokeAsync(async () => await ExitHostedAsync()));
            if (!invocation.Background) ShowMainWindow();
        }
        catch (Exception error)
        {
            if (!invocation.Background) MessageBox.Show("Hako 启动失败：" + error.Message, "Hako");
            await ExitHostedAsync(1);
        }
    }
    private void FinishCommand(CommandReply reply, bool json)
    {
        try { CliConsole.Write(reply, json); }
        catch (IOException) { Shutdown(reply.ExitCode == 0 ? 1 : reply.ExitCode); return; }
        Shutdown(reply.ExitCode);
    }
    private bool TryOwnInstance()
    {
        if (ownsInstance) return true;
        try { ownsInstance = instance!.WaitOne(0); }
        catch (AbandonedMutexException) { ownsInstance = true; }
        return ownsInstance;
    }
    private async Task<CommandReply> RunCommandAsync(CliInvocation invocation)
    {
        var request = invocation.Request!;
        if (request.Command == "help") return CliHelp.Reply(request.Options.GetValueOrDefault("topic", ""));
        instance = new Mutex(false, invocation.Profile.MutexName);
        var deadline = DateTime.UtcNow.AddSeconds(5);
        while (true)
        {
            var forwarded = await AgentPipeClient.TrySendAsync(invocation.Profile, request);
            if (forwarded is not null) return forwarded;
            if (TryOwnInstance())
            {
                if (request.Command == "connect")
                {
                    invocation.Profile.Store.Load().Validate();
                    instance.ReleaseMutex(); ownsInstance = false;
                    StartBackground(invocation.Profile);
                    return await SendUntilReadyAsync(invocation.Profile, request, TimeSpan.FromSeconds(20))
                        ?? CommandReply.Failure(3, "instance_unavailable", "后台实例未能就绪，请检查配置或先退出旧版本。");
                }
                await using var local = new AgentRuntime(invocation.Profile.Store, false);
                await local.InitializeAsync(autoConnect: false);
                return await local.ExecuteAsync(request);
            }
            if (DateTime.UtcNow >= deadline) return CommandReply.Failure(3, "instance_unavailable", "实例正在启动、忙碌或不支持 CLI，请稍后重试；旧版需先退出。");
            await Task.Delay(100);
        }
    }
    private static async Task<CommandReply?> SendUntilReadyAsync(AgentProfile profile, AgentCommand request, TimeSpan timeout)
    {
        var deadline = DateTime.UtcNow + timeout;
        while (DateTime.UtcNow < deadline)
        {
            var response = await AgentPipeClient.TrySendAsync(profile, request, 250);
            if (response is not null) return response;
            await Task.Delay(100);
        }
        return null;
    }
    private static void StartBackground(AgentProfile profile)
    {
        var executable = Environment.ProcessPath ?? throw new InvalidOperationException("无法找到 Hako 可执行文件。");
        var start = new ProcessStartInfo(executable) { UseShellExecute = false, CreateNoWindow = true,
            RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true };
        if (string.Equals(Path.GetFileNameWithoutExtension(executable), "dotnet", StringComparison.OrdinalIgnoreCase))
            start.ArgumentList.Add(Path.Combine(AppContext.BaseDirectory, "Hako.dll"));
        start.ArgumentList.Add("--background");
        start.ArgumentList.Add("--data-dir"); start.ArgumentList.Add(profile.Store.DirectoryPath);
        // A detached child must not retain the invoking script's stdout/stderr pipe handles.
        using var standardHandles = CliConsole.PreventStandardHandleInheritance();
        using var process = Process.Start(start) ?? throw new InvalidOperationException("无法启动后台实例。");
        process.StandardInput.Close();
    }
    private void ShowMainWindow()
    {
        if (runtime is null || exiting) return;
        if (window is null) window = new MainWindow(runtime, () => ExitHostedAsync());
        window.ShowWindow();
    }
    private async Task ExitHostedAsync(int exitCode = 0)
    {
        if (exiting) return;
        exiting = true;
        window?.DisposeForExit();
        if (pipe is not null) await pipe.DisposeAsync();
        if (runtime is not null) await runtime.DisposeAsync();
        Shutdown(exitCode);
    }
    protected override void OnExit(ExitEventArgs e)
    {
        if (ownsInstance) instance?.ReleaseMutex();
        instance?.Dispose();
        base.OnExit(e);
    }
}
