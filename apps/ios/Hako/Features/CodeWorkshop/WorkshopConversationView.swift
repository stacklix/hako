import SwiftUI
import UIKit
import PhotosUI
import ImageIO
import UniformTypeIdentifiers

struct WorkshopConversationView: View {
    @ObservedObject var conversation: WorkshopConversation
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var detail: WorkshopEntry?
    @State private var artifact: WorkshopArtifact?
    @State private var showingInfo = false
    @State private var showingCommands = false
    @State private var showingCommandTask = false
    @StateObject private var commands: WorkshopCommands
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var previewPhoto: WorkshopPhoto?
    @State private var loadingPhoto = false
    @State private var scrollFollowing = WorkshopScrollFollowing()
    @State private var scrollPosition = ScrollPosition(edge: .bottom)
    @State private var synchronizationOwner = UUID()

    init(conversation: WorkshopConversation) {
        self.conversation = conversation
        _commands = StateObject(wrappedValue: WorkshopCommands(store: conversation.store, agent: conversation.agent, application: conversation.application))
    }

    private var transcriptVisible: Bool { detail == nil && artifact == nil && previewPhoto == nil && !showingInfo && !showingCommands && !showingCommandTask }

    var body: some View {
        let transcript = WorkshopTranscriptPresentation(entries: conversation.entries, followups: conversation.followups)
        let artifactsByEntry = WorkshopArtifactPlacement.group(conversation.artifacts, entries: transcript.history,
            projectPath: conversation.application.path)
        let groups = WorkshopEntryGroup.group(transcript.history, artifactsAfter: Set(artifactsByEntry.keys))
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
                } else if conversation.loadingHistory {
                    Text(conversation.entries.isEmpty ? "正在读取会话…" : "正在更新会话…")
                        .font(.footnote).foregroundStyle(HakoStyle.muted)
                }
                if conversation.entries.isEmpty && !conversation.loadingHistory {
                    Text("想在 \(conversation.application.name) 中完成什么？")
                        .font(.subheadline).foregroundStyle(HakoStyle.muted).padding(.vertical, 40)
                }
                ForEach(groups) { group in
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(group.entries) { entry in
                            VStack(alignment: .leading, spacing: 12) {
                                entryView(entry)
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
                if let operation = conversation.operation {
                    Label(operationLabel(operation), systemImage: operation.active ? "circle.dotted" : "checkmark.circle")
                        .font(.footnote).foregroundStyle(HakoStyle.muted)
                }
                if let error = conversation.error ?? conversation.connectionIssue {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(error).font(.footnote).textSelection(.enabled)
                        Button("检查会话与任务结果") { Task { await conversation.checkResult() } }
                            .font(.footnote).disabled(conversation.busy)
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
        }
        .scrollPosition($scrollPosition)
        .onAppear {
            WorkshopRuntime.shared.enter(synchronizationOwner, conversation: conversation)
            scrollFollowing = WorkshopScrollFollowing()
            conversation.setReadingLatest(scenePhase == .active && transcriptVisible)
            // Keep an edge target through the initial lazy layout and later
            // streaming updates instead of resolving an unmeasured child ID.
            scrollPosition = ScrollPosition(edge: .bottom)
        }
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentSize.height - geometry.visibleRect.maxY <= 80
        } action: { _, nearBottom in
            scrollFollowing.observe(nearBottom: nearBottom)
            conversation.setReadingLatest(nearBottom && scenePhase == .active && transcriptVisible)
        }
        .onDisappear {
            conversation.setReadingLatest(false)
            WorkshopRuntime.shared.leave(synchronizationOwner, conversation: conversation)
        }
        .onChange(of: scenePhase) { _, phase in
            conversation.setReadingLatest(phase == .active && scrollFollowing.followsBottom && transcriptVisible)
        }
        .onChange(of: transcriptVisible) { _, visible in
            conversation.setReadingLatest(visible && scenePhase == .active && scrollFollowing.followsBottom)
        }
        .onScrollPhaseChange { _, phase in
            if phase == .tracking || phase == .interacting { scrollFollowing.interacting(true) }
            else if phase == .idle { scrollFollowing.interacting(false) }
        }
        .onChange(of: conversation.entries) { _, _ in
            if scrollFollowing.shouldFollowUpdates { scrollPosition.scrollTo(edge: .bottom) }
        }
        .onChange(of: conversation.appendedMessageID) { _, id in
            if id != nil {
                scrollFollowing = WorkshopScrollFollowing()
                if reduceMotion { scrollPosition.scrollTo(edge: .bottom) }
                else { withAnimation { scrollPosition.scrollTo(edge: .bottom) } }
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .background(HakoStyle.background)
        .background(WorkshopKeyboardDismissal())
        .navigationTitle(conversation.title)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                projectInfo
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
        }
        .safeAreaInset(edge: .bottom) {
            if conversation.isArchived {
                HStack {
                    Label("此会话已归档", systemImage: "archivebox").font(.footnote).foregroundStyle(HakoStyle.muted)
                    Spacer()
                    Button("取消归档") { Task { await conversation.unarchive() } }.font(.subheadline)
                        .disabled(conversation.busy)
                }.padding(.horizontal, 20).frame(minHeight: 44).background(HakoStyle.background)
            } else { composer }
        }
        .refreshable { await conversation.synchronize() }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { showingCommands = true } label: { Image(systemName: "terminal") }.accessibilityLabel("快捷命令")
                Button { showingInfo = true } label: { Image(systemName: "ellipsis") }.accessibilityLabel("更多会话设置")
            }
        }
        .sheet(item: $detail) { entry in
            SettingsSheet(title: entry.recordTitle) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Text(entry.text).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        if entry.truncated { Text("此项内容过长，手机中显示前 8,000 个字符。完整内容保留在电脑的 Codex 会话中。")
                            .font(.footnote).foregroundStyle(.secondary) }
                    }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .sheet(item: $artifact) { file in WorkshopPreviewView(store: conversation.store, agent: conversation.agent, artifact: file) }
        .sheet(item: $previewPhoto) { photo in WorkshopPhotoPreview(photo: photo) }
        .sheet(isPresented: $showingInfo) { WorkshopConversationSettings(conversation: conversation) }
        .sheet(isPresented: $showingCommands) { WorkshopCommandLibraryView(client: commands) }
        .sheet(isPresented: $showingCommandTask) { SettingsSheet(title: "命令执行") { WorkshopCommandTaskView(client: commands) } }
        .task(id: commands.observationID) { await commands.observe() }
        .task(id: selectedPhoto) { await loadPhoto(selectedPhoto) }
        .task { if conversation.models.isEmpty || conversation.modelError != nil { await conversation.loadModels() } }
    }

    @ViewBuilder private func entryView(_ entry: WorkshopEntry) -> some View {
        if entry.kind == "followup" {
            followupView(entry)
        } else if entry.role == "user" {
            HStack {
                Spacer(minLength: 30)
                userMessage(entry).padding(14)
                    .background(HakoStyle.line, in: RoundedRectangle(cornerRadius: 16))
            }
        } else if entry.role == "assistant" {
            VStack(alignment: .leading, spacing: 10) {
                Label("Codex", systemImage: "terminal").font(.caption.weight(.medium))
                WorkshopMessageView(text: entry.text)
                if entry.truncated {
                    Button("查看内容说明") { detail = entry }.font(.caption)
                }
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
                    Label(followupLabel(status?.state ?? entry.state), systemImage: "text.line.first.and.arrowtriangle.forward")
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
        WorkshopUserMessage(entry: entry, threadId: conversation.threadId, store: conversation.store, agent: conversation.agent)
    }

    private var projectInfo: some View {
        HStack {
            Label(conversation.application.name, systemImage: "folder")
            Spacer()
            Text(conversation.modelLabel).lineLimit(1).truncationMode(.middle)
        }
        .font(.caption).foregroundStyle(HakoStyle.muted)
        .padding(.horizontal, 20).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(HakoStyle.background)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if conversation.editingMessageID != nil {
                HStack {
                    Text("修改排队消息").font(.caption).foregroundStyle(HakoStyle.muted)
                    Spacer()
                    Button { conversation.cancelEditing() } label: { Image(systemName: "xmark").frame(width: 44, height: 44) }
                        .accessibilityLabel("取消修改消息").disabled(conversation.busy)
                }
            }
            if !conversation.photos.isEmpty { photoAttachments }
            if loadingPhoto { Text("正在处理图片…").font(.caption).foregroundStyle(HakoStyle.muted) }
            if let progress = conversation.uploadProgress {
                ProgressView("正在上传图片 \(Int(progress * 100))%", value: progress).font(.caption)
            }
            if conversation.canCompose && (conversation.synchronizing || conversation.uncertain) {
                Text(conversation.synchronizing ? "正在同步会话，可先输入，同步完成后可发送" : "任务状态待确认，可先输入，确认后可发送")
                    .font(.caption).foregroundStyle(HakoStyle.muted)
            }
            HStack(alignment: .bottom, spacing: 2) {
                PhotosPicker(selection: $selectedPhoto, matching: .images) {
                    Image(systemName: "plus").font(.system(size: 22, weight: .bold))
                        .foregroundStyle(HakoStyle.text).frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("添加图片")
                .disabled(!conversation.canCompose || conversation.editingMessageID != nil || loadingPhoto || conversation.photos.count >= 3)
                TextField("描述你的想法…", text: $conversation.draft, axis: .vertical)
                    .font(.body).lineLimit(1...5).accessibilityLabel("发给 Codex 的消息")
                    .padding(.vertical, 11).frame(maxWidth: .infinity, alignment: .leading)
                    .disabled(!conversation.canCompose)
                if conversation.synchronizing || conversation.uncertain {
                    Button {} label: {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 18, weight: .semibold))
                            .symbolEffect(.rotate, options: .repeating, isActive: !reduceMotion)
                    }
                    .buttonStyle(WorkshopSendButtonStyle())
                    .accessibilityLabel(conversation.synchronizing ? "正在同步会话，等待发送" : "正在确认任务状态，等待发送")
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

    private var photoAttachments: some View {
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

    private func loadPhoto(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        loadingPhoto = true
        defer { loadingPhoto = false }
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else { throw HakoError(message: "无法读取图片。") }
            let encoded = await Task.detached(priority: .userInitiated) { Self.encodePhoto(data) }.value
            try Task.checkCancellation()
            guard let encoded else { throw HakoError(message: "图片处理失败，请选择其他图片。") }
            try conversation.attach(encoded)
            selectedPhoto = nil
        } catch is CancellationError { }
        catch { conversation.error = error.localizedDescription; selectedPhoto = nil }
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

    private func operationLabel(_ operation: WorkshopOperation) -> String {
        switch operation.state {
        case "starting": "正在连接 Codex…"
        case "running": "任务在电脑上执行中"
        case "waiting": "等待你确认"
        case "finishing": "正在保存结果并释放会话"
        case "completed": "本轮已完成"
        case "interrupted": "任务已停止"
        case "failed": "本轮未完成"
        default: "请核对本轮执行结果"
        }
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
            var view = touch.view
            while let current = view {
                if let field = current as? UITextField, field.isEnabled { return false }
                if let editor = current as? UITextView, editor.isEditable { return false }
                view = current.superview
            }
            return true
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }

        @objc private func dismissKeyboard() { window?.endEditing(true) }
    }
}

private struct WorkshopEntryGroup: Identifiable {
    var entries: [WorkshopEntry]
    var id: String { entries[0].id }
    var isRecords: Bool { Self.isRecord(entries[0]) }

    static func group(_ entries: [WorkshopEntry], artifactsAfter: Set<String>) -> [Self] {
        var groups: [Self] = []
        for entry in entries {
            if isRecord(entry), let last = groups.last, last.isRecords,
               !artifactsAfter.contains(last.entries.last!.id) {
                groups[groups.count - 1].entries.append(entry)
            } else { groups.append(Self(entries: [entry])) }
        }
        return groups
    }

    private static func isRecord(_ entry: WorkshopEntry) -> Bool {
        entry.role != "user" && entry.role != "assistant" && entry.kind != "notice" && entry.kind != "followup"
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
