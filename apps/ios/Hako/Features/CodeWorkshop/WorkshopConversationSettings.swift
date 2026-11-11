import SwiftUI

struct WorkshopConversationSettings: View {
    @ObservedObject var conversation: WorkshopConversation
    @Environment(\.dismiss) private var dismiss
    @State private var selection: WorkshopChoice
    @State private var error: String?

    init(conversation: WorkshopConversation) {
        self.conversation = conversation
        _selection = State(initialValue: conversation.choice)
    }

    private var model: WorkshopModel? {
        if let id = selection.model { return conversation.models.first { $0.id == id } }
        return conversation.models.first { $0.isDefault }
    }

    private var speeds: [WorkshopSpeed] {
        [WorkshopSpeed.standard] + (model?.serviceTiers.filter { $0.id != "default" } ?? [])
    }

    private var speedSelection: Binding<String> {
        Binding(get: { selection.serviceTier ?? "default" }, set: { selection.serviceTier = $0 == "default" ? nil : $0 })
    }

    var body: some View {
        SettingsSheet(title: "会话设置", hasChanges: selection != conversation.choice,
            saveEnabled: conversation.canSend && selection != conversation.choice, onSave: save,
            saveAccessibilityLabel: "保存会话设置") {
            Form {
                Section {
                    Picker("模型", selection: $selection.model) {
                        Text("跟随会话设置").tag(Optional<String>.none)
                        ForEach(conversation.models) { model in Text(model.name).tag(Optional(model.id)) }
                        if let id = selection.model, !conversation.models.contains(where: { $0.id == id }) {
                            Text(id).tag(Optional(id))
                        }
                    }
                    .pickerStyle(.menu).workshopSettingsRow()
                    Picker("速度", selection: speedSelection) {
                        ForEach(speeds) { speed in Text(speed.name).tag(speed.id) }
                    }
                    .pickerStyle(.menu).workshopSettingsRow()
                    .disabled(conversation.loadingModels || model == nil)
                } header: { Text("生成设置") } footer: {
                    Text(speeds.first { $0.id == (selection.serviceTier ?? "default") }?.description ?? "此模型当前未提供所选速度。")
                }.disabled(!conversation.canSend)
                if conversation.loadingModels { ProgressView("正在读取模型…") }
                if let message = conversation.modelError {
                    Section {
                        Text(message).font(.footnote).foregroundStyle(.red)
                        Button("重新读取模型") { Task { await conversation.loadModels() } }
                    }
                }
                Section {
                    Picker("权限", selection: $selection.permission) {
                        ForEach(WorkshopPermission.allCases) { permission in Text(permission.title).tag(permission) }
                    }
                    .pickerStyle(.menu).workshopSettingsRow()
                } header: { Text("执行权限") } footer: {
                    Text(selection.permission.detail).foregroundStyle(selection.permission == .full ? Color.orange : .secondary)
                }.disabled(!conversation.canSend)
                Section("会话信息") {
                    LabeledContent("应用", value: conversation.application.name)
                    LabeledContent("会话名称", value: conversation.title)
                    LabeledContent("执行电脑", value: conversation.agent.name)
                }
                Section("项目目录") { Text(conversation.application.path).font(.caption.monospaced()).textSelection(.enabled) }
                Section { Text("设置在下一次发送时生效。").font(.footnote).foregroundStyle(.secondary) }
                if let error { Section { Text(error).font(.footnote).foregroundStyle(.red) } }
            }
            .task { await conversation.loadModels() }
            .onChange(of: selection.model) { _, _ in
                if let tier = selection.serviceTier, !speeds.contains(where: { $0.id == tier }) { selection.serviceTier = nil }
            }
        }
    }

    private func save() {
        do { try conversation.configure(selection); dismiss() }
        catch { self.error = error.localizedDescription }
    }
}

private extension View {
    func workshopSettingsRow() -> some View {
        frame(maxWidth: .infinity)
            .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
            .alignmentGuide(.listRowSeparatorTrailing) { $0.width }
    }
}
