import SwiftUI
import UIKit
import PhotosUI
import ImageIO
import UniformTypeIdentifiers
import AVFoundation

struct WorkshopConversationView: View {
    @ObservedObject var conversation: WorkshopConversation
    private let onSwitch: (() -> Void)?
    private let sidechatParent: WorkshopConversation?
    private let showSidechatList: (() -> Void)?
    private let newSidechat: (() -> Void)?
    private let returnSidechat: ((String) -> Void)?
    private let sidechatOverlayPresented: Bool
    @StateObject private var sidechats: WorkshopSidechats
    @State private var showingSidechats = false
    @State private var resolvedSidechatParent: WorkshopConversation?
    @State private var standaloneSidechatTransfer: WorkshopSidechatTransfer?
    @State private var returnToParent: WorkshopConversation?
    @State private var openParentAfterTransfer = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.hakoPinPreview) private var pinPreview
    @Environment(\.hakoPinEnter) private var enterPinnedPage
    @State private var detail: WorkshopEntry?
    @State private var artifact: WorkshopArtifact?
    @State private var browserLink: WorkshopBrowserLink?
    @State private var showingInfo = false
    @State private var showingContextUsage = false
    @ScaledMetric(relativeTo: .caption) private var contextIconSize = 12
    @State private var showingFiles = false
    @State private var confirmsCompact = false
    @State private var showingCommandTask = false
    @StateObject private var commands: WorkshopCommands
    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var previewPhoto: WorkshopPhoto?
    @State private var loadingPhoto = false
    @State private var showingCamera = false
    @State private var cameraPermissionDenied = false
    @State private var capturedPhoto: Data?
    @StateObject private var pageCapture = WorkshopPageCapture()
    @State private var capturingPage = false
    @State private var scrollFollowing = ConversationScrollFollowing()
    @State private var scrollPosition = ScrollPosition(edge: .bottom)
    @State private var synchronizationOwner = UUID()

    init(conversation: WorkshopConversation, onSwitch: (() -> Void)? = nil,
         sidechatParent: WorkshopConversation? = nil, showSidechatList: (() -> Void)? = nil,
         newSidechat: (() -> Void)? = nil, returnSidechat: ((String) -> Void)? = nil, sidechatOverlayPresented: Bool = false) {
        self.conversation = conversation
        self.onSwitch = onSwitch
        self.sidechatParent = sidechatParent
        self.showSidechatList = showSidechatList
        self.newSidechat = newSidechat
        self.returnSidechat = returnSidechat
        self.sidechatOverlayPresented = sidechatOverlayPresented
        _sidechats = StateObject(wrappedValue: WorkshopSidechats(parent: conversation))
        _commands = StateObject(wrappedValue: WorkshopCommands(store: conversation.store, agent: conversation.agent, application: conversation.application))
    }

    private var transcriptVisible: Bool { detail == nil && artifact == nil && browserLink == nil && previewPhoto == nil && !showingCamera && !showingInfo && !showingFiles && !showingCommandTask && !showingSidechats && standaloneSidechatTransfer == nil && returnToParent == nil && !sidechatOverlayPresented }
    private var activeSidechatParent: WorkshopConversation? { sidechatParent ?? resolvedSidechatParent }

    var body: some View {
        let transcript = conversation.presentation
        let artifactsByEntry = transcript.artifactsByEntry
        let groups = transcript.groups.compactMap { group -> WorkshopEntryGroup? in
            var group = group
            group.entries.removeAll { $0.kind == "notice" && $0.id == conversation.operation?.unconfirmedNoticeID }
            return group.entries.isEmpty ? nil : group
        }
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                if conversation.historyCursor != nil {
                    Button("加载更早的消息") { Task { await conversation.loadHistory(more: true) } }
                        .font(.caption).disabled(conversation.loadingHistory)
                }
                if let cachedAt = conversation.cachedAt {
                    HStack(spacing: 4) {
                        Text(conversation.synchronizing ? "已显示缓存，正在更新 ·" : "显示缓存 ·")
                        Text(cachedAt, style: .relative)
                    }.font(.caption).foregroundStyle(HakoStyle.muted)
                }
                if transcript.isEmpty {
                    VStack(spacing: 10) {
                        Text(conversation.threadId == nil ? "想在 \(conversation.application.name) 中完成什么？" : "暂未加载会话消息")
                            .font(.subheadline).foregroundStyle(HakoStyle.muted)
                        if conversation.threadId != nil {
                            ProgressView().opacity(conversation.loadingHistory || conversation.restoringCache ? 1 : 0)
                                .accessibilityHidden(!conversation.loadingHistory && !conversation.restoringCache)
                        }
                    }.frame(maxWidth: .infinity).padding(.vertical, 40)
                }
                ForEach(groups) { group in
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(group.entries) { entry in
                            VStack(alignment: .leading, spacing: 12) {
                                entryView(entry)
                                if let questions = entry.questions, !questions.isEmpty {
                                    WorkshopAsyncQuestionView(entry: entry, questions: questions, conversation: conversation)
                                }
                                ForEach(artifactsByEntry[entry.id] ?? []) { file in
                                    WorkshopArtifactButton(file: file) { artifact = file }
                                }
                            }.id(entry.id)
                        }
                    }
                    .padding(.vertical, group.isRecords ? 3 : 0)
                    .background(group.isRecords ? HakoStyle.card : Color.clear, in: RoundedRectangle(cornerRadius: 10))
                }
                ForEach(conversation.approvals) { approval in
                    WorkshopApprovalView(approval: approval, conversation: conversation)
                }
                if let operation = conversation.operation, !operation.resultUnconfirmed,
                   !transcript.turnFooters.values.contains(where: { $0.id == operation.turnId }) {
                    WorkshopOperationStatus(operation: operation)
                }
                if let error = conversation.presentedError {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(error).font(.footnote).textSelection(.enabled)
                        Button(conversation.synchronizing ? "正在重新同步…" : "重新同步会话与任务状态") { Task { await conversation.checkResult() } }
                            .font(.footnote).disabled(conversation.busy || conversation.synchronizing)
                        if conversation.canRetry {
                            Button("重试原消息") { Task { await conversation.retryOriginal() } }
                                .font(.footnote).disabled(conversation.busy)
                        }
                    }
                    .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                    .background(HakoStyle.card, in: RoundedRectangle(cornerRadius: 12))
                }
                ForEach(transcript.queued) { entry in
                    followupView(entry).id(entry.id)
                }
            }
            .padding(20)
            .environment(\.openURL, OpenURLAction { url in
                if url.absoluteString == UIApplication.openSettingsURLString { return .systemAction }
                guard let link = WorkshopBrowserLink(url: url) else { return .discarded }
                browserLink = link
                return .handled
            })
        }
        .scrollPosition($scrollPosition)
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .onAppear {
            WorkshopRuntime.shared.enter(synchronizationOwner, conversation: conversation, preview: onSwitch != nil || pinPreview)
            scrollFollowing = ConversationScrollFollowing()
            updateReadingLatest(scenePhase == .active && transcriptVisible)
            // Keep an edge target through the initial lazy layout and later
            // streaming updates instead of resolving an unmeasured child ID.
            scrollPosition = ScrollPosition(edge: .bottom)
        }
        .onScrollGeometryChange(for: ConversationScrollFollowing.Layout.self) { geometry in
            ConversationScrollFollowing.Layout(contentHeight: geometry.contentSize.height,
                viewportHeight: geometry.visibleRect.height, visibleBottom: geometry.visibleRect.maxY)
        } action: { _, layout in
            if scrollFollowing.observe(layout) { alignLatestMessage() }
            updateReadingLatest(layout.nearBottom && scenePhase == .active && transcriptVisible)
        }
        .onDisappear {
            conversation.setReadingLatest(false)
            WorkshopRuntime.shared.leave(synchronizationOwner, conversation: conversation)
            Task { await conversation.store.flushComposerDrafts() }
        }
        .onChange(of: scenePhase) { _, phase in
            updateReadingLatest(phase == .active && scrollFollowing.followsBottom && transcriptVisible)
            if phase != .active { Task { await conversation.store.flushComposerDrafts() } }
        }
        .onChange(of: transcriptVisible) { _, visible in
            updateReadingLatest(visible && scenePhase == .active && scrollFollowing.followsBottom)
        }
        .onReceive(WorkshopRuntime.shared.visibilityChanges) { _ in
            updateReadingLatest(scenePhase == .active && transcriptVisible && scrollFollowing.followsBottom)
        }
        .onScrollPhaseChange { _, phase in
            if phase == .tracking || phase == .interacting { scrollFollowing.interacting(true) }
            else if phase == .idle { scrollFollowing.interacting(false) }
        }
        .onChange(of: conversation.presentation.revision) { _, _ in
            followRenderedMessages()
        }
        .onChange(of: conversation.appendedMessageID) { _, id in
            if let id {
                // Sending precedes the asynchronous renderer. Do not scroll the
                // old lazy layout while the keyboard and operation footer change.
                scrollFollowing.messageAppended(id)
                followRenderedMessages()
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .background(HakoStyle.background)
        .background(WorkshopKeyboardDismissal())
        .background(WorkshopPageCaptureHost(capture: pageCapture).frame(width: 0, height: 0))
        .navigationTitle(activeSidechatParent == nil ? conversation.title : "侧聊")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                projectInfo
                if let activeSidechatParent {
                    WorkshopSidechatParentStatus(parent: activeSidechatParent)
                        .padding(.horizontal, 20).padding(.vertical, 8).background(HakoStyle.card)
                }
                if commands.task?.active == true || commands.pendingCommand != nil {
                    Button { showingCommandTask = true } label: {
                        HStack {
                            Label(commands.task?.name ?? "快捷命令任务", systemImage: "terminal")
                            Spacer()
                            Text(commands.task?.status ?? "正在确认").foregroundStyle(.secondary)
                            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                        }.font(.caption).padding(.horizontal, 20).frame(minHeight: 44)
                    }.buttonStyle(.plain).background(HakoStyle.card)
                }
            }
            .overlay(alignment: .topLeading) {
                GeometryReader { header in
                    if showingContextUsage {
                        contextUsageDetails
                            .font(.caption).foregroundStyle(HakoStyle.muted)
                            .padding(.horizontal, 20).padding(.vertical, 12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(HakoStyle.background)
                            .overlay(alignment: .bottom) { Divider() }
                            .shadow(color: .black.opacity(0.08), radius: 8, y: 4)
                            .fixedSize(horizontal: false, vertical: true)
                            // Place the panel's top below the actual header,
                            // independently of its own height or alignment guides.
                            .offset(y: header.size.height)
                    }
                }
            }
            .zIndex(1)
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
                if conversation.isArchived {
                    VStack(alignment: .leading, spacing: 8) {
                        WorkshopSynchronizationHint(conversation: conversation)
                        HStack {
                            Label("此会话已归档", systemImage: "archivebox").font(.footnote).foregroundStyle(HakoStyle.muted)
                            Spacer()
                            Button("取消归档") { Task { await conversation.unarchive() } }.font(.subheadline)
                                .disabled(conversation.busy)
                        }.frame(minHeight: 44)
                    }.padding(.horizontal, 20).background(HakoStyle.background)
                } else {
                    WorkshopComposerView(conversation: conversation, input: conversation.composerInput,
                        selectedPhotos: $selectedPhotos, previewPhoto: $previewPhoto, loadingPhoto: loadingPhoto,
                        takePhoto: { Task { await openCamera() } })
                }
            }
        }
        .refreshable { await conversation.synchronize() }
        .toolbar {
            ToolbarItemGroup(placement: .topBarLeading) {
                if let showSidechatList {
                    Button(action: showSidechatList) { Image(systemName: "list.bullet") }.accessibilityLabel("侧聊历史")
                }
                if let enter = onSwitch ?? (pinPreview ? enterPinnedPage : nil) {
                    Button("进入", systemImage: "arrow.up.right", action: enter)
                        .accessibilityLabel("进入此会话")
                }
                if pageCapture.available && activeSidechatParent == nil {
                    Button { Task { await capturePage() } } label: {
                        if capturingPage { ProgressView() }
                        else { Image(systemName: "camera.viewfinder") }
                    }
                    .accessibilityLabel(capturingPage ? "正在截取背后页面" : "截取背后页面")
                    .accessibilityHint("将截图加入待发送图片，由你确认后发送")
                    .disabled(!conversation.canCompose || conversation.isArchived || conversation.editingMessageID != nil || loadingPhoto || conversation.photos.count >= 3)
                }
            }
            if activeSidechatParent != nil {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if let newSidechat {
                        Button(action: newSidechat) { Image(systemName: "plus") }.accessibilityLabel("新建侧聊")
                    }
                    Button { dismiss() } label: { Image(systemName: "xmark") }.accessibilityLabel("关闭侧聊")
                }
            } else if onSwitch != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("关闭会话预览")
                }
            } else if !pinPreview {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { showingSidechats = true } label: { Image(systemName: "bubble.left.and.bubble.right") }
                        .accessibilityLabel("侧聊")
                        .disabled(conversation.threadId == nil || conversation.isArchived || conversation.parentThreadId != nil)
                        .disabled(!conversation.store.authenticated || conversation.scope != conversation.store.scope)
                    Menu {
                        if let page = WorkshopPinContributor.page(for: conversation) { HakoPinButton(page: page) }
                        Button { showingInfo = true } label: { Label("设置", systemImage: "slider.horizontal.3") }
                        Button { showingFiles = true } label: { Label("项目文件", systemImage: "folder") }
                        if !commands.commands.isEmpty {
                            Section("快捷命令") {
                                ForEach(commands.commands) { command in
                                    Button {
                                        showingCommandTask = true
                                        Task { await commands.execute(command) }
                                    } label: { Label(command.name, systemImage: "terminal") }
                                    .disabled(commands.busy || commands.pendingCommand != nil && commands.pendingCommand?.id != command.id)
                                }
                            }
                        }
                        if !commands.prompts.isEmpty {
                            Section("快捷提示词") {
                                ForEach(commands.prompts) { prompt in
                                    Button {
                                        Task { await conversation.sendPrompt(prompt.text) }
                                    } label: { Label(prompt.name, systemImage: "text.bubble") }
                                    .disabled(!conversation.canSendPrompt)
                                }
                            }
                        }
                        Divider()
                        Button { confirmsCompact = true } label: {
                            Label("压缩上下文", systemImage: "arrow.down.right.and.arrow.up.left")
                        }.disabled(!conversation.canCompact)
                    } label: { Image(systemName: "ellipsis") }
                    .accessibilityLabel("更多会话功能")
                }
            }
        }
        .sheet(item: $detail) { entry in
            SettingsSheet(title: entry.recordTitle) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if entry.kind == "fileChange" {
                            WorkshopDiffView(text: entry.text)
                        } else {
                            Text(entry.text).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        }
                        if entry.truncated { Text("此项内容过长，手机中显示前 8,000 个字符。完整内容保留在电脑的 Codex 会话中。")
                            .font(.footnote).foregroundStyle(.secondary) }
                    }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .sheet(item: $artifact) { file in WorkshopPreviewView(store: conversation.store, agent: conversation.agent, artifact: file) }
        .sheet(item: $browserLink) { link in WorkshopBrowserView(link: link) }
        .sheet(item: $previewPhoto) { photo in WorkshopPhotoPreview(photo: photo, photos: conversation.photos) }
        .sheet(isPresented: $showingCamera, onDismiss: finishCamera) {
            WorkshopCameraPicker { image in
                capturedPhoto = image?.jpegData(compressionQuality: 0.9)
                showingCamera = false
            }.ignoresSafeArea()
        }
        .alert("需要相机权限", isPresented: $cameraPermissionDenied) {
            Button("取消", role: .cancel) { }
            Button("打开设置") {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
        } message: { Text("请在系统设置中允许 Hako 使用相机，以拍照添加图片。") }
        .sheet(isPresented: $showingInfo) { WorkshopConversationSettings(conversation: conversation, commands: commands) }
        .sheet(isPresented: $showingFiles) { WorkshopFilesView(store: conversation.store, agent: conversation.agent, application: conversation.application) }
        .sheet(isPresented: $showingSidechats) { WorkshopSidechatSheet(model: sidechats) }
        .sheet(item: $standaloneSidechatTransfer, onDismiss: {
            if openParentAfterTransfer { openParentAfterTransfer = false; returnToParent = activeSidechatParent }
        }) { transfer in
            if let activeSidechatParent {
                WorkshopSidechatReturnView(parent: activeSidechatParent, text: transfer.text) {
                    openParentAfterTransfer = true
                    standaloneSidechatTransfer = nil
                }
            }
        }
        .sheet(item: $returnToParent) { parent in NavigationStack { WorkshopConversationView(conversation: parent) } }
        .sheet(isPresented: $showingCommandTask) { SettingsSheet(title: "命令执行") { WorkshopCommandTaskView(client: commands) } }
        .alert("压缩上下文", isPresented: $confirmsCompact) {
            Button("取消", role: .cancel) { }
            Button("开始压缩") { Task { await conversation.compactContext() } }
        } message: { Text("将压缩当前会话的模型上下文，历史消息仍会保留。") }
        .task(id: commands.observationID) { await commands.observe() }
        .task(id: selectedPhotos) { await loadPhotos(selectedPhotos) }
        .task { if conversation.models.isEmpty || conversation.modelError != nil { await conversation.loadModels() } }
        .task(id: conversation.parentThreadId) {
            guard sidechatParent == nil, let parentID = conversation.parentThreadId else { return }
            do {
                resolvedSidechatParent = try await WorkshopRuntime.shared.pageConversation(computerID: conversation.agent.id,
                    threadID: parentID, title: "主会话")
            } catch is CancellationError { }
            catch { conversation.error = "暂时无法读取关联的主会话：" + error.localizedDescription }
        }
    }

    private func updateReadingLatest(_ visible: Bool) {
        conversation.setReadingLatest(visible && WorkshopRuntime.shared.isForegroundConversation(conversation.id))
    }

    private func followRenderedMessages() {
        let transcript = conversation.presentation
        if scrollFollowing.presentationUpdated(containsMessage: transcript.containsMessage) { alignLatestMessage() }
    }

    private func alignLatestMessage() {
        // Avoid overlapping scroll animations while lazy row heights settle or
        // the keyboard closes; geometry observation corrects the measured edge.
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) { scrollPosition.scrollTo(edge: .bottom) }
    }

    @ViewBuilder private func entryView(_ entry: WorkshopEntry) -> some View {
        if entry.kind == "followup" {
            followupView(entry)
        } else if entry.role == "user" {
            HStack {
                Spacer(minLength: 30)
                VStack(alignment: .trailing, spacing: 5) {
                    userMessage(entry).padding(14)
                        .background(HakoStyle.line, in: RoundedRectangle(cornerRadius: 16))
                    WorkshopMessageMetadata(entry: entry, running: false, showsElapsed: false)
                }
            }
        } else if entry.role == "assistant" {
            let completedTurn = conversation.presentation.turnFooters[entry.id]
            VStack(alignment: .leading, spacing: 10) {
                Label("Codex", systemImage: "terminal").font(.caption.weight(.medium))
                if entry.kind == "imageGeneration" {
                    WorkshopUserMessage(entry: entry, threadId: conversation.threadId, store: conversation.store, agent: conversation.agent)
                } else {
                    WorkshopMessageView(text: entry.text, parts: conversation.presentation.messageParts[entry.id] ?? [],
                        store: conversation.store).equatable()
                }
                if entry.truncated {
                    Button("查看内容说明") { detail = entry }.font(.caption)
                }
                HStack(spacing: 8) {
                    if let returnSidechat, completedTurn != nil {
                        Button { returnSidechat(entry.text) } label: { Label("发回主会话", systemImage: "arrow.up.right") }
                            .frame(minHeight: 44)
                    } else if activeSidechatParent != nil, completedTurn != nil {
                        Button { standaloneSidechatTransfer = .init(text: entry.text) } label: { Label("发回主会话", systemImage: "arrow.up.right") }
                            .frame(minHeight: 44)
                    } else if conversation.parentThreadId == nil, conversation.threadId != nil, completedTurn != nil {
                        Button {
                            sidechats.create(quote: entry.text)
                            showingSidechats = true
                        } label: {
                            Image(systemName: "bubble.left.and.bubble.right")
                                .frame(width: 44, height: 44)
                        }
                        .accessibilityLabel("引用这条回复进入侧聊")
                        .disabled(entry.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    Spacer(minLength: 0)
                    WorkshopMessageMetadata(entry: entry, running: false, showsElapsed: completedTurn != nil, completedTurn: completedTurn)
                }
                .font(.caption).foregroundStyle(HakoStyle.muted).buttonStyle(.plain)
            }
        } else if entry.kind == "notice" {
            Text(entry.text).font(.footnote).foregroundStyle(HakoStyle.muted).textSelection(.enabled)
        } else {
            Button { detail = entry } label: {
                HStack(spacing: 7) {
                    Image(systemName: entry.recordIcon).font(.caption).frame(width: 16)
                    Text(entry.recordSummary).lineLimit(1).truncationMode(.middle)
                        .font(.caption.monospaced()).foregroundStyle(HakoStyle.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.right").font(.caption2)
                }.padding(.horizontal, 10).frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
                    .contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("\(entry.recordTitle)：\(entry.recordSummary)，查看详情")
        }
    }

    private func followupView(_ entry: WorkshopEntry) -> some View {
        let status = conversation.followups.first { $0.id == entry.id }
        let pending = conversation.pendingSend(entry.id) != nil
        return HStack {
            Spacer(minLength: 30)
            VStack(alignment: .trailing, spacing: 4) {
                HStack(spacing: 4) {
                    Label(followupLabel(entry.state), systemImage: "text.line.first.and.arrowtriangle.forward")
                        .font(.caption).foregroundStyle(HakoStyle.muted)
                    if status?.editable == true || pending || status?.state == "unknown" {
                        Menu {
                            if status?.editable == true {
                                Button { conversation.editMessage(entry) } label: { Label("修改消息", systemImage: "pencil") }
                                Button { Task { await conversation.mutateMessage(entry.id, action: "steer") } } label: {
                                    Label(conversation.operation?.active == true ? "Steer instead" : "立即发送", systemImage: "arrow.turn.down.right")
                                }
                                .disabled(conversation.operation?.state == "starting" || conversation.operation?.state == "finishing")
                                Button(role: .destructive) { Task { await conversation.mutateMessage(entry.id, action: "cancel") } } label: {
                                    Label("取消消息", systemImage: "trash")
                                }
                            } else {
                                Button("检查消息结果") { Task { await conversation.checkResult() } }
                                if pending { Button("重试原消息") { Task { await conversation.retryQueued(entry.id) } } }
                            }
                        } label: {
                            Image(systemName: "ellipsis").font(.caption.weight(.medium))
                                .foregroundStyle(HakoStyle.muted).frame(width: 36, height: 44).contentShape(Rectangle())
                        }
                        .accessibilityLabel("排队消息操作").disabled(!conversation.canEditMessages)
                    }
                }
                userMessage(entry).padding(14)
                    .background(HakoStyle.card, in: RoundedRectangle(cornerRadius: 16))
                    .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(HakoStyle.line, lineWidth: 1) }
            }
        }
    }

    private func followupLabel(_ state: String) -> String {
        switch state {
        case "queued": "Queued"
        case "pending": "Queued · 确认中"
        case "paused": "Queued · 已暂停"
        case "steering": "Steer · 提交中"
        case "steered": "Steer · 已接收"
        case "unknown": "结果待确认"
        case "failed": "发送未完成"
        default: "已发送"
        }
    }

    private func userMessage(_ entry: WorkshopEntry) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            WorkshopUserMessage(entry: entry, threadId: conversation.threadId, store: conversation.store, agent: conversation.agent,
                imageIDs: conversation.followups.first(where: { $0.id == entry.id })?.imageIds ?? [],
                replies: conversation.presentation.questionReplies[entry.id] ?? [])
            if let delivery = conversation.outbox.states[entry.id] {
                WorkshopMessageDeliveryView(state: delivery, canRetry: conversation.canRetryDelivery(entry.id),
                    retry: { Task { await conversation.retryDelivery(entry.id) } },
                    cancel: { conversation.cancelUpload(entry.id) },
                    check: { Task { await conversation.checkResult() } })
            }
        }
    }

    private var projectInfo: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                WorkshopProjectConnectionLabel(store: conversation.store, name: conversation.application.name,
                    agentID: conversation.agent.id, scope: conversation.scope,
                    verified: conversation.connectionVerified,
                    needsRecovery: conversation.needsConnectionRecovery)
                Spacer(minLength: 8)
                HStack(spacing: 8) {
                    if let model = conversation.generation.model, !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(conversation.generationLabel).lineLimit(2).multilineTextAlignment(.trailing)
                            .accessibilityLabel("Model: \(conversation.modelLabel), Speed: \(conversation.speedLabel), Reasoning: \(conversation.generation.effortLabel)")
                    }
                    Button {
                        showingContextUsage.toggle()
                        if showingContextUsage { Task { await conversation.refreshContextUsage() } }
                    } label: {
                        contextUsageRing.frame(width: 44, height: 44, alignment: .trailing)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).padding(.leading, contextIconSize - 44)
                    .accessibilityLabel(conversation.contextUsage?.remainingPercentText.map { "上下文剩余 \($0)" } ?? "上下文暂无统计")
                    .accessibilityValue(showingContextUsage ? "已展开" : "已收起")
                    .accessibilityHint(showingContextUsage ? "收起上下文详情" : "展开上下文详情")
                }
                .layoutPriority(1)
            }
            .padding(.horizontal, 20)
        }
        .font(.caption).foregroundStyle(HakoStyle.muted)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(HakoStyle.background)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var contextUsageRing: some View {
        let usage = conversation.contextUsage
        let remaining = usage?.remainingFraction ?? 0
        return Circle().strokeBorder(HakoStyle.muted.opacity(0.25), lineWidth: 1.5)
            .overlay {
                Circle().inset(by: 0.75).trim(from: 0, to: remaining)
                    .stroke((usage?.usedFraction ?? 0) >= 0.85 ? Color.orange : HakoStyle.muted, lineWidth: 1.5)
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: contextIconSize, height: contextIconSize)
            .accessibilityHidden(true)
    }

    private var contextUsageDetails: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let usage = conversation.contextUsage, let usedText = usage.usedText, let fraction = usage.usedFraction {
                HStack {
                    Text(usedText)
                    Spacer(minLength: 8)
                    Text(usage.usedPercentText ?? "")
                }
                .foregroundStyle(.primary)
                GeometryReader { geometry in
                    Capsule().fill(HakoStyle.muted.opacity(0.2))
                        .overlay(alignment: .leading) {
                            Capsule().fill(HakoStyle.muted).frame(width: geometry.size.width * min(1, max(0, fraction)))
                        }
                }
                .frame(height: 3).accessibilityHidden(true)
                HStack {
                    Text(usage.remainingText ?? "")
                    Spacer(minLength: 8)
                    if conversation.refreshingContextUsage {
                        Text("正在更新…")
                    } else {
                        Text("最近统计 \(usage.date.formatted(date: .omitted, time: .shortened))")
                    }
                }
                .font(.caption2)
            } else if conversation.refreshingContextUsage {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.mini)
                    Text("正在读取上下文统计…")
                }
            } else {
                Text("尚未收到上下文统计")
            }
            if let error = conversation.contextUsageError {
                Text(error).font(.caption2).foregroundStyle(.orange)
            }
        }
        .monospacedDigit()
    }

    private func capturePage() async {
        guard pageCapture.available, conversation.canCompose, conversation.editingMessageID == nil,
              !loadingPhoto, conversation.photos.count < 3 else { return }
        loadingPhoto = true; capturingPage = true
        defer { loadingPhoto = false; capturingPage = false }
        do {
            let data = try pageCapture.capture()
            let encoded = await Task.detached(priority: .userInitiated) { Self.encodePhoto(data) }.value
            try Task.checkCancellation()
            guard let encoded else { throw HakoError(message: "截图处理失败，未添加图片，请重试。") }
            try conversation.attach(encoded)
        } catch is CancellationError { }
        catch { conversation.error = error.localizedDescription }
    }

    private func openCamera() async {
        guard conversation.canCompose, conversation.editingMessageID == nil,
              !loadingPhoto, conversation.photos.count < 3 else { return }
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            conversation.error = "当前设备无法使用相机，请从相册选择图片。"; return
        }
        let allowed = await AVCaptureDevice.requestAccess(for: .video)
        guard allowed else { cameraPermissionDenied = true; return }
        guard conversation.canCompose, conversation.editingMessageID == nil,
              !loadingPhoto, conversation.photos.count < 3 else { return }
        capturedPhoto = nil; showingCamera = true
    }

    private func finishCamera() {
        guard let data = capturedPhoto else { return }
        capturedPhoto = nil; loadingPhoto = true
        Task {
            defer { loadingPhoto = false }
            let encoded = await Task.detached(priority: .userInitiated) { Self.encodePhoto(data) }.value
            do {
                guard let encoded else { throw HakoError(message: "拍摄的图片处理失败，请重新拍照。") }
                try conversation.attach(encoded)
            } catch { conversation.error = error.localizedDescription }
        }
    }

    private func loadPhotos(_ items: [PhotosPickerItem]) async {
        guard !items.isEmpty else { return }
        loadingPhoto = true
        defer { if selectedPhotos == items { loadingPhoto = false; selectedPhotos = [] } }
        var failures: [String] = []
        for (index, item) in items.enumerated() {
            do {
                try Task.checkCancellation()
                guard let data = try await item.loadTransferable(type: Data.self) else { throw HakoError(message: "无法读取图片。") }
                let encoded = await Task.detached(priority: .userInitiated) { Self.encodePhoto(data) }.value
                try Task.checkCancellation()
                guard let encoded else { throw HakoError(message: "图片处理失败，请选择其他图片。") }
                try conversation.attach(encoded)
            } catch is CancellationError { return }
            catch { failures.append("第 \(index + 1) 张：\(error.localizedDescription)") }
        }
        if !failures.isEmpty { conversation.error = failures.joined(separator: "\n") }
    }

    nonisolated private static func encodePhoto(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                       kCGImageSourceThumbnailMaxPixelSize: 2048] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        for quality in [0.86, 0.68, 0.5] {
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
            if CGImageDestinationFinalize(destination), data.length <= 2_000_000 { return data as Data }
        }
        return nil
    }

}

private struct WorkshopMessageMetadata: View {
    let entry: WorkshopEntry
    let running: Bool
    var showsElapsed = true
    var completedTurn: WorkshopTurn? = nil
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if showsElapsed && running && scenePhase == .active {
                // Only this message's footer ticks; the transcript and Markdown stay unchanged.
                TimelineView(.periodic(from: .now, by: 1)) { context in metadata(at: context.date) }
            } else { metadata(at: .now) }
        }
        .font(.caption).foregroundStyle(HakoStyle.muted).monospacedDigit()
    }

    private func metadata(at now: Date) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                timestamp
                if let elapsed = showsElapsed ? completedTurn?.elapsedText : nil {
                    if entry.messageDate != nil { Text("·").accessibilityHidden(true) }
                    Text((running ? "已耗时 " : "耗时 ") + elapsed)
                }
            }.fixedSize(horizontal: true, vertical: false)
            VStack(alignment: .trailing, spacing: 3) {
                timestamp
                if let elapsed = showsElapsed ? completedTurn?.elapsedText : nil {
                    Text((running ? "已耗时 " : "耗时 ") + elapsed)
                }
            }
        }
    }

    @ViewBuilder private var timestamp: some View {
        if let date = completedTurn?.completedAt.flatMap({ (1...253_402_300_799).contains($0) ? Date(timeIntervalSince1970: Double($0)) : nil }) ?? entry.messageDate {
            if Calendar.current.isDateInToday(date) {
                Text(date, format: .dateTime.hour().minute().second())
                    .accessibilityLabel(date.formatted(date: .complete, time: .complete))
            } else {
                Text(date, format: .dateTime.year().month(.twoDigits).day(.twoDigits).hour().minute().second())
            }
        }
    }
}

private struct WorkshopOperationStatus: View {
    let operation: WorkshopOperation
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if operation.active && operation.startedAt > 0 && scenePhase == .active {
                // Keep the per-second update local to this footer, not the transcript.
                TimelineView(.periodic(from: .now, by: 1)) { context in label(at: context.date) }
            } else { label(at: .now) }
        }
        .font(.footnote).foregroundStyle(operation.state == "failed" ? Color.orange : HakoStyle.muted)
    }

    private func label(at date: Date) -> some View {
        Label {
            if let elapsed = operation.elapsedText(at: date) {
                Text(operation.statusLabel + " · " + (operation.active ? "已处理 " : "用时 ") + elapsed)
                    .monospacedDigit()
            } else { Text(operation.statusLabel) }
        } icon: { Image(systemName: operation.statusIcon) }
    }
}

private struct WorkshopProjectConnectionLabel: View {
    @ObservedObject var store: WorkshopStore
    let name: String
    let agentID: String
    let scope: String
    let verified: Bool
    let needsRecovery: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var state: WorkshopConnectionState {
        guard store.authenticated, scope == store.scope else { return .disconnected }
        return (store.connections[agentID] ?? .disconnected)
            .forConversation(verified: verified, needsRecovery: needsRecovery)
    }

    private var connectedColor: Color { HakoStyle.adaptive(0x16803c, 0x6edb91) }
    private var statusColor: Color {
        switch state {
        case .connected: connectedColor
        case .reconnecting: HakoStyle.adaptive(0xa87900, 0xf5cf58)
        default: HakoStyle.muted
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            // Symbol effects animate drawing only. A phase animation on the
            // whole label also animates its initial safe-area layout on entry.
            Image(systemName: state == .connected ? "folder.fill" : "folder")
                .symbolEffect(.pulse, options: .repeating,
                    isActive: (state == .connecting || state == .reconnecting) && !reduceMotion)
                .accessibilityHidden(true)
            Text(name)
        }
        .foregroundStyle(statusColor)
        .accessibilityElement(children: .combine)
        .accessibilityValue(state.conversationAccessibilityDescription)
    }
}

// Connection issues and unconfirmed outcomes share the composer's status area.
private struct WorkshopSynchronizationHint: View {
    @ObservedObject var conversation: WorkshopConversation

    var body: some View {
        if let hint = conversation.synchronizationHint, conversation.presentedError == nil {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Label(hint, systemImage: "arrow.triangle.2.circlepath")
                        .foregroundStyle(HakoStyle.muted)
                        .accessibilityHint(conversation.connectionIssue ?? conversation.operation?.message ?? "重新同步以核对本轮执行结果，此消息不会自动重发。")
                    Spacer(minLength: 0)
                    Button(conversation.synchronizing ? "同步中…" : "重新同步") {
                        Task { await conversation.checkResult() }
                    }
                    .foregroundStyle(HakoStyle.link)
                    .disabled(conversation.busy || conversation.synchronizing)
                    .accessibilityLabel("重新同步会话与任务状态")
                }
                if conversation.canRetry {
                    Button("重试原消息") { Task { await conversation.retryOriginal() } }
                        .foregroundStyle(HakoStyle.link)
                        .disabled(conversation.busy)
                }
            }
            .font(.caption)
            .buttonStyle(.plain)
        }
    }
}

// Observe only the editor's text here; keystrokes must not invalidate the transcript.
private struct WorkshopComposerView: View {
    @ObservedObject var conversation: WorkshopConversation
    @ObservedObject var input: WorkshopComposerInput
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var selectedPhotos: [PhotosPickerItem]
    @Binding var previewPhoto: WorkshopPhoto?
    let loadingPhoto: Bool
    let takePhoto: () -> Void
    @State private var showingPhotoLibrary = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if conversation.editingMessageID != nil {
                HStack {
                    Text("修改排队消息").font(.caption).foregroundStyle(HakoStyle.muted)
                    Spacer()
                    Button { conversation.cancelEditing() } label: { Image(systemName: "xmark").frame(width: 44, height: 44) }
                        .accessibilityLabel("取消修改消息").disabled(conversation.busy)
                }
            }
            if !conversation.photos.isEmpty { WorkshopComposerAttachments(conversation: conversation, previewPhoto: $previewPhoto) }
            if loadingPhoto { Text("正在处理图片…").font(.caption).foregroundStyle(HakoStyle.muted) }
            WorkshopSynchronizationHint(conversation: conversation)
            if conversation.canCompose && conversation.awaitingSubmissionCheck && conversation.synchronizationHint == nil {
                Text(conversation.restoringCache || conversation.synchronizing ? "正在获取最新消息与任务状态，可先输入" : "任务状态待确认，可先输入，确认后可发送")
                    .font(.caption).foregroundStyle(HakoStyle.muted)
            }
            HStack(alignment: .bottom, spacing: 2) {
                Menu {
                    Button(action: takePhoto) { Label("拍照", systemImage: "camera") }
                    Button { showingPhotoLibrary = true } label: { Label("从相册选择", systemImage: "photo.on.rectangle") }
                } label: {
                    Image(systemName: "plus").font(.system(size: 22, weight: .bold))
                        .foregroundStyle(HakoStyle.text).frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .photosPicker(isPresented: $showingPhotoLibrary, selection: $selectedPhotos,
                    maxSelectionCount: max(1, 3 - conversation.photos.count), selectionBehavior: .ordered, matching: .images)
                .accessibilityLabel("添加图片，最多还可选择 \(max(0, 3 - conversation.photos.count)) 张")
                .disabled(!conversation.canCompose || conversation.editingMessageID != nil || loadingPhoto || conversation.photos.count >= 3)
                ZStack(alignment: .topLeading) {
                    if input.text.isEmpty {
                        Text("描述你的想法…").font(.body).foregroundStyle(Color(uiColor: .placeholderText))
                            .padding(.vertical, 11).allowsHitTesting(false).accessibilityHidden(true)
                    }
                    WorkshopComposerTextEditor(input: input, snapshot: input.snapshot)
                        .disabled(!conversation.canCompose)
                }.frame(maxWidth: .infinity, alignment: .leading)
                if conversation.awaitingSubmissionCheck {
                    Button {} label: {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 18, weight: .semibold))
                            .symbolEffect(.rotate, options: .repeating, isActive: !reduceMotion)
                    }
                    .buttonStyle(WorkshopSendButtonStyle())
                    .accessibilityLabel(conversation.restoringCache || conversation.synchronizing ? "正在同步会话，等待发送" : "正在确认任务状态，等待发送")
                    .disabled(true)
                } else if conversation.operation?.active == true && !conversation.hasDraftInput && conversation.editingMessageID == nil {
                    Button { Task { await conversation.stop() } } label: {
                        Image(systemName: "square.fill").font(.system(size: 13, weight: .semibold))
                    }
                    .buttonStyle(WorkshopSendButtonStyle()).accessibilityLabel("停止生成").disabled(conversation.busy)
                } else {
                    Button { Task { await conversation.send() } } label: {
                        Image(systemName: conversation.editingMessageID == nil ? "arrow.up" : "checkmark").font(.system(size: 18, weight: .semibold))
                    }
                    .buttonStyle(WorkshopSendButtonStyle()).accessibilityLabel(conversation.editingMessageID == nil ? "发送消息" : "保存修改")
                    .disabled(!(conversation.editingMessageID == nil ? conversation.canSubmitMessage : conversation.canEditMessages)
                              || loadingPhoto || !conversation.hasDraftInput)
                }
            }
            .padding(4)
            .background(HakoStyle.card, in: RoundedRectangle(cornerRadius: 27))
            .overlay { RoundedRectangle(cornerRadius: 27).strokeBorder(HakoStyle.line, lineWidth: 1).allowsHitTesting(false) }
        }
        .padding(.horizontal, 16).padding(.vertical, 8).background(HakoStyle.background)
    }


}

// Keep one native editor and explicitly apply acknowledged resets to its buffer.
// SwiftUI's multiline TextField can restore its old editing value when disabled
// during submission, including after replacing the field's view identity.
private struct WorkshopComposerTextEditor: UIViewRepresentable {
    let input: WorkshopComposerInput
    // A reference alone is unchanged when text resets. Keep the rendered
    // value in the representable so attachment/layout changes cannot hide it.
    let snapshot: WorkshopComposerText
    @Environment(\.isEnabled) private var enabled

    func makeCoordinator() -> Coordinator { Coordinator(input) }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.delegate = context.coordinator
        view.backgroundColor = .clear
        view.textColor = .label
        view.adjustsFontForContentSizeCategory = true
        view.font = .preferredFont(forTextStyle: .body)
        view.textContainer.lineFragmentPadding = 0
        view.textContainerInset = UIEdgeInsets(top: 11, left: 0, bottom: 11, right: 0)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.accessibilityLabel = "发给 Codex 的消息"
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        guard snapshot == input.snapshot else { return }
        let coordinator = context.coordinator
        coordinator.applying = true
        view.delegate = nil
        defer { view.delegate = coordinator; coordinator.applying = false }
        let reset = coordinator.editorID != snapshot.editorID
        coordinator.input = input
        coordinator.editorID = snapshot.editorID
        if reset || view.text != snapshot.text {
            view.unmarkText()
            view.text = snapshot.text
            if reset {
                view.undoManager?.removeAllActions()
                view.selectedRange = NSRange(location: 0, length: 0)
                view.setContentOffset(.zero, animated: false)
            }
            view.invalidateIntrinsicContentSize()
        }
        if reset {
            HakoLog.record(.codeWorkshop, "输入框已应用发送后重置",
                detail: "editorId=\(snapshot.editorID); textLength=\(view.text?.utf16.count ?? 0)")
        }
        view.isEditable = enabled
        if !enabled, view.isFirstResponder { view.resignFirstResponder() }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }
        let line = uiView.font?.lineHeight ?? 22
        let insets = uiView.textContainerInset.top + uiView.textContainerInset.bottom
        let size = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: min(max(ceil(size.height), line + insets), line * 5 + insets))
    }

    static func dismantleUIView(_ view: UITextView, coordinator: Coordinator) { view.delegate = nil }

    final class Coordinator: NSObject, UITextViewDelegate {
        var input: WorkshopComposerInput
        var editorID: UUID
        var applying = false

        init(_ input: WorkshopComposerInput) { self.input = input; editorID = input.editorID }

        func textViewDidChange(_ view: UITextView) {
            guard !applying, view.isEditable, view.isFirstResponder else { return }
            input.updateText(view.text ?? "", editorID: editorID)
            view.invalidateIntrinsicContentSize()
        }
    }
}

private struct WorkshopComposerAttachments: View {
    @ObservedObject var conversation: WorkshopConversation
    @Binding var previewPhoto: WorkshopPhoto?

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 12) {
                ForEach(conversation.photos) { photo in
                    if let image = UIImage(data: photo.data) {
                        Button { previewPhoto = photo } label: {
                            Image(uiImage: image).resizable().scaledToFill().frame(width: 76, height: 76).clipped()
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                            .buttonStyle(.plain).accessibilityLabel("预览待发送图片")
                            .overlay(alignment: .topTrailing) {
                                Button { conversation.removePhoto(photo.id) } label: {
                                    Image(systemName: "xmark.circle.fill").symbolRenderingMode(.palette)
                                        .foregroundStyle(.white, .black.opacity(0.65)).frame(width: 32, height: 32)
                                }.accessibilityLabel("移除图片").disabled(!conversation.canCompose)
                            }
                    }
                }
            }
        }.scrollIndicators(.hidden)
    }

}

// Observe taps without consuming button actions or disturbing editing gestures.
private struct WorkshopKeyboardDismissal: UIViewRepresentable {
    func makeUIView(context: Context) -> DismissalView { DismissalView() }
    func updateUIView(_ view: DismissalView, context: Context) { }
    static func dismantleUIView(_ view: DismissalView, coordinator: ()) { view.detach() }

    final class DismissalView: UIView, UIGestureRecognizerDelegate {
        private var tap: UITapGestureRecognizer?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            detach()
            isUserInteractionEnabled = false
            guard let window else { return }
            let tap = UITapGestureRecognizer(target: self, action: #selector(dismissKeyboard))
            tap.cancelsTouchesInView = false
            tap.delaysTouchesBegan = false
            tap.delaysTouchesEnded = false
            tap.delegate = self
            window.addGestureRecognizer(tap)
            self.tap = tap
        }

        func detach() {
            if let tap { tap.view?.removeGestureRecognizer(tap) }
            tap = nil
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            // The window also hosts selection handles and system edit menus outside this transcript.
            guard bounds.contains(touch.location(in: self)) else { return false }
            var view = touch.view
            while let current = view {
                if let field = current as? UITextField, field.isEnabled { return false }
                if let editor = current as? UITextView, editor.isSelectable { return false }
                view = current.superview
            }
            return window.flatMap(editingView(in:)) != nil
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }

        private func editingView(in view: UIView) -> UIView? {
            if view.isFirstResponder {
                if let editor = view as? UITextView, editor.isEditable { return editor }
                if let field = view as? UITextField, field.isEnabled { return field }
                return nil
            }
            for child in view.subviews {
                if let editor = editingView(in: child) { return editor }
            }
            return nil
        }

        @objc private func dismissKeyboard() {
            // Dismiss only the input control, never a message's active text selection.
            _ = window.flatMap(editingView(in:))?.resignFirstResponder()
        }
    }
}

private struct WorkshopArtifactButton: View {
    let file: WorkshopArtifact
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 12) {
                Image(systemName: "rectangle.and.hand.point.up.left")
                VStack(alignment: .leading, spacing: 5) {
                    Text(file.name).font(.subheadline.weight(.medium))
                    Text("交互原型 · 点击预览").font(.caption).foregroundStyle(HakoStyle.muted)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption)
            }.padding(15).frame(maxWidth: .infinity, alignment: .leading)
                .background(HakoStyle.card, in: RoundedRectangle(cornerRadius: 14))
        }.buttonStyle(.plain)
    }
}

private struct WorkshopSendButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.frame(width: 36, height: 36)
            .foregroundStyle(enabled ? HakoStyle.background : HakoStyle.muted)
            .background(enabled ? HakoStyle.text : HakoStyle.line, in: Circle())
            .padding(4).contentShape(Circle()).opacity(configuration.isPressed ? 0.6 : 1)
    }
}

private struct WorkshopApprovalView: View {
    let approval: WorkshopApproval
    @ObservedObject var conversation: WorkshopConversation
    @State private var answers: [String: String] = [:]
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(approval.kind == "question" ? "需要补充信息" : "需要你确认", systemImage: "checkmark.shield")
                .font(.subheadline.weight(.medium))
            Text(approval.detail).font(.caption.monospaced()).textSelection(.enabled)
            if approval.kind == "question" {
                ForEach(approval.questions) { question in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(question.question).font(.subheadline).foregroundStyle(.secondary)
                        ForEach(question.options, id: \.self) { option in
                            Button { answers[question.id] = option } label: {
                                HStack { Text(option); Spacer(); if answers[question.id] == option { Image(systemName: "checkmark") } }
                            }.font(.caption).frame(minHeight: 44)
                        }
                        TextField("填写回答", text: Binding(get: { answers[question.id] ?? "" }, set: { answers[question.id] = $0 }))
                            .accessibilityLabel(question.question)
                    }
                }
                Button("提交回答") { Task { await conversation.reply(approval, answers: answers) } }
                    .buttonStyle(HakoActionButtonStyle())
                    .disabled(approval.questions.contains { answers[$0.id]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false })
            } else {
                HStack(spacing: 12) {
                    Button("拒绝") { Task { await conversation.reply(approval, decision: "decline") } }.buttonStyle(HakoActionButtonStyle(primary: false))
                    Button("允许一次") { Task { await conversation.reply(approval, decision: "accept") } }.buttonStyle(HakoActionButtonStyle())
                }
            }
        }
        .padding(15).background(HakoStyle.card, in: RoundedRectangle(cornerRadius: 14)).disabled(conversation.busy)
    }
}

private struct WorkshopAsyncQuestionView: View {
    let entry: WorkshopEntry
    let questions: [WorkshopAsyncQuestion]
    @ObservedObject var conversation: WorkshopConversation
    @State private var answers: [Int: String] = [:]
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(conversation.hasAnswered(entry) ? "回答已提交，可在消息中查看状态" : "需要你回答", systemImage: "bubble.left.and.text.bubble.right")
                .font(.subheadline.weight(.medium))
            if !conversation.hasAnswered(entry) {
                ForEach(Array(questions.enumerated()), id: \.offset) { index, question in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(question.title).font(.subheadline).foregroundStyle(.secondary)
                        ForEach(Array(question.options.enumerated()), id: \.offset) { _, option in
                            Button { answers[index] = option } label: {
                                HStack { Text(option); Spacer(); if answers[index] == option { Image(systemName: "checkmark") } }
                                    .frame(maxWidth: .infinity, alignment: .leading).frame(minHeight: 44)
                            }.buttonStyle(.plain)
                        }
                        Text("你的回答").font(.subheadline).foregroundStyle(.secondary)
                        TextField("选择选项或填写回答", text: Binding(get: { answers[index] ?? "" }, set: { answers[index] = $0 }), axis: .vertical)
                            .accessibilityLabel(question.title).textFieldStyle(.roundedBorder)
                    }
                }
                Button("提交回答") { Task { await conversation.replyToQuestion(entry, answers: answers) } }
                    .buttonStyle(HakoActionButtonStyle())
                    .disabled(!conversation.canEditMessages || WorkshopAsyncQuestion.replyMessage(questions, answers: answers) == nil)
                Text("回答会发送到此会话，正在执行的任务会收到补充信息。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.padding(15).background(HakoStyle.card, in: RoundedRectangle(cornerRadius: 14))
    }
}
