import SwiftUI
import AVFoundation
import CryptoKit
import Combine
import UIKit.UIGestureRecognizerSubclass

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
    @Published private(set) var navigationPending = false
    @Published private(set) var navigationMessage: String?
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
    private var navigationWorker: Task<Void, Never>?
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
    func navigate(_ navigation: AndroidScreenNavigation) {
        guard connected, !navigationPending, let agent, let id = sessionID else { return }
        let client = DeviceMonitorClient.shared, context = requestContext, ticket = generation
        guard context == client.requestContext, client.authenticated, !client.logoutPending else { return }
        navigationPending = true; navigationMessage = nil
        navigationWorker = Task {
            defer { if generation == ticket { navigationPending = false; navigationWorker = nil } }
            do {
                struct Sent: Decodable { let sent: Bool }
                let result = try await client.invokeAgent(agent, method: KageAndroidCommand.stream, version: 1,
                    params: ["operation": "navigate", "sessionId": id, "navigation": navigation.rawValue], as: Sent.self)
                try Task.checkCancellation()
                guard generation == ticket, context == client.requestContext else { return }
                guard result.sent else { throw HakoError(message: "导航指令未确认发送。") }
            } catch {
                if generation == ticket, context == client.requestContext, !Task.isCancelled {
                    navigationMessage = navigation.title + "失败：" + error.localizedDescription
                }
            }
        }
    }
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
        navigationWorker?.cancel(); navigationWorker = nil; navigationPending = false; navigationMessage = nil
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
    @State private var controlsCollapsed = false
    @State private var controlsPosition = CGPoint.zero
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
                .overlay {
                    if player.connected && !fullScreen {
                        AndroidFloatingControls(player: player, collapsed: $controlsCollapsed, position: $controlsPosition,
                                                fullScreen: false) { fullScreen = true }
                    }
                }
            if let message = player.navigationMessage { Text(message).font(.caption).foregroundStyle(.orange) }
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
        .fullScreenCover(isPresented: $fullScreen) {
            AndroidFullScreenView(player: player, controlsCollapsed: $controlsCollapsed, controlsPosition: $controlsPosition)
        }
        .onDisappear { if !fullScreen { player.disconnect() } }
        .onChange(of: scenePhase) { _, phase in if phase != .active { player.disconnect() } }
        .onChange(of: serial) { _, _ in player.disconnect() }
        .onChange(of: available) { _, value in if !value { player.disconnect() } }
    }
}

private struct AndroidFloatingControls: View {
    @ObservedObject var player: AndroidVideoPlayer
    @Binding var collapsed: Bool
    @Binding var position: CGPoint
    let fullScreen: Bool
    let toggleFullScreen: () -> Void
    @State private var translation = CGSize.zero
    private var controlsSize: CGSize { collapsed ? CGSize(width: 44, height: 44) : CGSize(width: 228, height: 64) }

    var body: some View {
        GeometryReader { geometry in
            let center = AndroidFloatingControlsLayout.center(in: geometry.size, controls: controlsSize, position: position, translation: translation)
            AndroidFloatingToolbar(collapsed: collapsed, fullScreen: fullScreen,
                                   navigationEnabled: player.connected && !player.navigationPending,
                                   toggleFullScreen: toggleFullScreen, navigate: player.navigate,
                                   toggleCollapsed: { collapsed.toggle() }) { delta, ended in
                if ended {
                    let final = AndroidFloatingControlsLayout.center(in: geometry.size, controls: controlsSize, position: position, translation: delta)
                    position = AndroidFloatingControlsLayout.position(for: final, in: geometry.size, controls: controlsSize)
                    translation = .zero
                } else { translation = delta }
            }
            .frame(width: controlsSize.width, height: controlsSize.height)
            .background(Color(white: 0.15).opacity(0.95), in: RoundedRectangle(cornerRadius: collapsed ? 22 : 18))
            .overlay { RoundedRectangle(cornerRadius: collapsed ? 22 : 18).strokeBorder(.white.opacity(0.18), lineWidth: 0.5).allowsHitTesting(false) }
            .position(center)
        }
    }
}

// Native controls receive touch-up directly. The drag recognizer stays possible
// through normal finger jitter and only cancels a button once dragging begins.
private struct AndroidFloatingToolbar: UIViewRepresentable {
    let collapsed: Bool
    let fullScreen: Bool
    let navigationEnabled: Bool
    let toggleFullScreen: () -> Void
    let navigate: (AndroidScreenNavigation) -> Void
    let toggleCollapsed: () -> Void
    let drag: (CGSize, Bool) -> Void

    func makeUIView(context: Context) -> Toolbar { Toolbar(self) }
    func updateUIView(_ view: Toolbar, context: Context) { view.update(self) }

    final class Toolbar: UIView {
        private var parent: AndroidFloatingToolbar
        private var buttons: [UIButton] = []
        private let movement = AndroidFloatingDragRecognizer()
        private var configured = false

        init(_ parent: AndroidFloatingToolbar) {
            self.parent = parent
            super.init(frame: .zero)
            for index in 0..<6 {
                let button = UIButton(type: .custom)
                button.tag = index
                button.addTarget(self, action: #selector(pressed(_:)), for: .touchUpInside)
                button.accessibilityHint = "也可拖动整组工具条调整位置"
                addSubview(button); buttons.append(button)
            }
            movement.addTarget(self, action: #selector(moved(_:)))
            movement.delaysTouchesBegan = false; movement.delaysTouchesEnded = false
            movement.cancelsTouchesInView = false
            addGestureRecognizer(movement)
            update(parent)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        func update(_ value: AndroidFloatingToolbar) {
            let changed = !configured || parent.collapsed != value.collapsed || parent.fullScreen != value.fullScreen || parent.navigationEnabled != value.navigationEnabled
            parent = value
            // Video frames refresh the hosting view frequently. Keep native
            // button tracking/configuration stable until a control state changes.
            guard changed else { return }
            configured = true
            configure(buttons[0], title: value.fullScreen ? "退出" : "全屏",
                      symbol: value.fullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                      accessibility: value.fullScreen ? "退出全屏" : "全屏投屏")
            for (index, navigation) in AndroidScreenNavigation.allCases.enumerated() {
                let button = buttons[index + 1]
                configure(button, title: navigation.title, symbol: navigation.symbol, accessibility: navigation.accessibilityLabel)
                button.isEnabled = value.navigationEnabled
                button.alpha = value.navigationEnabled ? 1 : 0.5
            }
            configure(buttons[4], title: "收起", symbol: "chevron.compact.left", accessibility: "收起投屏工具条")
            buttons[4].alpha = 0.65
            configure(buttons[5], title: nil, symbol: "ellipsis", accessibility: "展开投屏工具条")
            for button in buttons { button.isHidden = value.collapsed ? button.tag != 5 : button.tag == 5 }
            setNeedsLayout()
        }
        private func configure(_ button: UIButton, title: String?, symbol: String, accessibility: String) {
            var configuration = UIButton.Configuration.plain()
            configuration.title = title
            configuration.image = UIImage(systemName: symbol)
            configuration.imagePlacement = .top; configuration.imagePadding = 3
            configuration.contentInsets = .zero
            configuration.baseForegroundColor = .white
            configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 19)
            configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
                var attributes = attributes; attributes.font = .systemFont(ofSize: 11); return attributes
            }
            button.configuration = configuration; button.accessibilityLabel = accessibility
        }
        override func layoutSubviews() {
            super.layoutSubviews()
            for button in buttons {
                button.frame = parent.collapsed ? bounds : CGRect(x: 4 + CGFloat(button.tag) * 44, y: 4, width: 44, height: 56)
            }
        }
        override func didMoveToWindow() {
            super.didMoveToWindow()
            var ancestor = superview
            while let view = ancestor {
                if let scroll = view as? UIScrollView { scroll.panGestureRecognizer.require(toFail: movement); break }
                ancestor = view.superview
            }
        }
        @objc private func pressed(_ button: UIButton) {
            switch button.tag {
            case 0: parent.toggleFullScreen()
            case 1...3: parent.navigate(AndroidScreenNavigation.allCases[button.tag - 1])
            default: parent.toggleCollapsed()
            }
        }
        @objc private func moved(_ gesture: AndroidFloatingDragRecognizer) {
            guard gesture.isDragging else { return }
            switch gesture.state {
            case .began, .changed: parent.drag(gesture.translation, false)
            case .ended, .cancelled: parent.drag(gesture.translation, true)
            default: break
            }
        }
    }
}

private final class AndroidFloatingDragRecognizer: UIGestureRecognizer {
    private var origin: CGPoint?
    private var movement = AndroidFloatingDragState()
    var translation: CGSize { movement.translation }
    var isDragging: Bool { movement.isDragging }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard touches.count == 1, origin == nil, let touch = touches.first else {
            state = state == .possible ? .failed : .cancelled; return
        }
        origin = touch.location(in: view?.window)
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let origin, let touch = touches.first else { return }
        let point = touch.location(in: view?.window)
        movement.move(to: CGSize(width: point.x - origin.x, height: point.y - origin.y))
        if state == .possible {
            if movement.isDragging { cancelsTouchesInView = true; state = .began }
        } else if state == .began || state == .changed { state = .changed }
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        // Claim a tap without cancelling native button delivery. This also
        // prevents an ancestor ScrollView from winning when small jitter ends.
        state = .ended
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        state = state == .possible ? .failed : .cancelled
    }
    override func reset() { super.reset(); origin = nil; movement = AndroidFloatingDragState(); cancelsTouchesInView = false }
}

private struct AndroidFullScreenView: View {
    @ObservedObject var player: AndroidVideoPlayer
    @Binding var controlsCollapsed: Bool
    @Binding var controlsPosition: CGPoint
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        ZStack {
            GeometryReader { geometry in
                AndroidVideoViewport(aspect: player.aspect, maximumHeight: geometry.size.height) {
                    AndroidVideoSurface(player: player)
                }.frame(width: geometry.size.width, height: geometry.size.height)
            }
            AndroidFloatingControls(player: player, collapsed: $controlsCollapsed, position: $controlsPosition,
                                    fullScreen: true) { dismiss() }
        }
        .overlay(alignment: .bottom) {
            if let message = player.navigationMessage {
                Text(message).font(.caption).foregroundStyle(.orange).padding(12)
                    .background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 10))
                    .padding(12).allowsHitTesting(false)
            }
        }
        .background(.black).foregroundStyle(.white).statusBarHidden().persistentSystemOverlays(.hidden)
        .onChange(of: player.connected) { _, connected in if !connected { dismiss() } }
    }

}
