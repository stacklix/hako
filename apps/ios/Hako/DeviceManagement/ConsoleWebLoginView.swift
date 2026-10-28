import SwiftUI
import Combine
import AVFoundation
import UIKit

struct ConsoleWebLoginView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var client = ConsoleClient.shared
    @State private var request: ConsoleWebLoginRequest?
    @State private var approved: Bool?
    @State private var busy = false
    @State private var text = ""
    @State private var scannerError: String?
    @State private var message: String?
    @State private var now = Date.now

    var body: some View {
        Group {
            if let request {
                Form {
                    Section("网页登录请求") {
                        LabeledContent("服务器", value: request.origin)
                        LabeledContent("浏览器", value: request.browser)
                        Text(request.confirmationCode).font(.system(size: 34, weight: .semibold, design: .monospaced))
                            .frame(maxWidth: .infinity).padding(.vertical, 12)
                        Text("请核对网页上的六位确认码，确认一致后点击“确认登录”。不要确认他人发送的二维码。")
                            .font(.footnote).foregroundStyle(.secondary)
                        Text(remaining(request)).font(.footnote).foregroundStyle(.secondary)
                    }
                    Section {
                        Button("确认登录") { Task { await confirm(request, approve: true) } }
                            .disabled(busy || expired(request) || !client.authenticated)
                        Button("拒绝此次登录", role: .destructive) { Task { await confirm(request, approve: false) } }
                            .disabled(busy || expired(request) || !client.authenticated)
                        Button("重新扫码") { scanAgain() }.disabled(busy)
                    }
                    if busy { ProgressView("正在处理…") }
                    if let message { Section { Text(message).font(.footnote).foregroundStyle(.secondary) } }
                }
            } else if let approved {
                ContentUnavailableView {
                    Label(approved ? "已确认登录" : "已拒绝登录", systemImage: approved ? "checkmark.circle" : "xmark.circle")
                } description: {
                    Text(approved ? "网页将自动完成登录。" : "此次网页登录请求已拒绝。")
                } actions: {
                    Button("完成") { dismiss() }.buttonStyle(.borderedProminent)
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
                            Button("重新扫码") { scanAgain() }.buttonStyle(.borderedProminent)
                        }
                        .frame(maxHeight: .infinity)
                    } else {
                        ConsoleQRScanner(onScan: { payload in
                            Task { await inspect(payload, scanned: true) }
                        }, onError: { scannerError = $0 })
                        .frame(maxHeight: .infinity)
                        .overlay(alignment: .bottom) {
                            Text("扫描自己正在使用的网页管理登录二维码")
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
                            .buttonStyle(.borderedProminent)
                            .disabled(busy || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !client.authenticated)
                        if let message { Text(message).font(.footnote).foregroundStyle(.secondary) }
                    }
                    .padding().background(.background)
                    .disabled(busy)
                }
            }
        }
        .navigationTitle(request != nil ? "确认网页登录" : approved != nil ? "网页登录" : "扫描二维码")
        .navigationBarTitleDisplayMode(.inline)
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { now = $0 }
    }
    private func scanAgain() {
        request = nil; approved = nil; text = ""; scannerError = nil; message = nil; now = .now
    }
    private func expired(_ request: ConsoleWebLoginRequest) -> Bool { (request.expiry ?? .distantPast) <= now }
    private func remaining(_ request: ConsoleWebLoginRequest) -> String {
        guard let expiry = request.expiry, expiry > now else { return "二维码已过期，请在网页刷新后重新扫码。" }
        return "\(Int(ceil(expiry.timeIntervalSince(now)))) 秒后过期"
    }
    @MainActor private func inspect(_ payload: String, scanned: Bool = false) async {
        guard !busy else { return }
        busy = true; message = nil; request = nil
        defer { busy = false }
        do { request = try await client.inspectWebLogin(payload); text = ""; now = .now }
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
