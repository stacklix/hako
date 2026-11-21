import Foundation

struct AndroidH264Frame {
    let sps: Data
    let pps: Data
    let nals: [Data]
    var isKeyFrame: Bool { nals.contains { ($0.first ?? 0) & 31 == 5 } }
}

// scrcpy 3.3.4 framing: codec metadata then complete MediaCodec access units.
// An idle screen's first picture never waits for a subsequent picture.
struct AndroidH264Stream {
    private var pending: [UInt8] = []
    private var hasCodec = false
    private var sps = Data(), pps = Data()
    private var synchronized = false
    mutating func append(_ data: Data) throws -> [AndroidH264Frame] {
        guard !data.isEmpty, data.count <= 32768, pending.count + data.count <= 2 * 1024 * 1024 + 32780 else { throw Self.invalid() }
        pending.append(contentsOf: data)
        var offset = 0, output: [AndroidH264Frame] = []
        func number(_ start: Int, _ count: Int) -> UInt64 { pending[start..<(start + count)].reduce(0) { $0 << 8 | UInt64($1) } }
        if !hasCodec {
            guard pending.count >= 12 else { return [] }
            guard Array(pending.prefix(4)) == Array("h264".utf8) else { throw Self.invalid() }
            let width = number(4, 4), height = number(8, 4)
            guard width > 0, width <= 4096, height > 0, height <= 4096, width * height <= 4096 * 4096 else { throw Self.invalid() }
            hasCodec = true; offset = 12
        }
        while pending.count - offset >= 12 {
            let flags = pending[offset], size = Int(number(offset + 8, 4))
            guard (1...2 * 1024 * 1024).contains(size) else { throw Self.invalid() }
            guard pending.count - offset >= 12 + size else { break }
            let bytes = Array(pending[(offset + 12)..<(offset + 12 + size)])
            offset += 12 + size
            let nals = try Self.nals(bytes)
            if flags & 0x80 != 0 {
                for nal in nals {
                    let type = (nal.first ?? 0) & 31
                    guard nal.count <= 65536 else { throw Self.invalid() }
                    if type == 7 { if sps != nal { synchronized = false }; sps = nal }
                    else if type == 8 { pps = nal }
                }
            } else {
                let picture = nals.filter { let type = ($0.first ?? 0) & 31; return type == 1 || type == 5 }
                guard !picture.isEmpty, !sps.isEmpty, !pps.isEmpty else { throw Self.invalid() }
                let frame = AndroidH264Frame(sps: sps, pps: pps, nals: picture)
                if frame.isKeyFrame { synchronized = true }
                if synchronized { output.append(frame) }
            }
        }
        if offset > 0 { pending.removeFirst(offset) }
        return output
    }
    private static func nals(_ bytes: [UInt8]) throws -> [Data] {
        var starts: [(Int, Int)] = [], index = 0
        while index + 2 < bytes.count {
            if bytes[index] == 0, bytes[index + 1] == 0 {
                if bytes[index + 2] == 1 { starts.append((index, 3)); index += 3; continue }
                if index + 3 < bytes.count, bytes[index + 2] == 0, bytes[index + 3] == 1 {
                    starts.append((index, 4)); index += 4; continue
                }
            }
            index += 1
        }
        guard starts.first?.0 == 0, starts.count <= 256 else { throw Self.invalid() }
        var output: [Data] = []
        for index in starts.indices {
            let start = starts[index].0 + starts[index].1
            let end = index + 1 < starts.count ? starts[index + 1].0 : bytes.count
            guard end > start, bytes[start] & 0x80 == 0, (1...23).contains(bytes[start] & 31) else { throw Self.invalid() }
            output.append(Data(bytes[start..<end]))
        }
        return output
    }
    private static func invalid() -> NSError { NSError(domain: "AndroidVideo", code: 1, userInfo: [NSLocalizedDescriptionKey: "手机返回了无效的 H.264 视频。"]) }
}
