import SwiftUI

struct WorkshopSystemPromptSheet: View {
    @ObservedObject var store: WorkshopStore
    @Environment(\.dismiss) private var dismiss
    @State private var draft: String
    @State private var error: String?
    private let account: String

    init(store: WorkshopStore) {
        self.store = store
        account = store.settingsAccount
        _draft = State(initialValue: store.systemPrompt)
    }

    var body: some View {
        SettingsSheet(title: "系统提示词", hasChanges: draft != store.systemPrompt,
            saveEnabled: (draft != store.systemPrompt || store.systemPromptLoadError != nil) && WorkshopSystemPrompt.valid(draft), onSave: save,
            saveAccessibilityLabel: "保存系统提示词") {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("代码工坊系统提示词").font(.subheadline).foregroundStyle(.secondary)
                        TextEditor(text: $draft).frame(minHeight: 300)
                            .accessibilityLabel("代码工坊系统提示词")
                        Text("\(draft.utf16.count) / \(WorkshopSystemPrompt.maximumLength)")
                            .font(.caption).foregroundStyle(WorkshopSystemPrompt.valid(draft) ? Color.secondary : .red)
                    }
                } footer: {
                    Text("保存在这台手机，当前账号的所有项目共用。只在新建会话的第一条消息中发送；后续消息沿用会话已有提示词。修改不影响已存在的会话。留空则不附加提示词。")
                }
                Section {
                    Button("恢复默认提示词") { draft = WorkshopSystemPrompt.defaultText }
                        .buttonStyle(HakoActionButtonStyle(primary: false))
                        .listRowBackground(Color.clear)
                }
                if let issue = store.systemPromptLoadError { Section { Text(issue).font(.footnote).foregroundStyle(.red) } }
                if let error { Section { Text(error).font(.footnote).foregroundStyle(.red) } }
            }
        }
        .onChange(of: store.settingsAccount) { _, _ in dismiss() }
    }

    private func save() {
        guard account == store.settingsAccount else { return }
        do { try store.saveSystemPrompt(draft); dismiss() }
        catch { self.error = error.localizedDescription }
    }
}
