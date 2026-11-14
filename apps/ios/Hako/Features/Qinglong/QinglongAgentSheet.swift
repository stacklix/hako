import PhotosUI
import SwiftUI
import UIKit

@MainActor
struct QinglongAgentSheet: View {
    private struct ToolSelection: Identifiable { let id: UUID }



    @ObservedObject private var store: QinglongStore
    @ObservedObject private var agent: QinglongAgentSession
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedTool: ToolSelection?
    @State private var editing: QinglongAgentProposal?
    @State private var expandedThinking: Set<UUID> = []
    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var photoSelectionLimit = QinglongAgentSession.maximumImageCount
    @State private var imagePreview: AssistantImageSelection?
    @State private var showsPhotos = false
    @State private var showsModelSettings = false
    @State private var confirmsNewConversation = false
    @State private var scrollFollowing = ConversationScrollFollowing()
    @State private var scrollPosition = ScrollPosition(edge: .bottom)
    @FocusState private var composing: Bool

    private struct ThreadGeometry: Equatable {
        let contentHeight: CGFloat
        let visibleHeight: CGFloat
        let nearBottom: Bool
    }

    init(store: QinglongStore, agent: QinglongAgentSession) {
        self.store = store
        self.agent = agent
    }

    var body: some View {
        SettingsSheet(title: "青龙助手", isBusy: agent.committing) {
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
        .onChange(of: store.revision) { _, _ in
            selectedPhotos = []; expandedThinking = []; selectedTool = nil; editing = nil
            agent.restoreConversation()
            scrollFollowing = ConversationScrollFollowing()
            scrollPosition = ScrollPosition(edge: .bottom)
        }
        .alert("新建会话", isPresented: $confirmsNewConversation) {
            Button("取消", role: .cancel) {}
            Button("新建会话", role: .destructive, action: startNewConversation)
        } message: {
            Text("开始新会话会清空当前对话，并放弃未发送的消息和待确认的操作预览。")
        }
        .photosPicker(isPresented: $showsPhotos, selection: $selectedPhotos,
                      maxSelectionCount: photoSelectionLimit,
                      selectionBehavior: .ordered, matching: .images)
        .onChange(of: selectedPhotos) { _, items in agent.loadPhotos(items) }
        .sheet(item: $imagePreview) { preview in
            AssistantPhotoPreview(images: preview.images, selection: preview.index)
        }
        .sheet(item: $selectedTool) { selection in AssistantToolDetail(source: agent, id: selection.id) }
        .sheet(item: $editing) { proposal in QinglongAgentDraftEditor(agent: agent, proposal: proposal) }
        .sheet(isPresented: $showsModelSettings, onDismiss: agent.checkConfiguration) { LanguageModelSettingsSheet() }

    }

    private var thread: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if agent.messages.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        assistantLabel
                        Text("可以查询任务、分析脚本和日志，或描述想做的修改。操作前会请你核对。")
                            .font(.subheadline)
                        Text("查询结果与所选图片会发送至当前模型。环境变量值默认隐藏；文件和日志可能包含敏感内容，请按需读取。")
                            .font(.footnote).foregroundStyle(.secondary)
                        Text(store.connection.map { "当前面板：" + $0.name } ?? "请先在青龙设置中配置连接。")
                            .font(.footnote).foregroundStyle(.secondary)
                        if !agent.configured {
                            Button("打开大模型配置") { showsModelSettings = true }
                                .buttonStyle(HakoActionButtonStyle(primary: false))
                        }
                    }
                }
                ForEach(agent.messages) { item in messageRow(item).id(item.id) }
                if let error = agent.error { Text(error).font(.footnote).foregroundStyle(.red) }
                if agent.canRetry {
                    Button("重试回复", action: agent.retryReply).buttonStyle(HakoActionButtonStyle(primary: false))
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
                Color.clear.frame(height: 1)
            }
            .padding(15)
            .scrollTargetLayout()
        }
        .scrollPosition($scrollPosition)
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .scrollDismissesKeyboard(.interactively)
        .onAppear {
            scrollFollowing = ConversationScrollFollowing()
            scrollPosition = ScrollPosition(edge: .bottom)
        }
        .onScrollGeometryChange(for: ThreadGeometry.self) { geometry in
            ThreadGeometry(contentHeight: geometry.contentSize.height, visibleHeight: geometry.visibleRect.height,
                           nearBottom: geometry.contentSize.height - geometry.visibleRect.maxY <= 60)
        } action: { previous, current in
            scrollFollowing.observe(nearBottom: current.nearBottom)
            if previous.contentHeight != current.contentHeight || previous.visibleHeight != current.visibleHeight {
                followLatest()
            }
        }
        .onScrollPhaseChange { _, phase in
            if phase == .tracking || phase == .interacting { scrollFollowing.interacting(true) }
            else if phase == .idle { scrollFollowing.interacting(false) }
        }
        .onChange(of: agent.messages.last?.id) { _, _ in
            if agent.messages.last?.isUser == true { scrollFollowing = ConversationScrollFollowing() }
            followLatest()
        }
        .onChange(of: agent.working) { _, _ in followLatest() }
        .onChange(of: agent.committing) { _, _ in followLatest() }
        .onChange(of: agent.streamContent.text) { _, _ in followLatest() }
        .onChange(of: agent.streamContent.thinking) { _, _ in
            if expandedThinking.contains(agent.streamContent.id) { followLatest() }
        }
        .onChange(of: agent.toolCalls) { _, _ in followLatest() }
    }

    private func followLatest() {
        if scrollFollowing.shouldFollowUpdates, selectedTool == nil, editing == nil, imagePreview == nil,
           !expandedThinking.contains(agent.streamContent.id) { scrollPosition.scrollTo(edge: .bottom) }
    }

    private var assistantLabel: some View {
        Label("青龙助手", systemImage: "sparkles")
            .font(.caption.weight(.medium)).foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func messageRow(_ item: QinglongAgentSession.Message) -> some View {
        if item.isUser {
            AssistantUserMessage(text: item.text, images: item.images) { images, index in
                imagePreview = AssistantImageSelection(images: images, index: index)
            }
        } else if let record = agent.toolCalls[item.id] {
            AssistantToolRow(record: record, resolved: agent.toolFollowUps[record.id] != nil) { selectedTool = .init(id: record.id) }.equatable()
        } else if !item.text.isEmpty || item.html != nil || item.operation != nil || agent.thinking[item.id]?.isEmpty == false {
            VStack(alignment: .leading, spacing: 7) {
                assistantLabel
                let streaming = agent.working && item.id == agent.streamContent.id
                let thought = streaming ? agent.streamContent.thinking : agent.thinking[item.id] ?? ""
                if !thought.isEmpty { thinkingView(thought, id: item.id) }
                if streaming {
                    if !agent.streamContent.text.isEmpty { Text(verbatim: agent.streamContent.displayText).textSelection(.enabled) }
                } else if let html = item.html {
                    AssistantReplyView(html: html)
                } else if !item.text.isEmpty {
                    Text(verbatim: item.text).textSelection(.enabled)
                }
                if let operation = item.operation { proposalPreview(operation) }
            }
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    shortcut("任务状态") { message = "查一下当前任务状态。"; composing = true }
                    shortcut("截图分析") {
                        openPhotos()
                    }
                    .disabled(!canAddPhotos)
                    shortcut("排查失败") { message = "帮我查找最近执行失败的任务，并分析日志。"; composing = true }
                }
            }
            .scrollIndicators(.hidden)
            if !attachments.isEmpty { photoAttachments }
            if loadingPhoto { ProgressView("正在读取图片…").font(.footnote) }
            if agent.proposal != nil {
                Text("有问题可以继续补充或提问，确认后才会提交。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            AssistantInputBar(text: $agent.composerDraft.text, prompt: agent.proposal == nil ? "描述面板操作或问题…" : "补充、更正或询问这项操作…",
                              imageCount: attachments.count, maximumImages: QinglongAgentSession.maximumImageCount,
                              allowsPhotos: canAddPhotos, canSend: canSend, working: agent.working,
                              focus: $composing, onPhotos: openPhotos, onSend: send, onStop: agent.stop)
        }
        .padding(.horizontal, 16).padding(.vertical, 8).background(HakoStyle.background)
        .disabled(agent.committing)
    }

    private func proposalPreview(_ operation: QinglongAgentConversation.Operation) -> some View {
        let proposal = operation.proposal
        let pending = operation.state == .pending && agent.proposal?.id == proposal.id
        return VStack(alignment: .leading, spacing: 12) {
            Text("操作预览 · " + operation.state.title).font(.caption).foregroundStyle(.secondary)
            Text(proposal.title).font(.headline)
            Text(operation.panelName).font(.caption).foregroundStyle(.secondary)
            if let item = proposal.item {
                Text("资源 ID：" + item.id).font(.caption.monospaced()).textSelection(.enabled)
                Text("提交前状态：" + item.stateText).font(.caption).foregroundStyle(.secondary)
                if item.resource == .tasks, !proposal.action.editable {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("当前执行命令").font(.caption).foregroundStyle(.secondary)
                        Text(verbatim: item.raw["command"].text).font(.caption.monospaced()).textSelection(.enabled)
                        Text("当前 Cron：" + item.raw["schedule"].text).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            ForEach(previewKeys(proposal), id: \.self) { key in
                VStack(alignment: .leading, spacing: 5) {
                    Text(key == "enabled" && proposal.action.resource == .tasks ? "自动执行" : QinglongAgentAction.fieldTitle(key)).font(.caption).foregroundStyle(.secondary)
                    if let old = proposal.originalContent, key == "content" {
                        DisclosureGroup("原文件") {
                            Text(verbatim: old).font(.caption.monospaced()).textSelection(.enabled)
                        }
                    } else if let old = proposal.item?.raw[key].text, !old.isEmpty, old != proposal.editingFields[key] {
                        Text("原值：" + (key == "value" ? "[已隐藏]" : old)).font(.caption).foregroundStyle(.secondary)
                    }
                    if key == "value" {
                        SecureField("新变量值", text: .constant(proposal.editingFields[key] ?? "")).disabled(true)
                        DisclosureGroup("核对新变量值") {
                            Text(verbatim: proposal.editingFields[key] ?? "").font(.caption.monospaced()).textSelection(.enabled)
                        }
                    } else if key == "enabled" {
                        Text(proposal.editingEnabled ? "开启" : "关闭")
                    } else {
                        Text(verbatim: proposal.editingFields[key] ?? "")
                            .font(key == "content" || key == "command" ? .caption.monospaced() : .subheadline)
                            .textSelection(.enabled)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            if pending && proposal.action.kind == .delete {
                Text("确认后将删除此资源。").font(.footnote).foregroundStyle(.red)
            }
            if operation.state == .submitting { ProgressView("正在提交操作…").font(.footnote) }
            if let result = operation.result {
                Text(result).font(.footnote).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if pending {
                if proposal.action.editable {
                    Divider()
                    Button("修改") { editing = proposal }
                        .buttonStyle(.plain).font(.subheadline)
                        .disabled(agent.committing || agent.working || store.busy)
                }
                Text("确认时会重新检查远端内容。")
                    .font(.footnote).foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    Button("取消", action: agent.discard).buttonStyle(HakoActionButtonStyle(primary: false))
                    Button("确认" + proposal.action.verb, role: proposal.action.destructive ? .destructive : nil) {
                        Task { await agent.commit(proposal.id) }
                    }.buttonStyle(HakoActionButtonStyle(destructive: proposal.action.destructive))
                }.disabled(agent.committing || agent.working || store.busy)
            }
        }.padding(14).background(HakoStyle.card, in: RoundedRectangle(cornerRadius: 14))
    }

    private func previewKeys(_ proposal: QinglongAgentProposal) -> [String] {
        guard proposal.action.editable else { return [] }
        let order = ["name", "command", "url", "alias", "schedule", "value", "remarks", "branch", "whitelist", "blacklist", "filename", "directory", "content"]
        let keys = order.filter { proposal.editingFields[$0] != nil }
        return keys + ([QinglongResource.tasks, .envs].contains(proposal.action.resource) ? ["enabled"] : [])
    }
    private func thinkingView(_ text: String, id: UUID) -> some View {
        AssistantThinkingView(text: text, expanded: Binding(get: { expandedThinking.contains(id) }, set: {
            if $0 { expandedThinking.insert(id) } else { expandedThinking.remove(id) }
        }))
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

    private var photoAttachments: some View {
        AssistantAttachmentsView(attachments: $agent.composerDraft.attachments, loadingPhoto: loadingPhoto) { images, index in
            imagePreview = AssistantImageSelection(images: images, index: index)
        }
    }

    private var canAddPhotos: Bool {
        !loadingPhoto && !agent.committing && attachments.count < QinglongAgentSession.maximumImageCount
    }

    private var canSend: Bool {
        !agent.working && !store.busy && store.connection != nil && !loadingPhoto &&
            (!message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty)
    }

    private var hasUnsentMessage: Bool { !message.isEmpty || !attachments.isEmpty || loadingPhoto }

    private var canStartNewConversation: Bool {
        !agent.working && !agent.committing &&
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
        photoSelectionLimit = QinglongAgentSession.maximumImageCount - attachments.count
        selectedPhotos = []
        showsPhotos = true
    }

}


extension QinglongAgentSession: AssistantToolSource {}
