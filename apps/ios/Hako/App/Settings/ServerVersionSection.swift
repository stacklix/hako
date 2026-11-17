import SwiftUI

struct ServerVersionSection: View {
    let currentVersion: String
    let active: Bool
    @ObservedObject private var console = ConsoleClient.shared
    @State private var result: (context: String, version: InvestmentDatabaseVersion, date: Date)?
    @State private var failure: (context: String, message: String)?
    @State private var loading: (context: String, id: UUID)?
    @State private var refreshID = 0

    private var taskID: String { "\(console.requestContext)\n\(active)\n\(refreshID)" }
    private var current: InvestmentDatabaseVersion? {
        result?.context == console.requestContext ? result?.version : nil
    }
    private var isLoading: Bool { loading?.context == console.requestContext }
    private var placeholder: String {
        if console.serverURL.isEmpty { return "未配置" }
        if !console.authenticated || console.logoutPending { return "登录后获取" }
        return isLoading ? "正在获取…" : "未能获取"
    }

    var body: some View {
        Section {
            fact("Hako iOS", currentVersion)
            fact("Hako 服务端", console.serverVersionLabel)
            fact("投资数据库", current?.versionLabel ?? placeholder)
            fact("数据库目标版本", current?.expectedVersionLabel ?? placeholder)
            LabeledContent("数据库状态") {
                Text(current?.statusLabel ?? placeholder)
                    .foregroundStyle(current.map { $0.matchesExpected ? Color.secondary : .orange } ?? .secondary)
                    .multilineTextAlignment(.trailing)
            }
            .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
            .alignmentGuide(.listRowSeparatorTrailing) { $0.width }
            Button { refreshID += 1 } label: {
                HStack {
                    Text("刷新版本信息")
                    Spacer()
                    if isLoading { ProgressView() }
                }
            }
            .disabled(console.serverURL.isEmpty || isLoading || !active)
            .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
            .alignmentGuide(.listRowSeparatorTrailing) { $0.width }
        } header: {
            Text("版本信息")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text("数据库版本从服务端实际读取，目标版本由当前服务端声明；登录后可查询。")
                if let result, result.context == console.requestContext {
                    Text("最近检查：\(result.date.formatted(date: .abbreviated, time: .standard))")
                }
                if let failure, failure.context == console.requestContext {
                    Text(failure.message).foregroundStyle(.orange)
                }
            }
        }
        .task(id: taskID) { await refresh() }
    }

    private func fact(_ title: String, _ value: String) -> some View {
        LabeledContent(title) { Text(value).multilineTextAlignment(.trailing).textSelection(.enabled) }
            .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
            .alignmentGuide(.listRowSeparatorTrailing) { $0.width }
    }

    @MainActor private func refresh() async {
        guard active, !console.serverURL.isEmpty else { return }
        let request = UUID(), context = console.requestContext, task = taskID
        let origin = console.serverURL
        loading = (context, request)
        result = nil
        failure = nil
        defer { if loading?.id == request { loading = nil } }
        _ = await console.checkServerVersion(origin: origin)
        guard !Task.isCancelled, taskID == task, console.requestContext == context else { return }
        guard console.authenticated, !console.logoutPending else { return }
        do {
            let data = try await console.send("/api/v1/investment/version", method: "GET", body: nil, logSource: .hako)
            let version = try InvestmentDatabaseVersion.decode(data)
            guard !Task.isCancelled, taskID == task, console.requestContext == context else { return }
            result = (context, version, .now)
        } catch is CancellationError { }
        catch {
            guard !Task.isCancelled, taskID == task, console.requestContext == context else { return }
            failure = (context, "数据库版本查询失败：" + error.localizedDescription)
        }
    }
}
