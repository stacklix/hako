using System;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Net.WebSockets;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Hako.Core;
using Hako.Platform;

internal static class WorkshopCloudChecks
{
    private static async Task<JsonElement> Read(WebSocket socket, CancellationToken token)
    {
        using var bytes = new MemoryStream(); var buffer = new byte[8192];
        while (true)
        {
            var frame = await socket.ReceiveAsync(buffer, token);
            if (frame.MessageType != WebSocketMessageType.Text) throw new Exception("Unexpected cloud frame");
            bytes.Write(buffer,0,frame.Count);
            if (frame.EndOfMessage) return JsonDocument.Parse(bytes.ToArray()).RootElement.Clone();
        }
    }
    private static Task Send(WebSocket socket, object frame, CancellationToken token) =>
        socket.SendAsync(new ArraySegment<byte>(JsonSerializer.SerializeToUtf8Bytes(frame,WorkshopProtocol.Json)),WebSocketMessageType.Text,true,token);

    internal static async Task RunAsync()
    {
        var directory=Path.Combine(Path.GetTempPath(),"hako-workshop-cloud-"+Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(Path.Combine(directory,"code-workshop"));
        var operation=Guid.NewGuid().ToString();
        File.WriteAllBytes(Path.Combine(directory,"code-workshop",operation+".json"),JsonSerializer.SerializeToUtf8Bytes(new WorkshopJob{Id=operation,State="completed",ApplicationId="fixture",Cwd=directory},WorkshopProtocol.Json));
        using var key=RSA.Create(2048);
        var probe=new TcpListener(IPAddress.Loopback,0);probe.Start();var port=((IPEndPoint)probe.LocalEndpoint).Port;probe.Stop();
        var origin=$"http://127.0.0.1:{port}";
        var settings=new AgentSettings(origin,"owner",key.ExportPkcs8PrivateKeyPem());
        File.WriteAllBytes(Path.Combine(directory,"code-workshop",operation+".json"),JsonSerializer.SerializeToUtf8Bytes(new WorkshopJob{Id=operation,State="completed",ApplicationId="fixture",Cwd=directory,NotificationScope=WorkshopConnection.NotificationScope(settings),FinishedAt=DateTimeOffset.UtcNow.ToUnixTimeMilliseconds()},WorkshopProtocol.Json));
        using var listener=new HttpListener();listener.Prefixes.Add(origin+"/");listener.Start();
        using var lifetime=new CancellationTokenSource(TimeSpan.FromSeconds(15));
        try
        {
            await using var dispatcher=new WorkshopDispatcher(directory);
            string? identity=null;
            await using var connection=new WorkshopConnection(dispatcher,id=>identity=id);
            await connection.StartAsync(settings);
            var context=await listener.GetContextAsync().WaitAsync(lifetime.Token);
            if (context.Request.Url?.AbsolutePath!="/ws/workshop/agent") throw new Exception("Workshop used the device endpoint");
            var accepted=await context.AcceptWebSocketAsync(null);using var socket=accepted.WebSocket;
            var hello=await Read(socket,lifetime.Token);
            if (CodexJson.Text(hello,"kind")!="hello" || CodexJson.Text(hello,"protocol")!=WorkshopProtocol.Name || hello.TryGetProperty("type",out _)) throw new Exception("Workshop reused the device hello");
            var payload=Encoding.UTF8.GetBytes("hako-workshop-auth/v1\n"+origin+"\nowner\n"+CodexJson.Text(hello,"keyId")+"\nfixture-nonce");
            await Send(socket,new{kind="challenge",protocol=WorkshopProtocol.Name,payload=Convert.ToBase64String(payload)},lifetime.Token);
            var proof=await Read(socket,lifetime.Token);
            if (CodexJson.Text(proof,"kind")!="proof" || !key.VerifyData(payload,Convert.FromBase64String(CodexJson.Text(proof,"signature")),HashAlgorithmName.SHA256,RSASignaturePadding.Pss)) throw new Exception("Workshop proof failed");
            await Send(socket,new{kind="welcome",protocol=WorkshopProtocol.Name,computerId="PC"},lifetime.Token);
            var terminal=await Read(socket,lifetime.Token);
            if(CodexJson.Text(terminal,"kind")!="terminal" || CodexJson.Text(terminal,"operationId")!=operation || CodexJson.Text(CodexJson.Field(terminal,"result"),"state")!="completed") throw new Exception("Durable terminal not reported without an iOS subscription");
            await Send(socket,new{kind="terminal_ack",operationId=operation},lifetime.Token);
            await Send(socket,new{kind="keepalive"},lifetime.Token);
            if (CodexJson.Text(await Read(socket,lifetime.Token),"kind")!="alive") throw new Exception("Workshop heartbeat failed");
            await Send(socket,new{kind="call",id="fixture",method="operation.read",@params=new{operationId=operation,cursor=0}},lifetime.Token);
            var result=await Read(socket,lifetime.Token);
            if (CodexJson.Text(result,"kind")!="result" || CodexJson.Text(result,"id")!="fixture" || CodexJson.Text(CodexJson.Field(CodexJson.Field(result,"result"),"operation"),"id")!=operation) throw new Exception("Workshop request/result protocol failed");
            if (identity!="PC" || connection.State!="connected") throw new Exception("Independent Workshop identity not confirmed");
            if (!JsonDocument.Parse(File.ReadAllBytes(Path.Combine(directory,"code-workshop",operation+".json"))).RootElement.GetProperty("notificationAcknowledged").GetBoolean()) throw new Exception("Server ACK was not persisted");
            await connection.StopAsync();
            if (connection.State!="disconnected") throw new Exception("Workshop did not stop independently");
        }
        finally { listener.Stop(); Directory.Delete(directory,true); }
        Console.WriteLine("PASS: real Workshop cloud socket, dedicated endpoint/hello, bound RSA proof, heartbeat and request/result exchange");
    }
}
