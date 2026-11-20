import SwiftUI

struct HakoCloudSettingsView: View {
    @ObservedObject private var cloud = HakoCloudSettings.shared
    @State private var checkResult: String?

    var body: some View {
        SettingsSheet(title: "iCloud 与换机恢复") {
            Form {
                Section {
                    Text("密钥和普通设置使用 iCloud 同步。提示词、助手会话及未发送草稿随系统整机备份恢复，不进行跨设备实时同步。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section {
                    Label("iCloud 钥匙串", systemImage: "key.icloud")
                    Text(cloud.credentialStatus).font(.footnote).foregroundStyle(.secondary)
                    Text("请在系统 iCloud 设置中开启“密码与钥匙串”。换机时使用同一 Apple 账户；系统负责上传和接收，Hako 无法确认其他设备是否已收到。")
                        .font(.footnote).foregroundStyle(.secondary)
                } header: { Text("密钥与连接配置") } footer: {
                    Text("包含 GitHub、交易所、行情、大模型、SSH、容器和面板等凭据及对应配置；修改和删除也会同步。设备身份私钥和服务端登录会话保留在本机，新手机仍须重新绑定、登录。")
                }
                Section {
                    Toggle("同步普通设置", isOn: Binding(get: { cloud.enabled }, set: cloud.setEnabled))
                    Text(cloud.settingsStatus).font(.footnote).foregroundStyle(.secondary)
                    if let date = cloud.lastReceivedAt {
                        LabeledContent("最近接收云端设置", value: date.formatted(date: .abbreviated, time: .standard))
                            .font(.footnote)
                    }
                } header: { Text("设置同步") } footer: {
                    Text("同步主题、首页排序、GitHub 仓库、服务器地址及用户名、网络配置、钱包列表、自选币种和投资显示偏好。不包含运行中的任务和缓存。部分连接配置下次启动生效。")
                }
                Section {
                    Label("提示词、助手会话与草稿", systemImage: "icloud.and.arrow.up")
                    Text("已允许系统将这些文件纳入备份。请在系统中开启 iCloud 云备份，并确认 Hako 未被排除；在新手机设置过程中恢复整机备份。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Toggle("备份执行历史与运行日志", isOn: Binding(get: { cloud.includesHistory }, set: cloud.setIncludesHistory))
                    if let issue = cloud.backupIssue { Text(issue).font(.footnote).foregroundStyle(.orange) }
                } header: { Text("整机备份与恢复") } footer: {
                    Text("文件纳入备份不代表已经上传；备份由 iOS 调度。行情、目录和消息等可重新下载的缓存继续排除。投资账本及已同步到 GitHub 的历史仍从原服务恢复。")
                }
                Section {
                    Button {
                        Task {
                            await cloud.prepareForRecovery(recheckBackup: true)
                            checkResult = [
                                "密钥与连接配置：\n\(cloud.credentialStatus)",
                                "普通设置：\n\(cloud.settingsStatus)",
                                "文件备份：\n\(cloud.backupIssue ?? "备份标记已更新，等待系统执行备份。")",
                                "以上是本机准备结果，不代表已上传完成。整机备份可前往系统 iCloud 云备份中手动执行。"
                            ].joined(separator: "\n\n")
                        }
                    } label: {
                        if cloud.preparing {
                            HStack {
                                ProgressView()
                                Text("正在检查…")
                            }.frame(maxWidth: .infinity)
                        }
                        else { Text("检查同步与备份准备") }
                    }
                    .buttonStyle(HakoActionButtonStyle())
                    .disabled(cloud.preparing)
                    .listRowBackground(Color.clear)
                }
            }
            .privacySensitive()
        }
        .alert("检查结果", isPresented: Binding(get: { checkResult != nil }, set: { if !$0 { checkResult = nil } })) {
            Button("知道了", role: .cancel) { checkResult = nil }
        } message: {
            Text(checkResult ?? "")
        }
        .task { await cloud.prepareForRecovery() }
    }
}
