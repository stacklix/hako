using System;
using System.Buffers.Binary;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace Hako.Platform;

internal sealed partial class CodeWorkshop
{
    internal const int BinaryUploadChunkSize = 32 * 1024;
    private sealed record BinaryUploadState(int Total, string Sha256, int[] Received);
    private string BinaryMetadata(string id) => UploadPath(id) + ".v2.json";
    private string BinaryPart(string id) => UploadPath(id) + ".v2.part";
    private static int BinaryPrefix(BinaryUploadState state)
    {
        var position = 0;
        while (position < state.Total && state.Received.Contains(position))
            position += Math.Min(BinaryUploadChunkSize, state.Total - position);
        return position;
    }
    private void SaveBinaryState(string id, BinaryUploadState state)
    {
        var path = BinaryMetadata(id);
        var temporary = path + ".tmp";
        using (var file = new FileStream(temporary, FileMode.Create, FileAccess.Write, FileShare.None))
        { file.Write(JsonSerializer.SerializeToUtf8Bytes(state, WorkshopProtocol.Json)); file.Flush(true); }
        File.Move(temporary, path, true);
    }
    private BinaryUploadState ReadBinaryState(string id)
    {
        if (!File.Exists(BinaryMetadata(id))) throw new WorkshopException("codex_upload_offset", "请先初始化图片上传。");
        return JsonSerializer.Deserialize<BinaryUploadState>(File.ReadAllText(BinaryMetadata(id)), WorkshopProtocol.Json)
            ?? throw new InvalidDataException("Invalid binary upload metadata.");
    }
    public Task<object?> BeginBinaryUploadAsync(JsonElement parameters, CancellationToken token)
    {
        CodexJson.Keys(parameters, "uploadId", "total", "sha256");
        var id = OperationId(parameters, "uploadId");
        var totalField = CodexJson.Field(parameters, "total");
        if (totalField.ValueKind != JsonValueKind.Number || !totalField.TryGetInt32(out var total) || total is < 4 or > 2_000_000) throw CodexJson.Invalid();
        var digest = CodexJson.Required(parameters, "sha256", 64).ToLowerInvariant();
        if (digest.Length != 64 || !digest.All(Uri.IsHexDigit)) throw CodexJson.Invalid();
        token.ThrowIfCancellationRequested();
        lock (gate)
        {
            var path = UploadPath(id);
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            if (File.Exists(path))
            {
                if (new FileInfo(path).Length != total || !Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(path))).Equals(digest, StringComparison.OrdinalIgnoreCase))
                    throw new WorkshopException("codex_upload_conflict", "图片上传 ID 已用于其他内容。");
                return Task.FromResult<object?>(new { id, nextOffset = total, complete = true });
            }
            BinaryUploadState state;
            if (File.Exists(BinaryMetadata(id)))
            {
                state = ReadBinaryState(id);
                if (state.Total != total || state.Sha256 != digest)
                    throw new WorkshopException("codex_upload_conflict", "图片上传 ID 已用于其他内容。");
            }
            else
            {
                if (Directory.EnumerateFiles(Path.GetDirectoryName(path)!, "*.v2.part").Count() >= 20)
                    throw new WorkshopException("codex_upload_busy", "未完成的图片上传过多。");
                using (var file = new FileStream(BinaryPart(id), FileMode.CreateNew, FileAccess.Write, FileShare.Read)) { file.Flush(true); }
                state = new(total, digest, []);
                SaveBinaryState(id, state);
            }
            var prefix = BinaryPrefix(state);
            if (prefix == total) FinalizeBinaryUpload(id, state);
            return Task.FromResult<object?>(new { id, nextOffset = prefix, complete = prefix == total });
        }
    }
    private void FinalizeBinaryUpload(string id, BinaryUploadState state)
    {
        var image = File.ReadAllBytes(BinaryPart(id));
        if (image.Length != state.Total || image[0] != 0xff || image[1] != 0xd8 || image[^2] != 0xff || image[^1] != 0xd9 ||
            !Convert.ToHexString(SHA256.HashData(image)).Equals(state.Sha256, StringComparison.OrdinalIgnoreCase))
        {
            using (var reset = new FileStream(BinaryPart(id), FileMode.Truncate, FileAccess.Write)) { reset.Flush(true); }
            SaveBinaryState(id, state with { Received = [] });
            throw new WorkshopException("codex_image_invalid", "图片格式或校验值不正确，请重新上传。");
        }
        File.Move(BinaryPart(id), UploadPath(id));
    }
    public Task<object?> UploadBinaryAsync(JsonElement parameters, CancellationToken token)
    {
        CodexJson.Keys(parameters, "packet");
        byte[] packet;
        try { packet = Convert.FromBase64String(CodexJson.Required(parameters, "packet", 48 * 1024)); }
        catch (FormatException) { throw CodexJson.Invalid(); }
        if (packet.Length is <= 40 or > BinaryUploadChunkSize + 40 ||
            !Guid.TryParseExact(Encoding.ASCII.GetString(packet, 0, 36), "D", out var identity)) throw CodexJson.Invalid();
        var id = identity.ToString("D");
        var unsigned = BinaryPrimitives.ReadUInt32BigEndian(packet.AsSpan(36, 4));
        if (unsigned > 2_000_000 || unsigned % BinaryUploadChunkSize != 0) throw CodexJson.Invalid();
        var offset = (int)unsigned;
        var bytes = packet.AsSpan(40);
        token.ThrowIfCancellationRequested();
        lock (gate)
        {
            var path = UploadPath(id);
            if (File.Exists(path))
            {
                var image = File.ReadAllBytes(path);
                if (offset >= image.Length || bytes.Length != Math.Min(BinaryUploadChunkSize, image.Length - offset) ||
                    !image.AsSpan(offset, bytes.Length).SequenceEqual(bytes))
                    throw new WorkshopException("codex_upload_conflict", "重复图片分片与原内容不一致。");
                return Task.FromResult<object?>(new { id, nextOffset = image.Length, complete = true });
            }
            var state = ReadBinaryState(id);
            if (offset >= state.Total || bytes.Length != Math.Min(BinaryUploadChunkSize, state.Total - offset)) throw CodexJson.Invalid();
            using (var file = new FileStream(BinaryPart(id), FileMode.Open, FileAccess.ReadWrite, FileShare.Read))
            {
                file.Position = offset;
                if (state.Received.Contains(offset))
                {
                    var previous = new byte[bytes.Length];
                    file.ReadExactly(previous);
                    if (!previous.AsSpan().SequenceEqual(bytes)) throw new WorkshopException("codex_upload_conflict", "重复图片分片与原内容不一致。");
                }
                else
                {
                    file.Write(bytes); file.Flush(true);
                    state = state with { Received = state.Received.Append(offset).Order().ToArray() };
                    SaveBinaryState(id, state);
                }
            }
            var nextOffset = BinaryPrefix(state);
            var complete = nextOffset == state.Total;
            if (complete) FinalizeBinaryUpload(id, state);
            return Task.FromResult<object?>(new { id, nextOffset, complete });
        }
    }
}
