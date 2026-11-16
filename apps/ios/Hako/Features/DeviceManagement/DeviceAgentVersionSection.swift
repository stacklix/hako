import SwiftUI

struct DeviceAgentVersionSection: View {
    let agent: ConsoleAgent
    @ObservedObject private var client = DeviceMonitorClient.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var versions: DeviceAgentVersions?
    @State private var loading = false
    @State private var error: String?

    private var supported: Bool {
        agent.capabilities?.contains { $0.name == DeviceAgentVersions.command && $0.version == 1 } == true
    }
    private var context: String {
        "\(client.requestContext)\n\(agent.id)\n\(agent.online)\n\(supported)\n\(scenePhase)"
    }
    private var placeholder: String {
        if !agent.online { return "设备离线" }
        if !supported { return "设备未提供" }
        return loading ? "正在读取…" : "暂时无法读取"
    }
    var body: some View {
        Section {
            fact("Agent", agent.name)
            fact("当前版本", agent.online ? versions?.currentVersion ?? placeholder : placeholder)
            fact("最新版本", agent.online ? versions?.latestVersionLabel ?? placeholder : placeholder)
            fact("期望服务端版本", agent.online ? versions?.expectedServerVersion ?? placeholder : placeholder)
            if agent.online, let versions {
                if let hash = versions.currentBuild.split(separator: "+").last, versions.currentBuild.contains("+") {
                    fact("当前构建", String(hash.prefix(12)))
                }
                if let build = versions.latestBuildId { fact("最新构建", String(build)) }
            }
            if agent.online, supported {
                Button { Task { await refresh() } } label: {
                    HStack {
                        Text("刷新版本信息")
                        Spacer()
                        if loading { ProgressView() }
                    }
                }
                .disabled(loading)
                .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                .alignmentGuide(.listRowSeparatorTrailing) { $0.width }
            }
        } header: {
            Text("Agent 版本信息")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                if !agent.online {
                    Text("设备上线后可读取版本信息。")
                } else if !supported {
                    Text("此设备尚未提供版本查询功能。")
                } else {
                    Text("期望服务端版本由当前 Agent 声明。最新版本指已发布的 Agent 版本，检查结果最多缓存 5 分钟。")
                    if versions?.latestCheckState == .unavailable { Text("设备暂时无法查询发布版本，请稍后重试。") }
                    if let checked = versions?.latestCheckedAt, let date = Self.date(checked) {
                        Text("最近检查：\(date.formatted(date: .abbreviated, time: .standard))")
                    }
                    if let error { Text(error).foregroundStyle(.orange) }
                }
            }
        }
        .task(id: context) {
            guard scenePhase == .active, agent.online, supported else { return }
            await refresh()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
                await refresh()
            }
        }
    }
    private func fact(_ title: String, _ value: String) -> some View {
        LabeledContent(title) { Text(value).multilineTextAlignment(.trailing).textSelection(.enabled) }
            .frame(maxWidth: .infinity, alignment: .leading)
            .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
            .alignmentGuide(.listRowSeparatorTrailing) { $0.width }
    }
    @MainActor private func refresh() async {
        guard !loading, agent.online, supported else { return }
        let requestedContext = context
        loading = true; error = nil
        defer { loading = false }
        do {
            let result = try await client.invokeAgent(agent, method: DeviceAgentVersions.command, version: 1, as: DeviceAgentVersions.self)
            guard !Task.isCancelled, requestedContext == context else { return }
            guard result.isValid else { throw HakoError(message: "设备返回的版本信息无效。") }
            versions = result
        } catch is CancellationError { }
        catch {
            guard !Task.isCancelled, requestedContext == context else { return }
            versions = nil
            self.error = DeviceMonitorFailure.message(for: error)
        }
    }
    private static func date(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}
