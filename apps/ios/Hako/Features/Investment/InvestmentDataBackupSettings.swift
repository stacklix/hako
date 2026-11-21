import SwiftUI

struct InvestmentDataBackupSettings: View {
    @State private var draft = InvestmentBackup.backupFile()
    @State private var saved = InvestmentBackup.backupFile()
    @State private var report = AppServices.dataBackup().latestReport(applicationID: InvestmentBackup.applicationID)
    @State private var running = false
    @State private var message: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        SettingsSheet(title: "投资数据备份", hasChanges: draft != saved, isBusy: running,
                      saveEnabled: valid, onSave: save) {
            Form {
                Section {
                    field("子目录", text: $draft.subdirectory, hint: "投资记账")
                    field("文件名", text: $draft.fileName, hint: "投资记账-{date}-{time}.zip")
                    if let target = try? draft.resolved() {
                        LabeledContent("相对路径") {
                            Text((target.directories + [target.fileName]).joined(separator: "/"))
                                .font(.caption).textSelection(.enabled)
                        }
                    }
                } header: { Text("备份文件") } footer: {
                    Text("子目录可留空或用 / 分层。文件名支持北京时间 {date} 和 {time}。目的地、账号和父目录统一在主应用“设置 → 数据备份”中配置。")
                }
                Section {
                    LabeledContent("统一入口", value: "同步 Hako 数据")
                    LabeledContent("子任务", value: InvestmentBackup.shortcutName)
                    LabeledContent("自动执行时间", value: "北京时间每周日")
                    Text("快捷指令自动运行时，非周日记录为跳过。手动点击下方按钮立即备份，不受星期限制；账本 ZIP 由主应用分发到所有已启用的备份目的地。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button(running ? "正在执行…" : "执行备份子任务") { Task { await execute() } }
                        .buttonStyle(HakoActionButtonStyle()).disabled(running || !valid || draft != saved)
                    if draft != saved { Text("请先保存修改，再执行子任务。").font(.footnote).foregroundStyle(.secondary) }
                } header: { Text("快捷指令自动化") } footer: {
                    Text("在快捷指令中保留“同步 Hako 数据”操作即可。需要有效的服务端登录和网络；结果与跳过原因可在主应用“快捷指令执行历史”中查看。")
                }
                if let report {
                    Section("最近一次备份尝试") {
                        LabeledContent("记录时间", value: report.completedAt.formatted(date: .abbreviated, time: .standard))
                        LabeledContent("目的地结果", value: "\(report.destinations.count) / \(report.expectedCount)")
                        Text(report.message).font(.footnote).textSelection(.enabled)
                    }
                }
                Section {
                    Text("备份包含服务端已保存的全部账本 CSV 和 SQLite 建表语句。未保存的编辑不包含在内。固定文件名会更新原文件，包含日期和时间可保留多份备份。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .alert("投资数据备份", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("好", role: .cancel) { message = nil }
        } message: { Text(message ?? "") }
    }
    private var valid: Bool { (try? draft.resolved().fileName.lowercased().hasSuffix(".zip")) == true }
    private func field(_ title: String, text: Binding<String>, hint: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            TextField(hint, text: text).textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityLabel(title)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
        .alignmentGuide(.listRowSeparatorTrailing) { $0.width }
    }
    private func save() {
        do { try InvestmentBackup.saveBackupFile(draft); saved = draft; dismiss() }
        catch { message = error.localizedDescription }
    }
    private func execute() async {
        running = true
        defer { running = false; report = AppServices.dataBackup().latestReport(applicationID: InvestmentBackup.applicationID) }
        do { message = try await HakoShortcutRegistry.run(InvestmentBackup.shortcutName, names: [InvestmentBackup.shortcutName], manual: true) }
        catch { message = error.localizedDescription }
    }
}
