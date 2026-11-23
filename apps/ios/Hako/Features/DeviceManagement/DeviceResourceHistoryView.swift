import SwiftUI
import Charts

struct DeviceResourceHistoryView: View {
    let agent: ConsoleAgent
    let liveRefresh: Bool
    let refreshID: UUID
    @ObservedObject private var client = DeviceMonitorClient.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var range: DeviceResourceHistoryRange = .fifteenMinutes
    @State private var showsRanges = false
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
                rangeSelector
            }.zIndex(40)
            if let history {
                if history.points.isEmpty {
                    Text("此时间范围暂无历史记录。Kage 运行后每秒采样一次。").font(.footnote).foregroundStyle(.secondary)
                } else {
                    resourceChart(history, cpu: true)
                    resourceChart(history, cpu: false)
                    Text("每个点代表 \(history.bucketDurationText)内有效采样的平均值，末段按实际时长统计。")
                        .font(.caption2).foregroundStyle(.secondary)
                    Text("共 \(history.sampleCount) 次采样 · 按住曲线查看该点的起止时间和数值。")
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
            Text("与实时指标共用每秒采样，每 5 分钟批量写盘，保留最近 7 天；未写盘数据也可查看。Kage 正常退出时保存，异常退出可能丢失最近 5 分钟的数据。")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .devicePagePanel()
        .onDisappear { showsRanges = false }
        .onChange(of: scenePhase) { _, phase in if phase != .active { showsRanges = false } }
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

    private var rangeSelector: some View {
        let accent = HakoStyle.adaptive(0x514298, 0xc5b7ff)
        let selectedFill = HakoStyle.adaptive(0xf0eef8, 0x2b2936)
        return Button { showsRanges.toggle() } label: {
            HStack(spacing: 5) { Text(range.title); Image(systemName: "chevron.down").font(.caption2) }
                .font(.caption.weight(.medium)).foregroundStyle(accent).frame(minHeight: 38)
        }
        .buttonStyle(.plain).accessibilityLabel("历史时间范围")
        .accessibilityValue(range.title + (showsRanges ? "，已展开" : "，已收起"))
        .overlay(alignment: .topTrailing) {
            if showsRanges {
                VStack(spacing: 2) {
                    ForEach(DeviceResourceHistoryRange.allCases) { option in
                        Button { range = option; selectedDate = nil; showsRanges = false } label: {
                            HStack(spacing: 12) {
                                Text(option.title); Spacer(minLength: 4)
                                if range == option { Image(systemName: "checkmark").font(.caption) }
                            }
                            .font(.subheadline).foregroundStyle(range == option ? accent : Color.primary)
                            .padding(.horizontal, 12).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .background(range == option ? selectedFill : .clear, in: RoundedRectangle(cornerRadius: 7))
                            .contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityAddTraits(range == option ? .isSelected : [])
                    }
                }
                .padding(5).frame(width: 174)
                .background(HakoStyle.adaptive(0xffffff, 0x323237), in: RoundedRectangle(cornerRadius: 12))
                .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(HakoStyle.line, lineWidth: 1).allowsHitTesting(false) }
                .shadow(color: .black.opacity(0.16), radius: 12, y: 6).offset(y: 43)
                .accessibilityElement(children: .contain).accessibilityLabel("历史时间范围选项")
                .accessibilityAction(.escape) { showsRanges = false }.zIndex(20)
            }
        }.zIndex(showsRanges ? 20 : 0)
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
        return VStack(alignment: .leading, spacing: 8) {
            Text(cpu ? "CPU" : "内存").font(.subheadline.weight(.medium))
            Text(String(format: "平均 %.1f%%", average))
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            Chart {
                ForEach(Array(history.points.enumerated()), id: \.element.id) { index, point in
                    // A missing bucket splits the series instead of inventing a continuous history.
                    let segment = segmentID(history, index: index)
                    LineMark(x: .value("时间", point.date), y: .value("平均使用率", cpu ? point.cpuUsagePercent : point.memoryUsagePercent),
                             series: .value("平均", "average-\(segment)"))
                        .foregroundStyle(color)
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
                Text(intervalLabel(history.interval(for: selected))
                     + String(format: " · 分段平均 %.1f%%", cpu ? selected.cpuUsagePercent : selected.memoryUsagePercent))
                    .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                Text("该时段共 \(selected.sampleCount) 次有效采样")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func intervalLabel(_ interval: DateInterval) -> String {
        let includesDate = [.day, .week].contains(range)
            || !Calendar.current.isDate(interval.start, inSameDayAs: interval.end)
        let dateStyle: Date.FormatStyle.DateStyle = includesDate ? .numeric : .omitted
        let start = interval.start.formatted(date: dateStyle, time: .standard)
        if interval.duration == 0 { return start + "（当前采样）" }
        return start + " – " + interval.end.formatted(date: dateStyle, time: .standard)
    }

    private func segmentID(_ history: DeviceResourceHistory, index: Int) -> Int64 {
        var start = index
        while start > 0 && history.points[start].timestamp - history.points[start - 1].timestamp <= Int64(history.bucketSeconds) * 1000 { start -= 1 }
        return history.points[start].timestamp
    }
}
