import SwiftUI
import UIKit
import SwiftTerm

// Keep presentation identity and its snapshot outside List's dynamic sections.
struct ArcaneTerminalPresentation: Identifiable {
    let id = UUID()
    let details: ArcaneContainerDetails
    let connectionID: String
}

@MainActor private final class ArcaneTerminalData: ObservableObject {
    @Published private(set) var connected = false
    @Published private(set) var connecting = false
    @Published private(set) var error: String?
    @Published private(set) var availableShells: [String] = []
    @Published private(set) var selectedShell = "/bin/sh"
    @Published private(set) var rendererID = UUID()
    @Published var control = false
    weak var terminal: SwiftTerm.TerminalView?
    private var channel: (any ArcaneTerminalChannel)?
    private var reader: Task<Void, Never>?
    private var writer: Task<Void, Never>?
    private var healthCheck: Task<Void, Never>?
    private var lease: UUID?
    private weak var store: ArcaneStore?
    private var generation = UUID()
    private var columns = 80
    private var rows = 24
    private var queuedBytes = 0
    private var pendingOutput = Data()

    func connect(store: ArcaneStore, environment: String, details: ArcaneContainerDetails, shell: String, connectionID: String, fallback: Bool = false) {
        guard !connected, !connecting else { return }
        error = nil
        do {
            let client = try store.client()
            guard client.connection.id == connectionID else { throw ArcaneFailure(message: "Arcane 连接已变化，请返回详情页重新进入终端。") }
            _ = try ArcaneSocketTerminal.request(client.connection, environment: environment, container: details.id, shell: shell, columns: columns, rows: rows)
            lease = try store.beginTerminalSession(); self.store = store
            let ticket = UUID(); generation = ticket; connecting = true; error = nil
            // A new session gets a fresh emulator, input delegate and queue.
            // Do not reuse a view that may have been closed during presentation.
            terminal = nil; pendingOutput.removeAll(); rendererID = UUID()
            reader = Task {
                defer { if generation == ticket { finish() } }
                do {
                    let fresh = try await client.details(environment, id: details.id)
                    try Task.checkCancellation()
                    guard generation == ticket else { return }
                    guard fresh.id == details.id, fresh.state?.status == "running", fresh.state?.running != false else { throw ArcaneFailure(message: "容器不在运行中，请返回并刷新状态。") }
                    let columns = self.columns, rows = self.rows
                    let session = try await ArcaneShellDiscovery.connect(preferred: shell, fallback: fallback) { path in
                        try ArcaneSocketTerminal(client: client, environment: environment, container: details.id, shell: path, columns: columns, rows: rows)
                    }
                    guard generation == ticket, !Task.isCancelled else { session.channel.close(); return }
                    let channel = session.channel; self.channel = channel
                    availableShells = session.available; selectedShell = session.shell
                    let context = ArcaneCommandContext(connection: connectionID, environment: environment, details: details)
                    UserDefaults.standard.set(session.shell, forKey: ArcaneShellDiscovery.cacheKey(context))
                    connected = true; connecting = false
                    display(session.output)
                    if let terminal { activate(terminal) }
                    resize(columns: self.columns, rows: self.rows)
                    while !Task.isCancelled && generation == ticket {
                        let bytes = try await channel.receive()
                        guard generation == ticket, !Task.isCancelled else { return }
                        display(bytes)
                    }
                } catch {
                    if generation == ticket && !Task.isCancelled { self.error = client.redacted(error.localizedDescription) }
                }
            }
        } catch { self.error = error.localizedDescription; finish() }
    }
    func attach(_ view: SwiftTerm.TerminalView) {
        terminal = view
        if !pendingOutput.isEmpty { view.feed(byteArray: Array(pendingOutput)[...]); pendingOutput.removeAll() }
        activate(view)
    }
    func activate(_ view: SwiftTerm.TerminalView, resetFocus: Bool = false) {
        let ticket = generation
        // Reconnect is requested from an Alert. Restore keyboard focus after
        // dismissal, not while UIKit still owns the alert's responder chain.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self, weak view] in
            guard let self, let view, self.generation == ticket, self.connected,
                  self.terminal === view, view.window?.isKeyWindow == true else { return }
            if resetFocus { view.resignFirstResponder() }
            view.becomeFirstResponder()
            view.reloadInputViews()
        }
    }
    func recoverInput() {
        guard connected, let channel else {
            if !connecting { error = "终端会话已中断，请退出或重新连接。" }
            return
        }
        if let terminal { activate(terminal, resetFocus: true) }
        guard healthCheck == nil else { return }
        let ticket = generation
        healthCheck = Task {
            defer { if generation == ticket { healthCheck = nil } }
            do { try await channel.checkConnection() }
            catch {
                if generation == ticket && !Task.isCancelled {
                    self.error = "终端连接已失效，请退出或重新连接。"
                    disconnect()
                }
            }
        }
    }
    private func display(_ bytes: Data) {
        if let terminal { terminal.feed(byteArray: Array(bytes)[...]) }
        else { pendingOutput.append(bytes.prefix(max(0, 1_048_576 - pendingOutput.count))) }
    }
    private func finish() {
        healthCheck?.cancel(); healthCheck = nil
        channel?.close(); channel = nil; writer?.cancel(); writer = nil; queuedBytes = 0
        reader = nil
        connected = false; connecting = false; control = false
        if let lease { store?.endTerminalSession(lease) }; lease = nil
        terminal?.resignFirstResponder()
    }
    func disconnect() {
        generation = UUID(); reader?.cancel(); reader = nil; finish()
    }
    func send(_ bytes: Data) {
        guard connected, let channel else { return }
        var data = bytes
        if control, data.count == 1, let byte = data.first, (64...127).contains(byte) { data = Data([byte & 0x1f]); control = false }
        guard queuedBytes + data.count <= 1_048_576 else { error = "输入队列已满，请等待发送完成后再粘贴。"; return }
        queuedBytes += data.count
        let prior = writer, ticket = generation, payload = data
        writer = Task {
            await prior?.value
            guard !Task.isCancelled, ticket == generation else { return }
            defer { if ticket == generation { queuedBytes -= payload.count } }
            do { try await channel.send(payload) }
            catch { if ticket == generation { self.error = error.localizedDescription; disconnect() } }
        }
    }
    func resize(columns: Int, rows: Int) {
        self.columns = max(2, min(1000, columns)); self.rows = max(2, min(1000, rows))
        guard connected, let channel else { return }
        let prior = writer, ticket = generation, cols = self.columns, lines = self.rows
        writer = Task {
            await prior?.value
            guard !Task.isCancelled, ticket == generation else { return }
            do { try await channel.resize(columns: cols, rows: lines) }
            catch { if ticket == generation { self.error = error.localizedDescription; disconnect() } }
        }
    }
    func key(_ name: String) {
        guard connected, let terminal else { return }
        terminal.becomeFirstResponder()
        switch name {
        case "↑": terminal.sendKeyUp()
        case "↓": terminal.sendKeyDown()
        case "←": terminal.sendKeyLeft()
        case "→": terminal.sendKeyRight()
        case "Esc": terminal.send(txt: "\u{1b}")
        case "Tab": terminal.send(txt: "\t")
        case "Ctrl+C": terminal.send(txt: "\u{03}")
        case "回车": terminal.send(txt: "\r")
        case "粘贴": terminal.paste(nil)
        default: break
        }
    }
}

private struct ArcaneSwiftTerminal: UIViewRepresentable {
    @ObservedObject var data: ArcaneTerminalData
    @Environment(\.colorScheme) private var colorScheme
    func makeCoordinator() -> Coordinator { Coordinator(data: data) }
    func makeUIView(context: Context) -> SwiftTerm.TerminalView {
        let view = ArcaneNativeTerminal(frame: CGRect(x: 0, y: 0, width: 640, height: 384), font: .monospacedSystemFont(ofSize: 13, weight: .regular))
        view.terminalDelegate = context.coordinator
        view.inputAccessoryView = nil
        applyAppearance(view)
        view.onWindowAttached = { [weak data, weak view] in
            if let data, let view { data.activate(view) }
        }
        data.attach(view)
        return view
    }
    func updateUIView(_ uiView: SwiftTerm.TerminalView, context: Context) {
        if uiView.terminalDelegate == nil { uiView.terminalDelegate = context.coordinator }
        if data.terminal !== uiView { data.attach(uiView) }
        // A status update must not reset the terminal palette or trigger a
        // renderer refresh while SwiftUI is laying out the keyboard/menu.
        if context.coordinator.scheme != colorScheme { applyAppearance(uiView) }
        context.coordinator.scheme = colorScheme
        uiView.keyboardAppearance = colorScheme == .dark ? .dark : .light
    }
    static func dismantleUIView(_ uiView: SwiftTerm.TerminalView, coordinator: Coordinator) {
        uiView.terminalDelegate = nil
        // A retired renderer must not disconnect a newly attached renderer's
        // session. The screen owns the connection and closes it on disappearance.
        if coordinator.data.terminal === uiView { coordinator.data.terminal = nil }
        uiView.updateUiClosed()
    }
    private func applyAppearance(_ view: SwiftTerm.TerminalView) {
        let traits = UITraitCollection(userInterfaceStyle: colorScheme == .dark ? .dark : .light)
        view.nativeBackgroundColor = UIColor.systemBackground.resolvedColor(with: traits)
        view.nativeForegroundColor = UIColor.label.resolvedColor(with: traits)
        view.caretColor = UIColor.label.resolvedColor(with: traits)
    }
    @MainActor final class Coordinator: NSObject, TerminalViewDelegate {
        let data: ArcaneTerminalData
        var scheme: ColorScheme?
        init(data: ArcaneTerminalData) { self.data = data }
        func send(source: SwiftTerm.TerminalView, data: ArraySlice<UInt8>) {
            guard self.data.terminal === source else { return }
            self.data.send(Data(data))
        }
        func sizeChanged(source: SwiftTerm.TerminalView, newCols: Int, newRows: Int) {
            guard data.terminal === source else { return }
            data.resize(columns: newCols, rows: newRows)
        }
        func setTerminalTitle(source: SwiftTerm.TerminalView, title: String) { }
        func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) { }
        func scrolled(source: SwiftTerm.TerminalView, position: Double) { }
        func rangeChanged(source: SwiftTerm.TerminalView, startY: Int, endY: Int) { }
        func requestOpenLink(source: SwiftTerm.TerminalView, link: String, params: [String: String]) { }
    }
}

// SwiftUI may temporarily propose an empty/tiny rectangle during presentation
// and keyboard transitions. Do not resize SwiftTerm to a grid with zero cells.
private final class ArcaneNativeTerminal: SwiftTerm.TerminalView {
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

struct ArcaneTerminalScreen: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var store: ArcaneStore
    let environment: ArcaneEnvironment
    let details: ArcaneContainerDetails
    let connectionID: String
    @StateObject private var data = ArcaneTerminalData()
    @State private var shell = "/bin/sh"
    @State private var customShell = "/bin/zsh"
    @State private var confirming = false
    @State private var editingShell = false
    @State private var shellError: String?
    @State private var failure: String?
    @State private var started = false
    @State private var backgroundDisconnected = false
    @State private var pendingShell: String?
    private var active: Bool { data.connected || data.connecting }
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    if data.connecting { ProgressView().controlSize(.small).accessibilityLabel("正在探测 Shell") }
                    Text("Shell").font(.subheadline).foregroundStyle(.secondary)
                    Picker("Shell", selection: Binding(get: { shell }, set: { path in
                        if path == "__custom__" { customShell = shell; shellError = nil; editingShell = true }
                        else if path != shell { switchShell(path) }
                    })) {
                        if !data.availableShells.contains(shell) { Text(shell).tag(shell) }
                        ForEach(data.availableShells, id: \.self) { Text($0).tag($0) }
                        Text("自定义…").tag("__custom__")
                    }.pickerStyle(.menu).labelsHidden().disabled(data.connecting).accessibilityLabel("切换 Shell")
                }.padding(.horizontal).padding(.top, 6)
                Divider().padding(.bottom, 12)
                ArcaneSwiftTerminal(data: data)
                    .id(data.rendererID)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        Button("Ctrl") { data.control.toggle(); data.terminal?.becomeFirstResponder() }
                            .tint(data.control ? .accentColor : .secondary).accessibilityLabel("Control 修饰键").accessibilityAddTraits(data.control ? .isSelected : [])
                        ForEach(["Esc", "Tab", "Ctrl+C", "←", "↑", "↓", "→", "粘贴", "回车"], id: \.self) { key in
                            Button(key) { data.key(key) }.accessibilityLabel(key == "回车" ? "终端回车" : key)
                        }
                    }.buttonStyle(.bordered).controlSize(.small).padding(10).disabled(!data.connected)
                }.background(.bar)
            }
            .navigationTitle(details.displayName + " · 终端").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { if active { confirming = true } else { dismiss() } } }
            }
            .alert("退出容器终端？", isPresented: $confirming) {
                Button("断开并返回") { data.disconnect(); dismiss() }; Button("取消", role: .cancel) { }
            } message: { Text("将断开 \(environment.displayName) · \(details.displayName) 的终端会话。") }
        }
        .sheet(isPresented: $editingShell, onDismiss: {
            if let path = pendingShell { pendingShell = nil; switchShell(path) }
        }) { shellEditor }
        .alert("终端会话已结束", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("退出", role: .cancel) { data.disconnect(); dismiss() }
            Button("重新连接") { failure = nil; connect() }
        } message: { Text(failure ?? "请退出或重新连接。") }
        .privacySensitive().task {
            if !started {
                started = true
                let context = ArcaneCommandContext(connection: connectionID, environment: environment.id, details: details)
                shell = UserDefaults.standard.string(forKey: ArcaneShellDiscovery.cacheKey(context)) ?? "/bin/sh"
                connect(fallback: true)
            }
        }
        .onDisappear { data.disconnect() }
        .onAppear { if started && pendingShell == nil { recoverInput() } }
        .onReceive(data.$error) { error in if let error { failure = error } }
        .onChange(of: data.selectedShell) { _, path in shell = path }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background && active { backgroundDisconnected = true; data.disconnect() }
            if phase == .active && backgroundDisconnected {
                backgroundDisconnected = false
                failure = "应用进入后台后已关闭终端会话。重新连接将开启新会话，不会重放之前的输入。"
            } else if phase == .active {
                recoverInput()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in recoverInput() }
        .onReceive(NotificationCenter.default.publisher(for: UIWindow.didBecomeKeyNotification)) { notification in
            if let window = notification.object as? UIWindow, window === data.terminal?.window { recoverInput() }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.userDidTakeScreenshotNotification)) { _ in recoverInput() }
        .onChange(of: store.connection?.id) { _, _ in
            data.disconnect(); failure = "Arcane 连接已变化，请退出后重新进入终端。"
        }
    }
    private func connect(fallback: Bool = true) { data.connect(store: store, environment: environment.id, details: details, shell: shell, connectionID: connectionID, fallback: fallback) }
    private func recoverInput() {
        guard started, scenePhase == .active, !editingShell, !confirming, failure == nil, !backgroundDisconnected else { return }
        data.recoverInput()
    }
    private func switchShell(_ path: String) {
        data.disconnect(); failure = nil; shell = path; connect(fallback: false)
    }
    private var shellEditor: some View {
        NavigationStack {
            Form {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Shell 路径").font(.subheadline).foregroundStyle(.secondary)
                    TextField("/bin/zsh", text: $customShell).accessibilityLabel("Shell 路径")
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                if let shellError { Text(shellError).font(.footnote).foregroundStyle(.orange) }
            }
            .navigationTitle("自定义 Shell").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { editingShell = false } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("连接") {
                        do {
                            let path = customShell.trimmingCharacters(in: .whitespacesAndNewlines)
                            let client = try store.client()
                            _ = try ArcaneSocketTerminal.request(client.connection, environment: environment.id, container: details.id, shell: path, columns: 80, rows: 24)
                            pendingShell = path; editingShell = false
                        } catch { shellError = error.localizedDescription }
                    }
                }
            }
        }
    }
}
