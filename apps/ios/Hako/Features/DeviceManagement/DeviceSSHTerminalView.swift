import SwiftUI

struct DeviceSSHTerminalView: View {
    let agentID: String
    let account: String
    let selected: Bool
    @Binding var fullScreen: Bool
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var terminal = DeviceSSHTerminal()
    @State private var credentials: DeviceSSHCredentials?
    @State private var loadedCredentials = false
    @State private var editing = false
    @State private var storageError: String?
    private let storage = SecureStorage.namespace("me.stackli.hako.devices.ssh")

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                HakoNativeTerminal(data: terminal, active: selected && terminal.connected && scenePhase == .active && !editing,
                                   logSource: .devices, allowMouseReporting: false)
                    .allowsHitTesting(selected && terminal.connected && !editing)
                    .accessibilityHidden(!terminal.connected)
                if !terminal.connected { connectionOverlay }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if terminal.connected || fullScreen { shortcutBar }
        }
        .privacySensitive()
        .task(id: selected) {
            guard selected, !loadedCredentials else { return }
            loadedCredentials = true
            do {
                if let data = try storage.read(account: account) {
                    credentials = try JSONDecoder().decode(DeviceSSHCredentials.self, from: data)
                    connect()
                }
            } catch { storageError = "无法读取 SSH 配置，请解锁设备后重试。" }
        }
        .onDisappear { terminal.disconnect() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { terminal.disconnect() }
        }
        .sheet(isPresented: $editing) {
            DeviceSSHSettingsView(credentials: credentials ?? DeviceSSHCredentials()) { value in
                try storage.save(JSONEncoder().encode(value), account: account, accessibility: .whenUnlocked)
                credentials = value
                storageError = nil
                editing = false
                connect()
            }
        }
    }

    private var shortcutBar: some View {
        VStack(spacing: 0) {
            if terminal.connected, let message = terminal.message {
                Text(message).font(.footnote).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).padding(.top, 6).background(.bar)
            }
            HakoShortcutBar(fullScreen: $fullScreen) {
                if terminal.connected {
                    Button("Ctrl") { terminal.control.toggle() }
                        .tint(terminal.control ? .accentColor : .secondary)
                        .accessibilityLabel("Control 修饰键").accessibilityAddTraits(terminal.control ? .isSelected : [])
                    ForEach(["Esc", "Tab", "Ctrl+C", "←", "↑", "↓", "→", "粘贴"], id: \.self) { key in
                        Button(key) { terminal.display.key(key) }
                    }
                    Button("断开") { terminal.disconnect() }
                }
            }
        }
    }

    private var connectionOverlay: some View {
        ScrollView {
            VStack(spacing: 16) {
                Image(systemName: "terminal").font(.largeTitle).foregroundStyle(.secondary).accessibilityHidden(true)
                Text(terminal.pendingHostKey != nil ? "确认 SSH 主机身份" : terminal.connecting ? "正在连接 Windows SSH" : "Windows PowerShell")
                    .font(.headline)
                if let message = storageError ?? terminal.message {
                    Text(message).font(.footnote).foregroundStyle(.orange)
                }
                if let fingerprint = terminal.pendingHostKey {
                    Text("首次连接设备 \(agentID)，请与电脑上的 SSH 主机指纹核对。确认后会保存指纹，后续连接自动校验。")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Text(fingerprint).font(.footnote.monospaced())
                        .textSelection(.enabled).accessibilityLabel("SSH 主机指纹：\(fingerprint)")
                    Text("尚未向 Windows 进行密码认证。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button("信任并连接") { trust(fingerprint) }.buttonStyle(HakoActionButtonStyle())
                    Button("取消") { terminal.disconnect() }.buttonStyle(HakoActionButtonStyle(primary: false))
                } else if terminal.connecting {
                    Button("取消连接") { terminal.disconnect() }.buttonStyle(.bordered)
                } else if credentials?.isValid == true {
                    Button("连接 PowerShell", action: connect).buttonStyle(HakoActionButtonStyle())
                    Button("SSH 设置") { editing = true }.buttonStyle(HakoActionButtonStyle(primary: false))
                } else {
                    Text("填写 Windows OpenSSH 登录信息后即可连接。")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Button("配置 SSH") { editing = true }.buttonStyle(HakoActionButtonStyle())
                }
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: 360).padding(24).frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .defaultScrollAnchor(.center)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
    }

    private func connect() {
        guard selected, scenePhase == .active, let credentials else { return }
        storageError = nil
        terminal.connect(agentID: agentID, credentials: credentials, authentication: AuthenticatedServerService.shared)
    }

    private func trust(_ fingerprint: String) {
        guard selected, scenePhase == .active, terminal.pendingHostKey == fingerprint,
              var value = credentials else { return }
        value.fingerprint = fingerprint
        do {
            try storage.save(JSONEncoder().encode(value), account: account, accessibility: .whenUnlocked)
            credentials = value
            connect()
        } catch { storageError = "无法保存主机指纹，尚未继续连接。请解锁设备后重试。" }
    }
}

private struct DeviceSSHSettingsView: View {
    @State private var credentials: DeviceSSHCredentials
    private let original: DeviceSSHCredentials
    private let save: (DeviceSSHCredentials) throws -> Void
    @State private var error: String?
    @State private var confirmingReset = false

    init(credentials: DeviceSSHCredentials, save: @escaping (DeviceSSHCredentials) throws -> Void) {
        _credentials = State(initialValue: credentials)
        original = credentials
        self.save = save
    }

    private var normalized: DeviceSSHCredentials {
        DeviceSSHCredentials(username: credentials.username.trimmingCharacters(in: .whitespacesAndNewlines),
                             password: credentials.password,
                             fingerprint: credentials.fingerprint.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private var hasChanges: Bool {
        credentials.username != original.username ||
        credentials.password != original.password ||
        credentials.fingerprint != original.fingerprint
    }

    var body: some View {
        SettingsSheet(title: "SSH 设置", hasChanges: hasChanges,
                      saveEnabled: normalized.isValid, onSave: saveAndConnect,
                      saveAccessibilityLabel: "保存并连接") {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("SSH 账号").font(.subheadline).foregroundStyle(.secondary)
                        TextField("Windows 用户名", text: $credentials.username)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .accessibilityLabel("SSH 账号")
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("SSH 密码").font(.subheadline).foregroundStyle(.secondary)
                        SecureField("Windows 用户密码", text: $credentials.password)
                            .accessibilityLabel("SSH 密码")
                    }
                } footer: {
                    Text("使用 Windows OpenSSH 的 22 端口。首次连接时会展示主机指纹，确认信任后再进行密码认证。")
                }
                if !credentials.fingerprint.isEmpty {
                    Section("已信任主机") {
                        Text(credentials.fingerprint).font(.footnote.monospaced()).textSelection(.enabled)
                        Button("清除已信任指纹", role: .destructive) { confirmingReset = true }
                    }
                }
                if let error { Text(error).font(.footnote).foregroundStyle(.orange) }
            }
            .privacySensitive()
        }
        .alert("清除已信任指纹？", isPresented: $confirmingReset) {
            Button("取消", role: .cancel) { }
            Button("清除", role: .destructive) { credentials.fingerprint = "" }
        } message: {
            Text("仅在重装系统或重新生成 SSH 主机密钥后使用。保存后，下次连接需要重新核对并确认主机指纹。")
        }
    }

    private func saveAndConnect() {
        do { try save(normalized) }
        catch { self.error = "SSH 配置无法保存，请解锁设备后重试。" }
    }
}
