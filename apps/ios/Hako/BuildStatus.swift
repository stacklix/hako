import Foundation
import SwiftUI

enum BuildStatusWorkflow: String, CaseIterable, Identifiable {
    case ios = "ios.yml"
    case server = "server.yml"
    case windows = "windows.yml"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ios: "iOS"
        case .server: "服务端"
        case .windows: "Windows"
        }
    }

    private var stages: [(name: String, title: String)] {
        switch self {
        case .ios: [("snapshot", "Linux 测试"), ("test", "macOS 测试"), ("build", "打包 IPA"), ("deploy", "发布下载页面")]
        case .server: [("test", "服务端测试"), ("changes", "检查发布条件"), ("build", "构建并发布镜像")]
        case .windows: [("build", "构建和打包")]
        }
    }

    var pageURL: URL { URL(string: "https://github.com/stacklix/hako/actions/workflows/\(rawValue)")! }

    func jobTitle(_ name: String) -> String {
        stages.first { $0.name == name }?.title ?? name
    }

    func orderedJobs(_ jobs: [BuildStatusClient.Job]) -> [BuildStatusClient.Job] {
        let stages = self.stages.map { $0.name }
        return jobs.sorted {
            (stages.firstIndex(of: $0.name) ?? stages.count) < (stages.firstIndex(of: $1.name) ?? stages.count)
        }
    }
}

struct BuildStatusClient {
    var session: URLSession = HTTPTransport.shared
    let token: String

    struct Run: Decodable {
        let id: Int
        let runNumber: Int
        let runAttempt: Int
        let status: String
        let conclusion: String?
        let updatedAt: Date

        var refreshInterval: Int {
            status == "completed" || conclusion != nil ? 30 : 5
        }
    }
    struct Job: Decodable, Identifiable {
        struct Step: Decodable {
            let name: String
            let status: String
        }
        let id: Int
        let name: String
        let status: String
        let conclusion: String?
        let steps: [Step]?

        var activeStep: String? {
            steps?.first { $0.status == "in_progress" }?.name
        }
    }
    struct Snapshot {
        let run: Run
        let jobs: [Job]
    }

    private func get<T: Decodable>(_ path: String, as type: T.Type) async throws -> T {
        try Task.checkCancellation()
        let url = URL(string: "https://api.github.com/repos/stacklix/hako/" + path)!
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        if !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await HTTPTransport.data(for: request, using: session, secrets: [token])
        try Task.checkCancellation()
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            switch status {
            case 401:
                throw HakoError(message: "GitHub Token 无效或已过期，请在设置中更新并保存。")
            case 403, 404:
                throw HakoError(message: "无法读取构建状态（HTTP \(status)）。私有仓库需要 Token 可访问 stacklix/hako，并具有 Actions 读取权限；也可能遇到 API 限流，请稍后刷新。")
            case 429:
                throw HakoError(message: "GitHub 请求频率受限，请稍后刷新。")
            default:
                throw HakoError(message: "读取构建状态失败（HTTP \(status)），请稍后刷新。")
            }
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: data)
    }

    func latest(workflow: BuildStatusWorkflow) async throws -> Snapshot? {
        struct Runs: Decodable { let workflowRuns: [Run] }
        struct Jobs: Decodable { let jobs: [Job] }
        let result = try await get("actions/workflows/\(workflow.rawValue)/runs?branch=master&per_page=1", as: Runs.self)
        guard let run = result.workflowRuns.first else { return nil }
        // Pin jobs to this attempt so a rerun never mixes old and new steps.
        let jobs = try await get("actions/runs/\(run.id)/attempts/\(run.runAttempt)/jobs?per_page=100", as: Jobs.self)
        return Snapshot(run: run, jobs: workflow.orderedJobs(jobs.jobs))
    }

    static func statusText(_ status: String, conclusion: String?) -> String {
        if let conclusion {
            switch conclusion {
            case "success": return "已完成"
            case "failure": return "失败"
            case "cancelled": return "已取消"
            case "skipped": return "已跳过"
            case "timed_out": return "超时"
            case "action_required": return "需要操作"
            case "neutral": return "已结束"
            default: return conclusion
            }
        }
        switch status {
        case "queued": return "排队中"
        case "in_progress": return "执行中"
        case "waiting", "pending", "requested": return "等待中"
        case "completed": return "已结束"
        default: return status
        }
    }
}

struct GitHubBuildStatusRows: View {
    let isSettingsVisible: Bool
    @AppStorage("buildStatus.githubWorkflow") private var workflow = BuildStatusWorkflow.ios

    var body: some View {
        Picker("工作流", selection: $workflow) {
            ForEach(BuildStatusWorkflow.allCases) { option in
                Text(option.title).tag(option)
            }
        }
        .pickerStyle(.menu)

        GitHubWorkflowStatusRows(isSettingsVisible: isSettingsVisible, workflow: workflow)
            .id(workflow)
    }
}

private struct GitHubWorkflowStatusRows: View {
    let isSettingsVisible: Bool
    let workflow: BuildStatusWorkflow
    @Environment(\.scenePhase) private var scenePhase
    @State private var snapshot: BuildStatusClient.Snapshot?
    @State private var errorMessage: String?
    @State private var loadingRequest: UUID?
    @State private var loaded = false
    @State private var refreshID = 0
    @State private var checkedAt: Date?

    private var loading: Bool { loadingRequest != nil }
    var body: some View {
        Group {
            if let snapshot {
                LabeledContent("\(workflow.title) #\(snapshot.run.runNumber)", value: BuildStatusClient.statusText(snapshot.run.status, conclusion: snapshot.run.conclusion))
                ForEach(snapshot.jobs) { job in
                    VStack(alignment: .leading, spacing: 4) {
                        LabeledContent(workflow.jobTitle(job.name),
                                       value: BuildStatusClient.statusText(job.status, conclusion: job.conclusion))
                        if let step = job.activeStep {
                            Text(step).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } else if !loaded {
                ProgressView("读取\(workflow.title)构建进度…")
            } else if errorMessage == nil {
                Text("暂无\(workflow.title)构建记录").foregroundStyle(.secondary)
            }
            if let errorMessage {
                Text(errorMessage).font(.footnote).foregroundStyle(.secondary)
            }
            HStack {
                Button("刷新进度") { refreshID += 1 }.disabled(loading)
                Spacer()
                if loading { ProgressView() }
                else if let checkedAt {
                    Text("更新于 \(checkedAt.formatted(date: .omitted, time: .standard))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .task(id: "\(isSettingsVisible)-\(scenePhase)-\(refreshID)") {
                guard isSettingsVisible, scenePhase == .active, !Task.isCancelled else { return }
                repeat {
                    await refresh()
                    guard !Task.isCancelled else { return }
                    // Back off after errors instead of repeatedly hitting a rate limit.
                    let interval = errorMessage == nil ? (snapshot?.run.refreshInterval ?? 30) : 120
                    do { try await Task.sleep(for: .seconds(interval)) }
                    catch { return }
                } while !Task.isCancelled
            }
            Link("在 GitHub 查看", destination: snapshot.map {
                URL(string: "https://github.com/stacklix/hako/actions/runs/\($0.run.id)")!
            } ?? workflow.pageURL)
        }
    }

    @MainActor private func refresh() async {
        guard !Task.isCancelled else { return }
        let request = UUID()
        loadingRequest = request
        defer {
            if loadingRequest == request { loadingRequest = nil }
        }
        do {
            let token = try TokenStore.read()
            let latest = try await BuildStatusClient(token: token).latest(workflow: workflow)
            try Task.checkCancellation()
            guard loadingRequest == request else { return }
            snapshot = latest
            errorMessage = nil
            checkedAt = .now
            loaded = true
        } catch {
            guard !Task.isCancelled, loadingRequest == request else { return }
            errorMessage = error.localizedDescription
            loaded = true
        }
    }
}
