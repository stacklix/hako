import SwiftUI

struct ArcaneWorkspaceMutationView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: ArcaneStore
    let session: ArcaneFileMutationSession
    let onChanged: () -> Void
    @StateObject private var data: ArcaneWorkspaceMutationData
    @FocusState private var focused: Bool

    init(store: ArcaneStore, session: ArcaneFileMutationSession, onChanged: @escaping () -> Void) {
        self.store = store; self.session = session; self.onChanged = onChanged
        _data = StateObject(wrappedValue: ArcaneWorkspaceMutationData(name: session.mutation.initialName))
    }
    private var validation: String? {
        do { _ = try session.mutation.plan(name: data.name, project: session.project, workspace: session.workspace); return nil }
        catch { return error.localizedDescription }
    }
    private var restriction: String? { session.mutation.restriction(project: session.project, workspace: session.workspace) }
    private var folderName: String {
        let root = (session.project.path ?? session.project.name).split(separator: "/").last.map(String.init) ?? session.project.name
        return session.mutation.parent.isEmpty ? root : root + "/" + session.mutation.parent
    }
    private var canSubmit: Bool {
        validation == nil && !data.saving && !data.uncertain && !store.operationRunning && !store.fileSaveRunning && store.pending == nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("所在目录", value: folderName)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(session.mutation.isRename ? "新名称" : "名称").font(.subheadline).foregroundStyle(.secondary)
                        TextField(session.mutation.nameHint, text: $data.name)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .accessibilityLabel(session.mutation.isRename ? "新名称" : "名称")
                            .focused($focused).disabled(data.saving || restriction != nil)
                            .submitLabel(.done).onSubmit { if canSubmit { submit() } }
                    }
                } footer: {
                    if let restriction { Text(restriction) }
                    else if data.name != session.mutation.initialName, !data.name.isEmpty, let validation { Text(validation) }
                }
                if let error = data.error {
                    Section {
                        Text(error).font(.footnote).foregroundStyle(.orange)
                        Button("关闭并刷新目录") { onChanged(); dismiss() }.disabled(data.saving)
                    }
                }
            }
            .navigationTitle(session.mutation.title).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(data.saving) }
                ToolbarItem(placement: .confirmationAction) {
                    Button { submit() } label: {
                        if data.saving { ProgressView() } else { Text(session.mutation.isRename ? "重命名" : "创建") }
                    }.disabled(!canSubmit)
                }
            }
            .onAppear { focused = restriction == nil }
        }
        .presentationDetents([.medium, .large])
        .interactiveDismissDisabled(data.saving)
    }

    private func submit() {
        focused = false
        Task {
            let saved = await data.submit(store: store, session: session)
            if saved || data.uncertain { onChanged() }
            if saved { dismiss() }
        }
    }
}
