import SwiftUI

struct ArcaneHostView: View {
    @ObservedObject var store: ArcaneStore
    let environment: ArcaneEnvironment
    var body: some View {
        ArcaneHostDetails(store: store, environment: environment)
            .id((store.connection?.id ?? "") + ":" + environment.id)
    }
}

private struct ArcaneHostDetails: View {
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var store: ArcaneStore
    let environment: ArcaneEnvironment
    @StateObject private var data = ArcaneHostData()
    @State private var visible = false
    @State private var revision = UUID()
    private var active: Bool { visible && scenePhase == .active }
    private var taskKey: String { "\(active):\(store.connection?.id ?? ""):\(environment.id)" }
    private var cpuCount: Int? { [data.sample?.cpuCount, data.info?.cpuCount].compactMap { $0 }.first { $0 > 0 } }
    private var memoryTotal: Int64? { [data.sample?.memoryTotal, data.info?.memoryTotal].compactMap { $0 }.first { $0 > 0 } }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text(environment.displayName).font(.title2.bold())
                    Label(environment.statusText, systemImage: "server.rack").font(.caption).foregroundStyle(.secondary)
                    TimelineView(.periodic(from: .now, by: 5)) { timeline in
                        let recent = data.sampledAt.map { timeline.date.timeIntervalSince($0) < 15 } ?? false
                        let live = data.connected && recent
                        Label(live ? "实时更新" : data.sample == nil ? "等待资源数据" : "显示上次数据",
                              systemImage: live ? "circle.fill" : "clock")
                            .font(.caption).foregroundStyle(live ? Color.green : Color.secondary)
                    }
                }.padding(.vertical, 6).arcaneRowSeparators()
            }
            resources
            networkPorts
            if let info = data.info { systemInformation(info); dockerInformation(info); counts(info) }
            if data.infoLoading && data.info == nil { Section { ProgressView("正在读取主机信息…").arcaneRowSeparators() } }
            if let error = data.infoError {
                Section {
                    Label(error, systemImage: "exclamationmark.circle").font(.footnote).foregroundStyle(.orange).arcaneRowSeparators()
                    Button("重新读取主机信息") { Task { await refreshInfo() } }.disabled(data.infoLoading)
                }
            }
        }
        .navigationTitle("主机信息").navigationBarTitleDisplayMode(.inline)
        .refreshable { revision = UUID(); await refreshOverview() }
        .onAppear { visible = true }.onDisappear { visible = false }
        .task(id: taskKey) { if active { await refreshOverview() } }
        .task(id: taskKey + revision.uuidString) {
            guard active else { return }
            do { await data.observe(client: try store.client(), environment: environment.id) }
            catch { data.fail(error) }
        }
    }

    private var networkPorts: some View {
        Section {
            if data.portsLoading && data.ports == nil { ProgressView("正在读取网络端口…").arcaneRowSeparators() }
            if let ports = data.ports {
                if ports.isEmpty { Text("没有 Docker 网络端口").foregroundStyle(.secondary).arcaneRowSeparators() }
                ForEach(ports) { container in
                    HStack(alignment: .top, spacing: 12) {
                        Text(container.name).font(.subheadline.weight(.semibold))
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        VStack(alignment: .trailing, spacing: 4) {
                            ForEach(container.ports) { port in
                                Text(port.title).font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
                                    .multilineTextAlignment(.trailing).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }.padding(.vertical, 4).textSelection(.enabled).arcaneRowSeparators()
                }
            }
            if let error = data.portsError {
                Label(error, systemImage: "exclamationmark.circle").font(.footnote).foregroundStyle(.orange).arcaneRowSeparators()
                Button("重新读取端口") { Task { await refreshPorts() } }.disabled(data.portsLoading).arcaneRowSeparators()
            }
        } header: { Text("网络端口") }
    }

    private var resources: some View {
        Section {
            metric("CPU 使用率", icon: "cpu", percent: data.sample?.cpuPercent,
                   detail: cpuCount.flatMap { $0 > 0 ? "\($0) CPU" : nil } ?? "核心数暂不可用")
            metric("内存使用率", icon: "memorychip", percent: ArcaneHostStats.usagePercent(data.sample?.memoryUsage, memoryTotal),
                   detail: ArcaneHostFormat.usage(data.sample?.memoryUsage, memoryTotal))
            metric("磁盘使用率", icon: "internaldrive", percent: data.sample?.diskPercent,
                   detail: ArcaneHostFormat.usage(data.sample?.diskUsage, data.sample?.diskTotal))
            if let error = data.streamError {
                Label(error, systemImage: "exclamationmark.circle").font(.footnote).foregroundStyle(.orange).arcaneRowSeparators()
            }
            if data.sample == nil && data.streamError == nil { ProgressView("正在连接主机资源…").arcaneRowSeparators() }
            ForEach(data.sample?.gpus ?? [], id: \.index) { gpu in
                let used = ArcaneHostFormat.byteCount(gpu.memoryUsed)
                let total = ArcaneHostFormat.byteCount(gpu.memoryTotal)
                metric(gpu.name, icon: "display", percent: ArcaneHostStats.usagePercent(used, total),
                       detail: "显存 " + ArcaneHostFormat.usage(used, total))
            }
        } header: { Text("资源使用") } footer: {
            Text("CPU、内存为当前环境的系统指标。磁盘统计 Arcane 配置的磁盘用量路径所在文件系统，默认是 /，不是所有硬盘容量之和。")
        }
    }

    private func metric(_ title: String, icon: String, percent: Double?, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(title, systemImage: icon).font(.subheadline)
                Spacer(minLength: 12)
                Text(ArcaneHostFormat.percent(percent)).font(.subheadline.weight(.semibold)).monospacedDigit()
            }
            Text(detail).font(.caption).foregroundStyle(.secondary)
            if let percent { ProgressView(value: percent, total: 100).tint(percent >= 90 ? Color.orange : Color.accentColor) }
        }.padding(.vertical, 6).arcaneRowSeparators()
    }

    private func systemInformation(_ info: ArcaneHostInfo) -> some View {
        Section {
            information("主机名称", info.name ?? data.sample?.hostname)
            information("操作系统", info.operatingSystem ?? info.osType ?? data.sample?.platform)
            information("内核版本", info.kernelVersion)
            information("处理器架构", info.architecture ?? data.sample?.architecture)
            information("CPU 核心数", cpuCount.flatMap { $0 > 0 ? String($0) : nil })
            information("内存总量", memoryTotal.map { ArcaneHostFormat.bytes($0) })
        } header: { Text("系统信息") }
    }

    private func dockerInformation(_ info: ArcaneHostInfo) -> some View {
        Section {
            information("Docker 版本", info.serverVersion)
            information("API 版本", info.apiVersion)
            information("存储驱动", info.driver)
            information("日志驱动", info.loggingDriver)
            information("Docker 数据目录", info.dockerRootDir)
        } header: { Text("Docker 信息") }
    }

    private func counts(_ info: ArcaneHostInfo) -> some View {
        Section {
            information("容器总数", count(info.containers))
            information("运行中", count(info.running))
            information("已停止", count(info.stopped))
            information("已暂停", count(info.paused))
            information("镜像", count(info.images))
        } header: { Text("Docker 资源") }
    }
    private func count(_ value: Int?) -> String? { value.flatMap { $0 >= 0 ? String($0) : nil } }
    private func information(_ title: String, _ value: String?) -> some View {
        LabeledContent(title) {
            Text(value.flatMap { $0.isEmpty ? nil : $0 } ?? "—").multilineTextAlignment(.trailing).textSelection(.enabled)
        }.arcaneRowSeparators()
    }
    private func refreshInfo() async {
        do { await data.refresh(client: try store.client(), environment: environment.id) }
        catch { data.fail(error) }
    }
    private func refreshPorts() async {
        do { await data.refreshPorts(client: try store.client(), environment: environment.id) }
        catch { data.failPorts(error) }
    }
    private func refreshOverview() async {
        async let info: Void = refreshInfo()
        async let ports: Void = refreshPorts()
        _ = await (info, ports)
    }
}
