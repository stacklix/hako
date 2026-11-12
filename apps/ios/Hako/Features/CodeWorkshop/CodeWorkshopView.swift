import SwiftUI

struct CodeWorkshopView: View {
    @ObservedObject private var store = WorkshopRuntime.shared.store
    @ObservedObject private var push = BuildPushSubscription.shared
    @State private var synchronizationOwner = UUID()
    @State private var settingsPresented = false
    @State private var creating = false
    @State private var conversation: WorkshopConversation?
    @State private var pendingArchive: WorkshopSession?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { timeline in
            page(at: timeline.date)
        }
        .task(id: push.workshopLink?.id) {
            guard let link = push.workshopLink else { return }
            await openNotification(link)
        }
        .sheet(item: $pendingArchive) { session in
            SettingsSheet(title: "归档会话", onSave: { archive(session) }, saveAccessibilityLabel: "确认归档") {
                Form {
                    Section {
                        Text("确定归档「\(session.title)」吗？归档后可在「已归档」列表中查看和恢复。")
                        Button("确认归档") { archive(session) }
                            .buttonStyle(HakoActionButtonStyle())
                    }
                }
            }
        }
    }

    private func openNotification(_ link: WorkshopPushNotice) async {
        let requestID = push.workshopNavigationID
        func isCurrent() -> Bool {
            !Task.isCancelled && push.workshopNavigationID == requestID && push.workshopLink?.id == link.id
        }
        do {
            guard UUID(uuidString: link.threadId) != nil else {
                store.error = "这条通知没有可打开的会话。"; return
            }
            await store.prepareNetwork()
            guard isCurrent() else { return }
            // Open known conversations immediately, including when the computer is offline.
            if store.authenticated, let agent = store.selectedAgent, agent.id == link.computerId,
               let session = store.sessions.first(where: { $0.id.caseInsensitiveCompare(link.threadId) == .orderedSame }),
               let application = store.applications.first(where: { $0.id == session.applicationId }) {
                showNotification(session, agent: agent, application: application)
                return
            }
            await store.restore()
            // The catalog synchronizer may already own the same refresh during cold launch.
            while store.loading { try await Task.sleep(for: .milliseconds(100)) }
            guard isCurrent() else { return }
            guard store.agents.contains(where: { $0.id == link.computerId }) else {
                store.error = "通知对应的电脑当前不可用，请检查连接。"; return
            }
            await store.selectAgent(link.computerId)
            while store.loading { try await Task.sleep(for: .milliseconds(100)) }
            guard isCurrent(), let agent = store.selectedAgent, agent.id == link.computerId else { return }
            if let session = store.sessions.first(where: { $0.id.caseInsensitiveCompare(link.threadId) == .orderedSame }),
               let application = store.applications.first(where: { $0.id == session.applicationId }) {
                showNotification(session, agent: agent, application: application)
                return
            }
            let scope = store.scope
            let history: WorkshopHistory = try await store.call(agent, "history.read", ["threadId": link.threadId])
            guard isCurrent(), scope == store.scope, agent.id == store.selectedAgentID else { return }
            guard let application = WorkshopApplication.containing(history.cwd, in: store.applications) else {
                store.error = "通知对应的项目已不可用。"; return
            }
            let session = WorkshopSession(id: link.threadId,
                title: link.subtitle.isEmpty ? "会话" : link.subtitle, applicationId: application.id, cwd: history.cwd,
                preview: "", updatedAt: Int64(Date.now.timeIntervalSince1970), state: "unknown",
                operationId: history.operationId, completionId: history.completionId)
            showNotification(session, agent: agent, application: application)
        } catch is CancellationError { }
        catch { if isCurrent() { store.error = "无法打开通知对应的会话，请检查连接后重试。" } }
    }

    private func showNotification(_ session: WorkshopSession, agent: WorkshopAgent, application: WorkshopApplication) {
        store.selectApplication(application.id)
        settingsPresented = false; creating = false; pendingArchive = nil
        conversation = WorkshopRuntime.shared.open(session, agent: agent, application: application, archived: store.showingArchived)
        push.workshopLink = nil
    }

    private func page(at date: Date) -> some View {
        List {
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
                            VStack(alignment: .leading, spacing: 4) {
                                applicationTabs
                                HStack {
                                    sessionFilter
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
                            description: Text("请先在「设备监控」添加 Windows Agent。"))
                    }
                }
                .buttonStyle(.plain)
                .listRowInsets(EdgeInsets(top: 12, leading: 0, bottom: 0, trailing: 0))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
            if store.authenticated, let agent = store.selectedAgent, agent.supported {
                sessionList(agent, at: date)
            }
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    if store.authenticated, let agent = store.selectedAgent {
                        if store.hasMore && agent.supported {
                            Button("加载更早的会话") { Task { await store.refresh(more: true) } }
                                .font(.subheadline).disabled(store.loading)
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
                .buttonStyle(.plain)
                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 16, trailing: 0))
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
            if let conversation { WorkshopConversationView(conversation: conversation).id(conversation.id) }
        }
        .onChange(of: store.scope) { _, _ in
            conversation = nil; creating = false; settingsPresented = false; pendingArchive = nil
        }
        .onChange(of: store.selectedAgentID) { _, _ in pendingArchive = nil }
        .onChange(of: store.selectedApplicationID) { _, _ in pendingArchive = nil }
        .onChange(of: store.showingArchived) { _, _ in pendingArchive = nil }
        .onAppear { WorkshopRuntime.shared.enter(synchronizationOwner) }
        .onDisappear { WorkshopRuntime.shared.leave(synchronizationOwner) }
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
                      Text(store.selectedAgent?.online == true ? store.transportLabel : "离线").foregroundStyle(HakoStyle.muted)
                }
                .font(.caption).frame(minHeight: 44)
            }
            .buttonStyle(.plain).accessibilityLabel("选择执行电脑")
        }
    }

    private var applicationTabs: some View {
        GeometryReader { proxy in
            let applications = store.orderedApplications
            let count = applications.count * 78 <= Int(proxy.size.width) ? applications.count : max(1, Int((proxy.size.width - 64) / 78))
            let visible = Array(applications.prefix(count))
            let overflow = Array(applications.dropFirst(count))
            let overflowSelection = overflow.first { $0.id == store.selectedApplicationID }
            HStack(spacing: 4) {
                ForEach(visible) { application in
                    Button { store.selectApplication(application.id) } label: {
                        tabLabel(application.name, selected: application.id == store.selectedApplicationID)
                    }.buttonStyle(.plain).accessibilityAddTraits(application.id == store.selectedApplicationID ? .isSelected : [])
                }
                if !overflow.isEmpty {
                    Menu {
                        ForEach(overflow) { application in
                            Button { store.selectApplication(application.id) } label: {
                                if application.id == store.selectedApplicationID { Label(application.name, systemImage: "checkmark") }
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
        }
        .frame(height: 44)
    }

    private var sessionFilter: some View {
        Menu {
            Button { Task { await store.selectArchiveMode(false) } } label: {
                Label("会话", systemImage: store.showingArchived ? "bubble.left.and.bubble.right" : "checkmark")
            }
            Button { Task { await store.selectArchiveMode(true) } } label: {
                Label("已归档", systemImage: store.showingArchived ? "checkmark" : "archivebox")
            }.disabled(store.selectedAgent?.supportsArchiving != true)
        } label: {
            HStack(spacing: 4) {
                Text(store.showingArchived ? "已归档 · \(store.visibleSessions.count) 个会话" : "\(store.visibleSessions.count) 个会话")
                Image(systemName: "chevron.down").font(.caption2)
            }.font(.caption).foregroundStyle(HakoStyle.muted).frame(minHeight: 44)
        }
        .disabled(store.loading || store.archivingSessionID != nil)
        .accessibilityLabel("当前已加载 \(store.visibleSessions.count) 个\(store.showingArchived ? "已归档" : "")会话，切换列表")
    }

    private func tabLabel(_ name: String, selected: Bool) -> some View {
        Text(name).font(.subheadline.weight(selected ? .semibold : .regular))
            .lineLimit(1).minimumScaleFactor(0.85).frame(maxWidth: .infinity, minHeight: 44)
            .foregroundStyle(selected ? HakoStyle.text : HakoStyle.muted)
            .overlay(alignment: .bottom) { if selected { Rectangle().fill(HakoStyle.text).frame(height: 2) } }
    }

    @ViewBuilder private func sessionList(_ agent: WorkshopAgent, at date: Date) -> some View {
        let sessions = store.visibleSessions
        if sessions.isEmpty {
            ContentUnavailableView(store.showingArchived ? "暂无已归档会话" : "暂无会话",
                systemImage: store.showingArchived ? "archivebox" : "bubble.left.and.text.bubble.right",
                description: Text(store.showingArchived ? "归档后的会话会显示在这里，可随时取消归档。" :
                    store.applications.isEmpty ? "此电脑的 Code 目录中尚未发现项目。" : "在当前应用中新建会话，或加载更早的会话。"))
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        } else {
            Section {
                ForEach(sessions) { session in
                    let hasDraft = store.hasDraft(session)
                    Button {
                        guard let application = store.applications.first(where: { $0.id == session.applicationId }) else { return }
                        conversation = WorkshopRuntime.shared.open(session, agent: agent,
                            application: application, archived: store.showingArchived)
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: hasDraft || session.inProgress || store.isUnread(session, at: date) ? "terminal.fill" : "terminal")
                                .symbolRenderingMode(.monochrome)
                                .font(.subheadline).padding(.top, 3)
                                .foregroundStyle(hasDraft ? Color.orange : session.inProgress ? Color.green : store.isUnread(session, at: date) ? Color.blue : HakoStyle.text)
                            VStack(alignment: .leading, spacing: 9) {
                                HStack(alignment: .top) {
                                    Text(session.title).font(.subheadline.weight(.medium))
                                    Spacer(minLength: 5)
                                    Text(Date(timeIntervalSince1970: Double(session.updatedAt)), style: .relative)
                                        .font(.caption2).foregroundStyle(HakoStyle.muted)
                                }
                                Text(session.preview).font(.caption).foregroundStyle(HakoStyle.muted).lineLimit(2)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            if store.archivingSessionID == session.id {
                                ProgressView().accessibilityLabel(store.showingArchived ? "正在取消归档" : "正在归档")
                            }
                        }
                        .padding(16).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    .accessibilityValue(hasDraft ? "有未发送的草稿" : session.inProgress ? (session.state == "waiting" ? "等待确认" : "处理中") : store.isUnread(session, at: date) ? "未读" : "已读")
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

private struct WorkshopSettingsView: View {
    @ObservedObject var store: WorkshopStore
    var body: some View {
        SettingsSheet(title: "代码工坊设置") {
            Form {
                Section("执行电脑") {
                    ForEach(store.agents) { agent in
                        Button { Task { await store.selectAgent(agent.id) } } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(agent.name).foregroundStyle(.primary)
                                    Text(agent.online ? agent.supported ? "在线" : "需要更新 Agent" : "离线").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if agent.id == store.selectedAgentID { Image(systemName: "checkmark") }
                            }
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                            .alignmentGuide(.listRowSeparatorTrailing) { $0.width }
                        }.disabled(store.loading)
                    }
                    if store.agents.isEmpty { Text("请先在设备监控中登记 Windows Agent。").foregroundStyle(.secondary) }
                }
                Section("Codex") {
                    LabeledContent("模型与权限", value: "在会话的更多页面设置")
                    Text("使用电脑上已登录的 Codex。默认自动审批，也可在会话中选择请求确认、完全访问或跟随电脑配置。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                WorkshopPushSettings(authentication: store.authentication)
                Section {
                    Text("手机断线后，任务保留在电脑端。回到会话会继续读取进度。桌面版仍持有写锁时，需要先由桌面版释放会话。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
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
