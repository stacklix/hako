import SwiftUI

struct WorkshopDefaultGenerationSettings: View {
    @ObservedObject var store: WorkshopStore
    let agent: WorkshopAgent
    @Environment(\.dismiss) private var dismiss
    @State private var selection: WorkshopGenerationDefaults
    @State private var models: [WorkshopModel] = []
    @State private var loading = false
    @State private var error: String?
    private let openingScope: String

    init(store: WorkshopStore, agent: WorkshopAgent) {
        self.store = store; self.agent = agent; openingScope = store.scope
        _selection = State(initialValue: store.generationDefaults(for: agent.id))
    }

    private var model: WorkshopModel? {
        if let id = selection.model { return models.first { $0.id == id } }
        return models.first { $0.isDefault }
    }
    private var speeds: [WorkshopSpeed] { [.standard] + (model?.serviceTiers.filter { $0.id != "default" } ?? []) }
    private var hasChanges: Bool { selection != store.generationDefaults(for: agent.id) }
    private var speedSelection: Binding<String> {
        Binding(get: { selection.serviceTier ?? "default" }, set: { selection.serviceTier = $0 == "default" ? nil : $0 })
    }

    var body: some View {
        SettingsSheet(title: "默认生成设置", hasChanges: hasChanges,
            saveEnabled: hasChanges && !loading && openingScope == store.scope && selection.validationError(models: models) == nil,
            onSave: save, saveAccessibilityLabel: "保存默认生成设置") {
            Form {
                Section {
                    LabeledContent("执行电脑", value: agent.name).defaultGenerationRow()
                } footer: { Text("保存在当前账号的这台手机上，按执行电脑分别设置。仅用于新会话，已有会话及其单独设置不受影响。") }
                Section("默认生成设置") {
                    Picker("模型", selection: $selection.model) {
                        Text("跟随执行电脑").tag(Optional<String>.none)
                        ForEach(models) { item in Text(item.name).tag(Optional(item.id)) }
                        if let id = selection.model, !models.contains(where: { $0.id == id }) {
                            Text(id).tag(Optional(id))
                        }
                    }.pickerStyle(.menu).defaultGenerationRow().disabled(loading)
                    Picker("速度", selection: speedSelection) {
                        ForEach(speeds) { speed in Text(speed.name).tag(speed.id) }
                        if let tier = selection.serviceTier, !speeds.contains(where: { $0.id == tier }) {
                            Text(tier).tag(tier)
                        }
                    }.pickerStyle(.menu).defaultGenerationRow().disabled(model == nil || loading)
                    Picker("推理强度", selection: $selection.reasoningEffort) {
                        Text("跟随模型默认").tag(Optional<String>.none)
                        ForEach(model?.reasoningEfforts ?? []) { effort in Text(effort.title).tag(Optional(effort.id)) }
                        if let effort = selection.reasoningEffort, model?.reasoningEfforts.contains(where: { $0.id == effort }) != true {
                            Text(WorkshopReasoningEffort(id: effort, description: "").title).tag(Optional(effort))
                        }
                    }.pickerStyle(.menu).defaultGenerationRow().disabled(model == nil || loading)
                }
                Section {
                    if loading { ProgressView("正在读取模型…") }
                    if let error { Text(error).font(.footnote).foregroundStyle(.red) }
                    if let validation = selection.validationError(models: models), !loading {
                        Text(validation).font(.footnote).foregroundStyle(.secondary)
                    }
                    Button("刷新模型列表") { Task { await loadModels() } }
                        .defaultGenerationRow().disabled(loading || !agent.online || openingScope != store.scope)
                    Button("恢复默认") { selection = WorkshopGenerationDefaults() }
                        .defaultGenerationRow().disabled(selection == WorkshopGenerationDefaults())
                } footer: {
                    Text("可用选项来自这台电脑。更换模型时，不支持的速度和推理强度会重置；保存后，新会话仍可单独调整。")
                }
            }
            .task(id: store.scope) { await loadModels() }
            .onChange(of: selection.model) { _, _ in
                if let tier = selection.serviceTier, !speeds.contains(where: { $0.id == tier }) { selection.serviceTier = nil }
                if let effort = selection.reasoningEffort, model?.reasoningEfforts.contains(where: { $0.id == effort }) != true { selection.reasoningEffort = nil }
            }
        }
    }

    private func loadModels() async {
        guard !loading, openingScope == store.scope else { return }
        guard agent.online else { error = "执行电脑离线，连接后可读取模型列表。"; return }
        loading = true; error = nil
        defer { loading = false }
        do {
            let result: WorkshopModelList = try await store.call(agent, "models.list")
            try Task.checkCancellation()
            guard openingScope == store.scope else { return }
            models = result.models
            if models.isEmpty { error = "这台电脑尚未返回可用模型，请稍后重试。" }
        } catch {
            guard !Task.isCancelled, openingScope == store.scope else { return }
            self.error = error.localizedDescription
        }
    }

    private func save() {
        do {
            try store.saveGenerationDefaults(selection, agent: agent, models: models, expectedScope: openingScope)
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

private extension View {
    func defaultGenerationRow() -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
            .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
            .alignmentGuide(.listRowSeparatorTrailing) { $0.width }
    }
}
