import SwiftUI

struct DeviceProcessesView: View {
    let agent: ConsoleAgent
    let entry: ConsoleCapabilityData?
    let metrics: ConsoleMetrics?
    let loaded: Bool
    private enum Ranking: String, CaseIterable { case cpu = "CPU", memory = "内存" }
    @State private var ranking: Ranking = .cpu

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !agent.online {
                Label("设备离线，以下为上次采样结果。", systemImage: "clock")
                    .font(.footnote).foregroundStyle(.orange)
            }
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("CPU 使用率").font(.caption).foregroundStyle(.secondary)
                    Text(percent(metrics?.cpuUsagePercent)).font(.title2.monospacedDigit().weight(.semibold))
                }.frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 6) {
                    Text("内存使用率").font(.caption).foregroundStyle(.secondary)
                    Text(percent(metrics?.memoryUsagePercent)).font(.title2.monospacedDigit().weight(.semibold))
                    if let metrics {
                        Text(bytes(metrics.memoryUsedBytes) + " / " + bytes(metrics.memoryTotalBytes))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.devicePagePanel()
            if let error = entry?.error {
                Label(error.localizedDescription, systemImage: "exclamationmark.circle")
                    .font(.footnote).foregroundStyle(.orange).devicePagePanel()
            } else if let entry {
                if entry.version == 1, let snapshot = entry.result?.decode(DeviceProcessSnapshot.self), snapshot.isValid {
                    processes(snapshot)
                } else {
                    Text("进程采样数据无效，请刷新后重试。")
                        .font(.footnote).foregroundStyle(.orange).devicePagePanel()
                }
            } else {
                Text(loaded ? "尚未返回进程数据，请下拉刷新。" : "正在采样进程占用…")
                    .font(.footnote).foregroundStyle(.secondary).devicePagePanel()
            }
        }
    }

    @ViewBuilder private func processes(_ snapshot: DeviceProcessSnapshot) -> some View {
        HakoUnderlineTabs(title: "进程排行", options: Ranking.allCases, selection: $ranking) { $0.rawValue }
        VStack(alignment: .leading, spacing: 12) {
            Text(ranking.rawValue + " 占用最高的 10 个进程").font(.subheadline.weight(.medium))
            let rows = ranking == .cpu ? snapshot.cpuTop : snapshot.memoryTop
            if rows.isEmpty {
                Text("暂无可用进程样本。").font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, process in
                if index > 0 { Divider() }
                HStack(alignment: .top, spacing: 10) {
                    Text("\(index + 1)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        .frame(width: 20, alignment: .leading)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(process.processName).font(.subheadline.weight(.medium))
                            .fixedSize(horizontal: false, vertical: true)
                        Text("PID \(process.processId)").font(.caption.monospaced()).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .trailing, spacing: 5) {
                        Text("CPU " + percent(process.cpuUsagePercent))
                        Text("内存 " + bytes(process.memoryBytes)).foregroundStyle(.secondary)
                    }.font(.caption.monospacedDigit())
                }.accessibilityElement(children: .combine)
            }
        }.devicePagePanel()
        Text("\(snapshot.processCount) 个进程 · 最近采样 \(time(snapshot.collectedAt))")
            .font(.caption).foregroundStyle(.secondary)
        Text("开启上方“实时刷新”后自动更新。CPU 按采样期间的占用计算；内存为工作集大小，包含共享页面。")
            .font(.caption).foregroundStyle(.secondary)
    }

    private func percent(_ value: Double?) -> String { value.map { String(format: "%.1f%%", $0) } ?? "—" }
    private func bytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .memory)
    }
    private func time(_ value: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value) else { return "—" }
        return date.formatted(date: .omitted, time: .standard)
    }
}
