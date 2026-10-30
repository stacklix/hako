import SwiftUI
import Charts

struct ECSNetworkSections: View {
    let snapshot: ECSSnapshot?
    let monitor: [ECSMonitorPoint]
    @State private var interface = ""

    private var selectedInterface: ECSInterface? {
        let values = snapshot?.interfaces ?? []
        return values.first { $0.name == interface }
            ?? values.first { $0.name == snapshot?.primaryInterface }
            ?? values.first { $0.name != "lo" } ?? values.first
    }
    var body: some View {
        Group {
            summary
            if let sockets = snapshot?.sockets { listeners(sockets) }
            if !monitor.isEmpty { trend }
            if let selected = selectedInterface { interfaceDetails(selected) }
        }
    }

    private var summary: some View {
        Section {
            HStack(alignment: .top, spacing: 8) {
                let up = ECSNetworkRate(selectedInterface?.sendRate)
                let down = ECSNetworkRate(selectedInterface?.receiveRate)
                ECSNetworkMetric(title: "上行", value: up.value, unit: up.unit)
                ECSNetworkMetric(title: "下行", value: down.value, unit: down.unit)
                ForEach([ECSConnectionDirection.outgoing, .incoming]) { direction in
                    NavigationLink {
                        if let snapshot { ECSNetworkConnectionsView(direction: direction, snapshot: snapshot) }
                    } label: {
                        ECSNetworkMetric(title: direction.title,
                            value: direction.count(snapshot?.socketSummary).map { $0.formatted() } ?? "—", unit: "个")
                    }
                    .buttonStyle(.plain)
                    .disabled(snapshot?.socketSummary == nil)
                    .accessibilityHint("查看\(direction.title)的 TCP 连接")
                }
            }.padding(.vertical, 6)
            if let values = snapshot?.interfaces, let selected = selectedInterface {
                Picker("流量网卡", selection: Binding(get: { selected.name }, set: { interface = $0 })) {
                    ForEach(values) { Text($0.name).tag($0.name) }
                }
            }
        } header: { Text("网络概况") } footer: {
            VStack(alignment: .leading, spacing: 5) {
                Text("流量为所选网卡约 1 秒采样；连接数为主机 TCP 已建立连接，按当前监听地址与端口推断，不随网卡切换。点连接数查看详情。")
                if let unknown = snapshot?.socketSummary?.unknown, unknown > 0 {
                    Text("另有 \(unknown) 个连接无法区分方向。").foregroundStyle(.orange)
                }
            }
        }
    }

    private func listeners(_ sockets: [ECSSocket]) -> some View {
        let ports = ECSListeningPort.grouped(sockets)
        return Section {
            ForEach(ports) { port in
                NavigationLink { ECSListeningPortDetails(port: port) } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(port.name).font(.system(.headline, design: .monospaced))
                            Spacer()
                            Text(port.protocolName.uppercased()).font(.caption).foregroundStyle(.secondary)
                        }
                        Text(port.processes).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }.padding(.vertical, 3)
                }
            }
            if ports.isEmpty { Text("当前没有监听端口。").foregroundStyle(.secondary) }
            if let total = snapshot?.totalListeningPorts, ports.count < total {
                Text("共 \(total) 个监听端口，本次返回 \(ports.count) 个，详情地址也可能不完整。")
                    .font(.caption).foregroundStyle(.orange)
            } else if snapshot?.truncated == true {
                Text("快照结果已截断，端口的监听地址可能不完整。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text("监听端口 · \(snapshot?.totalListeningPorts ?? ports.count)")
        } footer: {
            Text("按协议与端口合并 IPv4 / IPv6；点击端口查看监听 IP 和进程。UDP 展示已绑定的端口。")
        }
    }

    private var trend: some View {
        Section("实例内网 · 最近 1 小时") {
            Chart {
                ForEach(monitor) { point in
                    if let value = point.receiveBytesPerSecond {
                        LineMark(x: .value("时间", point.time), y: .value("KiB/s", value / 1024))
                            .foregroundStyle(by: .value("方向", "下行"))
                    }
                    if let value = point.sendBytesPerSecond {
                        LineMark(x: .value("时间", point.time), y: .value("KiB/s", value / 1024))
                            .foregroundStyle(by: .value("方向", "上行"))
                    }
                }
            }.chartYAxisLabel("KiB/s").frame(height: 175)
            if let last = monitor.last {
                Text("监控时间：\(last.time.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("阿里云实例内网 1 分钟均值，与上方网卡短时采样的范围和时段不同。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func interfaceDetails(_ selected: ECSInterface) -> some View {
        Section("网卡 · \(selected.name)") {
            DisclosureGroup("累计流量与丢包") {
                LabeledContent("累计上行", value: ECSFormat.bytes(selected.send))
                LabeledContent("累计下行", value: ECSFormat.bytes(selected.receive))
                LabeledContent("接收 / 发送丢包", value: "\(Int64(selected.receiveDrops)) / \(Int64(selected.sendDrops))")
                Text("来自系统网卡计数，重建网卡或重启可能重置。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct ECSNetworkMetric: View {
    let title: String
    let value: String
    let unit: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
            Text(value).font(.title3.weight(.semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
                .foregroundStyle(.primary)
            Text(unit.isEmpty ? " " : unit).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

private struct ECSListeningPortDetails: View {
    let port: ECSListeningPort
    var body: some View {
        List {
            Section("端口") {
                LabeledContent("端口", value: port.name)
                LabeledContent("协议", value: port.protocolName.uppercased())
            }
            Section("监听地址 · \(port.sockets.count)") {
                ForEach(port.sockets) { socket in
                    VStack(alignment: .leading, spacing: 6) {
                        if let endpoint = ECSSocketEndpoint(socket.local) {
                            LabeledContent(endpoint.family, value: endpoint.address)
                        } else { Text(socket.local).font(.body.monospaced()) }
                        if let name = socket.process { Text(name).font(.subheadline) }
                        if let pid = socket.pid { Text("PID \(pid)").font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
        }.navigationTitle("\(port.protocolName.uppercased()) \(port.name)").textSelection(.enabled)
    }
}

private struct ECSNetworkConnectionsView: View {
    let direction: ECSConnectionDirection
    let snapshot: ECSSnapshot
    private var rows: [ECSSocket] { direction.sockets(snapshot.sockets ?? []) }
    var body: some View {
        List {
            Section {
                LabeledContent("已建立 TCP 连接", value: direction.count(snapshot.socketSummary)?.formatted() ?? "—")
                Text("按快照中的本机监听地址与端口推断方向，监听已关闭或复用源端口时可能无法准确区分。")
                    .font(.footnote).foregroundStyle(.secondary)
                Text("快照：\(Date(timeIntervalSince1970: snapshot.time).formatted(date: .abbreviated, time: .standard))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("连接详情 · \(rows.count)") {
                ForEach(rows) { socket in
                    NavigationLink { ECSNetworkSocketDetails(socket: socket) } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(socket.peer).font(.subheadline.monospaced())
                            Text([socket.process, socket.pid.map { "PID \($0)" }].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                            Text("本机 \(socket.local)").font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                    }
                }
                if rows.isEmpty { Text("本次返回记录中没有此类连接。").foregroundStyle(.secondary) }
                if snapshot.truncated == true {
                    Text("连接总数在截断前统计，列表仅展示本次返回的部分记录。")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
        }.navigationTitle(direction.title)
    }
}

private struct ECSNetworkSocketDetails: View {
    let socket: ECSSocket
    var body: some View {
        List {
            Section("连接信息") {
                LabeledContent("协议", value: socket.protocolName.uppercased())
                LabeledContent("状态", value: socket.state)
                LabeledContent("本机", value: socket.local)
                LabeledContent("对端", value: socket.peer)
                if let name = socket.process { LabeledContent("进程", value: name) }
                if let pid = socket.pid { LabeledContent("PID", value: String(pid)) }
            }
        }.textSelection(.enabled).navigationTitle("连接详情")
    }
}
