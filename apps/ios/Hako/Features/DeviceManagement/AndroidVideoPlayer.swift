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
    @Published private(set) var stopping = false
    @Published private(set) var message: String?
    @Published private(set) var shutdownMessage: String?
    @Published private(set) var route = ""
    @Published private(set) var aspect: CGFloat = 9 / 20
    private var worker: Task<Void, Never>?
    private var socket: URLSessionWebSocketTask?
    private var sessionID: String?
    private var agent: ConsoleAgent?
    private var deviceID: String?
    private var serial: String?
    private var requestContext = ""
    private var generation = UUID()
    private var format: CMVideoFormatDescription?
    private var parameterSets: [Data] = []
    private var pixels = CGSize.zero
    private var controlKey: SymmetricKey?
    private var inputSequence: UInt64 = 0
    private var inputs: [Data] = []
    private var inputWorker: Task<Void, Never>?
    private let transport: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil; config.httpShouldSetCookies = false
        config.connectionProxyDictionary = [:]
        return URLSession(configuration: config, delegate: NoRedirectDelegate(), delegateQueue: nil)
    }()
    func connect(agent: ConsoleAgent, device: KageAndroidDevice, serial: String?) {
        guard worker == nil, !stopping else { return }
        let ticket = UUID(); generation = ticket
        let id = UUID().uuidString.lowercased(), client = DeviceMonitorClient.shared
        sessionID = id; self.agent = agent; deviceID = device.id; self.serial = serial
        let context = client.requestContext
        requestContext = context
        connecting = true; message = nil; shutdownMessage = nil; route = ""
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
                controlKey = key; inputSequence = 0
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
            pixels = CGSize(width: CGFloat(dimensions.width), height: CGFloat(dimensions.height))
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
    func touch(_ action: UInt8, point: CGPoint, surface: CGSize) {
        guard connected, let packet = AndroidScreenInput.touch(action: action, point: point, surface: surface, pixels: pixels) else { return }
        // Replace queued intermediate moves; never drop finger down/up/cancel.
        if action == 2, inputs.last?[1] == 2 { inputs[inputs.count - 1] = packet }
        else { inputs.append(packet) }
        guard inputs.count <= 128 else { end("触控发送过慢，请重新连接。"); return }
        guard inputWorker == nil, let socket, let key = controlKey, let id = sessionID else { return }
        let ticket = generation
        inputWorker = Task {
            defer { if generation == ticket { inputWorker = nil } }
            do {
                while !inputs.isEmpty, generation == ticket, !Task.isCancelled {
                    let packet = inputs.removeFirst()
                    var number = inputSequence.bigEndian; inputSequence += 1
                    var plain = withUnsafeBytes(of: &number) { Data($0) }; plain.append(packet)
                    let sealed = try AES.GCM.seal(plain, using: key,
                        authenticating: Data(("hako-agent-lan-v1:video-input:" + id).utf8))
                    try await socket.send(.data(sealed.combined!))
                }
            } catch {
                if generation == ticket, !Task.isCancelled { end("触控连接已中断，请重新开启投屏。") }
            }
        }
    }
    private func end(_ message: String?) {
        guard sessionID != nil || worker != nil else { return }
        let id = sessionID, agent = agent, context = requestContext, deviceID = deviceID, serial = serial
        generation = UUID(); worker?.cancel(); worker = nil
        inputWorker?.cancel(); inputWorker = nil; inputs = []; controlKey = nil; pixels = .zero
        let closing = generation
        socket?.cancel(with: .goingAway, reason: nil); socket = nil
        sessionID = nil; self.agent = nil; self.deviceID = nil; self.serial = nil
        connecting = false; connected = false; self.message = message
        format = nil; parameterSets = []; layer.flushAndRemoveImage()
        if let id, let agent {
            stopping = true
            Task {
                defer { if generation == closing { stopping = false } }
                guard DeviceMonitorClient.shared.requestContext == context else { return }
                do {
                    let result = try await AndroidVideoShutdown.finish {
                        struct Stopped: Decodable { let stopped: Bool }
                        let reply = try await DeviceMonitorClient.shared.invokeAgent(agent, method: KageAndroidCommand.stream, version: 1,
                            params: ["operation":"stop", "sessionId":id], as: Stopped.self)
                        guard reply.stopped else { throw HakoError(message: "关闭结果未确认。") }
                    } screen: {
                        guard generation == closing, DeviceMonitorClient.shared.requestContext == context, let deviceID else { throw CancellationError() }
                        var params: [String: Any] = ["deviceId": deviceID]
                        if let serial { params["serial"] = serial }
                        let detail = try await DeviceMonitorClient.shared.invokeAgent(agent, method: KageAndroidCommand.detail, version: 1,
                            params: params, as: KageAndroidDetail.self)
                        guard detail.isValid else { throw URLError(.badServerResponse) }
                        return detail.screen
                    }
                    if generation == closing, DeviceMonitorClient.shared.requestContext == context {
                        shutdownMessage = result
                    }
                } catch { /* Context changes and cancellation do not describe this phone's state. */ }
            }
        }
    }
}

private struct AndroidVideoSurface: UIViewRepresentable {
    @ObservedObject var player: AndroidVideoPlayer
    final class Surface: UIView {
        let video: AVSampleBufferDisplayLayer
        var onTouch: ((UInt8, CGPoint, CGSize) -> Void)?
        init(_ video: AVSampleBufferDisplayLayer) {
            self.video = video; super.init(frame: .zero); backgroundColor = .black; layer.addSublayer(video)
            let gesture = UILongPressGestureRecognizer(target: self, action: #selector(touchChanged(_:)))
            gesture.minimumPressDuration = 0; gesture.allowableMovement = .greatestFiniteMagnitude
            gesture.numberOfTouchesRequired = 1
            addGestureRecognizer(gesture)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func layoutSubviews() { super.layoutSubviews(); video.frame = bounds }
        @objc private func touchChanged(_ gesture: UILongPressGestureRecognizer) {
            let action: UInt8
            switch gesture.state {
            case .began: action = 0
            case .changed: action = 2
            case .ended: action = 1
            case .cancelled: action = 3
            default: return
            }
            onTouch?(action, gesture.location(in: self), bounds.size)
        }
    }
    func makeUIView(context: Context) -> Surface { Surface(player.layer) }
    func updateUIView(_ view: Surface, context: Context) {
        view.onTouch = { action, point, size in player.touch(action, point: point, surface: size) }
        view.isUserInteractionEnabled = player.connected
        if player.layer.superlayer !== view.layer { view.layer.addSublayer(player.layer) }
        view.setNeedsLayout()
    }
}

private struct AndroidVideoViewport: Layout {
    let aspect: CGFloat
    let maximumHeight: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let heightLimit = min(proposal.height ?? maximumHeight, maximumHeight)
        let width = min(proposal.width ?? heightLimit * aspect, heightLimit * aspect)
        return CGSize(width: width, height: width / aspect)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for subview in subviews {
            subview.place(at: CGPoint(x: bounds.midX, y: bounds.midY), anchor: .center,
                          proposal: ProposedViewSize(bounds.size))
        }
    }
}

struct AndroidLiveScreenView: View {
    let agent: ConsoleAgent
    let device: KageAndroidDevice
    let serial: String?
    let available: Bool
    @StateObject private var player = AndroidVideoPlayer()
    @State private var fullScreen = false
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("实时屏幕").font(.headline); Spacer()
                if player.connected {
                    Text(player.route).font(.caption).foregroundStyle(.secondary)
                    Button { fullScreen = true } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right").frame(minWidth: 44, minHeight: 44)
                    }.accessibilityLabel("全屏投屏")
                }
            }
            AndroidVideoViewport(aspect: player.connected ? player.aspect : 16 / 9,
                                 maximumHeight: player.connected ? 360 : 180) {
                ZStack {
                    if fullScreen { Color.black }
                    else { AndroidVideoSurface(player: player) }
                    if !player.connected {
                        VStack(spacing: 12) {
                            if player.connecting { ProgressView().tint(.white); Text("正在连接屏幕…") }
                            else { Image(systemName: "rectangle.on.rectangle").font(.title); Text("投屏未连接") }
                        }.font(.subheadline).foregroundStyle(.white)
                    }
                }.clipShape(RoundedRectangle(cornerRadius: 12))
            }.frame(maxWidth: .infinity, alignment: .center)
            if let message = player.message { Text(message).font(.caption).foregroundStyle(.orange) }
            if let message = player.shutdownMessage { Text(message).font(.caption).foregroundStyle(.orange) }
            if player.connected { Text("可直接点击、长按或单指滑动屏幕。部分手机需开启「USB 调试（安全设置）」。").font(.caption).foregroundStyle(.secondary) }
            Button(player.stopping ? "正在关闭投屏…" : player.connected || player.connecting ? "关闭投屏" : "开启投屏") {
                if player.connected || player.connecting { player.disconnect() }
                else { player.connect(agent: agent, device: device, serial: serial) }
            }.buttonStyle(HakoActionButtonStyle(primary: !player.connected))
                .disabled(player.stopping || (!available && !player.connected && !player.connecting))
            Text("开启投屏时自动亮屏，关闭时自动息屏。切换页面或进入后台也会关闭投屏；亮屏不会解锁手机。")
                .font(.caption).foregroundStyle(.secondary)
        }.devicePagePanel()
        .fullScreenCover(isPresented: $fullScreen) { AndroidFullScreenView(player: player) }
        .onDisappear { if !fullScreen { player.disconnect() } }
        .onChange(of: scenePhase) { _, phase in if phase != .active { player.disconnect() } }
        .onChange(of: serial) { _, _ in player.disconnect() }
        .onChange(of: available) { _, value in if !value { player.disconnect() } }
    }
}

private struct AndroidFullScreenView: View {
    @ObservedObject var player: AndroidVideoPlayer
    @Environment(\.dismiss) private var dismiss
    @State private var exitPosition: CGPoint?
    @GestureState private var exitTranslation = CGSize.zero
    var body: some View {
        ZStack {
            GeometryReader { geometry in
                AndroidVideoViewport(aspect: player.aspect, maximumHeight: geometry.size.height) {
                    AndroidVideoSurface(player: player)
                }.frame(width: geometry.size.width, height: geometry.size.height)
            }.ignoresSafeArea()
            GeometryReader { controls in exitButton(in: controls.size) }
                .coordinateSpace(name: "android-fullscreen-controls")
        }
        .background(.black).foregroundStyle(.white).statusBarHidden().persistentSystemOverlays(.hidden)
        .onChange(of: player.connected) { _, connected in if !connected { dismiss() } }
    }

    private func boundedPosition(_ point: CGPoint, in size: CGSize) -> CGPoint {
        let inset: CGFloat = 34
        return CGPoint(x: min(max(point.x, inset), max(inset, size.width - inset)),
                       y: min(max(point.y, inset), max(inset, size.height - inset)))
    }

    private func exitButton(in size: CGSize) -> some View {
        let origin = boundedPosition(exitPosition ?? CGPoint(x: 34, y: 34), in: size)
        let position = boundedPosition(CGPoint(x: origin.x + exitTranslation.width,
                                               y: origin.y + exitTranslation.height), in: size)
        return Button { dismiss() } label: {
            Image(systemName: "arrow.down.right.and.arrow.up.left")
                .font(.body.weight(.semibold))
                .frame(width: 44, height: 44)
                .background(.black.opacity(0.6), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("退出全屏")
        .accessibilityHint("点击返回投屏卡片，也可拖动按钮调整位置")
        .highPriorityGesture(
            DragGesture(minimumDistance: 8, coordinateSpace: .named("android-fullscreen-controls"))
                .updating($exitTranslation) { value, translation, _ in translation = value.translation }
                .onEnded { value in
                    exitPosition = boundedPosition(CGPoint(x: origin.x + value.translation.width,
                                                          y: origin.y + value.translation.height), in: size)
                }
        )
        .position(position)
    }
}
