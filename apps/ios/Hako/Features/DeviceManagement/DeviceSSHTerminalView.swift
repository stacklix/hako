import SwiftUI

struct DeviceSSHTerminalView: View {
    let agentID: String
    let account: String
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var terminal = DeviceSSHTerminal()
    @State private var credentials: DeviceSSHCredentials?
    @State private var editing = false
    @State private var storageError: String?
    private let storage = SecureStorage.namespace("me.stackli.hako.devices.ssh")

    var body: some View {
        ZStack {
            HakoNativeTerminal(data: terminal, active: terminal.connected && scenePhase == .active && !editing, logSource: .devices)
                .allowsHitTesting(terminal.connected && !editing)
                .accessibilityHidden(!terminal.connected)
            if !terminal.connected { connectionOverlay }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if terminal.connected {
                VStack(spacing: 0) {
                    if let message = terminal.message {
                        Text(message).font(.footnote).foregroundStyle(.secondary).padding(.top, 6)
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            Button("Ctrl") { terminal.control.toggle() }
                                .tint(terminal.control ? .accentColor : .secondary)
                                .accessibilityLabel("Control 修饰键").accessibilityAddTraits(terminal.control ? .isSelected : [])
                            ForEach(["Esc", "Tab", "Ctrl+C", "←", "↑", "↓", "→", "粘贴"], id: \.self) { key in
                                Button(key) { terminal.display.key(key) }
                            }
                            Button("断开") { terminal.disconnect() }
                        }.buttonStyle(.bordered).controlSize(.small).padding(10)
                    }
                }.background(.bar)
            }
        }
        .privacySensitive()
        .task {
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

    private var connectionOverlay: some View {
        ScrollView {
            VStack(spacing: 16) {
                Image(systemName: "terminal").font(.largeTitle).foregroundStyle(.secondary).accessibilityHidden(true)
                Text(terminal.connecting ? "正在连接 Windows SSH" : "Windows PowerShell")
                    .font(.headline)
                if let message = storageError ?? terminal.message {
                    Text(message).font(.footnote).foregroundStyle(.orange)
                }
                if terminal.connecting {
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
        guard scenePhase == .active, let credentials else { return }
        terminal.connect(agentID: agentID, credentials: credentials, authentication: AuthenticatedServerService.shared)
    }
}

private struct DeviceSSHSettingsView: View {
    @State private var credentials: DeviceSSHCredentials
    private let original: DeviceSSHCredentials
    private let save: (DeviceSSHCredentials) throws -> Void
    @State private var error: String?

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
                    VStack(alignment: .leading, spacing: 6) {
                        Text("SSH 主机指纹").font(.subheadline).foregroundStyle(.secondary)
                        TextField("SHA256:…", text: $credentials.fingerprint)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .accessibilityLabel("SSH 主机指纹")
                    }
                } footer: {
                    Text("使用 Windows OpenSSH 的 22 端口。请从可信来源核对并填入主机密钥的 SHA256 指纹。")
                }
                if let error { Text(error).font(.footnote).foregroundStyle(.orange) }
            }
            .privacySensitive()
        }
    }

    private func saveAndConnect() {
        do { try save(normalized) }
        catch { self.error = "SSH 配置无法保存，请解锁设备后重试。" }
    }
}
