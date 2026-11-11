using System;
using System.Collections.Concurrent;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Hako.Core;

namespace Hako.Platform;

internal sealed class CodexRpcException(string message) : Exception(message);

// Owns one stdio connection. Server requests retain their original JSON-RPC IDs.
internal sealed class CodexAppServer : IAsyncDisposable
{
    private readonly Process process;
    private readonly SemaphoreSlim writing = new(1, 1);
    private readonly ConcurrentDictionary<string, TaskCompletionSource<JsonElement>> pending = new();
    private readonly Task reader;
    private readonly Task stderr;
    private int sequence;
    public event Action<JsonElement>? Event;

    private CodexAppServer(ProcessStartInfo start)
    {
        start.UseShellExecute = false;
        start.CreateNoWindow = true;
        start.WindowStyle = ProcessWindowStyle.Hidden;
        start.RedirectStandardInput = true;
        start.RedirectStandardOutput = true;
        start.RedirectStandardError = true;
        start.StandardOutputEncoding = Encoding.UTF8;
        start.StandardErrorEncoding = Encoding.UTF8;
        // A CLI launched from the desktop app must not inherit its registered
        // Core identity: the standalone executable is outside the app package.
        start.Environment.Remove("CODEX_WINDOWS_REGISTERED_CORE");
        process = Process.Start(start) ?? throw new IOException("Codex 进程未能启动。");
        reader = ReadAsync();
        // Drain diagnostics, but never forward local credentials or full startup logs.
        stderr = DrainAsync();
    }

    public static async Task<CodexAppServer> StartAsync(CancellationToken token, ProcessStartInfo? fixture = null)
    {
        CodexAppServer server;
        try { server = new(fixture ?? Executable()); }
        catch (Exception e) when (e is IOException or Win32Exception)
        { throw new WorkshopException("codex_unavailable", "无法启动 Codex，请在当前 Windows 用户下安装并登录 Codex CLI。"); }
        try
        {
            await server.RequestAsync("initialize", new
            {
                clientInfo = new { name = "hako", title = "Hako", version = typeof(CodexAppServer).Assembly.GetName().Version?.ToString(3) ?? "1.0.0" },
                capabilities = new { experimentalApi = true }
            }, token);
            await server.WriteAsync(new { method = "initialized" }, token);
            return server;
        }
        catch { await server.DisposeAsync(); throw; }
    }

    internal static ProcessStartInfo Executable()
    {
        var paths = (Environment.GetEnvironmentVariable("PATH") ?? "").Split(Path.PathSeparator)
            .Where(path => !string.IsNullOrWhiteSpace(path)).Select(path => path.Trim('"')).ToArray();
        foreach (var directory in paths)
        {
            var native = Path.Combine(directory, "codex.exe");
            if (File.Exists(native)) return WithArguments(new(native));
            // npm installs a shell wrapper on Windows. Invoke its JS entry point
            // directly, with ArgumentList, instead of constructing a shell command.
            var script = Path.Combine(directory, "node_modules", "@openai", "codex", "bin", "codex.js");
            if (!File.Exists(script)) continue;
            var node = paths.Select(path => Path.Combine(path, "node.exe")).FirstOrDefault(File.Exists);
            if (node is null) continue;
            var start = new ProcessStartInfo(node);
            start.ArgumentList.Add(script);
            return WithArguments(start);
        }
        throw new IOException("Codex CLI is not on PATH");
    }

    internal static ProcessStartInfo WithArguments(ProcessStartInfo start)
    {
        start.ArgumentList.Add("app-server");
        // The phone can answer structured questions while Codex is in Default mode.
        start.ArgumentList.Add("--enable");
        start.ArgumentList.Add("default_mode_request_user_input");
        start.ArgumentList.Add("--listen");
        start.ArgumentList.Add("stdio://");
        return start;
    }

    public async Task<JsonElement> RequestAsync(string method, object parameters, CancellationToken token)
    {
        var id = Interlocked.Increment(ref sequence);
        var key = id.ToString(System.Globalization.CultureInfo.InvariantCulture);
        var completion = new TaskCompletionSource<JsonElement>(TaskCreationOptions.RunContinuationsAsynchronously);
        pending[key] = completion;
        try
        {
            await WriteAsync(new { id, method, @params = parameters }, token);
            return await completion.Task.WaitAsync(TimeSpan.FromSeconds(8), token);
        }
        finally { pending.TryRemove(key, out _); }
    }

    public Task ReplyAsync(JsonElement id, object result, CancellationToken token) => WriteAsync(new { id, result }, token);
    public Task RejectAsync(JsonElement id, CancellationToken token) =>
        WriteAsync(new { id, error = new { code = -32601, message = "Hako does not support this request type." } }, token);

    private async Task WriteAsync(object message, CancellationToken token)
    {
        await writing.WaitAsync(token);
        try
        {
            await process.StandardInput.WriteLineAsync(JsonSerializer.Serialize(message, WorkshopProtocol.Json).AsMemory(), token);
            await process.StandardInput.FlushAsync(token);
        }
        finally { writing.Release(); }
    }

    private async Task ReadAsync()
    {
        Exception failure = new IOException("Codex 连接已关闭，请查看会话历史确认任务状态。");
        try
        {
            while (await process.StandardOutput.ReadLineAsync() is { } line)
            {
                using var document = JsonDocument.Parse(line);
                var message = document.RootElement;
                if (message.TryGetProperty("method", out _)) { Event?.Invoke(message.Clone()); continue; }
                if (!message.TryGetProperty("id", out var id) || !pending.TryGetValue(id.GetRawText(), out var completion)) continue;
                if (message.TryGetProperty("error", out var error))
                    completion.TrySetException(new CodexRpcException(CodexJson.Text(error, "message")));
                else if (message.TryGetProperty("result", out var result)) completion.TrySetResult(result.Clone());
            }
        }
        catch (Exception e) { failure = e; }
        finally
        {
            foreach (var request in pending.Values) request.TrySetException(failure);
            Event?.Invoke(JsonSerializer.SerializeToElement(new { method = "hako/connectionClosed" }));
        }
    }

    private async Task DrainAsync()
    {
        try { while (await process.StandardError.ReadLineAsync() is not null) { } }
        catch (IOException) { }
    }

    public async ValueTask DisposeAsync()
    {
        try
        {
            process.StandardInput.Close();
            await process.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(2));
        }
        catch (Exception e) when (e is TimeoutException or IOException or InvalidOperationException)
        {
            if (!process.HasExited) process.Kill(entireProcessTree: true);
        }
        try { await Task.WhenAll(reader, stderr).WaitAsync(TimeSpan.FromSeconds(2)); }
        catch (TimeoutException) { }
        process.Dispose();
    }
}

internal static class CodexJson
{
    public static string Text(JsonElement value, string key) => value.ValueKind == JsonValueKind.Object &&
        value.TryGetProperty(key, out var field) && field.ValueKind == JsonValueKind.String ? field.GetString()! : "";
    public static JsonElement Field(JsonElement value, string key) => value.ValueKind == JsonValueKind.Object &&
        value.TryGetProperty(key, out var field) ? field : default;
    public static JsonElement[] Items(JsonElement value) => value.ValueKind == JsonValueKind.Array ? value.EnumerateArray().ToArray() : [];
    public static string Clip(string value, int count)
    {
        if (value.Length <= count) return value;
        if (char.IsHighSurrogate(value[count - 1])) count--;
        return value[..count];
    }
    public static WorkshopException Invalid() => new("invalid_params", "代码工坊请求参数无效。");
    public static void Keys(JsonElement value, params string[] allowed)
    {
        if (value.ValueKind != JsonValueKind.Object || value.EnumerateObject().Any(field => !allowed.Contains(field.Name))) throw Invalid();
    }
    public static string Required(JsonElement value, string key, int maximum = 1024)
    {
        var result = Text(value, key);
        if (string.IsNullOrWhiteSpace(result) || result.Length > maximum) throw Invalid();
        return result;
    }
}
