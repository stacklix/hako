import SwiftUI

struct HakoDataBackupSettings: View {
    @ObservedObject private var backup = HakoBackupService.shared
    @State private var editing: HakoBackupTarget?
    @State private var showsConnections = false

    var body: some View {
        SettingsSheet(title: "数据备份") {
            Form {
                Section {
                    ForEach(backup.targets) { target in
                        Button { editing = target } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(target.name).foregroundStyle(.primary)
                                    Text(target.provider.title + " · " + (target.parentDirectory.isEmpty ? "根目录" : target.parentDirectory))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(target.enabled ? "已启用" : "已停用").font(.caption).foregroundStyle(.secondary)
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }
                        .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                        .alignmentGuide(.listRowSeparatorTrailing) { $0.width }
                    }
                    if backup.targets.isEmpty { Text("尚未配置备份目的地").foregroundStyle(.secondary) }
                    Button("添加备份目的地") { editing = HakoBackupTarget() }
                        .buttonStyle(HakoActionButtonStyle()).disabled(backup.busy)
                    if let issue = backup.storageIssue { Text(issue).foregroundStyle(.red) }
                } header: { Text("备份目的地") } footer: {
                    Text("支持同时启用多个 Google Drive 和 WebDAV 目的地。子应用提交一次数据后，主应用依次发送到所有启用目的地；某个目的地失败不会阻止其他目的地。")
                }
                Section("连接管理") {
                    Button { showsConnections = true } label: {
                        Label("Google Drive 连接与配置说明", systemImage: "externaldrive.badge.icloud")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                    .alignmentGuide(.listRowSeparatorTrailing) { $0.width }
                }
                Section("快捷指令") {
                    Text("使用统一的“同步 Hako 数据”操作。“记账投资数据备份”子任务自动运行时仅在北京时间周日备份，其他日期记录为跳过；在主应用“设置 → 快捷指令”中点击“立即同步 Hako 数据”、在投资记账设置中手动执行，或在执行历史中手动重试失败的备份，不受星期限制。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .sheet(item: $editing) { HakoBackupTargetEditor(target: $0) }
        .sheet(isPresented: $showsConnections) { GoogleDriveSettingsSheet() }
    }
}

struct HakoBackupTargetEditor: View {
    let original: HakoBackupTarget
    @State private var draft: HakoBackupTarget
    @State private var password = ""
    @State private var checking = false
    @State private var checkMessage: String?
    @State private var error: String?
    @State private var showsConnections = false
    @State private var confirmingDelete = false
    @ObservedObject private var backup = HakoBackupService.shared
    @ObservedObject private var drive = GoogleDriveBackupService.shared
    @Environment(\.dismiss) private var dismiss

    init(target: HakoBackupTarget) { original = target; _draft = State(initialValue: target) }
    private var busy: Bool { checking || backup.busy || drive.busy }

    var body: some View {
        SettingsSheet(title: "备份目的地", hasChanges: draft != original || !password.isEmpty, isBusy: busy,
                      saveEnabled: (try? draft.validate()) != nil, onSave: save) {
            Form {
                Section("目的地") {
                    BackupTextField(title: "名称", text: $draft.name, hint: "个人网盘 / 家庭 NAS")
                    Toggle("启用此目的地", isOn: $draft.enabled)
                    Picker("类型", selection: $draft.provider) {
                        ForEach(HakoBackupProvider.allCases) { Text($0.title).tag($0) }
                    }
                    BackupTextField(title: "备份父目录", text: $draft.parentDirectory, hint: "Hako")
                }.disabled(busy)
                if draft.provider == .googleDrive {
                    Section {
                        Picker("Google Drive 连接", selection: $draft.googleDriveConnectionID) {
                            Text("请选择连接").tag(Optional<UUID>.none)
                            ForEach(drive.connections) { connection in
                                Text(connection.name + (drive.connectedIDs.contains(connection.id) ? " · 已连接" : " · 未连接"))
                                    .tag(Optional(connection.id))
                            }
                        }.disabled(busy)
                        Button("管理 Google Drive 连接") { showsConnections = true }.disabled(busy)
                    } footer: {
                        Text("在“我的云端硬盘”中自动创建父目录，可用 / 分层。填写名称不会授予已有目录访问权限，只管理 Hako 已获授权的目录与文件。多个目的地可共用一个连接。")
                    }
                } else {
                    Section {
                        BackupTextField(title: "WebDAV 目录地址", text: $draft.webDAV.serverURL, hint: "https://nas.example.com/remote.php/dav/files/user/")
                        BackupTextField(title: "用户名", text: $draft.webDAV.username, hint: "备份账号")
                        VStack(alignment: .leading, spacing: 6) {
                            Text("密码 / 应用专用密码").font(.subheadline).foregroundStyle(.secondary)
                            SecureField("新目的地必填；编辑时留空保留已保存密码", text: $password)
                                .textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityLabel("WebDAV 密码")
                        }
                        .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                        .alignmentGuide(.listRowSeparatorTrailing) { $0.width }
                        Button(checking ? "正在验证…" : "验证 WebDAV 目录") {
                            Task {
                                checking = true; checkMessage = nil
                                defer { checking = false }
                                do { try await backup.checkWebDAV(draft, password: password); checkMessage = "目录可访问，写入完整性将在备份时校验。" }
                                catch { self.error = error.localizedDescription }
                            }
                        }.buttonStyle(HakoActionButtonStyle(primary: false)).disabled(busy)
                        if let checkMessage { Text(checkMessage).font(.footnote).foregroundStyle(.secondary) }
                    } header: { Text("WebDAV") } footer: {
                        Text("填写已存在的 WebDAV 目录地址；建议使用 HTTPS 和应用专用密码。父目录和子应用目录自动创建。上传后下载文件逐字节校验，固定文件名会更新同路径文件。密码仅保存在本机钥匙串。")
                    }.disabled(checking || backup.busy)
                }
                if backup.targets.contains(where: { $0.id == draft.id }) {
                    Section {
                        HakoDeleteButton(title: "删除备份目的地") { confirmingDelete = true }
                            .disabled(busy).listRowBackground(Color.clear)
                    }
                }
            }
        }
        .sheet(isPresented: $showsConnections) { GoogleDriveSettingsSheet() }
        .hakoDeleteConfirmation(Text("删除此备份目的地？"), isPresented: $confirmingDelete,
                                message: Text("移除本机配置，不删除已上传的备份。")) {
            do { try backup.remove(draft.id); dismiss() } catch { self.error = error.localizedDescription }
        }
        .alert("数据备份", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("好", role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
    }
    private func save() {
        do { try backup.save(draft, password: password); dismiss() } catch { self.error = error.localizedDescription }
    }
}

struct BackupTextField: View {
    let title: String
    @Binding var text: String
    let hint: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            TextField(hint, text: $text).textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityLabel(title)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
        .alignmentGuide(.listRowSeparatorTrailing) { $0.width }
    }
}
