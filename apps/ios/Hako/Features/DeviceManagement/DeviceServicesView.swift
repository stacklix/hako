import SwiftUI

struct DeviceServicesView: View {
    let agent: ConsoleAgent
    let entry: ConsoleCapabilityData?
    let loaded: Bool
    @ObservedObject private var client = DeviceMonitorClient.shared
    @State private var starting: Set<String> = []
    @State private var requestIDs: [String: String] = [:]
    @State private var messages: [String: String] = [:]
    @State private var expandedServiceID: String?
    private var online: Bool { agent.online }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !online {
                Label("设备离线，以下为上次检查结果。", systemImage: "clock")
                    .font(.footnote).foregroundStyle(.orange)
            }
            if let error = entry?.error {
                Label(error.localizedDescription, systemImage: "exclamationmark.circle")
                    .font(.footnote).foregroundStyle(.orange).devicePagePanel()
            } else if let entry {
                if entry.version == 1, let snapshot = entry.result?.decode(DeviceServiceSnapshot.self), snapshot.isValid {
                    services(snapshot)
                } else {
                    Text("服务监控数据格式无效，请刷新后重试。")
                        .font(.footnote).foregroundStyle(.orange).devicePagePanel()
                }
            } else {
                Text(loaded ? "未返回服务监控数据，请下拉刷新。" : "等待检查登记服务…")
                    .font(.footnote).foregroundStyle(.secondary).devicePagePanel()
            }
        }
    }

    @ViewBuilder private func services(_ snapshot: DeviceServiceSnapshot) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text("\(snapshot.services.count) 个服务").font(.subheadline.weight(.medium))
            Spacer()
            Text("\(snapshot.services.filter { $0.status == .responding }.count) 个已响应")
                .font(.caption).foregroundStyle(.secondary)
        }
        Text("最近检查 · \(formattedTime(snapshot.collectedAt))")
            .font(.caption).foregroundStyle(.secondary)
        if snapshot.services.isEmpty {
            ContentUnavailableView("尚未登记服务", systemImage: "server.rack",
                description: Text("设备的 server.json 中暂无服务。登记后下拉刷新即可显示。"))
                .devicePagePanel()
        }
        ForEach(snapshot.services) { service in
            serviceRow(service).devicePagePanel()
                .contentShape(Rectangle())
                .onTapGesture { toggleDetails(service) }
                .accessibilityAction(named: "展开或收起服务详情") { toggleDetails(service) }
        }
        ForEach(Array(snapshot.warnings.enumerated()), id: \.offset) { _, warning in
            Text(warning).font(.caption).foregroundStyle(.orange)
        }
        Text("读取设备的 ~/.codex/server.json，检查登记端口与 HTTP 检测地址。开启实时刷新后约每 10 秒检查一次。")
            .font(.caption).foregroundStyle(.secondary)
        Text("HTTP 4xx 仍表示服务已响应，5xx 标记为服务异常；HTTP 响应不代表业务健康检查通过。")
            .font(.caption).foregroundStyle(.secondary)
    }

    private func serviceRow(_ service: DeviceServiceStatus) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline) {
                    Text(service.name).font(.subheadline.weight(.semibold))
                    Spacer(minLength: 12)
                    statusBadge(service.status)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text(service.name).font(.subheadline.weight(.semibold))
                    statusBadge(service.status)
                }
            }
            HStack(spacing: 12) {
                Text("端口 \(service.port.formatted(.number.grouping(.never)))")
                if let http = service.http, let code = http.statusCode {
                    Text("HTTP \(code.formatted(.number.grouping(.never)))")
                    Text("\(http.elapsedMs) ms")
                }
            }
            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            if let description = service.description, !description.isEmpty {
                Text(description).font(.footnote).foregroundStyle(.secondary)
            }
            if let failure = service.http?.failure {
                Text(failure).font(.footnote).foregroundStyle(.orange)
            }
            if service.status == .stopped || service.status == .unknown {
                if let startup = service.startup {
                    Text(startup.message).font(.footnote).foregroundStyle(.secondary)
                } else if !service.canStart && service.status == .stopped {
                    Text("尚未登记启动命令，请在设备的 server.json 中填写 startCommand。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            if let message = messages[service.name] {
                Text(message).font(.footnote).foregroundStyle(.secondary)
            }
            if service.status == .stopped || starting.contains(service.name) {
                Button {
                    Task { await start(service) }
                } label: {
                    Label(starting.contains(service.name) ? "正在启动并检查…" : "启动服务", systemImage: "play.fill")
                }
                .buttonStyle(HakoActionButtonStyle())
                .disabled(!online || !service.canStart || starting.contains(service.name)
                    || agent.capabilities?.contains(where: { $0.name == DeviceServiceCommand.start && $0.version == 1 }) != true)
            }
            if !service.processes.isEmpty {
                HStack {
                    Text("监听进程 · \(service.processes.count)")
                    Spacer()
                    Image(systemName: expandedServiceID == service.id ? "chevron.down" : "chevron.right")
                        .accessibilityHidden(true)
                }
                .font(.footnote).foregroundStyle(HakoStyle.text)
                .accessibilityValue(expandedServiceID == service.id ? "已展开" : "已收起")
                if expandedServiceID == service.id {
                    VStack(alignment: .leading, spacing: 12) {
                        if let url = service.http?.url {
                            Text("探测地址：\(url)").textSelection(.enabled)
                        }
                        ForEach(service.processes) { process in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(process.displayName).fontWeight(.medium)
                                Text("PID \(process.processId.formatted(.number.grouping(.never))) · 运行 \(process.formattedUptime)")
                                Text("监听 IP：" + process.addresses.joined(separator: "、"))
                            }
                        }
                        Text("按端口匹配当前进程，运行时长为采集时的进程存活时间。")
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                }
            }
        }
    }

    private func toggleDetails(_ service: DeviceServiceStatus) {
        guard !service.processes.isEmpty else { return }
        expandedServiceID = expandedServiceID == service.id ? nil : service.id
    }

    @MainActor private func start(_ service: DeviceServiceStatus) async {
        guard service.canStart, online, !starting.contains(service.name) else { return }
        starting.insert(service.name)
        defer { starting.remove(service.name) }
        let context = client.requestContext
        let requestID = requestIDs[service.name] ?? UUID().uuidString.lowercased()
        requestIDs[service.name] = requestID
        messages[service.name] = nil
        do {
            let reply = try await client.invokeAgent(agent, method: DeviceServiceCommand.start, version: 1,
                params: ["name": service.name, "requestId": requestID], as: DeviceServiceStartReply.self)
            guard context == client.requestContext, reply.name == service.name, reply.requestId == requestID else { return }
            messages[service.name] = reply.message
            if ["failed", "exited", "already_listening"].contains(reply.state) { requestIDs[service.name] = nil }
            for attempt in 0..<8 {
                guard context == client.requestContext, !Task.isCancelled, await client.refreshServices(agent) else { return }
                let snapshot = client.deviceData[agent.id]?.entries[DeviceServiceCommand.status]?.result?.decode(DeviceServiceSnapshot.self)
                if let current = snapshot?.services.first(where: { $0.name == service.name }),
                   current.status != .stopped || ["failed", "exited", "unknown"].contains(current.startup?.state ?? "") {
                    messages[service.name] = nil
                    if current.status != .stopped || current.startup?.state != "unknown" { requestIDs[service.name] = nil }
                    return
                }
                if attempt < 7 { try await Task.sleep(for: .seconds(2)) }
            }
            messages[service.name] = "启动命令已提交，端口尚未监听。可稍后下拉刷新或查看设备上的启动日志。"
        } catch {
            guard context == client.requestContext else { return }
            if error is ConsoleAgentError { requestIDs[service.name] = nil }
            messages[service.name] = error.localizedDescription + " 请先刷新确认服务状态。"
            await client.refreshServices(agent)
        }
    }

    private func statusBadge(_ status: DeviceServiceState) -> some View {
        let color: Color
        if !online { color = .secondary }
        else {
            color = switch status {
            case .responding: .green
            case .stopped, .httpError: .red
            case .unreachable, .unknown: .orange
            }
        }
        return Label(status.title, systemImage: "circle.fill")
            .font(.caption).foregroundStyle(color)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(color.opacity(0.1), in: Capsule()).fixedSize()
    }

    private func formattedTime(_ value: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
        return date?.formatted(date: .numeric, time: .standard) ?? value
    }
}
