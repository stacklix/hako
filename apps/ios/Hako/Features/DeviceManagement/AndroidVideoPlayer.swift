import SwiftUI
import AVFoundation
import CryptoKit
import Combine

private struct AndroidVideoDescriptor: Decodable {
    let sessionId: String
    let codec: String
    let `protocol`: String
    let key: String
    let port: Int
    let addresses: [String]
    let path: String
    var secret: SymmetricKey? {
        guard codec == "h264", self.protocol == "hako-video-v1", let data = Data(base64Encoded: key), data.count == 32,
              UUID(uuidString: sessionId) != nil, path == "/agent/v1/streams/" + sessionId,
              (0...65535).contains(port), addresses.count <= 32 else { return nil }
        return SymmetricKey(data: data)
    }
}

@MainActor final class AndroidVideoPlayer: ObservableObject {
    let layer = AVSampleBufferDisplayLayer()
    @Published private(set) var connecting = false
    @Published private(set) var connected = false
    @Published private(set) var message: String?
    @Published private(set) var route = ""
    @Published private(set) var aspect: CGFloat = 9 / 20
    private var worker: Task<Void, Never>?
    private var socket: URLSessionWebSocketTask?
    private var sessionID: String?
    private var agent: ConsoleAgent?
    private var requestContext = ""
    private var generation = UUID()
    private var format: CMVideoFormatDescription?
    private var parameterSets: [Data] = []
    private let transport: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil; config.httpShouldSetCookies = false
        config.connectionProxyDictionary = [:]
        return URLSession(configuration: config, delegate: NoRedirectDelegate(), delegateQueue: nil)
    }()
    func connect(agent: ConsoleAgent, device: KageAndroidDevice, serial: String?) {
        guard worker == nil else { return }
        let ticket = UUID(); generation = ticket
        let id = UUID().uuidString.lowercased(), client = DeviceMonitorClient.shared
        sessionID = id; self.agent = agent
        let context = client.requestContext
        requestContext = context
        connecting = true; message = nil; route = ""
        layer.videoGravity = .resizeAspect
        worker = Task {
            defer { if generation == ticket { end(message) } }
            do {
                var params: [String: Any] = ["operation": "start", "sessionId": id, "deviceId": device.id]
                if let serial { params["serial"] = serial }
                let descriptor = try await client.invokeAgent(agent, method: KageAndroidCommand.stream, version: 1, params: params, as: AndroidVideoDescriptor.self)
                try Task.checkCancellation()
                guard generation == ticket, context == client.requestContext, descriptor.sessionId == id, let key = descriptor.secret else { throw CancellationError() }
                var media: URLSessionWebSocketTask?
                var initialFrame: Data?
                if descriptor.port > 0 {
                    for address in descriptor.addresses.prefix(8) where AgentLanDescriptor.isOnWiFiSubnet(address) {
                        guard let url = URL(string: "ws://\(address):\(descriptor.port)" + descriptor.path) else { continue }
                        var request = URLRequest(url: url); request.timeoutInterval = 4
                        let direct = transport.webSocketTask(with: request); direct.maximumMessageSize = 65564
                        self.socket = direct; direct.resume()
                        do {
                            let plain = try JSONSerialization.data(withJSONObject: ["sessionId": id, "timestamp": Int64(Date().timeIntervalSince1970 * 1000)])
                            let sealed = try AES.GCM.seal(plain, using: key, authenticating: Data(("hako-agent-lan-v1:video-client:" + id).utf8))
                            try await direct.send(.data(sealed.combined!))
                            // First encrypted frame proves the media channel is usable.
                            let first = try await receive(direct, timeout: 12)
                            try Task.checkCancellation()
                            guard generation == ticket, context == client.requestContext else { direct.cancel(with: .goingAway, reason: nil); return }
                            _ = try unpack(first, key: key, id: id, sequence: 0)
                            initialFrame = first
                            media = direct; route = "局域网直连"; break
                        } catch {
                            direct.cancel(with: .goingAway, reason: nil)
                            try Task.checkCancellation()
                            // Once a producer has started, never create a second source.
                            if connected { throw error }
                        }
                    }
                }
                if media == nil {
                    let auth = AuthenticatedServerService.shared
                    let (relay, hello) = try await auth.openWebSocket("/ws/streams", logSource: .devices)
                    guard generation == ticket, context == client.requestContext, !Task.isCancelled else { relay.cancel(with: .goingAway, reason: nil); return }
                    self.socket = relay; relay.maximumMessageSize = 65564
                    struct Relay: Decodable { let id: String; let producerToken: String }
                    let relayInfo = try JSONDecoder().decode(Relay.self, from: hello)
                    struct Started: Decodable { let connecting: Bool }
                    let _: Started = try await client.invokeAgent(agent, method: KageAndroidCommand.stream, version: 1,
                        params: ["operation":"relay", "sessionId":id, "relayId":relayInfo.id, "ticket":relayInfo.producerToken], as: Started.self)
                    try Task.checkCancellation()
                    guard generation == ticket, context == client.requestContext else { relay.cancel(with: .goingAway, reason: nil); return }
                    media = relay; route = "服务器转发"
                }
                guard let media else { throw URLError(.cannotConnectToHost) }
                self.socket = media
                var parser = AndroidH264Stream(), sequence: UInt64 = 0
                while !Task.isCancelled, generation == ticket, context == client.requestContext, client.authenticated, !client.logoutPending {
                    let data: Data
                    if let first = initialFrame { initialFrame = nil; data = first }
                    else { data = try await receive(media, timeout: connected ? 45 : 15) }
                    try Task.checkCancellation()
                    guard generation == ticket, context == client.requestContext else { return }
                    let raw = try unpack(data, key: key, id: id, sequence: sequence); sequence += 1
                    if !raw.isEmpty { for frame in try parser.append(raw) { try enqueue(frame) } }
                }
            } catch {
                if !Task.isCancelled, generation == ticket {
                    message = (error as? ServerHTTPError)?.status == 404 ? "服务端尚未启用视频转发，请更新服务端。" : error.localizedDescription
                }
            }
        }
    }
    private func receive(_ socket: URLSessionWebSocketTask, timeout: Double) async throws -> Data {
        let deadline = Task { try await Task.sleep(for: .seconds(timeout)); socket.cancel(with: .goingAway, reason: nil) }
        defer { deadline.cancel() }
        return try await withTaskCancellationHandler { try await socket.receiveData() }
            onCancel: { socket.cancel(with: .goingAway, reason: nil) }
    }
    private func unpack(_ data: Data, key: SymmetricKey, id: String, sequence: UInt64) throws -> Data {
        guard (37...32805).contains(data.count) else { throw URLError(.badServerResponse) }
        let plain = try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: key,
            authenticating: Data(("hako-agent-lan-v1:video-server:" + id).utf8))
        let received = plain.prefix(8).reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        guard plain.count > 9, received == sequence else { throw URLError(.badServerResponse) }
        if plain[8] == 1 { throw HakoError(message: String(decoding: plain.dropFirst(9), as: UTF8.self)) }
        if plain[8] == 2, sequence == 0, Data(plain.dropFirst(9)) == Data("ready".utf8) { return Data() }
        if plain[8] == 3, Data(plain.dropFirst(9)) == Data("alive".utf8) { return Data() }
        guard plain[8] == 0 else { throw URLError(.badServerResponse) }
        return Data(plain.dropFirst(9))
    }
    private func enqueue(_ frame: AndroidH264Frame) throws {
        if parameterSets != [frame.sps, frame.pps] {
            var next: CMFormatDescription?
            let status = frame.sps.withUnsafeBytes { sps in frame.pps.withUnsafeBytes { pps in
                let pointers = [sps.baseAddress!.assumingMemoryBound(to: UInt8.self), pps.baseAddress!.assumingMemoryBound(to: UInt8.self)]
                let sizes = [frame.sps.count, frame.pps.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: kCFAllocatorDefault, parameterSetCount: 2,
                    parameterSetPointers: pointers, parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &next)
            } }
            guard status == noErr, let next else { throw HakoError(message: "无法解析手机视频格式。") }
            format = next; parameterSets = [frame.sps, frame.pps]
            let dimensions = CMVideoFormatDescriptionGetDimensions(next)
            guard dimensions.width > 0, dimensions.height > 0, Int64(dimensions.width) * Int64(dimensions.height) <= 4096 * 4096 else { throw URLError(.badServerResponse) }
            aspect = CGFloat(dimensions.width) / CGFloat(dimensions.height)
            layer.flushAndRemoveImage()
        }
        guard let format else { return }
        var bytes = Data()
        for nal in frame.nals {
            var size = UInt32(nal.count).bigEndian
            withUnsafeBytes(of: &size) { bytes.append(contentsOf: $0) }; bytes.append(nal)
        }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: bytes.count,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0, dataLength: bytes.count,
            flags: 0, blockBufferOut: &block) == kCMBlockBufferNoErr, let block else { throw URLError(.cannotDecodeContentData) }
        let copied = bytes.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes.count) }
        guard copied == noErr else { throw URLError(.cannotDecodeContentData) }
        var sample: CMSampleBuffer?, size = bytes.count
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
            sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1,
            sampleSizeArray: &size, sampleBufferOut: &sample) == noErr, let sample else { throw URLError(.cannotDecodeContentData) }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) {
            let attachment = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(attachment, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(), Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        guard layer.status != .failed, layer.isReadyForMoreMediaData else { throw HakoError(message: "视频播放跟不上当前画面，请重新连接。") }
        layer.enqueue(sample)
        connecting = false; connected = true
    }
    func disconnect() { end(nil) }
    private func end(_ message: String?) {
        let id = sessionID, agent = agent, context = requestContext
        generation = UUID(); worker?.cancel(); worker = nil
        socket?.cancel(with: .goingAway, reason: nil); socket = nil
        sessionID = nil; self.agent = nil
        connecting = false; connected = false; self.message = message
        format = nil; parameterSets = []; layer.flushAndRemoveImage()
        if let id, let agent {
            Task {
                guard DeviceMonitorClient.shared.requestContext == context else { return }
                struct Stopped: Decodable { let stopped: Bool }
                let _: Stopped? = try? await DeviceMonitorClient.shared.invokeAgent(agent, method: KageAndroidCommand.stream, version: 1,
                    params: ["operation":"stop", "sessionId":id], as: Stopped.self)
            }
        }
    }
}

private struct AndroidVideoSurface: UIViewRepresentable {
    let layer: AVSampleBufferDisplayLayer
    final class Surface: UIView {
        let video: AVSampleBufferDisplayLayer
        init(_ video: AVSampleBufferDisplayLayer) { self.video = video; super.init(frame: .zero); backgroundColor = .black; layer.addSublayer(video) }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func layoutSubviews() { super.layoutSubviews(); video.frame = bounds }
    }
    func makeUIView(context: Context) -> Surface { Surface(layer) }
    func updateUIView(_ view: Surface, context: Context) { view.setNeedsLayout() }
}

struct AndroidLiveScreenView: View {
    let agent: ConsoleAgent
    let device: KageAndroidDevice
    let serial: String?
    let available: Bool
    @StateObject private var player = AndroidVideoPlayer()
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("实时屏幕").font(.headline); Spacer(); if player.connected { Text(player.route).font(.caption).foregroundStyle(.secondary) } }
            ZStack {
                AndroidVideoSurface(layer: player.layer).aspectRatio(player.aspect, contentMode: .fit).frame(maxHeight: 480)
                if !player.connected {
                    VStack(spacing: 12) {
                        if player.connecting { ProgressView().tint(.white); Text("正在连接屏幕…") }
                        else { Image(systemName: "rectangle.on.rectangle").font(.title); Text("投屏未连接") }
                    }.font(.subheadline).foregroundStyle(.white)
                }
            }.clipShape(RoundedRectangle(cornerRadius: 12))
            if let message = player.message { Text(message).font(.caption).foregroundStyle(.orange) }
            Button(player.connected || player.connecting ? "断开投屏" : "连接投屏") {
                if player.connected || player.connecting { player.disconnect() }
                else { player.connect(agent: agent, device: device, serial: serial) }
            }.buttonStyle(HakoActionButtonStyle(primary: !player.connected)).disabled(!available && !player.connected && !player.connecting)
            Text("连续视频画面。切换页面或进入后台会断开；手机需要先亮屏，投屏不会解锁手机。")
                .font(.caption).foregroundStyle(.secondary)
        }.devicePagePanel()
        .task { if available, scenePhase == .active { player.connect(agent: agent, device: device, serial: serial) } }
        .onDisappear { player.disconnect() }
        .onChange(of: scenePhase) { _, phase in if phase != .active { player.disconnect() } }
        .onChange(of: serial) { _, _ in player.disconnect() }
        .onChange(of: available) { _, value in if !value { player.disconnect() } }
    }
}
