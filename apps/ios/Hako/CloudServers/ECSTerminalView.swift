import SwiftUI
import UIKit
import SwiftTerm

struct ECSTerminalView: View {
    let connection: ECSConnection
    let active: Bool
    @StateObject private var data = ECSTerminalData()
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(data.connected ? "已连接" : data.connecting ? "正在连接…" : data.cleaning ? "正在结束会话…" : "已断开")
                    .font(.caption).foregroundStyle(data.connected ? Color.green : .secondary)
                Spacer()
                if data.connected {
                    Button("断开") { data.disconnect() }.disabled(!active)
                }
            }.padding(.horizontal, 18).padding(.vertical, 10)
            Divider()
            ZStack {
                ECSNativeTerminal(data: data)
                    .allowsHitTesting(data.connected && active)
                    .accessibilityHidden(!data.connected)
                if !data.connected { connectionOverlay }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if data.connected {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        Button("Ctrl") { data.control.toggle() }.tint(data.control ? .accentColor : .secondary)
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
        .onChange(of: active) { _, value in if !value { data.disconnect() } }
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
                    Button(data.error == nil ? "连接" : "重新连接") { data.connect(connection) }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                        .disabled(data.cleaning || !active)
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
        data.keyInput?(key)
    }
}

private struct ECSNativeTerminal: UIViewRepresentable {
    @ObservedObject var data: ECSTerminalData
    @Environment(\.colorScheme) private var colorScheme
    func makeCoordinator() -> Coordinator { Coordinator(data: data) }
    func makeUIView(context: Context) -> SwiftTerm.TerminalView {
        let view = SwiftTerm.TerminalView(frame: .zero, font: .monospacedSystemFont(ofSize: 13, weight: .regular))
        view.terminalDelegate = context.coordinator
        view.inputAccessoryView = nil
        view.nativeBackgroundColor = .systemBackground; view.nativeForegroundColor = .label; view.caretColor = .label
        data.receive = { [weak view] bytes in view?.feed(byteArray: Array(bytes)[...]) }
        data.onReady = { [weak view] in view?.resetToInitialState() }
        data.keyInput = { [weak view] key in
            guard let view else { return }
            view.becomeFirstResponder()
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
        return view
    }
    func updateUIView(_ view: SwiftTerm.TerminalView, context: Context) {
        view.nativeBackgroundColor = .systemBackground; view.nativeForegroundColor = .label; view.caretColor = .label
        view.keyboardAppearance = colorScheme == .dark ? .dark : .light
        if data.connected && !context.coordinator.wasConnected { view.becomeFirstResponder() }
        if !data.connected { view.resignFirstResponder() }
        context.coordinator.wasConnected = data.connected
    }
    static func dismantleUIView(_ view: SwiftTerm.TerminalView, coordinator: Coordinator) {
        view.terminalDelegate = nil; coordinator.data.receive = nil; coordinator.data.onReady = nil; coordinator.data.keyInput = nil; coordinator.data.disconnect()
    }
    @MainActor final class Coordinator: NSObject, TerminalViewDelegate {
        let data: ECSTerminalData
        var wasConnected = false
        init(data: ECSTerminalData) { self.data = data }
        func send(source: SwiftTerm.TerminalView, data: ArraySlice<UInt8>) { self.data.send(Data(data)) }
        func sizeChanged(source: SwiftTerm.TerminalView, newCols: Int, newRows: Int) { data.resize(columns: newCols, rows: newRows) }
        func setTerminalTitle(source: SwiftTerm.TerminalView, title: String) { }
        func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) { }
        func scrolled(source: SwiftTerm.TerminalView, position: Double) { }
        func rangeChanged(source: SwiftTerm.TerminalView, startY: Int, endY: Int) { }
        func requestOpenLink(source: SwiftTerm.TerminalView, link: String, params: [String: String]) { }
    }
}
