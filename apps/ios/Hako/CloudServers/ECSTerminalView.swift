import SwiftUI
import UIKit
import SwiftTerm

struct ECSTerminalView: View {
    let connection: ECSConnection
    let active: Bool
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var data = ECSTerminalData()
    var body: some View {
        ZStack {
            ECSNativeTerminal(data: data)
                .allowsHitTesting(data.connected && active && scenePhase == .active)
                .accessibilityHidden(!data.connected)
            if !data.connected { connectionOverlay }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if data.connected {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        Button("Ctrl") { data.control.toggle(); data.display.focus() }.tint(data.control ? .accentColor : .secondary)
                            .accessibilityLabel("Control 修饰键").accessibilityAddTraits(data.control ? .isSelected : [])
                        ForEach(["Esc", "Tab", "Ctrl+C", "←", "↑", "↓", "→", "粘贴", "回车"], id: \.self) { key in
                            Button(key) { keyInput(key) }
                        }
                    }.buttonStyle(.bordered).controlSize(.small).padding(10)
                }.background(.bar)
            }
        }
        .privacySensitive()
        .onDisappear { data.disconnect() }
        .onChange(of: active) { _, value in
            if !value { data.disconnect() } else { recoverInput() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { recoverConnection() }
            if phase == .inactive {
                data.pauseConnectionCheck()
                if data.connected { HakoLog.record(.cloudServers, "应用暂时失活，保留终端会话") }
            }
            if phase == .background {
                data.pauseConnectionCheck()
                data.display.blur()
                if data.connected || data.connecting { HakoLog.record(.cloudServers, "应用进入后台，保留终端会话") }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in recoverConnection() }
        .onReceive(NotificationCenter.default.publisher(for: UIWindow.didBecomeKeyNotification)) { _ in recoverInput() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.userDidTakeScreenshotNotification)) { _ in recoverInput() }
    }
    private var connectionOverlay: some View {
        ScrollView {
            VStack(spacing: 18) {
                Image(systemName: data.error == nil ? "terminal" : "network.slash")
                    .font(.largeTitle).foregroundStyle(.secondary).accessibilityHidden(true)
                Text(data.connecting ? "正在连接终端" : data.error == nil ? "终端未连接" : "终端连接已断开")
                    .font(.headline)
                if let error = data.error {
                    Text(error).font(.footnote).foregroundStyle(.orange).textSelection(.enabled)
                }
                if data.connecting {
                    ProgressView("正在建立会话…")
                    Button("取消连接") { data.disconnect() }.buttonStyle(.bordered)
                } else {
                    if data.cleaning { ProgressView("正在结束上一次会话…") }
                    Button { data.connect(connection) } label: {
                        Text(data.error == nil ? "连接" : "重新连接")
                            .foregroundStyle(Color(uiColor: .systemBackground))
                    }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                        .tint(.primary)
                        .disabled(data.cleaning || !active || scenePhase != .active)
                }
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: 360).padding(24)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .defaultScrollAnchor(.center)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
        .accessibilityElement(children: .contain)
    }
    private func keyInput(_ key: String) {
        if data.connected { data.display.key(key) }
    }
    private func recoverInput() {
        guard active, scenePhase == .active, data.connected else { return }
        data.display.focus()
    }
    private func recoverConnection() {
        guard active, scenePhase == .active else { return }
        data.recoverConnection()
    }
}

private struct ECSNativeTerminal: UIViewRepresentable {
    @ObservedObject var data: ECSTerminalData
    @Environment(\.colorScheme) private var colorScheme
    func makeCoordinator() -> Coordinator { Coordinator(data: data) }
    func makeUIView(context: Context) -> SwiftTerm.TerminalView {
        let view = ECSNativeTerminalView(frame: CGRect(x: 0, y: 0, width: 640, height: 384), font: .monospacedSystemFont(ofSize: 13, weight: .regular))
        let coordinator = context.coordinator
        view.terminalDelegate = coordinator
        view.inputAccessoryView = nil
        applyAppearance(view); coordinator.scheme = colorScheme
        view.onWindowAttached = { [weak coordinator] in coordinator?.focus() }
        coordinator.view = view
        data.display.attach(coordinator)
        if data.connected { coordinator.focus() }
        return view
    }
    func updateUIView(_ view: SwiftTerm.TerminalView, context: Context) {
        let coordinator = context.coordinator
        if view.terminalDelegate == nil { view.terminalDelegate = coordinator }
        if !data.display.isAttached(coordinator) {
            coordinator.view = view; data.display.attach(coordinator)
        }
        if coordinator.scheme != colorScheme { applyAppearance(view); coordinator.scheme = colorScheme }
        view.keyboardAppearance = colorScheme == .dark ? .dark : .light
        if data.connected && !coordinator.wasConnected { coordinator.focus() }
        if !data.connected { coordinator.blur() }
        coordinator.wasConnected = data.connected
    }
    private func applyAppearance(_ view: SwiftTerm.TerminalView) {
        let traits = UITraitCollection(userInterfaceStyle: colorScheme == .dark ? .dark : .light)
        view.nativeBackgroundColor = UIColor.systemBackground.resolvedColor(with: traits)
        view.nativeForegroundColor = UIColor.label.resolvedColor(with: traits)
        view.caretColor = UIColor.label.resolvedColor(with: traits)
    }
    static func dismantleUIView(_ view: SwiftTerm.TerminalView, coordinator: Coordinator) {
        view.terminalDelegate = nil
        coordinator.data.display.detach(coordinator)
        coordinator.blur(); coordinator.view = nil
        view.updateUiClosed()
    }
    @MainActor final class Coordinator: NSObject, TerminalViewDelegate, ECSTerminalRendering {
        let data: ECSTerminalData
        weak var view: SwiftTerm.TerminalView?
        var scheme: ColorScheme?
        var wasConnected = false
        private var focusTask: Task<Void, Never>?
        private var focusID = UUID()
        init(data: ECSTerminalData) { self.data = data }
        func reset() { view?.resetToInitialState() }
        func feed(_ bytes: Data) { view?.feed(byteArray: Array(bytes)[...]) }
        func focus() {
            guard data.connected, let view else { return }
            focusTask?.cancel()
            let ticket = UUID(); focusID = ticket
            focusTask = Task { [weak self, weak view] in
                defer { if let self, self.focusID == ticket { self.focusTask = nil } }
                // SwiftUI must remove the overlay and restore hit-testing before
                // UIKit can focus this view. Window attachment may happen later.
                for _ in 0..<5 {
                    do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                    guard let self, let view, self.data.connected, self.data.display.isAttached(self), self.focusID == ticket else { return }
                    if view.window?.isKeyWindow == true, view.bounds.width >= 32, view.bounds.height >= 32, view.isUserInteractionEnabled {
                        view.layoutIfNeeded()
                        if view.becomeFirstResponder() { view.reloadInputViews(); return }
                    }
                }
                HakoLog.record(.cloudServers, .warning, "终端键盘焦点未就绪", detail: "请轻点终端内容区重新获取输入焦点。")
            }
        }
        func blur() {
            focusID = UUID(); focusTask?.cancel(); focusTask = nil
            view?.resignFirstResponder()
        }
        func key(_ key: String) {
            guard data.connected, let view else { return }
            focus()
            switch key {
            case "↑": view.sendKeyUp()
            case "↓": view.sendKeyDown()
            case "←": view.sendKeyLeft()
            case "→": view.sendKeyRight()
            case "Esc": view.send(txt: "\u{1b}")
            case "Tab": view.send(txt: "\t")
            case "Ctrl+C": view.send(txt: "\u{03}")
            case "回车": view.send(txt: "\r")
            case "粘贴": view.paste(nil)
            default: break
            }
        }
        func send(source: SwiftTerm.TerminalView, data: ArraySlice<UInt8>) {
            guard self.data.display.isAttached(self), view === source else { return }
            self.data.send(Data(data))
        }
        func sizeChanged(source: SwiftTerm.TerminalView, newCols: Int, newRows: Int) {
            guard data.display.isAttached(self), view === source else { return }
            data.resize(columns: newCols, rows: newRows)
        }
        func setTerminalTitle(source: SwiftTerm.TerminalView, title: String) { }
        func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) { }
        func scrolled(source: SwiftTerm.TerminalView, position: Double) { }
        func rangeChanged(source: SwiftTerm.TerminalView, startY: Int, endY: Int) { }
        func requestOpenLink(source: SwiftTerm.TerminalView, link: String, params: [String: String]) { }
    }
}

private final class ECSNativeTerminalView: SwiftTerm.TerminalView {
    var onWindowAttached: (() -> Void)?
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { onWindowAttached?() }
    }
    override func layoutSubviews() {
        guard bounds.width >= 32, bounds.height >= 32 else { return }
        super.layoutSubviews()
    }
}
