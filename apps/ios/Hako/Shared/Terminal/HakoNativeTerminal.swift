import SwiftUI
import UIKit
import SwiftTerm

@MainActor protocol HakoNativeTerminalData: ObservableObject {
    var connected: Bool { get }
    var display: HakoTerminalDisplay { get }
    func send(_ bytes: Data)
    func resize(columns: Int, rows: Int)
}

struct HakoNativeTerminal<Session: HakoNativeTerminalData>: UIViewRepresentable {
    @ObservedObject var data: Session
    let active: Bool
    let logSource: HakoLogSource
    @Environment(\.colorScheme) private var colorScheme
    func makeCoordinator() -> Coordinator { Coordinator(data: data, logSource: logSource) }
    func makeUIView(context: Context) -> SwiftTerm.TerminalView {
        let view = HakoTerminalView(frame: CGRect(x: 0, y: 0, width: 640, height: 384), font: .monospacedSystemFont(ofSize: 13, weight: .regular))
        let coordinator = context.coordinator
        coordinator.active = active
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
        let becameActive = active && !coordinator.active
        coordinator.active = active
        if view.terminalDelegate == nil { view.terminalDelegate = coordinator }
        if !data.display.isAttached(coordinator) {
            coordinator.view = view; data.display.attach(coordinator)
        }
        if coordinator.scheme != colorScheme { applyAppearance(view); coordinator.scheme = colorScheme }
        view.keyboardAppearance = colorScheme == .dark ? .dark : .light
        if active && data.connected && (!coordinator.wasConnected || becameActive) { coordinator.focus() }
        if !active { coordinator.blur() }
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
    @MainActor final class Coordinator: NSObject, TerminalViewDelegate, HakoTerminalRendering {
        let data: Session
        let logSource: HakoLogSource
        weak var view: SwiftTerm.TerminalView?
        var scheme: ColorScheme?
        var wasConnected = false
        var active = false
        private var focusTask: Task<Void, Never>?
        private var focusID = UUID()
        init(data: Session, logSource: HakoLogSource) {
            self.data = data
            self.logSource = logSource
        }
        func reset() { view?.resetToInitialState() }
        func feed(_ bytes: Data) { view?.feed(byteArray: Array(bytes)[...]) }
        func focus() {
            guard active, data.connected, let view else { return }
            guard (view as? HakoTerminalView)?.keyboardDismissedByUser != true else { return }
            focusTask?.cancel()
            let ticket = UUID(); focusID = ticket
            focusTask = Task { [weak self, weak view] in
                defer { if let self, self.focusID == ticket { self.focusTask = nil } }
                // SwiftUI must remove the overlay and restore hit-testing before
                // UIKit can focus this view. Window attachment may happen later.
                for _ in 0..<5 {
                    do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                    guard let self, let view, self.active, self.data.connected, self.data.display.isAttached(self), self.focusID == ticket else { return }
                    guard (view as? HakoTerminalView)?.keyboardDismissedByUser != true else { return }
                    if view.window?.isKeyWindow == true, view.bounds.width >= 32, view.bounds.height >= 32, view.isUserInteractionEnabled {
                        view.layoutIfNeeded()
                        if view.becomeFirstResponder() { view.reloadInputViews(); return }
                    }
                }
                HakoLog.record(self?.logSource ?? .cloudServers, .warning, "终端键盘焦点未就绪", detail: "请轻点终端内容区重新获取输入焦点。")
            }
        }
        func blur() {
            focusID = UUID(); focusTask?.cancel(); focusTask = nil
            view?.resignFirstResponder()
        }
        func key(_ key: String) {
            guard active, data.connected, let view else { return }
            (view as? HakoTerminalView)?.showKeyboard()
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
