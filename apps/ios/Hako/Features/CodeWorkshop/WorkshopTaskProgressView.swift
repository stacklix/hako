import Foundation
import Combine

@MainActor final class WorkshopTaskProgress: ObservableObject {
    @Published private(set) var snapshot = TaskProgressSnapshot(tasks: [], warning: nil)
    @Published private(set) var issue: String?
    private var loadedThread: String?

    func watch(conversation: WorkshopConversation, active: Bool) async {
        let thread = conversation.threadId
        if loadedThread != thread {
            snapshot = TaskProgressSnapshot(tasks: [], warning: nil)
            issue = nil
            loadedThread = thread
        }
        guard active, let thread else { return }
        while !Task.isCancelled {
            do {
                let value: TaskProgressSnapshot = try await conversation.store.call(conversation.agent, "tasks.list", ["threadId": thread])
                try Task.checkCancellation()
                guard conversation.scope == conversation.store.scope, conversation.threadId == thread else { return }
                snapshot = value; issue = nil
            } catch {
                if Task.isCancelled { return }
                issue = "任务进度暂未同步，将自动重试。"
            }
            do { try await Task.sleep(for: .seconds(issue == nil ? 3 : 8)) } catch { return }
        }
    }
}
