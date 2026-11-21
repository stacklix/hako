import SwiftUI

struct GoogleDriveSettingsSheet: View {
    @ObservedObject private var drive = GoogleDriveBackupService.shared
    @State private var editing: GoogleDriveConnectionSettings?
    var body: some View {
        SettingsSheet(title: "Google Drive 连接") {
            Form {
                Section("连接") {
                    ForEach(drive.connections) { connection in
                        Button { editing = connection } label: {
                            HStack {
                                Text(connection.name)
                                Spacer()
                                Text(drive.connectedIDs.contains(connection.id) ? "已连接" : "未连接")
                                    .font(.caption).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                        .alignmentGuide(.listRowSeparatorTrailing) { $0.width }
                    }
                    Button("添加 Google Drive 连接") { editing = GoogleDriveConnectionSettings() }
                        .buttonStyle(HakoActionButtonStyle()).disabled(drive.busy)
                    if let issue = drive.storageIssue { Text(issue).foregroundStyle(.red) }
                }
                Section("Google Cloud 配置步骤") {
                    Text("1. 创建项目，启用 Google Drive API。\n2. 在 Google Auth Platform → Branding 填应用名称和联系邮箱；Audience 选择 External，自用测试时加入自己的 Google 账号。\n3. 在 Data Access 添加 https://www.googleapis.com/auth/drive.file 权限。\n4. 在 Clients 创建 iOS 客户端，Bundle ID 填 me.stackli.hako，Team ID 如要求则填应用签名团队。\n5. 复制 Client ID，在本页添加连接并完成授权。不需要 client secret 或后端回调地址。")
                        .font(.footnote).foregroundStyle(.secondary).textSelection(.enabled)
                    Link("打开 Google Drive API 配置", destination: URL(string: "https://console.cloud.google.com/apis/library/drive.googleapis.com")!)
                    Text("长期自动备份前，将外部 OAuth 应用发布状态设为 In production；Testing 状态下 Drive 刷新令牌通常 7 天后过期。发布状态与应用验证是不同事项。多个账号可使用同一个 iOS Client ID，分别授权为独立连接。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .sheet(item: $editing) { GoogleDriveConnectionEditor(connection: $0) }
    }
}

private struct GoogleDriveConnectionEditor: View {
    let original: GoogleDriveConnectionSettings
    @State private var draft: GoogleDriveConnectionSettings
    @State private var error: String?
    @State private var confirmingDelete = false
    @ObservedObject private var drive = GoogleDriveBackupService.shared
    @Environment(\.dismiss) private var dismiss
    init(connection: GoogleDriveConnectionSettings) { original = connection; _draft = State(initialValue: connection) }
    private var connected: Bool { drive.connectedIDs.contains(draft.id) }
    private var saved: GoogleDriveConnectionSettings { drive.connections.first(where: { $0.id == draft.id }) ?? original }

    var body: some View {
        SettingsSheet(title: "Google Drive 连接", hasChanges: draft != saved, isBusy: drive.busy,
                      saveEnabled: (try? draft.validate()) != nil, onSave: save) {
            Form {
                Section("连接配置") {
                    BackupTextField(title: "连接名称", text: $draft.name, hint: "个人账号 / 家庭账号").disabled(drive.busy)
                    BackupTextField(title: "iOS OAuth Client ID", text: $draft.clientID, hint: "…apps.googleusercontent.com")
                        .disabled(connected || drive.busy)
                    LabeledContent("授权状态", value: connected ? "已连接" : "未连接")
                    Button(drive.busy ? "正在授权…" : connected ? "重新选择账号并授权" : "连接 Google Drive") {
                        Task { do { try await drive.connect(draft) } catch { self.error = error.localizedDescription } }
                    }.buttonStyle(HakoActionButtonStyle()).disabled(drive.busy || (try? draft.validate()) == nil)
                    if connected {
                        Button("断开此连接") {
                            do { try drive.disconnect(draft.id) } catch { self.error = error.localizedDescription }
                        }.disabled(drive.busy)
                    }
                }
                Section {
                    Text("此处管理账号授权。返回“数据备份”添加 Google Drive 目的地，选择此连接并设置父目录；可为同一连接配置多个父目录。令牌保存在本机钥匙串。断开仅清除本机令牌，不删除云端文件。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if drive.connections.contains(where: { $0.id == draft.id }) {
                    Section {
                        HakoDeleteButton(title: "删除连接") { confirmingDelete = true }
                            .disabled(drive.busy).listRowBackground(Color.clear)
                    }
                }
            }
        }
        .hakoDeleteConfirmation(Text("删除此 Google Drive 连接？"), isPresented: $confirmingDelete,
                                message: Text("请先移除使用此连接的目的地。已上传文件不会删除。")) {
            do { try drive.remove(draft.id); dismiss() } catch { self.error = error.localizedDescription }
        }
        .alert("Google Drive", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("好", role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
    }
    private func save() { do { try drive.save(draft); dismiss() } catch { self.error = error.localizedDescription } }
}
