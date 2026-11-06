import Foundation
import SwiftUI

struct BuildStatusView: View {
    private enum Source: String, CaseIterable {
        case local = "本地"
        case github = "GitHub"
    }

    let isSettingsVisible: Bool
    @State private var source = Source.local

    var body: some View {
        Section("构建进度") {
            HStack(spacing: 25) {
                ForEach(Source.allCases, id: \.self) { option in
                    Button { source = option } label: {
                        Text(option.rawValue)
                            .font(.system(size: 14, weight: source == option ? .semibold : .regular))
                            .foregroundStyle(source == option ? HakoStyle.text : HakoStyle.muted)
                            .padding(.horizontal, 1)
                            .frame(minHeight: 44)
                            .overlay(alignment: .bottom) {
                                Rectangle().fill(source == option ? HakoStyle.text : .clear).frame(height: 2)
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(source == option ? .isSelected : [])
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("构建来源")
            .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
            .alignmentGuide(.listRowSeparatorTrailing) { $0.width }

            switch source {
            case .local: LocalBuildStatusRows(isSettingsVisible: isSettingsVisible)
            case .github: GitHubBuildStatusRows(isSettingsVisible: isSettingsVisible)
            }
        }
    }
}

private struct LocalBuildSnapshot: Decodable {
    struct HostUsage: Decodable {
        let cpuPercent: Double
        let memoryPercent: Double

        var description: String? {
            guard (0...100).contains(cpuPercent), (0...100).contains(memoryPercent) else { return nil }
            let cpu = (cpuPercent / 100).formatted(.percent.precision(.fractionLength(1)))
            let memory = (memoryPercent / 100).formatted(.percent.precision(.fractionLength(1)))
            return "CPU \(cpu) · 内存 \(memory)"
        }
    }

    let updatedAt: Date
    let active: [LocalBuildTask]
    let history: [LocalBuildTask]
    let hostUsage: HostUsage?

    var isStale: Bool { Date.now.timeIntervalSince(updatedAt) > 90 }
}

private struct LocalBuildTask: Decodable, Identifiable {
    enum Phase: String, Decodable, CaseIterable, Identifiable {
        case prepare, preflight, build, sign, package, install, launch, publish

        var id: Self { self }
        var title: String {
            switch self {
            case .prepare: "准备"
            case .preflight: "预检"
            case .build: "编译"
            case .sign: "签名"
            case .package: "打包"
            case .install: "安装"
            case .launch: "启动"
            case .publish: "发布到 chore"
            }
        }
    }

    let id: String
    let target: String
    let project: String?
    let createdAt: Date
    let build: String?
    let summary: String?
    let state: String
    let currentStage: Phase?
    let failedStage: Phase?
    let replacedBy: String?
    let cancellationRequested: Bool?
    let elapsedSeconds: Double?
    let stageDurations: [String: Double]?
    let stages: [String: String]

    var title: String { build.map { "\(target) \($0)" } ?? "\(target) · \(id.prefix(8))" }
    var submitted: String { createdAt.formatted(date: .abbreviated, time: .shortened) }

    var status: (text: String, tint: Color) {
        if state == "running", cancellationRequested == true { return ("取消中", .orange) }
        return switch state {
        case "queued": ("排队中", .orange)
        case "running":
            (currentStage == .publish ? "发布中" : currentStage.map { $0.title + "中" } ?? "运行中", .blue)
        case "succeeded": ("成功", .green)
        case "failed": ("失败", .red)
        case "stalled": ("已停滞", .orange)
        case "cancelled": (replacedBy == nil ? "已取消" : "已被替换", .secondary)
        case "interrupted": ("已中断", .red)
        default: ("状态未知", .secondary)
        }
    }

    var badge: some View {
        Text(status.text)
            .font(.caption)
            .foregroundStyle(status.tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(status.tint.opacity(0.12), in: Capsule())
    }

    func stageDetail(_ phase: Phase) -> String {
        let label = switch stages[phase.rawValue] {
        case "running": state == "stalled" ? "已停滞" : "运行中"
        case "succeeded": phase == .publish ? "已发布" : "已完成"
        case "failed": "失败"
        case "cancelled": "已取消"
        case "skipped": "未执行"
        default: "等待"
        }
        guard let duration = buildDuration(stageDurations?[phase.rawValue]) else { return label }
        return "\(label) · \(duration)"
    }
}

struct LocalBuildStatusRows: View {
    let isSettingsVisible: Bool
    @Environment(\.scenePhase) private var scenePhase
    @State private var snapshot: LocalBuildSnapshot?
    @State private var unavailable = false
    @State private var selectedTask: LocalBuildTask?
    @State private var refreshID = 0

    var body: some View {
        Group {
            heading("当前构建")
                .sheet(item: $selectedTask) { task in
                    LocalBuildTaskSheet(initialTask: task, snapshot: $snapshot, unavailable: $unavailable) {
                        refreshID += 1
                    }
                }
                .task(id: "\(isSettingsVisible)-\(scenePhase)-\(refreshID)") {
                    guard isSettingsVisible, scenePhase == .active else { return }
                    while !Task.isCancelled {
                        await refresh()
                        let interval = unavailable || snapshot?.active.isEmpty != false ? 30 : 5
                        do { try await Task.sleep(for: .seconds(interval)) }
                        catch { return }
                    }
                }
            if let snapshot {
                if unavailable || snapshot.isStale {
                    Text("进度暂未更新 · \(snapshot.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if snapshot.active.isEmpty {
                    Text("暂无进行中的构建").foregroundStyle(.secondary)
                } else {
                    ForEach(snapshot.active) { task in row(task) }
                }
                heading("构建历史")
                if snapshot.history.isEmpty {
                    Text("暂无构建记录").foregroundStyle(.secondary)
                } else {
                    ForEach(snapshot.history.prefix(3)) { task in row(task) }
                }
            } else if unavailable {
                Text("暂时无法获取本地构建进度").foregroundStyle(.secondary)
            } else {
                ProgressView("读取本地构建进度…")
            }
        }
    }

    private func heading(_ title: String) -> some View {
        Text(title)
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityAddTraits(.isHeader)
            .listRowSeparator(.hidden)
    }

    private func row(_ task: LocalBuildTask) -> some View {
        Button { selectedTask = task } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(task.title).font(.subheadline.weight(.medium))
                    Text(task.submitted)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                task.badge
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("查看任务详情")
        .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
        .alignmentGuide(.listRowSeparatorTrailing) { $0.width }
    }

    @MainActor private func refresh() async {
        let url = URL(string: "https://nux.luckyqiao.com/chore/ios/build-status.json")!
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        do {
            let (data, response) = try await HTTPTransport.shared.data(for: request)
            try Task.checkCancellation()
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                unavailable = true
                return
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            snapshot = try decoder.decode(LocalBuildSnapshot.self, from: data)
            unavailable = false
        } catch {
            if !Task.isCancelled { unavailable = true }
        }
    }
}

private struct LocalBuildTaskSheet: View {
    let initialTask: LocalBuildTask
    @Binding var snapshot: LocalBuildSnapshot?
    @Binding var unavailable: Bool
    let onRefresh: () -> Void
    @Environment(\.dismiss) private var dismiss

    private var currentTask: LocalBuildTask? {
        snapshot?.active.first { $0.id == initialTask.id }
            ?? snapshot?.history.first { $0.id == initialTask.id }
    }
    private var task: LocalBuildTask { currentTask ?? initialTask }
    private var hostUsageDescription: String {
        guard !unavailable, let snapshot, !snapshot.isStale, currentTask != nil else { return "暂时无法获取" }
        return snapshot.hostUsage?.description ?? "暂时无法获取"
    }
    private var note: String? {
        if task.state == "running", task.cancellationRequested == true {
            return "停止请求已发送，正在等待 xkode 确认任务结束。"
        }
        return switch task.state {
        case "cancelled": "xkode 已确认取消。已生成的日志和产物会保留。"
        case "failed": "请在构建机通过 xkode 查看该任务的日志。"
        case "stalled": "任务已停滞，请在构建机确认构建进程状态。"
        default: nil
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text(task.target).font(.title2.bold())
                            Spacer()
                            task.badge
                        }
                        Text("Windows · xkode").font(.footnote).foregroundStyle(.secondary)
                        field("任务 ID", task.id, monospaced: true)
                        field("工程", task.project ?? "暂无记录")
                        field("目标", task.target)
                        if let build = task.build { field("构建号", build) }
                        if let summary = task.summary { field("变更摘要", summary) }
                        field("提交时间", task.submitted)
                        field("总耗时", buildDuration(task.elapsedSeconds) ?? (task.state == "queued" ? "尚未开始" : "暂无记录"))
                        if let stage = task.currentStage ?? task.failedStage { field("阶段", stage.title) }
                        if task.state == "running" { field("构建机资源", hostUsageDescription) }
                        if let replacement = task.replacedBy { field("替代任务 ID", replacement, monospaced: true) }
                    }
                    .padding(16)
                    .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))

                    let phases = LocalBuildTask.Phase.allCases.filter { task.stages[$0.rawValue] != nil }
                    if phases.isEmpty {
                        Text("暂无阶段耗时记录").font(.footnote).foregroundStyle(.secondary)
                    } else {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("阶段耗时").font(.headline)
                            ForEach(phases) { phase in field(phase.title, task.stageDetail(phase)) }
                        }
                        .padding(16)
                        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
                    }
                    if let note {
                        Text(note).font(.footnote).foregroundStyle(.secondary)
                    }
                    if unavailable || snapshot?.isStale == true || currentTask == nil {
                        Text("暂时无法更新，当前显示上次任务状态。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .padding(20)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("任务详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: onRefresh) { Image(systemName: "arrow.clockwise") }
                        .accessibilityLabel("刷新任务状态")
                }
            }
        }
        .presentationDragIndicator(.visible)
    }

    private func field(_ label: String, _ value: String, monospaced: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider()
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(monospaced ? .footnote.monospaced() : .subheadline).textSelection(.enabled)
        }
    }
}

private func buildDuration(_ elapsedSeconds: Double?) -> String? {
    guard let seconds = elapsedSeconds, seconds >= 0, seconds <= Double(Int32.max) else { return nil }
    if seconds > 0 && seconds < 1 { return "不足 1 秒" }
    return Duration.seconds(seconds.rounded(.down)).formatted(.units(allowed: [.hours, .minutes, .seconds]))
}
