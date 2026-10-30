import Foundation

// Wire layout follows Alibaba Cloud's AxtMessage protocol (little endian).
// No SSH credentials or shell command framing are mixed into this transport.
struct ECSAXTFrame: Equatable, Sendable {
    var type: UInt32
    var channel = ""
    var instance = ""
    var timestamp: UInt64 = UInt64(Date.now.timeIntervalSince1970 * 1000)
    var input: UInt32 = 0
    var output: UInt32 = 0
    var payload = Data()

    func encode() throws -> Data {
        let channelBytes = Data(channel.utf8), instanceBytes = Data(instance.utf8)
        guard channelBytes.count <= 255, instanceBytes.count <= 255, payload.count <= 65535 else {
            throw ECSFailure(message: "终端消息超过协议限制。")
        }
        var bytes = Data()
        func write(_ value: UInt64, _ count: Int) {
            for index in 0..<count { bytes.append(UInt8(truncatingIfNeeded: value >> (8 * index))) }
        }
        write(UInt64(type), 4); bytes.append(Data("1.02".utf8))
        write(UInt64(channelBytes.count), 1); bytes.append(channelBytes)
        write(UInt64(instanceBytes.count), 1); bytes.append(instanceBytes)
        write(timestamp, 8); write(UInt64(input), 4); write(UInt64(output), 4)
        write(UInt64(payload.count), 2); write(0, 2); bytes.append(payload)
        return bytes
    }

    static func decode(_ data: Data) throws -> Self {
        let bytes = Array(data)
        var offset = 0
        func take(_ count: Int) throws -> Data {
            guard count >= 0, offset + count <= bytes.count else { throw ECSFailure(message: "终端消息不完整。") }
            defer { offset += count }
            return Data(bytes[offset..<(offset + count)])
        }
        func number(_ count: Int) throws -> UInt64 {
            let value = try take(count)
            return value.enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << (8 * $1.offset) }
        }
        let type = UInt32(try number(4))
        let version = try take(4)
        guard let text = String(data: version, encoding: .utf8), text.hasPrefix("1.") else {
            throw ECSFailure(message: "终端协议版本不受支持。")
        }
        let channelSize = Int(try number(1)), channelData = try take(channelSize)
        let instanceSize = Int(try number(1)), instanceData = try take(instanceSize)
        guard let channel = String(data: channelData, encoding: .utf8), let instance = String(data: instanceData, encoding: .utf8) else {
            throw ECSFailure(message: "终端通道标识无效。")
        }
        let timestamp = try number(8), input = UInt32(try number(4)), output = UInt32(try number(4))
        let length = Int(try number(2)), encoding = try number(1), reserved = try number(1)
        guard encoding == 0, reserved == 0 else { throw ECSFailure(message: "终端消息编码不受支持。") }
        let payload = try take(length)
        guard offset == bytes.count else { throw ECSFailure(message: "终端消息长度无效。") }
        return Self(type: type, channel: channel, instance: instance, timestamp: timestamp, input: input, output: output, payload: payload)
    }
}

struct ECSAXTFlow {
    private(set) var channel = ""
    private(set) var input: UInt32 = 0
    private(set) var output: UInt32 = 0
    private(set) var ready = false
    private var waiting: [ECSAXTFrame] = []
    private var waitingBytes = 0
    private var syncing = false

    struct Event { var bytes = Data(); var ready = false; var ended = false; var replies: [ECSAXTFrame] = [] }
    mutating func message(type: UInt32, payload: Data = Data()) throws -> ECSAXTFrame {
        if type == 0 || type == 2 {
            guard input < .max, waiting.count < 2048, waitingBytes + payload.count <= 1_048_576 else {
                throw ECSFailure(message: "终端尚未确认之前的输入，请等待或重新连接。")
            }
            input += 1
        }
        let frame = ECSAXTFrame(type: type, channel: channel, input: input, output: output, payload: payload)
        if type == 0 || type == 2 { waiting.append(frame); waitingBytes += payload.count }
        return frame
    }
    mutating func receive(_ frame: ECSAXTFrame) throws -> Event {
        if channel.isEmpty { channel = frame.channel }
        if !channel.isEmpty, !frame.channel.isEmpty, channel != frame.channel { throw ECSFailure(message: "终端通道不匹配。") }
        var event = Event()
        switch frame.type {
        case 1:
            guard frame.input <= input else { throw ECSFailure(message: "终端输入确认序号无效。") }
            let confirmed = frame.input
            waitingBytes -= waiting.filter { $0.input <= confirmed }.reduce(0) { $0 + $1.payload.count }
            waiting.removeAll { $0.input <= confirmed }
            if frame.output <= output { return event }
            guard output < .max else { throw ECSFailure(message: "终端会话已达到消息上限。") }
            if frame.output != output + 1 {
                if !syncing { event.replies = [try message(type: 6)]; syncing = true }
                return event
            }
            syncing = false; output = frame.output; ready = true
            event.bytes = frame.payload; event.ready = true
        case 6:
            // Resend the original frame/sequence only, on the same live channel.
            event.replies = waiting.filter { $0.input >= frame.input }
        case 5:
            guard let status = frame.payload.first else { throw ECSFailure(message: "终端状态消息无效。") }
            switch status {
            case 3: ready = true; event.ready = true
            case 2: throw ECSFailure(message: "云助手未能打开终端，请检查用户、权限和会话管理设置。")
            case 5, 6, 8: event.ended = true
            default: break
            }
        default: break
        }
        return event
    }
    static func size(columns: Int, rows: Int) -> Data {
        let cols = UInt16(max(2, min(1000, columns))), lines = UInt16(max(2, min(1000, rows)))
        return Data([UInt8(truncatingIfNeeded: lines), UInt8(lines >> 8), UInt8(truncatingIfNeeded: cols), UInt8(cols >> 8)])
    }
}
