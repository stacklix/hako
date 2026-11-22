import SwiftUI
import UIKit

/// A data-only task surface. Build commands and project-specific adapters live in skills.
struct TaskProgressCard: View {
    let tasks: [TaskProgressItem]
    let warning: String?
    @State private var selectedID: String?
    @State private var details = Set<String>()
    @StateObject private var installer = TaskProgressInstaller()
    private var selected: TaskProgressItem? { tasks.first { $0.id == selectedID } ?? tasks.first }

    var body: some View {
        if let task = selected {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label("任务进度", systemImage: "hammer")
                    Spacer()
                    if tasks.count > 1 { Text("\(tasks.count) 个任务").foregroundStyle(.secondary) }
                }.font(.subheadline.weight(.medium))
                if tasks.count > 1 {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 20) {
                            ForEach(tasks) { item in
                                Button { selectedID = item.id } label: {
                                    Text(item.name).font(.subheadline.weight(task.id == item.id ? .medium : .regular))
                                    .padding(.vertical, 10)
                                    .overlay(alignment: .bottom) { if item.id == task.id { Rectangle().frame(height: 2) } }
                                }
                                .buttonStyle(.plain)
                                .accessibilityAddTraits(task.id == item.id ? .isSelected : [])
                            }
                        }
                    }
                }
                TaskProgressBody(task: task, expanded: Binding(get: { details.contains(task.id) }, set: {
                    if $0 { details.insert(task.id) } else { details.remove(task.id) }
                }), installer: installer)
                if let warning { Text(warning).font(.caption).foregroundStyle(.secondary) }
            }
            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(HakoStyle.card, in: RoundedRectangle(cornerRadius: 14))
            .onChange(of: tasks.map(\.id), initial: true) { _, ids in
                if selectedID == nil || !ids.contains(selectedID!) { selectedID = ids.first }
            }
            .alert(item: $installer.confirmation) { confirmation in
                Alert(title: Text("安装 \(confirmation.task.name)"), message: Text(confirmation.message),
                      primaryButton: .default(Text("安装 \(confirmation.version)")) { installer.confirm(confirmation) },
                      secondaryButton: .cancel())
            }
        }
    }

}

private struct TaskProgressBody: View {
    let task: TaskProgressItem
    @Binding var expanded: Bool
    @ObservedObject var installer: TaskProgressInstaller
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(task.name).font(.subheadline.weight(.medium))
                    Text(task.project + " · " + task.platform).font(.caption).foregroundStyle(.secondary)
                    if let release = task.release { Text(release.version + " (" + release.build + ")").font(.caption).foregroundStyle(.secondary) }
                }
                Spacer(minLength: 8)
                Text(TaskProgressItem.title(task.status)).font(.caption).foregroundStyle(task.status == "failed" ? Color.red : Color.secondary)
            }
            if let summary = task.summary, !summary.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("变更摘要").font(.caption.weight(.medium))
                    Text(summary).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            if !task.stages.isEmpty {
                ProgressView(value: Double(task.completedStages), total: Double(task.stages.count))
                HStack {
                    Text(task.currentStage?.name ?? TaskProgressItem.title(task.status))
                    Spacer()
                    Text("\(task.completedStages)/\(task.stages.count) 阶段").foregroundStyle(.secondary)
                }.font(.caption)
            } else if task.active { ProgressView().frame(maxWidth: .infinity, alignment: .leading) }
            if let message = task.message, !message.isEmpty { Text(message).font(.caption).foregroundStyle(.secondary) }
            TimelineView(.periodic(from: .now, by: 10)) { context in
                if task.stale(at: context.date) { Text("进度暂未更新，结果待确认").font(.caption).foregroundStyle(.orange) }
            }
            DisclosureGroup("阶段详情", isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(task.stages) { stage in
                        LabeledContent(stage.name, value: TaskProgressItem.title(stage.status)).font(.caption)
                    }
                    Text("任务 " + task.id).font(.caption2.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    Text(Date(timeIntervalSince1970: Double(task.updatedAt) / 1000), style: .relative)
                        .font(.caption2).foregroundStyle(.secondary)
                }.padding(.top, 8)
            }.font(.caption)
            if task.release != nil {
                Button { installer.check(task) } label: {
                    Text(installer.busy.contains(task.id) ? "正在检查版本…" : "检查并安装")
                }.buttonStyle(HakoActionButtonStyle()).disabled(installer.busy.contains(task.id))
            }
            if let message = installer.messages[task.id] { Text(message).font(.caption).foregroundStyle(.secondary) }
        }
    }
}

@MainActor private final class TaskProgressInstaller: ObservableObject {
    struct Confirmation: Identifiable {
        let task: TaskProgressItem
        let version: String
        let build: String
        let message: String
        var id: String { task.id }
    }
    @Published var confirmation: Confirmation?
    @Published var busy = Set<String>()
    @Published var messages: [String: String] = [:]

    func confirm(_ value: Confirmation) { check(value.task, confirmed: value.version + ":" + value.build) }
    func check(_ task: TaskProgressItem, confirmed: String? = nil) {
        guard !busy.contains(task.id), let release = task.release else { return }
        busy.insert(task.id); messages[task.id] = nil
        Task {
            defer { busy.remove(task.id) }
            do {
                guard let metadataURL = TaskProgressReleaseMetadata.secureURL(release.metadataUrl),
                      let candidate = TaskProgressVersion(version: release.version, build: release.build) else {
                    throw HakoError(message: "此任务的安装信息无效。")
                }
                let data = try await read(metadataURL, maximum: 64 * 1024)
                let latest = try JSONDecoder().decode(TaskProgressReleaseMetadata.self, from: data)
                guard let ordering = latest.ordering, ordering >= candidate,
                      let manifest = latest.manifestURL(relativeTo: metadataURL) else {
                    throw HakoError(message: "此构建尚未发布，暂不能安装，请稍后重试。")
                }
                let own = Bundle.main.bundleIdentifier == release.bundleId
                let installed = own ? TaskProgressVersion(version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "",
                                                         build: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "") : nil
                if let installed, installed >= ordering {
                    messages[task.id] = "本机已是最新版本或更高版本，无需安装。"
                    return
                }
                let manifestData = try await read(manifest, maximum: 256 * 1024)
                guard latest.validatesManifest(manifestData, bundleId: release.bundleId),
                      let installURL = TaskProgressReleaseMetadata.installationURL(manifest: manifest) else {
                    throw HakoError(message: "安装描述文件与目标应用或版本不一致，已停止安装。")
                }
                if (installed == nil || ordering > candidate), confirmed != latest.version + ":" + latest.build {
                    confirmation = Confirmation(task: task, version: latest.version, build: latest.build,
                        message: (installed == nil ? "无法确认本机此 App 的安装版本。" : "此任务已有更新的发布版本。") +
                            "将安装最新版本 \(latest.version) (\(latest.build))。")
                    return
                }
                // A confirmation always rechecks metadata and the manifest. Opening
                // the system installer does not prove that installation finished.
                let accepted = await UIApplication.shared.open(installURL)
                messages[task.id] = accepted ? "已请求系统安装，尚未确认安装结果。" : "系统未接受安装请求，请稍后重试。"
            } catch {
                if !Task.isCancelled { messages[task.id] = error.localizedDescription }
            }
        }
    }
    private func read(_ url: URL, maximum: Int) async throws -> Data {
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        let (data, response) = try await HTTPTransport.data(for: request, logBody: false)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200, data.count <= maximum else {
            throw HakoError(message: "无法读取最新安装信息，请联网后重试。")
        }
        return data
    }
}
