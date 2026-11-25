import SwiftUI

@MainActor enum WorkshopPinContributor {
    static func register(in registry: HakoPinRegistry) {
        registry.register(applicationID: "代码工坊", route: "conversation", providesPreviewNavigation: true,
            icon: { AnyView(WorkshopPinnedSessionIcon(page: $0)) }) { AnyView(WorkshopPinnedConversation(page: $0)) }
        registry.registerCollection(id: "workshop", title: "工坊会话") { select in
            AnyView(WorkshopQuickAccessView(select: select))
        }
    }

    static func page(for session: WorkshopSession, agent: WorkshopAgent, application: WorkshopApplication,
                     namespace: String) -> HakoPinnedPage? {
        guard UUID(uuidString: session.id) != nil else { return nil }
        return HakoPinnedPage(applicationID: "代码工坊", route: "conversation",
            key: namespace + ":" + agent.id + ":" + session.id.lowercased(),
            title: session.listTitle, subtitle: application.name, symbol: "terminal",
            parameters: ["computerID": agent.id, "threadID": session.id, "namespace": namespace])
    }

    static func page(for conversation: WorkshopConversation) -> HakoPinnedPage? {
        guard let thread = conversation.threadId, UUID(uuidString: thread) != nil else { return nil }
        let namespace = conversation.store.networkNamespace.consoleDigest
        return HakoPinnedPage(applicationID: "代码工坊", route: "conversation",
            key: namespace + ":" + conversation.agent.id + ":" + thread.lowercased(),
            title: conversation.title, subtitle: conversation.application.name, symbol: "terminal",
            parameters: ["computerID": conversation.agent.id, "threadID": thread, "namespace": namespace])
    }
}

private struct WorkshopPinnedConversation: View {
    let page: HakoPinnedPage
    @Environment(\.hakoPinEnter) private var enterPinnedPage
    @ObservedObject private var store = WorkshopRuntime.shared.store
    @State private var conversation: WorkshopConversation?
    @State private var failure: String?
    @State private var attempt = 0

    var body: some View {
        Group {
            if let conversation, conversation.scope == store.scope {
                WorkshopConversationView(conversation: conversation)
            } else if let failure {
                VStack(spacing: 16) {
                    ContentUnavailableView("无法打开会话", systemImage: "terminal", description: Text(failure))
                    Button("重试") { attempt += 1 }.buttonStyle(HakoActionButtonStyle()).padding(.horizontal, 20)
                }
            } else { ProgressView("正在打开会话…").frame(maxWidth: .infinity, maxHeight: .infinity) }
        }
        .background(HakoStyle.background)
        .navigationTitle(page.title).navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if conversation == nil || conversation?.scope != store.scope, let enterPinnedPage {
                ToolbarItem(placement: .topBarLeading) {
                    Button("进入", systemImage: "arrow.up.right", action: enterPinnedPage)
                        .accessibilityLabel("进入" + page.title)
                }
            }
        }
        .task(id: store.scope + "|\(attempt)") {
            conversation = nil; failure = nil
            guard page.parameters["namespace"] == store.networkNamespace.consoleDigest,
                  let computerID = page.parameters["computerID"], let threadID = page.parameters["threadID"] else {
                failure = "服务器或账号已变更，请切换回固定此会话时的账号。"; return
            }
            do {
                let value = try await WorkshopRuntime.shared.pageConversation(computerID: computerID, threadID: threadID, title: page.title)
                try Task.checkCancellation()
                guard page.parameters["namespace"] == store.networkNamespace.consoleDigest else { throw CancellationError() }
                conversation = value
            } catch is CancellationError { }
            catch { failure = error.localizedDescription }
        }
    }
}
