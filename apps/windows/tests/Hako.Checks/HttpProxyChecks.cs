using System;
using System.Collections.Generic;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Hako.Core;
using Hako.Platform;

internal static class HttpProxyChecks
{
    private static void Check(bool value, string message) { if (!value) throw new Exception(message); }
    internal static async Task RunAsync()
    {
        await using var dispatcher = new AgentDispatcher(new SystemMetrics());
        Check(dispatcher.Capabilities.Contains(new(HttpProxy.Command, 1)), "Proxy capability missing");
        async Task Reject(string target, string body = "", string method = "POST")
        {
            var invalid = JsonSerializer.SerializeToElement(new { url = "http://example.invalid/a", target, method,
                headers = new Dictionary<string, string>(), body, timeoutMs = 1000 }, AgentConnection.Json);
            try { await dispatcher.InvokeAsync(HttpProxy.Command, 1, invalid, default); throw new Exception("Invalid proxy request accepted: " + target); }
            catch (AgentActionException e) when (e.Code is "invalid_params" or "request_too_large") { }
        }
        foreach (var target in new[] { "localhost:80", "127.0.0.1", "http://127.0.0.1:80", "127.0.0.1:80/path", "127.0.0.1:80?x", "user@127.0.0.1:80", "127.0.0.1:0", "127.0.0.1:65536", "127.0.0.1:80\r\nX: x" })
            await Reject(target);
        await Reject("127.0.0.1:80", "invalid base64!");
        await Reject("127.0.0.1:80", Convert.ToBase64String(new byte[HttpProxy.RequestLimit + 1]));
        await Reject("127.0.0.1:80", method: "CONNECT");

        // Base64 rich in '+' must still fit the transport after nested JSON serialization.
        var dense = new byte[HttpProxy.ResponseLimit];
        var pattern = new byte[] { 251, 239, 190 };
        for (var i = 0; i < dense.Length; i++) dense[i] = pattern[i % 3];
        using (var frame = new MemoryStream())
        {
            await CliWire.WriteAsync(frame, new LocalReply(JsonSerializer.SerializeToElement(new HttpProxy.Output(200, new(), HttpProxy.EncodeBody(dense)), AgentConnection.Json)), default);
            Check(frame.Length < CliWire.MaximumFrameBytes, "Maximum binary response exceeds the local transport envelope");
        }

        var upload = Enumerable.Range(0, 180000).Select(i => (byte)i).ToArray();
        var download = Enumerable.Range(0, 220000).Select(i => (byte)(255 - i)).ToArray();
        foreach (var scenario in new[] { "binary", "redirect", "gzip", "oversized", "timeout", "cancel" })
        {
            using var listener = new TcpListener(IPAddress.Loopback, 0); listener.Start();
            var port = ((IPEndPoint)listener.LocalEndpoint).Port;
            using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(10));
            var server = Task.Run(async () =>
            {
                using var client = await listener.AcceptTcpClientAsync(deadline.Token);
                await using var stream = client.GetStream();
                using var head = new MemoryStream();
                var one = new byte[1];
                while (head.Length < 32 * 1024)
                {
                    if (await stream.ReadAsync(one, deadline.Token) == 0) throw new Exception("Incomplete request");
                    head.WriteByte(one[0]);
                    var bytes = head.GetBuffer(); var n = (int)head.Length;
                    if (n >= 4 && bytes[n - 4] == 13 && bytes[n - 3] == 10 && bytes[n - 2] == 13 && bytes[n - 1] == 10) break;
                }
                var text = Encoding.ASCII.GetString(head.ToArray());
                Check(text.StartsWith("POST /a%2Fb?q=hello%20world HTTP/1.1\r\n"), "Path or query changed: " + text.Split('\r')[0]);
                Check(text.Contains("Host: 127.0.0.1:" + port), "Target authority incorrect");
                Check(text.Contains("Authorization: Bearer target-secret"), "Target credentials lost");
                Check(!text.Contains("X-Proxy", StringComparison.OrdinalIgnoreCase) && !text.Contains("X-Hop", StringComparison.OrdinalIgnoreCase), "Control or connection header leaked");
                var incoming = new byte[upload.Length]; await stream.ReadExactlyAsync(incoming, deadline.Token);
                Check(incoming.SequenceEqual(upload), "Binary upload corrupted");
                if (scenario is "timeout" or "cancel") { await Task.Delay(1000, deadline.Token); return; }
                if (scenario == "oversized")
                {
                    await stream.WriteAsync(Encoding.ASCII.GetBytes($"HTTP/1.1 200 OK\r\nContent-Length: {HttpProxy.ResponseLimit + 1}\r\nConnection: close\r\n\r\n"), deadline.Token); return;
                }
                var payload = download;
                if (scenario == "gzip")
                {
                    using var compressed = new MemoryStream();
                    using (var zip = new GZipStream(compressed, CompressionLevel.Fastest, true)) zip.Write(download);
                    payload = compressed.ToArray();
                }
                var status = scenario == "redirect" ? "302 Found" : "404 Not Found";
                var extra = scenario == "redirect" ? "Location: http://unreachable.invalid/\r\n" : scenario == "gzip" ? "Content-Encoding: gzip\r\n" : "";
                await stream.WriteAsync(Encoding.ASCII.GetBytes($"HTTP/1.1 {status}\r\nContent-Type: application/octet-stream\r\nContent-Length: {payload.Length}\r\nConnection: close, X-Hop\r\nX-Hop: response-secret\r\n{extra}\r\n"), deadline.Token);
                await stream.WriteAsync(payload, deadline.Token);
            });
            var parameters = JsonSerializer.SerializeToElement(new { url = "http://original.invalid/a%2Fb?q=hello%20world", target = "127.0.0.1:" + port,
                method = "POST", headers = new Dictionary<string, string> { ["Authorization"] = "Bearer target-secret", ["X-Proxy"] = "hidden",
                    ["Host"] = "original.invalid", ["Connection"] = "X-Hop", ["X-Hop"] = "private" },
                body = HttpProxy.EncodeBody(upload), timeoutMs = scenario == "timeout" ? 100 : 8000 }, AgentConnection.Json);
            using var cancel = new CancellationTokenSource();
            if (scenario == "cancel") cancel.CancelAfter(100);
            try
            {
                var output = (HttpProxy.Output)(await dispatcher.InvokeAsync(HttpProxy.Command, 1, parameters, cancel.Token))!;
                Check(scenario is not ("oversized" or "timeout" or "cancel"), "Expected proxy failure");
                Check(output.Status == (scenario == "redirect" ? 302 : 404), "Status changed or redirect followed");
                Check(output.Body == HttpProxy.EncodeBody(download), "Response corrupted or compressed twice");
                Check(!output.Headers.ContainsKey("X-Hop") && !output.Headers.ContainsKey("Connection") && !output.Headers.ContainsKey("Content-Encoding"), "Hop or encoding header leaked");
                Check(output.Headers["Content-Length"] == download.Length.ToString(), "Response length incorrect");
                // Exercise the real guardian/main pipe framing, beyond the former 64 KiB limit.
                using var wire = new MemoryStream();
                await CliWire.WriteAsync(wire, new LocalReply(JsonSerializer.SerializeToElement(output, AgentConnection.Json)), default);
                wire.Position = 0;
                Check((await CliWire.ReadAsync<LocalReply>(wire, default)).Result?.GetProperty("body").GetString() == output.Body, "Local RPC body truncated");
            }
            catch (AgentActionException e) when (scenario == "oversized" && e.Code == "result_too_large" || scenario == "timeout" && e.Code == "proxy_timeout") { }
            catch (OperationCanceledException) when (scenario == "cancel" && cancel.IsCancellationRequested) { }
            await server;
        }
        Console.WriteLine("PASS: HTTP proxy binary bodies, path/query, authority, target auth, header filtering, redirects, gzip, size limits, timeout, cancellation and local RPC framing");
    }
}
