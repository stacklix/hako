import SwiftUI
import UIKit
import SwiftTerm

struct ECSTerminalView: View {
    let connection: ECSConnection
    let active: Bool
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var data: ECSTerminalData
    var body: some View {
        ZStack {
            HakoNativeTerminal(data: data, active: active && scenePhase == .active, logSource: .cloudServers)
                .allowsHitTesting(data.connected && active && scenePhase == .active)
                .accessibilityHidden(!data.connected)
            if !data.connected { connectionOverlay }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if data.connected {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        Button("Ctrl") { data.control.toggle(); data.display.key("Ctrl") }.tint(data.control ? .accentColor : .secondary)
                            .accessibilityLabel("Control 修饰键").accessibilityAddTraits(data.control ? .isSelected : [])
                        ForEach(["Esc", "Tab", "Ctrl+C", "←", "↑", "↓", "→", "粘贴"], id: \.self) { key in
                            Button(key) { keyInput(key) }
                        }
                    }.buttonStyle(.bordered).controlSize(.small).padding(10)
                }.background(.bar)
            }
        }
        .privacySensitive()
        .onDisappear { data.display.blur() }
        .onChange(of: active) { _, value in
            if !value { data.display.blur() } else { recoverConnection() }
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
                    Text("正在建立会话…").foregroundStyle(.secondary)
                    Button("取消连接") { data.disconnect() }.buttonStyle(.bordered)
                } else {
                    if data.cleaning { Text("正在结束上一次会话…").foregroundStyle(.secondary) }
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

extension ECSTerminalData: HakoNativeTerminalData {}
