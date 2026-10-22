import Foundation
import SwiftUI

struct BuildStatusClient {
    var session: URLSession = .shared
    let token: String

    struct Run: Decodable {
        let id: Int
        let runNumber: Int
        let runAttempt: Int
        let status: String
        let conclusion: String?
        let updatedAt: Date
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
        let url = URL(string: "https://api.github.com/repos/stacklix/hako/" + path)!
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        if !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await session.data(for: request)
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

    func latest() async throws -> Snapshot? {
        struct Runs: Decodable { let workflowRuns: [Run] }
        struct Jobs: Decodable { let jobs: [Job] }
        let result = try await get("actions/workflows/ios.yml/runs?branch=master&per_page=1", as: Runs.self)
        guard let run = result.workflowRuns.first else { return nil }
        // Pin jobs to this attempt so a rerun never mixes old and new steps.
        let jobs = try await get("actions/runs/\(run.id)/attempts/\(run.runAttempt)/jobs?per_page=100", as: Jobs.self)
        return Snapshot(run: run, jobs: jobs.jobs)
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

struct BuildStatusView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var snapshot: BuildStatusClient.Snapshot?
    @State private var errorMessage: String?
    @State private var loading = false
    @State private var loaded = false
    @State private var refreshID = 0
    @State private var checkedAt: Date?

    var body: some View {
        Section {
            if let snapshot {
                LabeledContent("构建 #\(snapshot.run.runNumber)", value: BuildStatusClient.statusText(snapshot.run.status, conclusion: snapshot.run.conclusion))
                ForEach(snapshot.jobs) { job in
                    VStack(alignment: .leading, spacing: 4) {
                        LabeledContent(job.name == "build" ? "打包" : job.name == "deploy" ? "发布下载页面" : job.name,
                                       value: BuildStatusClient.statusText(job.status, conclusion: job.conclusion))
                        if let step = job.activeStep {
                            Text(step).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } else if !loaded {
                ProgressView("读取构建进度…")
            } else if errorMessage == nil {
                Text("暂无构建记录").foregroundStyle(.secondary)
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
            Link("在 GitHub 查看", destination: URL(string: snapshot.map {
                "https://github.com/stacklix/hako/actions/runs/\($0.run.id)"
            } ?? "https://github.com/stacklix/hako/actions/workflows/ios.yml")!)
        } header: {
            Text("GitHub 构建进度")
        } footer: {
            Text("显示 Hako 主分支最新构建，页面在前台时每 5 秒刷新。可安装版本以已发布的构建时间为准。")
        }
        .task(id: "\(scenePhase)-\(refreshID)") {
            guard scenePhase == .active else { return }
            repeat {
                await refresh()
                // Back off after errors instead of repeatedly hitting a rate limit.
                do { try await Task.sleep(for: .seconds(errorMessage == nil ? 5 : 120)) }
                catch { return }
            } while !Task.isCancelled
        }
    }

    @MainActor private func refresh() async {
        loading = true
        defer { loading = false }
        do {
            let token = try TokenStore.read()
            let latest = try await BuildStatusClient(token: token).latest()
            try Task.checkCancellation()
            snapshot = latest
            errorMessage = nil
            checkedAt = .now
            loaded = true
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
            loaded = true
        }
    }
}
