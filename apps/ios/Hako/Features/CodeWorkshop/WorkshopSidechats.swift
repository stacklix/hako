import SwiftUI
import Combine

struct WorkshopSidechatList: Decodable { let sessions: [WorkshopSession]; let nextCursor: String? }

@MainActor final class WorkshopSidechats: ObservableObject {
    let parent: WorkshopConversation
    @Published private(set) var sessions: [WorkshopSession] = []
    @Published var selected: WorkshopConversation?
    @Published private(set) var loading = false
    @Published var error: String?
    @Published private(set) var nextCursor: String?
    private var draft: WorkshopConversation?

    init(parent: WorkshopConversation) { self.parent = parent }

    func refresh(more: Bool = false) async {
        guard parent.scope == parent.store.scope, parent.store.authenticated, let id = parent.threadId, !loading else { return }
        loading = true
        defer { loading = false }
        do {
            var parameters: [String: Any] = ["threadId": id, "applicationId": parent.application.id]
            if more { guard let nextCursor else { return }; parameters["cursor"] = nextCursor }
            let reply: WorkshopSidechatList = try await parent.store.call(parent.agent, "sidechat.list", parameters)
            guard parent.scope == parent.store.scope, !Task.isCancelled else { return }
            if more { sessions.append(contentsOf: reply.sessions.filter { incoming in !sessions.contains(where: { $0.id == incoming.id }) }) }
            else { sessions = reply.sessions }
            nextCursor = reply.nextCursor
            for receipt in parent.store.sidechatReceipts(parent: id, agent: parent.agent)
                where !sessions.contains(where: { $0.id == receipt.threadId || $0.operationId == receipt.id }) {
                sessions.insert(WorkshopSession(id: receipt.threadId ?? "pending-" + receipt.id, title: receipt.title,
                    applicationId: parent.application.id, cwd: parent.application.path, preview: receipt.message,
                    updatedAt: Int64(receipt.createdAt.timeIntervalSince1970), state: "starting", operationId: receipt.id,
                    parentThreadId: id), at: 0)
            }
            error = nil
        } catch is CancellationError { }
        catch { if parent.scope == parent.store.scope { self.error = error.localizedDescription } }
    }

    func create(quote: String? = nil) {
        guard parent.scope == parent.store.scope, parent.store.authenticated, let id = parent.threadId else { return }
        if let draft, draft.threadId == nil, draft.notificationOperationID == nil {
            if let quote, draft.draft.isEmpty { draft.draft = "关于主会话这段内容：\n\n" + String(quote.prefix(2400)) + "\n\n" }
            selected = draft
            return
        }
        let child = WorkshopRuntime.shared.create(agent: parent.agent, application: parent.application,
            title: "新的侧聊", parentThreadId: id, initialChoice: parent.choice)
        if let quote, child.draft.isEmpty { child.draft = "关于主会话这段内容：\n\n" + String(quote.prefix(2400)) + "\n\n" }
        selected = child
        draft = child
    }

    func open(_ session: WorkshopSession) {
        guard parent.scope == parent.store.scope else { return }
        selected = WorkshopRuntime.shared.open(session, agent: parent.agent, application: parent.application, archived: false)
    }
}

struct WorkshopSidechatSheet: View {
    @ObservedObject var model: WorkshopSidechats
    @Environment(\.dismiss) private var dismiss
    @State private var transfer: WorkshopSidechatTransfer?

    var body: some View {
        NavigationStack {
            if let child = model.selected {
                WorkshopConversationView(conversation: child, sidechatParent: model.parent,
                    showSidechatList: { model.selected = nil; Task { await model.refresh() } },
                    newSidechat: { model.create() }, returnSidechat: { transfer = .init(text: $0) }, sidechatOverlayPresented: transfer != nil)
            } else {
                List {
                    Section {
                        WorkshopSidechatParentStatus(parent: model.parent)
                    }
                    if let error = model.error {
                        Section {
                            Text(error).font(.footnote).foregroundStyle(.secondary)
                            Button("重新读取") { Task { await model.refresh() } }.disabled(model.loading)
                        }
                    }
                    if model.loading && model.sessions.isEmpty { ProgressView("正在读取侧聊…") }
                    ForEach(model.sessions) { session in
                        Button { model.open(session) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "bubble.left.and.bubble.right").foregroundStyle(HakoStyle.muted)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(session.title).foregroundStyle(HakoStyle.text).lineLimit(2)
                                    Text(session.preview).font(.caption).foregroundStyle(HakoStyle.muted).lineLimit(2)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                                .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                                .alignmentGuide(.listRowSeparatorTrailing) { $0.width }
                        }.buttonStyle(.plain)
                    }
                    if model.nextCursor != nil {
                        Button(model.loading ? "正在读取…" : "加载更早的侧聊") { Task { await model.refresh(more: true) } }
                            .disabled(model.loading)
                    }
                    Section {
                        Button { model.create() } label: { Label("新建侧聊", systemImage: "plus") }
                    } footer: {
                        Text("创建时继承主会话上下文，后续讨论独立保存。")
                    }
                }
                .scrollContentBackground(.hidden).background(HakoStyle.background)
                .navigationTitle("侧聊").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { dismiss() } label: { Image(systemName: "xmark") }.accessibilityLabel("关闭侧聊")
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { model.create() } label: { Image(systemName: "plus") }.accessibilityLabel("新建侧聊")
                    }
                }
                .refreshable { await model.refresh() }
                .task { await model.refresh() }
            }
        }
        .presentationDetents([.large]).presentationDragIndicator(.visible)
        .sheet(item: $transfer) { item in
            WorkshopSidechatReturnView(parent: model.parent, text: item.text) { dismiss() }
        }
    }
}

struct WorkshopSidechatTransfer: Identifiable { let id = UUID(); let text: String }

struct WorkshopSidechatParentStatus: View {
    @ObservedObject var parent: WorkshopConversation
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: parent.operation?.active == true ? "circle.fill" : "checkmark.circle")
                .foregroundStyle(parent.operation?.active == true ? Color.green : HakoStyle.muted)
            VStack(alignment: .leading, spacing: 3) {
                Text(parent.operation?.active == true ? "主任务继续执行中" : "关联主会话")
                Text(parent.title).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }.font(.caption)
    }
}

struct WorkshopSidechatReturnView: View {
    @ObservedObject var parent: WorkshopConversation
    @State var text: String
    let onSubmitted: () -> Void
    private let initialText: String
    @State private var steer = true
    @State private var sending = false
    @State private var error: String?

    init(parent: WorkshopConversation, text: String, onSubmitted: @escaping () -> Void) {
        self.parent = parent
        _text = State(initialValue: text)
        initialText = text
        self.onSubmitted = onSubmitted
    }

    var body: some View {
        SettingsSheet(title: "发回主会话", hasChanges: text != initialText, isBusy: sending) {
            Form {
                Section("补充给 Codex 的指令") {
                    TextEditor(text: $text).frame(minHeight: 150).accessibilityLabel("补充给 Codex 的指令")
                }
                if parent.operation?.active == true {
                    Section {
                        Picker("发送方式", selection: $steer) {
                            Text("立即引导").tag(true)
                            Text("排队发送").tag(false)
                        }.pickerStyle(.segmented)
                    } header: { Text("发送方式") } footer: { Text(steer ? "补充到正在执行的任务中。" : "当前轮次结束后再执行。") }
                } else {
                    Section { Text("发送后会在主会话开启新一轮。").font(.footnote).foregroundStyle(.secondary) }
                }
                if let error { Section { Text(error).font(.footnote).foregroundStyle(.secondary) } }
                Section {
                    Button(sending ? "正在发送…" : "发送并返回主会话") {
                        sending = true
                        Task {
                            let submitted = await parent.sendSidechatConclusion(text, steer: steer)
                            sending = false
                            if submitted { onSubmitted() }
                            else { error = parent.error ?? "主会话暂时无法发送，请检查连接或任务状态后重试。" }
                        }
                    }.buttonStyle(HakoActionButtonStyle())
                        .disabled(sending || !parent.canSendPrompt || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || text.utf16.count > 4000)
                }
            }
        }
    }
}
