import SwiftUI

struct WorkshopNotificationPreview: View {
    let notice: WorkshopPushNotice
    let onSwitch: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var conversation: WorkshopConversation?
    @State private var failure: String?
    @State private var attempt = 0

    var body: some View {
        NavigationStack {
            Group {
                if let conversation {
                    WorkshopConversationView(conversation: conversation, onSwitch: onSwitch)
                } else {
                    VStack(spacing: 16) {
                        if let failure {
                            Text(failure).font(.subheadline).foregroundStyle(HakoStyle.muted)
                            Button("重试") { attempt += 1 }.buttonStyle(HakoActionButtonStyle())
                        } else { ProgressView("正在打开会话…") }
                    }
                    .padding(20).frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(HakoStyle.background)
                    .navigationTitle(notice.subtitle.isEmpty ? "会话预览" : notice.subtitle)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("切换", systemImage: "arrow.up.right", action: onSwitch).disabled(true)
                        }
                        ToolbarItem(placement: .topBarTrailing) {
                            Button { dismiss() } label: { Image(systemName: "xmark") }.accessibilityLabel("关闭会话预览")
                        }
                    }
                }
            }
        }
        .tint(.primary)
        .presentationDetents([.large]).presentationDragIndicator(.visible)
        .task(id: attempt) {
            failure = nil
            do {
                let target = try await WorkshopRuntime.shared.notificationConversation(notice)
                try Task.checkCancellation()
                conversation = target
            } catch is CancellationError { }
            catch { if !Task.isCancelled { failure = error.localizedDescription } }
        }
    }
}

struct CodeWorkshopView: View {
    @ObservedObject private var store = WorkshopRuntime.shared.store
    @ObservedObject private var push = BuildPushSubscription.shared
    // State belongs to this particular stack instance. Reconstructing a View
    // value must not let the old list claim the replacement stack's request.
    @State private var navigationOwner = BuildPushSubscription.shared.workshopNavigationID
    @State private var synchronizationOwner = UUID()
    @State private var settingsPresented = false
    @State private var creating = false
    @State private var conversation: WorkshopConversation?
    @State private var pendingArchive: WorkshopSession?
    @State private var quotaState = WorkshopQuotaState()
    @State private var quotaVisit = UUID()
    @State private var quotaPageVisible = false
    @State private var clearQuotaCache = false

    private var quotaRefreshID: String {
        store.scope + "|" + store.selectedAgentID + "|\(quotaVisit)|\(quotaPageVisible && store.authenticated && conversation == nil && !creating && !settingsPresented)"
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { timeline in
            page(at: timeline.date)
        }
        .task(id: push.workshopNavigation) {
            guard let link = push.workshopLink,
                  push.workshopNavigation.accepts(ownerID: navigationOwner, noticeID: link.id) else { return }
            await openNotification(link)
        }
        .alert("归档会话", isPresented: Binding(
            get: { pendingArchive != nil },
            set: { if !$0 { pendingArchive = nil } }
        ), presenting: pendingArchive) { session in
            Button("取消", role: .cancel) { pendingArchive = nil }
            Button("确认归档") { archive(session) }
        } message: { session in
            Text("确定归档「\(session.title)」吗？归档后可在「已归档」列表中查看和恢复。")
        }
    }

    private func openNotification(_ link: WorkshopPushNotice) async {
        func isCurrent() -> Bool {
            !Task.isCancelled && push.workshopNavigation.accepts(ownerID: navigationOwner, noticeID: link.id)
        }
        do {
            let target = try await WorkshopRuntime.shared.notificationConversation(link)
            guard isCurrent() else { return }
            await store.selectAgent(target.agent.id)
            guard isCurrent(), target.scope == store.scope else { return }
            store.selectApplication(target.application.id)
            settingsPresented = false; creating = false; pendingArchive = nil
            conversation = target
        } catch is CancellationError { }
        catch { if isCurrent() { store.error = error.localizedDescription } }
    }

    private func page(at date: Date) -> some View {
        let items = store.sessionListItems(at: date)
        return List {
            Section {
                VStack(alignment: .leading, spacing: 16) {
                    heading
                    if !store.authenticated {
                        ContentUnavailableView("请先登录服务器", systemImage: "server.rack",
                            description: Text("在 Hako 首页的「设置 → 服务器与登录」完成连接，然后返回代码工坊。"))
                    } else if let agent = store.selectedAgent {
                        if !agent.supported {
                            Text("此电脑的 Agent 尚不支持代码工坊，请更新 Windows Agent 后重新连接。")
                                .font(.subheadline).foregroundStyle(HakoStyle.muted)
                        } else {
                            Button {
                                quotaState.prepareManualRefresh()
                                clearQuotaCache = true
                                quotaVisit = UUID()
                            } label: {
                                VStack(alignment: .leading, spacing: 10) {
                                    Text("Codex 额度").font(.subheadline.weight(.semibold))
                                    WorkshopQuotaView(store: store, agent: agent, state: quotaState)
                                        .equatable()
                                        .id(agent.id)
                                }
                                .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .background(HakoStyle.card,in:RoundedRectangle(cornerRadius:12))
                            .accessibilityHint("清空缓存并重新获取额度")
                            VStack(alignment: .leading, spacing: 4) {
                                applicationTabs
                                HStack {
                                    sessionFilter(count: items.count)
                                    Spacer()
                                    if !store.showingArchived {
                                        Button { creating = true } label: {
                                            HStack(spacing: 4) {
                                                Image(systemName: "plus")
                                                Text("新建会话")
                                            }.font(.subheadline)
                                        }
                                            .frame(minHeight: 44).disabled(store.selectedApplication == nil || !agent.online)
                                    }
                                }
                            }
                        }
                    } else {
                        ContentUnavailableView("尚无可用电脑", systemImage: "desktopcomputer",
                            description: Text("请先在「设备管理」添加 Windows Agent。"))
                    }
                }
                .buttonStyle(.plain)
                .listRowInsets(EdgeInsets(top: 12, leading: 0, bottom: 0, trailing: 0))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
            if store.authenticated, let agent = store.selectedAgent, agent.supported {
                sessionList(agent, items: items)
            }
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    if store.authenticated, let agent = store.selectedAgent {
                        if store.hasMore && agent.supported {
                            Button { Task { await store.loadMore() } } label: {
                                HStack(spacing: 8) {
                                    if store.loadingMore { ProgressView() }
                                    Text(store.loadingMore ? "正在加载更早的会话…" : "加载更早的会话")
                                }
                                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                                .font(.subheadline)
                                .disabled(store.loadingMore || store.archivingSessionID != nil)
                        }
                        if !agent.online { Text("电脑当前离线，联网后下拉刷新。已发送的任务由电脑端继续执行。")
                            .font(.footnote).foregroundStyle(HakoStyle.muted) }
                    }
                    if let error = store.error { Text(error).font(.footnote).foregroundStyle(.red).textSelection(.enabled) }
                    if let cachedAt = store.cachedAt {
                        HStack(spacing: 4) {
                            Text(store.loading ? "显示缓存，正在刷新 ·" : "显示上次内容 ·")
                            Text(cachedAt, style: .relative)
                        }.font(.caption2).foregroundStyle(HakoStyle.muted)
                    }
                    if store.sessions.isEmpty { Text(store.loading ? "正在读取会话…" : "连接后显示会话").font(.footnote).foregroundStyle(HakoStyle.muted) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .buttonStyle(.plain)
                .listRowInsets(EdgeInsets(top: 12, leading: 12, bottom: 16, trailing: 12))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(8)
        .contentMargins(.top, 0, for: .scrollContent)
        .scrollContentBackground(.hidden)
        .background(HakoStyle.background)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { settingsPresented = true } label: { Image(systemName: "slider.horizontal.3") }
                    .accessibilityLabel("代码工坊设置")
            }
        }
        .refreshable { await store.refresh() }
        .sheet(isPresented: $settingsPresented) { WorkshopSettingsView(store: store) }
        .sheet(isPresented: $creating) {
            if let application = store.selectedApplication, let agent = store.selectedAgent {
                WorkshopNewSessionView(application: application) { name in
                    creating = false
                    conversation = WorkshopRuntime.shared.create(agent: agent, application: application, title: name)
                }
            }
        }
        .navigationDestination(isPresented: Binding(get: { conversation != nil }, set: { if !$0 { conversation = nil } })) {
            if let conversation {
                WorkshopConversationView(conversation: conversation).id(conversation.id)
                    .onAppear {
                        push.workshopDestinationDisplayed(ownerID: navigationOwner, computerID: conversation.agent.id,
                            threadID: conversation.threadId, operationID: conversation.notificationOperationID)
                    }
            }
        }
        .onChange(of: store.scope) { _, _ in
            conversation = nil; creating = false; settingsPresented = false; pendingArchive = nil
        }
        .onChange(of: store.selectedAgentID) { _, _ in pendingArchive = nil }
        .onChange(of: store.selectedApplicationID) { _, _ in pendingArchive = nil }
        .onChange(of: store.showingArchived) { _, _ in pendingArchive = nil }
        .task(id: quotaRefreshID) {
            guard quotaPageVisible, conversation == nil, !creating, !settingsPresented, store.authenticated,
                  let agent = store.selectedAgent, agent.supported else { return }
            let clearCache = clearQuotaCache
            clearQuotaCache = false
            await quotaState.refresh(store: store, agent: agent, clearCache: clearCache)
        }
        .onAppear { quotaVisit = UUID(); quotaPageVisible = true; WorkshopRuntime.shared.enter(synchronizationOwner) }
        .onDisappear { quotaPageVisible = false; WorkshopRuntime.shared.leave(synchronizationOwner) }
    }

    private func archive(_ session: WorkshopSession) {
        pendingArchive = nil
        guard let agent = store.selectedAgent, !store.showingArchived else { return }
        guard let current = store.visibleSessions.first(where: { $0.id == session.id }) else {
            store.error = "会话列表已更新，请刷新后核对归档状态。"
            return
        }
        guard !current.inProgress, current.state != "paused" else {
            store.error = "会话当前有任务正在处理或暂停，请结束任务后再归档。"
            return
        }
        Task { await store.setArchived(session.id, archived: true, agent: agent) }
    }

    private var heading: some View {
        HStack(alignment: .center, spacing: 12) {
            Text("代码工坊").font(.system(size: 28, weight: .semibold))
            Spacer(minLength: 4)
            Button { settingsPresented = true } label: {
                VStack(alignment: .trailing, spacing: 4) {
                    HStack(spacing: 5) {
                        Image(systemName: "desktopcomputer")
                        Text(store.selectedAgent?.name ?? "选择电脑").lineLimit(1)
                        Circle().fill(store.selectedAgent?.online == true ? Color.green : HakoStyle.muted).frame(width: 5, height: 5)
                    }
                      Text(store.selectedAgent == nil ? "请选择执行电脑" : store.selectedAgent?.online == true ? store.transportLabel : "离线").foregroundStyle(HakoStyle.muted)
                }
                .font(.caption).frame(minHeight: 44)
            }
            .buttonStyle(.plain).accessibilityLabel("选择执行电脑")
        }
    }

    private var applicationTabs: some View {
        WorkshopApplicationTabs(applications: store.orderedApplications, selectedID: store.selectedApplicationID) {
            store.selectApplication($0)
        }
    }

    private func sessionFilter(count: Int) -> some View {
        Menu {
            Button { Task { await store.selectArchiveMode(false) } } label: {
                Label("会话", systemImage: store.showingArchived ? "bubble.left.and.bubble.right" : "checkmark")
            }
            Button { Task { await store.selectArchiveMode(true) } } label: {
                Label("已归档", systemImage: store.showingArchived ? "checkmark" : "archivebox")
            }.disabled(store.selectedAgent?.supportsArchiving != true)
        } label: {
            HStack(spacing: 4) {
                Text(store.showingArchived ? "已归档 · \(count) 个会话" : "\(count) 个会话")
                Image(systemName: "chevron.down").font(.caption2)
            }.font(.caption).foregroundStyle(HakoStyle.muted).frame(minHeight: 44)
        }
        .disabled(store.loading || store.archivingSessionID != nil)
        .accessibilityLabel("当前已加载 \(count) 个\(store.showingArchived ? "已归档" : "")会话，切换列表")
    }

    @ViewBuilder private func sessionList(_ agent: WorkshopAgent, items: [WorkshopSessionListItem]) -> some View {
        if items.isEmpty {
            ContentUnavailableView(store.showingArchived ? "暂无已归档会话" : "暂无会话",
                systemImage: store.showingArchived ? "archivebox" : "bubble.left.and.text.bubble.right",
                description: Text(store.showingArchived ? "归档后的会话会显示在这里，可随时取消归档。" :
                    store.applications.isEmpty ? "此电脑的 Code 目录中尚未发现项目。" : "在当前应用中新建会话，或加载更早的会话。"))
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        } else {
            Section {
                ForEach(items) { item in
                    let session = item.session
                    let hasDraft = item.hasDraft
                    let isOccupied = session.access?.state == "occupied"
                    Button {
                        guard let application = store.applications.first(where: { $0.id == session.applicationId }) else { return }
                        conversation = WorkshopRuntime.shared.open(session, agent: agent,
                            application: application, archived: store.showingArchived)
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: isOccupied ? "lock" : hasDraft || session.inProgress || item.isUnread ? "terminal.fill" : "terminal")
                                .symbolRenderingMode(.monochrome)
                                .font(.subheadline).padding(.top, 3)
                                .foregroundStyle(hasDraft ? Color.orange : session.inProgress ? Color.green : item.isUnread ? Color.blue : HakoStyle.text)
                            VStack(alignment: .leading, spacing: 9) {
                                Text(session.listTitle).font(.subheadline.weight(.medium))
                                    .lineLimit(2).truncationMode(.tail)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Text(session.preview).font(.caption).foregroundStyle(HakoStyle.muted).lineLimit(2)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            if store.archivingSessionID == session.id {
                                ProgressView().accessibilityLabel(store.showingArchived ? "正在取消归档" : "正在归档")
                            }
                        }
                        .padding(16).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    .accessibilityValue((isOccupied ? "其他客户端占用，" : "") + (hasDraft ? "有未发送的草稿" : session.inProgress ? (session.state == "waiting" ? "等待确认" : "处理中") : item.isUnread ? "未读" : "已读"))
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(HakoStyle.card)
                    .listRowSeparatorTint(HakoStyle.line)
                    .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                    .alignmentGuide(.listRowSeparatorTrailing) { $0.width }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        if agent.supportsArchiving, UUID(uuidString: session.id) != nil {
                            Button {
                                if store.showingArchived {
                                    Task { await store.setArchived(session.id, archived: false, agent: agent) }
                                } else {
                                    pendingArchive = session
                                }
                            } label: {
                                Image(systemName: store.showingArchived ? "tray.and.arrow.up" : "archivebox")
                            }
                            .accessibilityLabel(store.showingArchived ? "取消归档" : "归档")
                            .tint(.orange)
                            .disabled(!agent.online || store.archivingSessionID != nil ||
                                (!store.showingArchived && (session.inProgress || session.state == "paused")))
                        }
                    }
                }
            }
        }
    }
}

// Keep scroll-position geometry out of the header's view construction. Only a
// change in horizontal capacity invalidates this view's tab partition.
private struct WorkshopApplicationTabs: View {
    let applications: [WorkshopApplication]
    let selectedID: String
    let select: (String) -> Void
    @State private var capacity = 1

    var body: some View {
        let visible = Array(applications.prefix(capacity))
        let overflow = Array(applications.dropFirst(capacity))
        let overflowSelection = overflow.first { $0.id == selectedID }
        HStack(spacing: 4) {
            ForEach(visible) { application in
                Button { select(application.id) } label: {
                    tabLabel(application.name, selected: application.id == selectedID)
                }.buttonStyle(.plain).accessibilityAddTraits(application.id == selectedID ? .isSelected : [])
            }
            if !overflow.isEmpty {
                Menu {
                    ForEach(overflow) { application in
                        Button { select(application.id) } label: {
                            if application.id == selectedID { Label(application.name, systemImage: "checkmark") }
                            else { Text(application.name) }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(overflowSelection?.name ?? "更多").lineLimit(1).minimumScaleFactor(0.85)
                        Image(systemName: "chevron.down").font(.caption2)
                    }
                    .font(.subheadline).frame(minWidth: 48, maxWidth: 90, minHeight: 44)
                    .foregroundStyle(overflowSelection == nil ? HakoStyle.muted : HakoStyle.text)
                    .overlay(alignment: .bottom) { if overflowSelection != nil { Rectangle().frame(height: 2) } }
                }
                .menuOrder(.fixed).accessibilityLabel("更多应用，当前为\(overflowSelection?.name ?? "未选择")")
            }
        }
        .background(alignment: .bottom) { HakoStyle.line.frame(height: 1) }
        .accessibilityElement(children: .contain).accessibilityLabel("应用")
        .frame(maxWidth: .infinity, minHeight: 44, maxHeight: 44, alignment: .leading)
        .onGeometryChange(for: Int.self) { geometry in
            let width = max(0, geometry.size.width)
            return CGFloat(applications.count * 78) <= width ? applications.count : max(1, Int((width - 64) / 78))
        } action: { capacity = $0 }
    }

    private func tabLabel(_ name: String, selected: Bool) -> some View {
        Text(name).font(.subheadline.weight(selected ? .semibold : .regular))
            .lineLimit(1).minimumScaleFactor(0.85).frame(maxWidth: .infinity, minHeight: 44)
            .foregroundStyle(selected ? HakoStyle.text : HakoStyle.muted)
            .overlay(alignment: .bottom) { if selected { Rectangle().fill(HakoStyle.text).frame(height: 2) } }
    }

}

private struct WorkshopSettingsView: View {
    @ObservedObject var store: WorkshopStore
    @State private var showingGenerationDefaults = false
    @State private var editingSystemPrompt = false
    var body: some View {
        SettingsSheet(title: "代码工坊设置") {
            Form {
                Section("执行电脑") {
                    ForEach(store.agents) { agent in
                        WorkshopComputerSettingsRow(store: store, agent: agent)
                            .id(store.networkNamespace + "\n" + agent.id)
                    }
                    if store.agents.isEmpty { Text("启动并连接电脑端 Agent 后，执行电脑将自动显示。").foregroundStyle(.secondary) }
                }
                Section("Codex") {
                    if let agent = store.selectedAgent {
                        Button { showingGenerationDefaults = true } label: {
                            HStack {
                                Text("默认生成设置")
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                        .alignmentGuide(.listRowSeparatorTrailing) { $0.width }
                        .sheet(isPresented: $showingGenerationDefaults) {
                            WorkshopDefaultGenerationSettings(store: store, agent: agent)
                        }
                    }
                    Button { editingSystemPrompt = true } label: {
                        HStack {
                            Text("系统提示词").foregroundStyle(.primary)
                            Spacer()
                            Text("编辑").foregroundStyle(.secondary)
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                        .alignmentGuide(.listRowSeparatorTrailing) { $0.width }
                    }
                    Text("使用电脑上已登录的 Codex。默认自动审批，也可在会话中选择请求确认、完全访问或跟随电脑配置。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                WorkshopPushSettings(authentication: store.authentication)
                Section {
                    Text("手机断线后，任务保留在电脑端。回到会话会继续读取进度。桌面版仍持有写锁时，需要先由桌面版释放会话。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .sheet(isPresented: $editingSystemPrompt) { WorkshopSystemPromptSheet(store: store) }
        }
    }
}

private struct WorkshopNewSessionView: View {
    let application: WorkshopApplication
    let create: (String) -> Void
    @State private var name = ""
    var body: some View {
        SettingsSheet(title: "新建会话", hasChanges: !name.isEmpty, saveEnabled: !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            onSave: { create(name.trimmingCharacters(in: .whitespacesAndNewlines)) }, saveAccessibilityLabel: "开始会话") {
            Form {
                Section("应用") {
                    Text(application.name)
                    Text(application.path).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("会话名称").font(.subheadline).foregroundStyle(.secondary)
                        TextField("描述本次要做的事情", text: $name).accessibilityLabel("会话名称")
                            .onChange(of: name) { _, value in
                                var shortened = String(value.prefix(120))
                                while shortened.utf16.count > 120 { shortened.removeLast() }
                                if shortened != value { name = shortened }
                            }
                    }
                }
            }
        }
    }
}
