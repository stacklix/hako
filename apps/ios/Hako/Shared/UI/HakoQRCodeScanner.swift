import SwiftUI
import AVFoundation
import UIKit

// All capture-session configuration and callbacks run on one background queue.
private final class HakoQRCaptureEngine: NSObject, AVCaptureMetadataOutputObjectsDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "me.stackli.hako.qr-capture", qos: .userInitiated)
    private var camera: AVCaptureDevice?
    private var zoomOrigin: CGFloat = 1
    private var standardZoom: CGFloat = 1
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
                let types: [AVCaptureDevice.DeviceType] = [.builtInTripleCamera, .builtInDualWideCamera, .builtInWideAngleCamera]
                guard let camera = types.lazy.compactMap({ AVCaptureDevice.default($0, for: .video, position: .back) }).first,
                      let input = try? AVCaptureDeviceInput(device: camera), session.canAddInput(input) else {
                    session.commitConfiguration(); fail("无法打开摄像头，请检查是否被其他应用占用后重试。"); return
                }
                session.addInput(input)
                if session.canSetSessionPreset(.hd1920x1080) { session.sessionPreset = .hd1920x1080 }
                let output = AVCaptureMetadataOutput()
                guard session.canAddOutput(output) else { session.commitConfiguration(); fail("当前设备不支持相机扫码。"); return }
                session.addOutput(output)
                guard output.availableMetadataObjectTypes.contains(.qr) else { session.commitConfiguration(); fail("当前设备不支持二维码识别。"); return }
                output.setMetadataObjectsDelegate(self, queue: queue)
                output.metadataObjectTypes = [.qr]
                do {
                    try camera.lockForConfiguration()
                    defer { camera.unlockForConfiguration() }
                    // Start at the wide camera's field of view while allowing a
                    // virtual camera to select a closer-focusing lens as needed.
                    standardZoom = CGFloat(camera.virtualDeviceSwitchOverVideoZoomFactors.first?.doubleValue ?? 1)
                    camera.videoZoomFactor = min(camera.maxAvailableVideoZoomFactor,
                        max(camera.minAvailableVideoZoomFactor, standardZoom))
                    if camera.isSmoothAutoFocusSupported { camera.isSmoothAutoFocusEnabled = false }
                    if camera.isFocusPointOfInterestSupported { camera.focusPointOfInterest = CGPoint(x: 0.5, y: 0.5) }
                    if camera.isFocusModeSupported(.continuousAutoFocus) { camera.focusMode = .continuousAutoFocus }
                    if camera.isExposureModeSupported(.continuousAutoExposure) { camera.exposureMode = .continuousAutoExposure }
                } catch {
                    session.commitConfiguration(); fail("无法配置摄像头，请稍后重新扫描。"); return
                }
                self.camera = camera
                session.commitConfiguration(); configured = true
            }
            if !session.isRunning { session.startRunning() }
        }
    }
    func stop() { queue.async { [self] in session.stopRunning() } }
    func focus(at point: CGPoint) {
        queue.async { [self] in
            guard !delivered, let camera, (try? camera.lockForConfiguration()) != nil else { return }
            defer { camera.unlockForConfiguration() }
            if camera.isFocusPointOfInterestSupported { camera.focusPointOfInterest = point }
            if camera.isFocusModeSupported(.continuousAutoFocus) { camera.focusMode = .continuousAutoFocus }
            if camera.isExposurePointOfInterestSupported { camera.exposurePointOfInterest = point }
            if camera.isExposureModeSupported(.continuousAutoExposure) { camera.exposureMode = .continuousAutoExposure }
        }
    }
    func zoom(scale: CGFloat, began: Bool) {
        queue.async { [self] in
            guard !delivered, let camera else { return }
            if began { zoomOrigin = camera.videoZoomFactor; return }
            guard scale.isFinite, scale > 0, (try? camera.lockForConfiguration()) != nil else { return }
            defer { camera.unlockForConfiguration() }
            camera.videoZoomFactor = min(min(camera.maxAvailableVideoZoomFactor, standardZoom * 6),
                max(camera.minAvailableVideoZoomFactor, zoomOrigin * scale))
        }
    }
    private func fail(_ text: String) {
        guard !delivered else { return }; delivered = true
        Task { @MainActor [onError] in onError(text) }
    }
    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard !delivered, let payload = objects.compactMap({ object -> String? in
            guard let code = object as? AVMetadataMachineReadableCodeObject, code.type == .qr else { return nil }
            return code.stringValue
        }).first else { return }
        delivered = true; stop()
        Task { @MainActor [onScan] in onScan(payload) }
    }
}

struct HakoQRCodeScanner: UIViewControllerRepresentable {
    let onScan: @MainActor (String) -> Void
    let onError: @MainActor (String) -> Void
    func makeUIViewController(context: Context) -> HakoQRScannerController {
        HakoQRScannerController(onScan: onScan, onError: onError)
    }
    func updateUIViewController(_ controller: HakoQRScannerController, context: Context) { }
    static func dismantleUIViewController(_ controller: HakoQRScannerController, coordinator: ()) { controller.stop() }
}

final class HakoQRScannerController: UIViewController {
    private let engine: HakoQRCaptureEngine
    private let onError: @MainActor (String) -> Void
    private var preview: AVCaptureVideoPreviewLayer?
    private var visible = false
    init(onScan: @escaping @MainActor (String) -> Void, onError: @escaping @MainActor (String) -> Void) {
        engine = HakoQRCaptureEngine(onScan: onScan, onError: onError); self.onError = onError
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func viewDidLoad() {
        super.viewDidLoad(); view.backgroundColor = .black
        let layer = AVCaptureVideoPreviewLayer(session: engine.session); layer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(layer); preview = layer
        view.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(focus(_:))))
        view.addGestureRecognizer(UIPinchGestureRecognizer(target: self, action: #selector(zoom(_:))))
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews(); preview?.frame = view.bounds
        if let connection = preview?.connection, connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
    }
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated); visible = true
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: engine.start()
        case .notDetermined:
            Task { @MainActor [weak self] in
                let allowed = await AVCaptureDevice.requestAccess(for: .video)
                guard let self, self.visible else { return }
                if allowed { self.engine.start() } else { self.permissionDenied() }
            }
        default: permissionDenied()
        }
    }
    private func permissionDenied() { onError("未获得摄像头权限，请在系统设置中允许 Hako 使用摄像头。") }
    @objc private func focus(_ gesture: UITapGestureRecognizer) {
        guard let preview else { return }
        engine.focus(at: preview.captureDevicePointConverted(fromLayerPoint: gesture.location(in: view)))
    }
    @objc private func zoom(_ gesture: UIPinchGestureRecognizer) {
        if gesture.state == .began || gesture.state == .changed {
            engine.zoom(scale: gesture.scale, began: gesture.state == .began)
        }
    }
    override func viewWillDisappear(_ animated: Bool) { super.viewWillDisappear(animated); stop() }
    func stop() { visible = false; engine.stop() }
}
