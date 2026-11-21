using System;
using System.Buffers.Binary;
using System.IO;

namespace Hako.Platform;

// Only one finger is accepted; no arbitrary scrcpy commands or clipboard data.
internal sealed class AndroidVideoInput
{
    private ulong sequence;
    private bool touching;
    internal ReadOnlyMemory<byte> Read(byte[] plain)
    {
        if (plain.Length != 40 || BinaryPrimitives.ReadUInt64BigEndian(plain) != sequence)
            throw new InvalidDataException("Invalid touch sequence.");
        var packet = plain.AsSpan(8);
        var action = packet[1];
        var x = BinaryPrimitives.ReadUInt32BigEndian(packet[10..]);
        var y = BinaryPrimitives.ReadUInt32BigEndian(packet[14..]);
        var width = BinaryPrimitives.ReadUInt16BigEndian(packet[18..]);
        var height = BinaryPrimitives.ReadUInt16BigEndian(packet[20..]);
        if (packet[0] != 2 || action > 3 || BinaryPrimitives.ReadUInt64BigEndian(packet[2..]) != 0
            || width is 0 or > 4096 || height is 0 or > 4096 || x >= width || y >= height
            || BinaryPrimitives.ReadUInt64BigEndian(packet[24..]) != 0
            || BinaryPrimitives.ReadUInt16BigEndian(packet[22..]) != (action is 1 or 3 ? 0 : 65535)
            || (action == 0 ? touching : !touching))
            throw new InvalidDataException("Invalid touch event.");
        sequence++;
        touching = action is 0 or 2;
        return plain.AsMemory(8);
    }
}
