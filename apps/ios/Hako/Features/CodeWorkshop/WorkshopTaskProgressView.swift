import Foundation
import Combine
import SwiftUI

struct WorkshopBuildProgressBar: View {
    let conversation: WorkshopConversation
    let references: Set<String>
    let active: Bool
    @Binding var showingDetails: Bool
    @StateObject private var progress = WorkshopTaskProgress()

    var body: some View {
        let visibleTask = progress.snapshot.latestTask(references: references)
        Group {
            if let task = visibleTask {
                Button { showingDetails = true } label: {
                    HStack(spacing: 8) {
                        Image(systemName: task.status == "failed" ? "exclamationmark.circle" : "hammer")
                        Text(task.name).fontWeight(.medium).lineLimit(1)
                        Spacer(minLength: 8)
                        Text(task.currentStage?.name ?? TaskProgressItem.title(task.status))
                            .foregroundStyle(.secondary).lineLimit(1)
                        if progress.issue != nil { Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange) }
                        Image(systemName: "chevron.up").foregroundStyle(.tertiary)
                    }
                    .font(.caption)
                    .padding(.horizontal, 20).frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain).background(HakoStyle.card)
                .accessibilityLabel("最近构建：\(task.name)，\(TaskProgressItem.title(task.status))")
                .accessibilityHint("打开构建进度详情")
            }
        }
        .task(id: "\(active):\(conversation.threadId ?? "")") {
            await progress.watch(conversation: conversation, active: active)
        }
        .onChange(of: visibleTask?.id) { _, id in
            if id == nil { showingDetails = false }
        }
        .sheet(isPresented: $showingDetails) {
            SettingsSheet(title: "构建进度") {
                ScrollView {
                    if let task = visibleTask {
                        TaskProgressCard(tasks: [task], warning: progress.issue ?? progress.snapshot.warning)
                            .id(task.id).padding(20)
                    }
                }
                .background(HakoStyle.background)
            }
            .presentationDetents([.medium, .large])
        }
    }
}

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
                if snapshot != value { snapshot = value }
                if issue != nil { issue = nil }
            } catch {
                if Task.isCancelled { return }
                issue = "任务进度暂未同步，将自动重试。"
            }
            do { try await Task.sleep(for: .seconds(issue == nil ? 3 : 8)) } catch { return }
        }
    }
}
