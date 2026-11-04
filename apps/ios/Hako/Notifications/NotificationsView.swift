import SwiftUI

struct NotificationsView: View {
    @ObservedObject var store: HakoNotificationsStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var selection: NotificationSelection?
    @State private var showingServer = false
    @State private var confirmingClearAll = false
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
                    Text("登录 Hako 服务器后，可查看需要处理的通知。").foregroundStyle(.secondary)
                    Button("服务器与登录") { showingServer = true }
                }
            } else {
                if let message = store.message {
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
                                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                        Button(role: .destructive) {
                                            store.clear(notification)
                                            showNotice(notification.clearFeedback)
                                        } label: { Label("清除", systemImage: "trash") }
                                        .tint(.red)
                                    }
                            }
                        } header: {
                            HStack { Text(category.title); Spacer(); Text("\(items.count) 条待处理") }
                        } footer: {
                            Text(category.footer)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("通知").navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button(role: .destructive) { notice = nil; confirmingClearAll = true } label: {
                        Label("清除全部", systemImage: "trash").foregroundStyle(.red)
                    }
                } label: { Image(systemName: "ellipsis") }
                    .accessibilityLabel("通知操作")
                    .disabled(store.notifications.isEmpty)
                    .confirmationDialog("清除全部通知？", isPresented: $confirmingClearAll, titleVisibility: .visible) {
                        Button("清除全部", role: .destructive) { store.clearAll(); showNotice("已清除全部通知。") }
                        Button("取消", role: .cancel) { }
                    } message: {
                        Text("将移除当前列表中的 \(store.notifications.count) 条通知。不会批准或拒绝任何登录请求。")
                    }
            }
        }
        .overlay(alignment: .bottom) {
            if let notice {
                Text(notice).font(.footnote).multilineTextAlignment(.center)
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    .foregroundStyle(Color(uiColor: .systemBackground)).background(Color(uiColor: .label), in: RoundedRectangle(cornerRadius: 14))
                    .padding(.horizontal, 20).padding(.bottom, 8).allowsHitTesting(false)
            }
        }
        .task { await store.refresh() }
        .sheet(item: $selection, onDismiss: { Task { await store.refresh() } }) { selected in
            ConsoleLoginPromptSheet(session: selected.session) {
                // Only after a confirmed server response; local removal also
                // prevents an older in-flight list response restoring this row.
                store.markProcessed(selected.notification, context: selected.session.context)
            }
        }
        .sheet(isPresented: $showingServer) { ServerSettingsView() }
        .onChange(of: store.context) { _, _ in
            selection?.session.active = false; selection = nil; noticeTask?.cancel(); notice = nil
        }
        .onChange(of: store.activeIDs) { _, ids in
            guard let selected = selection, !selected.session.busy, selected.session.outcome == nil,
                  store.message == nil, !ids.contains(selected.id) else { return }
            selected.session.invalidate()
        }
        .onChange(of: scenePhase) { _, phase in if phase == .active { Task { await store.refresh() } } }
        .onDisappear { noticeTask?.cancel(); notice = nil }
    }

    private func notificationRow(_ notification: HakoNotification) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: notification.symbol).frame(width: 26).padding(.top, 2)
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(notification.title).font(.headline)
                    Spacer(minLength: 4)
                    if let created = notification.createdAt {
                        Text(created, style: .relative).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Text(notification.summary).font(.subheadline).foregroundStyle(.secondary)
            }
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary).padding(.top, 5)
        }.padding(.vertical, 6)
    }

    private func open(_ notification: HakoNotification) {
        noticeTask?.cancel(); notice = nil
        switch notification.content {
        case .loginRequest(let prompt): selection = NotificationSelection(notification: notification, session: ConsoleLoginPromptSession(prompt: prompt, context: store.context))
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
