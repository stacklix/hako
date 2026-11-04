import SwiftUI

struct ConsoleLoginRequestsView: View {
    @ObservedObject var store: ConsoleLoginRequestsStore
    @ObservedObject private var client = ConsoleClient.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var selection: LoginSelection?
    @State private var showingServer = false
    private struct LoginSelection: Identifiable {
        let session: ConsoleLoginPromptSession
        var id: String { session.prompt.id }
    }

    var body: some View {
        List {
            if !client.authenticated || client.logoutPending {
                Section {
                    Text("登录 Hako 服务器后，可查看当前待处理的网页登录和应用授权请求。")
                        .foregroundStyle(.secondary)
                    Button("服务器与登录") { showingServer = true }
                }
            } else {
                if let message = store.message {
                    Section { Label(message, systemImage: "exclamationmark.circle").font(.footnote).foregroundStyle(.secondary) }
                }
                if store.loading && store.requests.isEmpty { Section { ProgressView("正在读取登录请求…") } }
                else if store.requests.isEmpty && store.message == nil {
                    ContentUnavailableView("暂无登录请求", systemImage: "bell", description: Text("网页或应用发起登录后，会显示在这里。"))
                }
                if !store.requests.isEmpty {
                    Section {
                        ForEach(store.requests) { prompt in
                            Button {
                                selection = LoginSelection(session: ConsoleLoginPromptSession(prompt: prompt, context: store.context))
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: prompt.isApplication ? "square.stack.3d.up" : "desktopcomputer")
                                        .frame(width: 26).foregroundStyle(.secondary)
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(prompt.title).font(.headline)
                                        Text(prompt.actionDescription).font(.subheadline).foregroundStyle(.secondary)
                                        Text(prompt.isApplication ? prompt.applicationOrigin : prompt.origin)
                                            .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                        Text([prompt.browser, prompt.clientIP].filter { !$0.isEmpty }.joined(separator: " · "))
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 4)
                                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                                }.padding(.vertical, 5)
                            }.buttonStyle(.plain)
                        }
                    } header: { Text("待处理（\(store.requests.count)）") } footer: {
                        Text("点击请求查看详情并输入原浏览器的六位确认码。打开列表不会批准登录。")
                    }
                }
            }
        }
        .navigationTitle("登录通知").navigationBarTitleDisplayMode(.inline)
        .refreshable { await store.refresh() }
        .task { await store.refresh() }
        .sheet(item: $selection, onDismiss: { Task { await store.refresh() } }) { selected in
            ConsoleLoginPromptSheet(session: selected.session)
        }
        .sheet(isPresented: $showingServer) { ServerSettingsView() }
        .onChange(of: store.context) { _, _ in selection?.session.active = false; selection = nil }
        .onChange(of: store.requests.map(\.id)) { _, ids in
            guard let session = selection?.session, !session.busy, session.outcome == nil, store.message == nil, !ids.contains(session.prompt.id) else { return }
            session.invalidate()
        }
        .onChange(of: scenePhase) { _, phase in if phase == .active { Task { await store.refresh() } } }
    }
}
