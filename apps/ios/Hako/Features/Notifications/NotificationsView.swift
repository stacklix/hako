import SwiftUI

struct NotificationsView: View {
    @ObservedObject var store: HakoNotificationsStore
    @State private var selection: NotificationSelection?
    @State private var selectedPush: HakoPushNotification?
    @State private var showingServer = false
    @State private var confirmingClearAll = false
    @State private var clearAllContext: String?
    @State private var notice: String?
    @State private var noticeTask: Task<Void, Never>?
    private struct NotificationSelection: Identifiable {
        let notification: HakoNotification
        let session: ConsoleLoginPromptSession
        var id: String { notification.id }
    }

    var body: some View {
        List {
            if !store.authenticated {
                Section {
                    Text("登录 Hako 服务器后，可查看登录请求。").foregroundStyle(.secondary)
                    Button("服务器与登录") { showingServer = true }
                }
            }
            if let message = store.message, store.authenticated {
                Section { Label(message, systemImage: "wifi.exclamationmark").font(.footnote).foregroundStyle(.secondary) }
            }
            if store.notifications.isEmpty && store.message == nil {
                ContentUnavailableView("暂无通知", systemImage: "bell", description: Text("有新的消息时，会显示在这里。"))
            }
            ForEach(HakoNotification.Category.allCases, id: \.self) { category in
                let items = store.notifications.filter { $0.category == category }
                if !items.isEmpty {
                    Section {
                        ForEach(items) { notification in
                            Button { open(notification) } label: { notificationRow(notification) }
                                .buttonStyle(.plain)
                                .listRowInsets(EdgeInsets())
                                .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                                .alignmentGuide(.listRowSeparatorTrailing) { $0.width }
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    Button(role: .destructive) {
                                        store.clear(notification)
                                        showNotice(notification.clearFeedback)
                                    } label: { Label("清除", systemImage: "trash") }
                                    .tint(.red)
                                }
                        }
                    } header: {
                        HStack { Text(category.title); Spacer(); Text(category == .loginRequests ? "\(items.count) 条待处理" : "\(items.count) 条") }
                    } footer: {
                        Text(category.footer)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("通知").navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("全部已读") {
                    store.markAllRead()
                    showNotice("已将全部通知标为已读。")
                }
                    .disabled(store.unreadCount == 0)
                    .accessibilityLabel("全部标为已读")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button(role: .destructive) {
                        notice = nil
                        clearAllContext = store.context
                        confirmingClearAll = true
                    } label: {
                        Label("清除全部", systemImage: "trash").foregroundStyle(.red)
                    }
                } label: { Image(systemName: "ellipsis") }
                    .accessibilityLabel("通知操作")
                    .disabled(store.notifications.isEmpty)
            }
        }
        .hakoDeleteConfirmation(Text("清除全部通知？"), isPresented: $confirmingClearAll,
                                message: Text("将移除当前列表中的 \(store.notifications.count) 条通知。不会批准或拒绝任何登录请求。"),
                                disabled: store.notifications.isEmpty,
                                onDismiss: { clearAllContext = nil }) {
            guard clearAllContext == store.context else { return }
            store.clearAll()
            showNotice("已清除全部通知。")
        }
        .overlay(alignment: .bottom) {
            if let notice {
                Text(notice).font(.footnote).multilineTextAlignment(.center)
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    .foregroundStyle(Color(uiColor: .systemBackground)).background(Color(uiColor: .label), in: RoundedRectangle(cornerRadius: 14))
                    .padding(.horizontal, 20).padding(.bottom, 8).allowsHitTesting(false)
            }
        }
        .sheet(item: $selection) { selected in
            ConsoleLoginPromptSheet(session: selected.session) {
                // Only after a confirmed server response; local removal also
                // prevents an older in-flight list response restoring this row.
                store.markProcessed(selected.notification, context: selected.session.context)
            }
        }
        .sheet(isPresented: $showingServer) { ServerSettingsView() }
        .sheet(item: $selectedPush) { push in
            SettingsSheet(title: "推送详情") {
                Form {
                    Section(push.source) {
                        Text(push.title).font(.headline)
                        if !push.subtitle.isEmpty { Text(push.subtitle).foregroundStyle(.secondary) }
                        if !push.body.isEmpty { Text(push.body) }
                    }
                    Section("收到时间") {
                        Text(push.receivedAt, format: .dateTime.year().month().day().hour().minute().second())
                    }
                }
                .textSelection(.enabled)
            }
        }
        .onChange(of: store.context) { _, _ in
            selection?.session.active = false; selection = nil; noticeTask?.cancel(); notice = nil
            clearAllContext = nil
            confirmingClearAll = false
        }
        .onChange(of: store.activeIDs) { _, ids in
            guard let selected = selection, !selected.session.busy, selected.session.outcome == nil,
                  store.message == nil, !ids.contains(selected.id) else { return }
            selected.session.invalidate()
        }
        .onDisappear { noticeTask?.cancel(); notice = nil }
    }

    private func notificationRow(_ notification: HakoNotification) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: notification.symbol)
                .font(.system(size: 18, weight: .medium)).foregroundStyle(.blue)
                .frame(width: 34, height: 34)
                .background(Color.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 10) {
                    Text(notification.title).font(.headline)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                    if store.isUnread(notification) {
                        Circle().fill(.blue).frame(width: 8, height: 8).padding(.top, 6).accessibilityHidden(true)
                    }
                }
                Text(notification.summary).font(.subheadline).foregroundStyle(.secondary).lineLimit(3)
                HStack(spacing: 8) {
                    Text(notification.category.title)
                    if let created = notification.createdAt { Text("·"); Text(created, style: .relative) }
                }
                .font(.caption).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, minHeight: 80, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityValue(store.isUnread(notification) ? "未读" : "已读")
    }

    private func open(_ notification: HakoNotification) {
        noticeTask?.cancel(); notice = nil
        store.markRead(notification)
        switch notification.content {
        case .loginRequest(let prompt): selection = NotificationSelection(notification: notification, session: ConsoleLoginPromptSession(prompt: prompt, context: store.context))
        case .push(let push): selectedPush = push
        }
    }
    private func showNotice(_ text: String) {
        noticeTask?.cancel(); notice = text
        noticeTask = Task {
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            notice = nil
        }
    }
}
