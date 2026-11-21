import Foundation

@main struct AndroidH264StreamTests {
    static func main() throws {
        func number(_ value: UInt64, count: Int) -> [UInt8] { (0..<count).reversed().map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) } }
        func packet(_ flag: UInt8, _ nals: [[UInt8]]) -> [UInt8] {
            let bytes: [UInt8] = nals.flatMap { [UInt8(0), 0, 0, 1] + $0 }
            return [flag] + [UInt8](repeating: 0, count: 7) + number(UInt64(bytes.count), count: 4) + bytes
        }
        let header = Array("h264".utf8) + number(540, count: 4) + number(1200, count: 4)
        let fixture = Data(header + packet(0x80, [[0x67,0x64],[0x68,0xee]]) + packet(0x40, [[0x65,0x80,1],[0x65,0x40,2]]) + packet(0,[[0x41,0x80,3]]))
        for chunk in [1,2,3,7,19,32768] {
            var parser = AndroidH264Stream(), frames: [AndroidH264Frame] = []
            for offset in stride(from: 0, to: fixture.count, by: chunk) { frames += try parser.append(fixture.subdata(in: offset..<min(fixture.count, offset + chunk))) }
            precondition(frames.count == 2 && frames[0].isKeyFrame && frames[0].nals.count == 2 && !frames[1].isKeyFrame)
            precondition(frames[0].sps == Data([0x67,0x64]) && frames[0].pps == Data([0x68,0xee]))
        }
        var parser = AndroidH264Stream()
        let idle = try parser.append(fixture.dropLast(packet(0,[[0x41,0x80,3]]).count))
        precondition(idle.count == 1, "idle first picture must not wait for another picture")
        do { _ = try parser.append(Data(repeating: 0xff, count: 32769)); fatalError("unbounded input accepted") } catch { }
        var invalid = AndroidH264Stream()
        do { _ = try invalid.append(Data(header + [0,0,0,0,0,0,0,0] + number(3000000, count: 4))); fatalError("unbounded frame accepted") } catch { }
        if CommandLine.arguments.count > 1 {
            let bytes = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
            var parser = AndroidH264Stream(), frames: [AndroidH264Frame] = []
            for offset in stride(from: 0, to: bytes.count, by: 997) { frames += try parser.append(bytes.subdata(in: offset..<min(bytes.count, offset + 997))) }
            precondition(!frames.isEmpty && frames.first!.isKeyFrame)
            print("Real phone video: \(frames.count) complete pictures parsed")
        }
        print("Android H.264 stream tests passed")
    }
}
