import SwiftUI

// Used by manual entry and assistant draft editing; neither view submits a request.
struct QinglongTaskFields: View {
    @Binding var fields: [String: String]
    @Binding var enabled: Bool
    var timingNotice = "按青龙面板时区执行，修改在保存后生效。"
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 10) {
                sectionTitle("任务信息")
                VStack(spacing: 0) {
                    field("任务名称", key: "name")
                    separator
                    field("执行命令", key: "command", multiline: true)
                }.qinglongCard(padding: 0, cornerRadius: 16)
            }
            VStack(alignment: .leading, spacing: 10) {
                sectionTitle("执行计划")
                VStack(spacing: 0) {
                    field("Cron 表达式", key: "schedule")
                    separator
                    Toggle(isOn: $enabled) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("自动执行").font(.subheadline)
                            Text("关闭后仍可手动运行").font(.caption).foregroundStyle(QinglongStyle.muted)
                        }
                    }.toggleStyle(.switch).tint(.green).padding(16)
                }.qinglongCard(padding: 0, cornerRadius: 16)
                Text(timingNotice).font(.caption).foregroundStyle(QinglongStyle.muted).padding(.horizontal, 3)
            }
        }
    }
    private var separator: some View { Rectangle().fill(QinglongStyle.line).frame(height: 1).padding(.horizontal, 16) }
    private func sectionTitle(_ title: String) -> some View { Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(QinglongStyle.muted).padding(.horizontal, 3) }
    private func field(_ title: String, key: String, multiline: Bool = false) -> some View {
        let binding = Binding(get: { fields[key] ?? "" }, set: { fields[key] = $0 })
        return VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            if multiline {
            TextField("", text: binding, axis: .vertical).lineLimit(3...12)
                .font(.system(.footnote, design: .monospaced)).frame(minHeight: 72, alignment: .topLeading)
                .accessibilityLabel(title)
            } else {
            TextField("", text: binding).font(key == "schedule" ? .system(.body, design: .monospaced) : .body)
                .accessibilityLabel(title)
            }
        }.textInputAutocapitalization(.never).autocorrectionDisabled().padding(16)
    }
}

struct QinglongRecordFields: View {
    let resource: QinglongResource
    @Binding var fields: [String: String]
    @Binding var enabled: Bool
    let showsSchedule: Bool
    var body: some View {
        Section {
            field(resource == .envs ? "变量名" : "订阅名称", "name")
            if resource == .envs { field("变量值", "value"); field("备注", "remarks") }
            if resource == .subscriptions {
            field("仓库地址", "url"); field("别名", "alias")
            if showsSchedule { field("Cron 表达式", "schedule") }
            DisclosureGroup("更多选项") { field("分支", "branch"); field("包含关键词", "whitelist"); field("排除关键词", "blacklist") }
            }
        }
        if resource == .envs { Section { Toggle("启用此变量", isOn: $enabled).font(.subheadline) } }
    }
    private func field(_ title: String, _ key: String) -> some View {
        QinglongTextField(title, text: Binding(get: { fields[key] ?? "" }, set: { fields[key] = $0 }))
    }
}
