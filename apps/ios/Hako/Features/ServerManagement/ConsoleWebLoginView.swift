import SwiftUI
import Combine
import AVFoundation
import UIKit

struct ConsoleWebLoginView: View {
    var initialPayload: String? = nil
    @State private var loadedInitialPayload = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var client = ConsoleClient.shared
    @State private var showingServerSettings = false
    @State private var request: ConsoleWebLoginRequest?
    @State private var approved: Bool?
    @State private var busy = false
    @State private var text = ""
    @State private var scannerError: String?
    @State private var message: String?
    @State private var now = Date.now
    @State private var initialRemaining: TimeInterval = 1

    var body: some View {
        SettingsSheet(title: request != nil || approved != nil ? "网页登录" : "扫描二维码",
                      isBusy: busy) {
            Group {
                if !client.authenticated || client.logoutPending {
                    Form {
                        Section("Hako 服务器登录") {
                            Text(client.serverURL.isEmpty ? "请先配置 Hako 服务器，并使用已登记的本机密钥登录后批准网页登录。" : "请先验证 Hako 服务器登录，再扫描网页登录二维码。")
                                .foregroundStyle(.secondary)
                            Button("服务器与登录") { showingServerSettings = true }
                            if client.hasSavedSession || client.logoutPending {
                                Button(client.logoutPending ? "重试撤销服务端会话" : "验证并继续") {
                                    Task { await client.restore() }
                                }.disabled(client.busy)
                            }
                        }
                        if let message = client.message {
                            Section { Text(message).font(.footnote).foregroundStyle(.secondary) }
                        }
                    }
                } else if let request {
                    ConsoleWebLoginConfirmation(
                        request: request, now: now, initialRemaining: initialRemaining,
                        busy: busy, canRespond: !expired(request) && client.authenticated,
                        message: message,
                        onConfirm: { Task { await confirm(request, approve: true) } },
                        onReject: { Task { await confirm(request, approve: false) } }
                    )
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("重新扫码") { scanAgain() }.disabled(busy)
                        }
                    }
                } else if let approved {
                    ContentUnavailableView {
                        Label(approved ? "已确认登录" : "已拒绝登录", systemImage: approved ? "checkmark.circle" : "xmark.circle")
                    } description: {
                        Text(approved ? "网页将自动完成登录。" : "此次网页登录请求已拒绝。")
                    } actions: {
                        ConsoleLoginCompletionButton { dismiss() }
                    }
                } else {
                    VStack(spacing: 0) {
                        if busy {
                            ProgressView("正在读取登录请求…")
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else if let scannerError {
                            ContentUnavailableView {
                                Label("无法扫码", systemImage: "exclamationmark.triangle")
                            } description: {
                                Text(scannerError)
                            } actions: {
                                Button("重新扫码") { scanAgain() }.buttonStyle(.borderedProminent).tint(.blue)
                            }
                            .frame(maxHeight: .infinity)
                        } else {
                            ConsoleQRScanner(onScan: { payload in
                                Task { await inspect(payload, scanned: true) }
                            }, onError: { scannerError = $0 })
                            .frame(maxHeight: .infinity)
                            .overlay(alignment: .bottom) {
                                Text("扫描自己正在使用的 Hako 网页登录二维码")
                                    .font(.callout).foregroundStyle(.white)
                                    .padding().background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 12))
                                    .padding()
                            }
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            Text("粘贴登录请求").font(.headline)
                            Text("也可复制网页上的登录请求，粘贴后进入确认页。")
                                .font(.footnote).foregroundStyle(.secondary)
                            TextEditor(text: $text).frame(height: 75).font(.caption.monospaced())
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                                .accessibilityLabel("登录请求")
                                .overlay { RoundedRectangle(cornerRadius: 8).stroke(.secondary.opacity(0.3)) }
                            Button("解析登录请求") { Task { await inspect(text) } }
                                .buttonStyle(.borderedProminent).tint(.blue)
                                .disabled(busy || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !client.authenticated)
                            if let message { Text(message).font(.footnote).foregroundStyle(.secondary) }
                        }
                        .padding().background(.background)
                        .disabled(busy)
                    }
                }
            }
            .task(id: scenePhase) {
                guard scenePhase == .active else { return }
                await client.restore()
            }
            .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { now = $0 }
            .task(id: client.authenticated) {
                guard client.authenticated, !loadedInitialPayload, let initialPayload else { return }
                loadedInitialPayload = true
                await inspect(initialPayload)
            }
            .sheet(isPresented: $showingServerSettings) { ServerSettingsView() }
        }
    }
    private func scanAgain() {
        request = nil; approved = nil; text = ""; scannerError = nil; message = nil; now = .now
    }
    private func expired(_ request: ConsoleWebLoginRequest) -> Bool { (request.expiry ?? .distantPast) <= now }
    @MainActor private func inspect(_ payload: String, scanned: Bool = false) async {
        guard !busy else { return }
        busy = true; message = nil; request = nil
        defer { busy = false }
        do {
            let inspected = try await client.inspectWebLogin(payload)
            now = .now
            initialRemaining = max(1, (inspected.expiry ?? now).timeIntervalSince(now))
            request = inspected; text = ""
        }
        catch {
            if scanned { scannerError = error.localizedDescription }
            else { message = error.localizedDescription }
        }
    }
    @MainActor private func confirm(_ request: ConsoleWebLoginRequest, approve: Bool) async {
        guard !busy else { return }
        busy = true; message = nil
        defer { busy = false }
        do {
            try await client.confirmWebLogin(request, approve: approve)
            self.request = nil; approved = approve
        } catch { message = error.localizedDescription }
    }
}

private struct ConsoleWebLoginConfirmation: View {
    let request: ConsoleWebLoginRequest
    let now: Date
    let initialRemaining: TimeInterval
    let busy: Bool
    let canRespond: Bool
    let message: String?
    let onConfirm: () -> Void
    let onReject: () -> Void
    @ScaledMetric(relativeTo: .largeTitle) private var codeSize = 52.0

    private var remaining: TimeInterval { max(0, (request.expiry ?? now).timeIntervalSince(now)) }
    private var expired: Bool { remaining <= 0 }
    private var groupedCode: String {
        let code = request.confirmationCode
        return String(code.prefix(3)) + " " + String(code.dropFirst(3))
    }
    private var serverName: String {
        guard let url = URL(string: request.origin), let host = url.host else { return request.origin }
        return host + (url.port.map { ":\($0)" } ?? "")
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                introduction
                requestDetails
                confirmationCode
                warning
                if let message {
                    Text(message).font(.footnote).foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityAddTraits(.updatesFrequently)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 28)
            .padding(.bottom, 20)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            actions
                .padding(.horizontal, 24)
                .padding(.top, 12)
                .padding(.bottom, 8)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
                .background(Color(uiColor: .systemGroupedBackground))
        }
        .background(Color(uiColor: .systemGroupedBackground))
    }

    private var introduction: some View {
        VStack(spacing: 10) {
            Image(systemName: "macwindow")
                .font(.system(size: 46, weight: .ultraLight))
                .rotationEffect(.degrees(-5))
                .padding(.bottom, 8)
                .accessibilityHidden(true)
            Text("是你在登录吗？").font(.title2.bold())
            Text("核对网页上的确认码，再允许此次登录。")
                .font(.footnote).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    private var requestDetails: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("登录服务器").font(.caption).foregroundStyle(.secondary)
                Text(serverName).font(.headline).textSelection(.enabled)
                Text(request.origin).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Divider()
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(ipLabel).font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Text(request.clientIP ?? "未知（请更新服务器）").font(.subheadline).textSelection(.enabled)
                }
                detail(ipLabel, value: request.clientIP ?? "未知（请更新服务器）")
            }
            if request.isApplication {
                Divider()
                detail("应用", value: request.application ?? "")
                detail("应用地址", value: request.applicationOrigin ?? "")
                detail("操作", value: request.purpose == "bind" ? "绑定已有管理员账号" : "登录应用")
                if request.purpose == "oidc" {
                    detail("申请身份信息", value: request.scopes ?? "")
                    Text("openid：稳定账号标识。profile：当前账号名称。不提供邮箱；不授予 Hako 管理权限。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 19))
    }

    private var ipLabel: String {
        request.isApplication && request.purpose != "oidc" ? "来源 IP（应用报告）" : "来源 IP"
    }

    private func detail(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.subheadline).textSelection(.enabled)
        }
    }

    private var confirmationCode: some View {
        VStack(spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack {
                    Text("网页确认码")
                    Spacer(minLength: 12)
                    expiryLabel
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("网页确认码")
                    expiryLabel
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.caption).foregroundStyle(.secondary)
            Text(groupedCode)
                .font(.system(size: codeSize, weight: .semibold, design: .monospaced))
                .tracking(2).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.5)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity)
                .accessibilityLabel("确认码")
                .accessibilityValue(request.confirmationCode.map(String.init).joined(separator: " "))
                .privacySensitive()
            GeometryReader { geometry in
                Capsule().fill(.primary.opacity(0.12))
                    .overlay(alignment: .leading) {
                        Capsule().fill(.primary)
                            .frame(width: geometry.size.width * min(1, remaining / initialRemaining))
                    }
            }
            .frame(height: 3)
            .accessibilityHidden(true)
            Text(expired ? "请在网页刷新后，点击右上角「重新扫码」。" : "请确认与网页显示的六位数字完全一致")
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var expiryLabel: some View {
        Text(expired ? "已过期" : "\(Int(ceil(remaining))) 秒后过期")
            .monospacedDigit()
    }

    private var warning: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.circle").padding(.top, 2).accessibilityHidden(true)
            Text("仅确认你本人发起的登录。\n不要扫描或确认他人发来的二维码。")
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.caption)
        .foregroundStyle(HakoStyle.adaptive(0x725e3e, 0xd8c29d))
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(HakoStyle.adaptive(0xf1ece3, 0x302b23), in: RoundedRectangle(cornerRadius: 13))
    }

    private var actions: some View {
        VStack(spacing: 10) {
            Button(action: onConfirm) {
                HStack {
                    Spacer(minLength: 0)
                    Text(busy ? "正在处理…" : expired ? "请求已过期" : "确认登录")
                    Spacer(minLength: 0)
                }
                .frame(minHeight: 24)
                .overlay(alignment: .trailing) {
                    if !busy && !expired { Image(systemName: "arrow.up.right").accessibilityHidden(true) }
                }
                .padding(.vertical, 5)
            }
            .buttonStyle(HakoActionButtonStyle())
            Button("拒绝此次登录", role: .destructive, action: onReject)
                .font(.subheadline).frame(maxWidth: .infinity, minHeight: 44)
                .buttonStyle(.plain).foregroundStyle(.red)
        }
        .disabled(busy || !canRespond)
    }
}

// All capture-session configuration and callbacks run on one background queue.
private final class ConsoleCaptureEngine: NSObject, AVCaptureMetadataOutputObjectsDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "me.stackli.hako.qr-capture")
    private var configured = false
    private var delivered = false
    private let onScan: @MainActor (String) -> Void
    private let onError: @MainActor (String) -> Void

    init(onScan: @escaping @MainActor (String) -> Void, onError: @escaping @MainActor (String) -> Void) {
        self.onScan = onScan; self.onError = onError
        super.init()
    }
    func start() {
        queue.async { [self] in
            guard !delivered else { return }
            if !configured {
                session.beginConfiguration()
                guard let camera = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: camera), session.canAddInput(input) else {
                    session.commitConfiguration(); fail("无法打开摄像头，请重新扫码或在下方粘贴登录请求。"); return
                }
                session.addInput(input)
                let output = AVCaptureMetadataOutput()
                guard session.canAddOutput(output) else { session.commitConfiguration(); fail("设备不支持扫码，请在下方粘贴登录请求。"); return }
                session.addOutput(output)
                guard output.availableMetadataObjectTypes.contains(.qr) else { session.commitConfiguration(); fail("设备不支持二维码识别，请在下方粘贴登录请求。"); return }
                output.setMetadataObjectsDelegate(self, queue: queue)
                output.metadataObjectTypes = [.qr]
                session.commitConfiguration(); configured = true
            }
            session.startRunning()
        }
    }
    func stop() { queue.async { [self] in session.stopRunning() } }
    private func fail(_ text: String) {
        guard !delivered else { return }; delivered = true
        Task { @MainActor [onError] in onError(text) }
    }
    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard !delivered, let object = objects.compactMap({ $0 as? AVMetadataMachineReadableCodeObject }).first,
              object.type == .qr, let payload = object.stringValue else { return }
        delivered = true; stop()
        Task { @MainActor [onScan] in onScan(payload) }
    }
}

private struct ConsoleQRScanner: UIViewControllerRepresentable {
    let onScan: @MainActor (String) -> Void
    let onError: @MainActor (String) -> Void
    func makeUIViewController(context: Context) -> ConsoleScannerController {
        ConsoleScannerController(onScan: onScan, onError: onError)
    }
    func updateUIViewController(_ controller: ConsoleScannerController, context: Context) { }
    static func dismantleUIViewController(_ controller: ConsoleScannerController, coordinator: ()) { controller.stop() }
}

private final class ConsoleScannerController: UIViewController {
    private let engine: ConsoleCaptureEngine
    private let onError: @MainActor (String) -> Void
    private var preview: AVCaptureVideoPreviewLayer?
    private var visible = false
    init(onScan: @escaping @MainActor (String) -> Void, onError: @escaping @MainActor (String) -> Void) {
        engine = ConsoleCaptureEngine(onScan: onScan, onError: onError); self.onError = onError
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func viewDidLoad() {
        super.viewDidLoad(); view.backgroundColor = .black
        let layer = AVCaptureVideoPreviewLayer(session: engine.session); layer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(layer); preview = layer
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews(); preview?.frame = view.bounds
        if let connection = preview?.connection, connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated); visible = true
        Task { @MainActor [weak self] in
            let allowed = await AVCaptureDevice.requestAccess(for: .video)
            guard let self, self.visible else { return }
            if allowed { self.engine.start() } else { self.onError("未获得摄像头权限，可在系统设置中允许 Hako 使用摄像头，或在下方粘贴登录请求。") }
        }
    }
    override func viewWillDisappear(_ animated: Bool) { super.viewWillDisappear(animated); stop() }
    func stop() { visible = false; engine.stop() }
}
