import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

@MainActor
struct InvestmentAgentSheet: View {


    private struct ToolSelection: Identifiable { let id: UUID }

    @ObservedObject private var store: InvestmentStore
    @ObservedObject private var agent: InvestmentAgentSession
    @Environment(\.scenePhase) private var scenePhase
    @State private var scrollFollowing = ConversationScrollFollowing()
    @State private var expandedThinking: Set<UUID> = []
    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var photoSelectionLimit = InvestmentAgentConversation.maximumImageCount
    @State private var imagePreview: AssistantImageSelection?
    @State private var selectedTool: ToolSelection?
    @State private var showsPhotos = false
    @State private var showsModelSettings = false
    @State private var editing: InvestmentAgentProposal?
    @State private var exportDocument: InvestmentExportDocument?
    @State private var exporting = false
    @State private var showsExporter = false
    @State private var confirmsNewConversation = false
    @FocusState private var composing: Bool

    init(store: InvestmentStore, agent: InvestmentAgentSession) {
        self.store = store
        self.agent = agent
    }

    var body: some View {
        SettingsSheet(title: "记账助手",
                      isBusy: agent.committing || exporting) {
            VStack(spacing: 0) {
                thread
                composer
            }
            .background(HakoStyle.background)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { confirmsNewConversation = true } label: {
                        Image(systemName: "square.and.pencil")
                    }
                    .accessibilityLabel("新建会话")
                    .disabled(!canStartNewConversation)
                }
            }
        }
        .onAppear { agent.checkConfiguration() }
        .onDisappear { agent.saveComposerDraft() }
        .onChange(of: scenePhase) { _, phase in if phase != .active { agent.saveComposerDraft() } }
        .onChange(of: store.hasLoaded, initial: true) { _, loaded in
            if loaded { agent.restoreConversation() }
        }
        .alert("新建会话", isPresented: $confirmsNewConversation) {
            Button("取消", role: .cancel) {}
            Button("新建会话", role: .destructive, action: startNewConversation)
        } message: {
            Text("开始新会话会清空当前对话，并放弃未发送的消息和待确认的记账草稿。")
        }
        .photosPicker(isPresented: $showsPhotos, selection: $selectedPhotos,
                      maxSelectionCount: photoSelectionLimit,
                      selectionBehavior: .ordered, matching: .images)
        .onChange(of: selectedPhotos) { _, items in agent.loadPhotos(items) }
        .sheet(item: $imagePreview) { preview in
            AssistantPhotoPreview(images: preview.images, selection: preview.index)
        }
        .sheet(item: $selectedTool) { selection in
            AssistantToolDetail(source: agent, id: selection.id)
        }
        .sheet(isPresented: $showsModelSettings, onDismiss: agent.checkConfiguration) { LanguageModelSettingsSheet() }
        .sheet(item: $editing) { proposal in
            InvestmentAgentEditSheet(proposal: proposal, store: store) { actions in
                let live = try store.agentSnapshot()
                guard agent.proposal?.id == proposal.id, live.session == proposal.session, live.generation == proposal.generation else {
                    throw InvestmentAgentCommitError.stale
                }
                guard !agent.working, !agent.committing else { throw InvestmentError.invalid("助手正在处理，请稍后完成修改。") }
                try await agent.revise(actions)
                editing = nil
            }
        }
        .fileExporter(isPresented: $showsExporter, document: exportDocument, contentType: .zip,
                      defaultFilename: "投资记账-" + InvestmentBook.snapshotDateFormatter().string(from: InvestmentBook.day())) { result in
            exportDocument = nil
            if case .failure(let error) = result { agent.error = error.localizedDescription }
        }
    }

    private var thread: some View {
        ScrollViewReader { scroll in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if agent.messages.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            assistantLabel
                            Text("可以告诉我一笔交易、发来成交截图，或查询账本。写入前会请你核对。")
                                .font(.subheadline)
                            if !agent.configured {
                                Button("打开大模型配置") { showsModelSettings = true }
                                    .buttonStyle(HakoActionButtonStyle(primary: false))
                            }
                        }
                    }
                    ForEach(agent.messages) { item in messageRow(item).id(item.id) }
                    if let proposal = agent.proposal {
                        InvestmentAgentPreview(proposal: proposal, committing: agent.committing, busy: agent.working, stale: agent.stale,
                            edit: { editing = proposal }, discard: agent.discard,
                            confirm: { Task { await agent.commit(proposal.id) } }, regenerate: { Task { await regenerate(proposal) } })
                            .id(proposal.id)
                    }
                    if agent.canExport {
                        Button(exporting ? "正在准备账本…" : "导出账本") { Task { await exportLedger() } }
                            .buttonStyle(HakoActionButtonStyle(primary: false))
                            .disabled(exporting || agent.committing || agent.working)
                    }
                    if let error = agent.error { Text(error).font(.footnote).foregroundStyle(.red) }
                    if agent.canRetry {
                        Button("重试回复", action: agent.retryReply)
                            .buttonStyle(HakoActionButtonStyle(primary: false))
                            .disabled(agent.working || agent.committing)
                    }
                    if let issue = agent.storageIssue { Text(issue).font(.footnote).foregroundStyle(.red) }
                    if agent.working {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text(agent.progress).font(.footnote).foregroundStyle(.secondary)
                            Spacer()
                        }
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(15)
            }
            .scrollDismissesKeyboard(.interactively)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentSize.height - geometry.visibleRect.maxY <= 80
            } action: { _, nearBottom in scrollFollowing.observe(nearBottom: nearBottom) }
            .onScrollPhaseChange { _, phase in
                if phase == .tracking || phase == .interacting { scrollFollowing.interacting(true) }
                else if phase == .idle { scrollFollowing.interacting(false) }
            }
            .onChange(of: agent.streamContent.text) { _, _ in
                if agent.streamContent.hasContent, scrollFollowing.shouldFollowUpdates, selectedTool == nil {
                    scroll.scrollTo("end", anchor: .bottom)
                }
            }
            .onChange(of: agent.streamContent.thinking) { _, _ in
                if expandedThinking.contains(agent.streamContent.id), scrollFollowing.shouldFollowUpdates, selectedTool == nil {
                    scroll.scrollTo("end", anchor: .bottom)
                }
            }
            .onChange(of: agent.messages.last?.id, initial: true) { _, _ in
                if let reply = agent.messages.last {
                    if reply.isUser {
                        scrollFollowing = ConversationScrollFollowing()
                        scroll.scrollTo(reply.id, anchor: .bottom)
                    } else if scrollFollowing.shouldFollowUpdates, selectedTool == nil, !expandedThinking.contains(reply.id) {
                        if agent.toolCalls[reply.id] != nil { scroll.scrollTo("end", anchor: .bottom) }
                        else { scroll.scrollTo(reply.id, anchor: .top) }
                    }
                }
            }
            .onChange(of: agent.toolCalls) { _, _ in
                if scrollFollowing.shouldFollowUpdates, selectedTool == nil { scroll.scrollTo("end", anchor: .bottom) }
            }
            .onChange(of: agent.proposal?.id, initial: true) { _, id in
                if let id, scrollFollowing.shouldFollowUpdates, selectedTool == nil,
                   agent.messages.last.map({ expandedThinking.contains($0.id) }) != true {
                    scroll.scrollTo(id, anchor: .top)
                }
            }
        }
    }

    private var assistantLabel: some View {
        Label("记账助手", systemImage: "sparkles")
            .font(.caption.weight(.medium)).foregroundStyle(.secondary)
    }

    private func thinkingView(_ text: String, id: UUID) -> some View {
        AssistantThinkingView(text: text, expanded: Binding(get: { expandedThinking.contains(id) }, set: {
            if $0 { expandedThinking.insert(id) } else { expandedThinking.remove(id) }
        }))
    }

    @ViewBuilder
    private func messageRow(_ item: InvestmentAgentSession.Message) -> some View {
        if item.isUser {
            AssistantUserMessage(text: item.text, images: item.images) { images, index in
                imagePreview = AssistantImageSelection(images: images, index: index)
            }
        } else if let record = agent.toolCalls[item.id] {
            AssistantToolRow(record: record, resolved: agent.toolFollowUps[record.id] != nil) { selectedTool = ToolSelection(id: record.id) }.equatable()
        } else if !item.text.isEmpty || item.html != nil || agent.thinking[item.id]?.isEmpty == false {
            VStack(alignment: .leading, spacing: 7) {
                assistantLabel
                let streaming = agent.working && item.id == agent.streamContent.id
                let thought = streaming ? agent.streamContent.thinking : agent.thinking[item.id] ?? ""
                if !thought.isEmpty { thinkingView(thought, id: item.id) }
                if streaming {
                    if !agent.streamContent.text.isEmpty {
                        Text(verbatim: agent.streamContent.displayText).textSelection(.enabled)
                    }
                } else if let html = item.html {
                    AssistantReplyView(html: html)
                } else {
                    Text(verbatim: item.text).textSelection(.enabled)
                }
            }
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    shortcut("文字记账") { message = "帮我记一笔买入："; composing = true }
                    shortcut("成交截图") {
                        openPhotos()
                    }
                    .disabled(!canAddPhotos)
                    shortcut("查交易记录") { message = "查一下最近的交易记录。"; composing = true }
                }
            }
            .scrollIndicators(.hidden)
            if !attachments.isEmpty { photoAttachments }
            if loadingPhoto { ProgressView("正在读取图片…").font(.footnote) }
            if agent.proposal != nil {
                Text("有问题可以直接补充或提问，确认后才会写入。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            AssistantInputBar(text: $agent.composerDraft.text, prompt: agent.proposal == nil ? "描述这笔交易…" : "补充、更正或询问这笔交易…",
                              imageCount: attachments.count, maximumImages: InvestmentAgentConversation.maximumImageCount,
                              allowsPhotos: canAddPhotos, canSend: canSend, working: agent.working,
                              focus: $composing, onPhotos: openPhotos, onSend: send, onStop: agent.stop)
        }
        .padding(.horizontal, 16).padding(.vertical, 8).background(HakoStyle.background)
        .disabled(agent.committing)
    }

    private var photoAttachments: some View {
        AssistantAttachmentsView(attachments: $agent.composerDraft.attachments, loadingPhoto: loadingPhoto) { images, index in
            imagePreview = AssistantImageSelection(images: images, index: index)
        }
    }

    private var message: String {
        get { agent.composerDraft.text }
        nonmutating set { agent.composerDraft.text = newValue }
    }
    private var attachments: [AssistantComposerDraft.Attachment] {
        get { agent.composerDraft.attachments }
        nonmutating set { agent.composerDraft.attachments = newValue }
    }
    private var loadingPhoto: Bool { agent.loadingPhoto }

    private var canAddPhotos: Bool {
        !loadingPhoto && !agent.committing && attachments.count < InvestmentAgentConversation.maximumImageCount
    }

    private var canSend: Bool {
        !agent.working && !agent.committing && !loadingPhoto &&
            (!message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty)
    }

    private var hasUnsentMessage: Bool { !message.isEmpty || !attachments.isEmpty || loadingPhoto }

    private var canStartNewConversation: Bool {
        !agent.working && !agent.committing && !exporting &&
            (!agent.messages.isEmpty || agent.proposal != nil || agent.error != nil || agent.storageIssue != nil || hasUnsentMessage)
    }

    private func startNewConversation() {
        guard canStartNewConversation, agent.startNewConversation() else { return }
        message = ""
        attachments = []
        selectedPhotos = []
        composing = false
    }

    private func shortcut(_ title: String, action: @escaping () -> Void) -> some View {
        AssistantShortcutButton(title: title, action: action)
    }


    private func send() {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count <= 12_000 else { agent.error = "消息太长，请分段发送。"; return }
        if agent.send(text, images: attachments.map(\.data)) {
            message = ""
            attachments = []
            selectedPhotos = []
            composing = false
            agent.saveComposerDraft()
        }
    }

    private func openPhotos() {
        guard canAddPhotos else { return }
        photoSelectionLimit = InvestmentAgentConversation.maximumImageCount - attachments.count
        selectedPhotos = []
        showsPhotos = true
    }

    private func regenerate(_ proposal: InvestmentAgentProposal) async {
        do { try await agent.revise(proposal.actions) }
        catch is CancellationError { return }
        catch { agent.error = error.localizedDescription }
    }

    private func exportLedger() async {
        guard !exporting else { return }
        exporting = true
        defer { exporting = false }
        do {
            exportDocument = InvestmentExportDocument(data: try await agent.export())
            showsExporter = true
        } catch is CancellationError { return }
        catch { agent.error = error.localizedDescription }
    }
}

private struct InvestmentAgentPreview: View {
    let proposal: InvestmentAgentProposal
    let committing: Bool
    let busy: Bool
    let stale: Bool
    let edit: () -> Void
    let discard: () -> Void
    let confirm: () -> Void
    let regenerate: () -> Void
    @State private var page = 0
    private let pageSize = 8

    var body: some View {
        let preview = proposal.preview
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("记账预览").font(.caption).foregroundStyle(.secondary)
                    Text(preview.summary).font(.headline)
                }
                Spacer()
                Text(committing ? "正在写入" : stale ? "预览已过期" : "待确认")
                    .font(.caption)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .foregroundStyle(.primary)
                    .background(.orange.opacity(0.18), in: Capsule())
            }
            ForEach(preview.items.dropFirst(page * pageSize).prefix(pageSize)) { item in
                formItem(item)
            }
            if preview.items.count > pageSize {
                HStack {
                    Button("上一页") { page -= 1 }.disabled(page == 0)
                    Spacer()
                    Text("第 \(page + 1) 页").font(.caption)
                    Spacer()
                    Button("下一页") { page += 1 }.disabled((page + 1) * pageSize >= preview.items.count)
                }
                .font(.footnote)
            }
            if proposal.snapshotsOnly {
                Text("先补查缺失行情和汇率，再重算快照；仍缺少输入的日期会标记为不完整。确认后一起保存。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Divider()
            if proposal.editable {
                Button("修改", action: edit).font(.subheadline).disabled(stale)
            }
            if proposal.actions.contains(where: \.deletesData) {
                Text("确认后删除所列数据，删除不可撤销。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                Button("取消", action: discard)
                    .buttonStyle(HakoActionButtonStyle(primary: false))
                if stale {
                    Button("重新预览", action: regenerate).buttonStyle(HakoActionButtonStyle())
                } else if proposal.actions.contains(where: \.deletesData) {
                    HakoDeleteButton(title: proposal.actions.allSatisfy(\.deletesData) ? "确认删除" : "确认执行", action: confirm)
                } else {
                    Button("确认记账", action: confirm)
                        .buttonStyle(HakoActionButtonStyle())
                }
            }
        }
        .disabled(committing || busy)
        .padding(12)
        .background(HakoStyle.card, in: RoundedRectangle(cornerRadius: 14))
    }

    private func formItem(_ item: InvestmentAgentProposal.Preview.Item) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("\(item.operation.rawValue) · \(item.title)").font(.headline)
            ForEach(item.groups) { group in
                VStack(alignment: .leading, spacing: 12) {
                    if !group.title.isEmpty {
                        Text(group.title).font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                    }
                    ForEach(group.fields) { field in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(field.label).font(.subheadline).foregroundStyle(.secondary)
                            if item.operation == .edit, let before = field.before, before != field.after {
                                Text(before).strikethrough().foregroundStyle(.secondary)
                                Text(field.after ?? "—").monospacedDigit()
                            } else {
                                Text(field.after ?? field.before ?? "—").monospacedDigit()
                            }
                        }
                        .font(.body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                    }
                }
                Divider()
            }
        }
    }
}

extension InvestmentAgentSession: AssistantToolSource {}
