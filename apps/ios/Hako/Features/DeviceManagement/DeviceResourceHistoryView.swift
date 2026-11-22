import SwiftUI
import Charts

struct DeviceResourceHistoryView: View {
    let agent: ConsoleAgent
    let liveRefresh: Bool
    let refreshID: UUID
    @ObservedObject private var client = DeviceMonitorClient.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var range: DeviceResourceHistoryRange = .hour
    @State private var history: DeviceResourceHistory?
    @State private var error: String?
    @State private var loading = false
    @State private var selectedDate: Date?

    private var taskID: String {
        "\(client.requestContext)-\(client.authenticated)-\(agent.online)-\(range.rawValue)-\(scenePhase)-\(liveRefresh)-\(refreshID)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("历史利用率").font(.subheadline.weight(.semibold))
                Spacer()
                if loading { ProgressView().controlSize(.small) }
            }
            Picker("历史时间范围", selection: $range) {
                ForEach(DeviceResourceHistoryRange.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            if let history {
                if history.points.isEmpty {
                    Text("此时间范围暂无历史记录。Kage 运行后每 10 秒记录一次。").font(.footnote).foregroundStyle(.secondary)
                } else {
                    resourceChart(history, cpu: true)
                    resourceChart(history, cpu: false)
                    Text("共 \(history.sampleCount) 次采样 · 实线为平均值，虚线为峰值；按住曲线查看数值。")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                if let samplingError = history.samplingError {
                    Label(samplingError, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.orange)
                }
                if let last = history.lastSampleAt {
                    Text("最近采样：\(DeviceResourceHistory.date(last).formatted(date: .numeric, time: .standard))")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            } else if !loading && error == nil {
                Text("等待历史数据").font(.footnote).foregroundStyle(.secondary)
            }
            if let error { Text(error).font(.footnote).foregroundStyle(.orange) }
            Text(liveRefresh ? "实时刷新已开启 · 每 10 秒更新历史曲线" : "开启「实时刷新」后自动更新历史曲线")
                .font(.caption2).foregroundStyle(.secondary)
            Text("每 10 秒在设备本机记录，自动保留最近 7 天；Kage 停止或电脑休眠期间没有样本。")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .devicePagePanel()
        .task(id: taskID) {
            guard scenePhase == .active, client.authenticated else { return }
            guard agent.online else { error = "设备离线，暂时无法读取本机历史。"; return }
            if history.map({ $0.to - $0.from != Int64(range.rawValue) * 1000 }) == true {
                history = nil
                selectedDate = nil
            }
            await load()
            guard liveRefresh else { return }
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(10)) }
                catch { return }
                await load()
            }
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            let result = try await client.invokeAgent(agent, method: DeviceResourceHistoryCommand.name, version: 1,
                params: ["rangeSeconds": range.rawValue], as: DeviceResourceHistory.self)
            try Task.checkCancellation()
            guard result.isValid, result.to - result.from == Int64(range.rawValue) * 1000 else {
                throw HakoError(message: "设备返回的历史数据格式无效。")
            }
            history = result
            error = nil
        } catch is CancellationError { }
        catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }

    private func resourceChart(_ history: DeviceResourceHistory, cpu: Bool) -> some View {
        let color: Color = cpu ? .blue : .purple
        let selected = selectedDate.flatMap { date in history.points.min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) } }
        let average = cpu ? history.cpuAverage : history.memoryAverage
        let peak = history.points.map { cpu ? $0.cpuMaxPercent : $0.memoryMaxPercent }.max() ?? 0
        return VStack(alignment: .leading, spacing: 8) {
            Text(cpu ? "CPU" : "内存").font(.subheadline.weight(.medium))
            Text(String(format: "平均 %.1f%% · 峰值 %.1f%%", average, peak))
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            Chart {
                ForEach(Array(history.points.enumerated()), id: \.element.id) { index, point in
                    // A missing bucket splits the series instead of inventing a continuous history.
                    let segment = segmentID(history, index: index)
                    LineMark(x: .value("时间", point.date), y: .value("平均使用率", cpu ? point.cpuUsagePercent : point.memoryUsagePercent),
                             series: .value("平均", "average-\(segment)"))
                        .foregroundStyle(color)
                    LineMark(x: .value("时间", point.date), y: .value("峰值使用率", cpu ? point.cpuMaxPercent : point.memoryMaxPercent),
                             series: .value("峰值", "peak-\(segment)"))
                        .foregroundStyle(color.opacity(0.55)).lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    if history.points.count == 1 {
                        PointMark(x: .value("时间", point.date), y: .value("使用率", cpu ? point.cpuUsagePercent : point.memoryUsagePercent))
                            .foregroundStyle(color)
                    }
                }
                if let selected {
                    RuleMark(x: .value("选中时间", selected.date)).foregroundStyle(.secondary.opacity(0.4))
                }
            }
            .chartYScale(domain: 0...100)
            .chartXScale(domain: DeviceResourceHistory.date(history.from)...DeviceResourceHistory.date(history.to))
            .chartYAxis { AxisMarks(values: [0, 50, 100]) { value in
                AxisGridLine()
                AxisValueLabel { if let percent = value.as(Int.self) { Text("\(percent)%") } }
            } }
            .chartXSelection(value: $selectedDate)
            .frame(height: 150)
            .accessibilityLabel(cpu ? "CPU 历史使用率" : "内存历史使用率")
            if let selected {
                Text(selected.date.formatted(date: range == .week ? .numeric : .omitted, time: .shortened)
                     + String(format: " · 平均 %.1f%% · 峰值 %.1f%%", cpu ? selected.cpuUsagePercent : selected.memoryUsagePercent,
                              cpu ? selected.cpuMaxPercent : selected.memoryMaxPercent))
                    .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
            }
        }
    }

    private func segmentID(_ history: DeviceResourceHistory, index: Int) -> Int64 {
        var start = index
        while start > 0 && history.points[start].timestamp - history.points[start - 1].timestamp <= Int64(history.bucketSeconds) * 1000 { start -= 1 }
        return history.points[start].timestamp
    }
}
