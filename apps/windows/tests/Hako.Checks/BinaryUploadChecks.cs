using System;
using System.Buffers.Binary;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Threading.Tasks;
using Hako.Platform;

internal static class BinaryUploadChecks
{
    internal static byte[] Frame(string requestId,string computerId,string uploadId,int offset,byte[] bytes)
    {
        var routing=JsonSerializer.SerializeToUtf8Bytes(new {id=requestId,computerId});
        var packet=new byte[4+routing.Length+40+bytes.Length];
        BinaryPrimitives.WriteUInt32BigEndian(packet,(uint)routing.Length);routing.CopyTo(packet.AsSpan(4));
        Encoding.ASCII.GetBytes(uploadId).CopyTo(packet.AsSpan(4+routing.Length));
        BinaryPrimitives.WriteUInt32BigEndian(packet.AsSpan(4+routing.Length+36),(uint)offset);
        bytes.CopyTo(packet.AsSpan(4+routing.Length+40));return packet;
    }
    private static JsonElement Params(object value)=>JsonSerializer.SerializeToElement(value);
    private static async Task<JsonElement> Chunk(CodeWorkshop workshop,string id,int offset,byte[] bytes)
    {
        using var decoded=WorkshopBinaryFrame.Decode(Frame("request","PC",id,offset,bytes));
        return JsonSerializer.SerializeToElement(await workshop.UploadBinaryAsync(decoded.RootElement.GetProperty("params"),default));
    }
    private static void Check(bool passed,string message){if(!passed)throw new Exception(message);}
    internal static async Task RunAsync()
    {
        var directory=Path.Combine(Path.GetTempPath(),"hako-binary-"+Guid.NewGuid().ToString("N"));Directory.CreateDirectory(directory);
        try {
            var image=new byte[100_000];RandomNumberGenerator.Fill(image);image[0]=0xff;image[1]=0xd8;image[^2]=0xff;image[^1]=0xd9;
            var id=Guid.NewGuid().ToString("D");var hash=Convert.ToHexString(SHA256.HashData(image)).ToLowerInvariant();
            var begin=Params(new {uploadId=id,total=image.Length,sha256=hash});
            await using(var first=new CodeWorkshop(directory)) {
                await first.BeginBinaryUploadAsync(begin,default);
                var outOfOrder=await Chunk(first,id,32768,image.AsSpan(32768,32768).ToArray());
                Check(outOfOrder.GetProperty("nextOffset").GetInt32()==0,"Sparse files must not count as uploaded bytes");
                await Chunk(first,id,0,image.AsSpan(0,32768).ToArray());
                await Chunk(first,id,0,image.AsSpan(0,32768).ToArray());
                try {await first.BeginBinaryUploadAsync(Params(new {uploadId=id,total=image.Length,sha256=new string('0',64)}),default);throw new Exception("Conflicting image identity accepted");}
                catch(WorkshopException e) when(e.Code=="codex_upload_conflict"){}
                try {await Chunk(first,id,0,new byte[32768]);throw new Exception("Conflicting duplicate accepted");}
                catch(WorkshopException e) when(e.Code=="codex_upload_conflict"){}
            }
            await using(var restarted=new CodeWorkshop(directory)) {
                var resumed=JsonSerializer.SerializeToElement(await restarted.BeginBinaryUploadAsync(begin,default));
                Check(resumed.GetProperty("nextOffset").GetInt32()==65536,"Upload did not resume across process recreation");
                await Chunk(restarted,id,98304,image.AsSpan(98304).ToArray());
                var finished=await Chunk(restarted,id,65536,image.AsSpan(65536,32768).ToArray());
                Check(finished.GetProperty("complete").GetBoolean(),"Out-of-order image did not complete");
                Check(File.ReadAllBytes(Path.Combine(directory,"images",id+".jpg")).SequenceEqual(image),"Binary image changed in transit");
                // Simulate a crash after the final block was persisted but before rename.
                var final=Path.Combine(directory,"images",id+".jpg");File.Move(final,final+".v2.part");
                Check(JsonSerializer.SerializeToElement(await restarted.BeginBinaryUploadAsync(begin,default)).GetProperty("complete").GetBoolean(),"Ready upload was not finalized after restart");
                var repeated=await Chunk(restarted,id,65536,image.AsSpan(65536,32768).ToArray());
                Check(repeated.GetProperty("complete").GetBoolean(),"Lost final acknowledgement is not retryable");
                var orphanId=Guid.NewGuid().ToString("D");var orphan=new byte[]{255,216,0,1,255,217};
                File.WriteAllBytes(Path.Combine(directory,"images",orphanId+".jpg.v2.part"),new byte[]{1});
                await restarted.BeginBinaryUploadAsync(Params(new {uploadId=orphanId,total=orphan.Length,sha256=Convert.ToHexString(SHA256.HashData(orphan)).ToLowerInvariant()}),default);
                Check((await Chunk(restarted,orphanId,0,orphan)).GetProperty("complete").GetBoolean(),"Crash before initialization acknowledgement left an unretryable upload");
                var corruptId=Guid.NewGuid().ToString("D");var small=new byte[]{255,216,0,1,255,217};
                var corruptBegin=Params(new {uploadId=corruptId,total=small.Length,sha256=Convert.ToHexString(SHA256.HashData(small)).ToLowerInvariant()});
                await restarted.BeginBinaryUploadAsync(corruptBegin,default);small[2]=9;
                try {await Chunk(restarted,corruptId,0,small);throw new Exception("Corrupt image accepted");}
                catch(WorkshopException e) when(e.Code=="codex_image_invalid"){}
                Check(JsonSerializer.SerializeToElement(await restarted.BeginBinaryUploadAsync(corruptBegin,default)).GetProperty("nextOffset").GetInt32()==0,"Corrupt upload cannot restart safely");
            }
            foreach(var malformed in new[]{new byte[4],new byte[37*1024],new byte[]{255,255,255,255,0}}) {
                try {using var ignored=WorkshopBinaryFrame.Decode(malformed);throw new Exception("Invalid routing header accepted");}catch(InvalidDataException){}
            }
            Console.WriteLine("PASS: binary envelope, bounded/out-of-order chunks, persisted resume, idempotent replay, conflicting identity and final SHA-256 verification");
        } finally {Directory.Delete(directory,true);}
    }
}
