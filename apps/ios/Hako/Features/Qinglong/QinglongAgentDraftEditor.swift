import SwiftUI

@MainActor
struct QinglongAgentDraftEditor: View {
    @ObservedObject var agent: QinglongAgentSession
    let proposal: QinglongAgentProposal
    @Environment(\.dismiss) private var dismiss
    @State private var fields: [String: String]
    @State private var enabled: Bool
    @State private var error: String?

    init(agent: QinglongAgentSession, proposal: QinglongAgentProposal) {
        self.agent = agent; self.proposal = proposal
        _fields = State(initialValue: proposal.editingFields)
        _enabled = State(initialValue: proposal.editingEnabled)
    }
    private var changed: Bool { fields != proposal.editingFields || enabled != proposal.editingEnabled }
    private var busy: Bool { agent.working || agent.committing }
    private var showsSchedule: Bool { proposal.item == nil || proposal.item?.raw["schedule_type"].text == "crontab" }
    var body: some View {
        SettingsSheet(title: "修改草稿", hasChanges: changed, isBusy: busy, saveEnabled: changed,
                      onSave: save, saveAccessibilityLabel: "保存草稿") {
            Group {
                if proposal.action.resource == .tasks {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            QinglongTaskFields(fields: $fields, enabled: $enabled,
                                               timingNotice: "按青龙面板时区执行，确认卡片后才会提交。")
                            notice
                        }.padding(16)
                    }
                } else if [.envs, .subscriptions].contains(proposal.action.resource) {
                    Form {
                        QinglongRecordFields(resource: proposal.action.resource, fields: $fields, enabled: $enabled, showsSchedule: showsSchedule)
                        Section { notice }
                    }
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        if proposal.action.kind == .create {
                            QinglongTextField("文件名", text: binding("filename"))
                            QinglongTextField("目录", text: binding("directory"))
                        } else { Text(proposal.item?.filePath ?? "文件").font(.caption).foregroundStyle(.secondary) }
                        Text("文件内容").font(.subheadline).foregroundStyle(.secondary)
                        HakoCodeEditor(text: binding("content"), filename: proposal.item?.filePath ?? fields["filename"] ?? "",
                                       editable: !busy, saving: false)
                        notice
                    }.padding(16)
                }
            }
            .background(HakoStyle.background).disabled(busy)
        }
    }
    private var notice: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error { Text(error).font(.footnote).foregroundStyle(.red) }
            Text("保存后返回预览，确认前不会修改面板。")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }
    private func binding(_ key: String) -> Binding<String> { Binding(get: { fields[key] ?? "" }, set: { fields[key] = $0 }) }
    private func save() {
        do {
            try agent.revise(proposal.revising(fields: fields, enabled: enabled))
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
